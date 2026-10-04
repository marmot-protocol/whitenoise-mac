//
//  RemoteMediaHTTPParser.swift
//  whitenoise-mac
//
//  A deliberately small HTTP/1.1 client codec for the pinned remote-media transport: one GET
//  request serializer and an incremental response parser that enforces every size bound before
//  it buffers or appends anything.
//

import Foundation

nonisolated struct RemoteMediaHTTPField: Equatable, Sendable {
    /// Lowercased field name.
    let name: String
    /// Field value with surrounding SP/HTAB removed, decoded as ISO-8859-1 so `obs-text` round-trips.
    let value: String
}

nonisolated struct RemoteMediaHTTPResponseHead: Equatable, Sendable {
    let statusCode: Int
    /// `0` for HTTP/1.0, `1` for HTTP/1.1.
    let minorVersion: Int
    let fields: [RemoteMediaHTTPField]

    /// Every value of `name`, case-insensitively, in wire order. Repeated fields are kept apart
    /// so framing checks can tell a duplicate from a single list value.
    func values(for name: String) -> [String] {
        let key = name.lowercased()
        return fields.filter { $0.name == key }.map(\.value)
    }
}

/// Serializes the one request shape the transport ever sends.
nonisolated enum RemoteMediaHTTPRequest {
    /// Deliberately versionless: enough for CDNs that refuse an empty agent, without the
    /// app/OS/CFNetwork version fingerprint `URLSession` used to attach to every avatar fetch.
    static let userAgent = "WhiteNoise"

    /// `GET` in origin-form with the original `Host` (bracketed IPv6, explicit non-443 port),
    /// identity encoding and `Connection: close`. Never carries cookies, credentials, a
    /// referrer, or `Accept-Language`. `target` has already been restricted to visible ASCII.
    static func bytes(for target: RemoteMediaRequestTarget) -> Data {
        var text = "GET \(target.path) HTTP/1.1\r\n"
        text += "Host: \(target.hostHeader)\r\n"
        text += "User-Agent: \(userAgent)\r\n"
        text += "Accept: */*\r\n"
        text += "Accept-Encoding: identity\r\n"
        text += "Connection: close\r\n"
        text += "\r\n"
        return Data(text.utf8)
    }
}

/// Incremental HTTP/1.1 response parser.
///
/// Feed received bytes to `consume(_:)`. It stops at `.headReceived` once a final (non-1xx)
/// response head is parsed, *before* interpreting body framing, so the caller can close a
/// redirect or error response without draining it. Call `beginBody()` to continue, and
/// `finishAtEOF()` when the peer closes. Every bound is checked before bytes are buffered or
/// appended, and all counters are overflow-safe (`x <= limit - used`, never `used + x`).
/// After any thrown error the parser is latched failed.
nonisolated struct RemoteMediaHTTPResponseParser {
    static let maximumBodyBytes = Int(RemoteImageURLPolicy.maxResponseBytes)
    /// Aggregate across every informational head, the final head, and the trailer section.
    static let maximumHeaderBytes = 64 * 1024
    /// Aggregate chunk-size lines, chunk extensions, and chunk-data delimiters.
    static let maximumFramingBytes = 64 * 1024
    static let maximumInformationalResponses = 8

    enum Progress: Equatable, Sendable {
        case needsMoreData
        case headReceived
        case complete
    }

    private enum State: Equatable {
        case head
        case awaitingBodyDecision
        case fixedLength(remaining: Int)
        case chunkSize
        case chunkData(remaining: Int)
        case chunkDataEnd
        case trailers
        case complete
        case failed
    }

    private static let cr: UInt8 = 0x0D
    private static let lf: UInt8 = 0x0A
    private static let sp: UInt8 = 0x20
    private static let htab: UInt8 = 0x09

    private var state: State = .head
    /// Unparsed bytes live in `pending[cursor...]`; the consumed prefix is compacted once per
    /// `consume` so many small frames in one receive stay linear.
    private var pending: [UInt8] = []
    private var cursor = 0
    /// How far (relative to `cursor`) a terminator search has already looked, so a slow drip
    /// of header bytes is scanned once rather than once per byte.
    private var scanned = 0
    private var headerBytes = 0
    private var framingBytes = 0
    private var informationalResponses = 0

    private(set) var head: RemoteMediaHTTPResponseHead?
    private(set) var body = Data()

    init() {}

    var isComplete: Bool { state == .complete }

    mutating func consume(_ data: Data) throws -> Progress {
        do {
            switch state {
            case .failed, .awaitingBodyDecision:
                throw RemoteMediaTransportError.malformedResponse
            case .complete:
                guard data.isEmpty else { throw RemoteMediaTransportError.malformedResponse }
                return .complete
            default:
                break
            }
            if cursor > 0 {
                pending.removeFirst(cursor)
                cursor = 0
            }
            pending.append(contentsOf: data)
            return try advance()
        } catch {
            state = .failed
            throw error
        }
    }

    /// Interprets body framing for the head returned by `.headReceived` and parses any body
    /// bytes that arrived with it.
    mutating func beginBody() throws -> Progress {
        do {
            guard state == .awaitingBodyDecision, let head else {
                throw RemoteMediaTransportError.malformedResponse
            }
            for value in head.values(for: "content-encoding") {
                for token in value.split(separator: ",") where Self.trimmed(token).lowercased() != "identity" {
                    throw RemoteMediaTransportError.unsupportedContentEncoding
                }
            }
            let transferEncodings = head.values(for: "transfer-encoding")
            let contentLengths = head.values(for: "content-length")
            if head.statusCode == 204 || head.statusCode == 304 {
                guard transferEncodings.isEmpty else { throw RemoteMediaTransportError.unsupportedFraming }
                state = .complete
            } else if !transferEncodings.isEmpty {
                guard contentLengths.isEmpty else { throw RemoteMediaTransportError.ambiguousFraming }
                guard transferEncodings.count == 1,
                    Self.trimmed(Substring(transferEncodings[0])).lowercased() == "chunked",
                    head.minorVersion == 1
                else { throw RemoteMediaTransportError.unsupportedFraming }
                state = .chunkSize
            } else if !contentLengths.isEmpty {
                guard contentLengths.count == 1, !contentLengths[0].contains(",") else {
                    throw RemoteMediaTransportError.ambiguousFraming
                }
                let length = try Self.parseContentLength(contentLengths[0])
                body.reserveCapacity(length)
                state = length == 0 ? .complete : .fixedLength(remaining: length)
            } else {
                // Network.framework reports an abrupt TLS EOF without close_notify as a
                // clean receive completion on current macOS. EOF cannot authenticate the
                // end of an unframed image, so never pass close-delimited bytes to a decoder.
                throw RemoteMediaTransportError.unsupportedFraming
            }
            return try advance()
        } catch {
            state = .failed
            throw error
        }
    }

    /// EOF cannot complete a message. Its authenticated HTTP framing must already be complete.
    mutating func finishAtEOF() throws -> Progress {
        switch state {
        case .complete:
            return .complete
        default:
            state = .failed
            throw RemoteMediaTransportError.prematureEOF
        }
    }

    // MARK: - State machine

    private var available: Int { pending.count - cursor }

    private func byte(_ offset: Int) -> UInt8 { pending[cursor + offset] }

    private mutating func advanceCursor(by count: Int) {
        cursor += count
        scanned = 0
    }

    private mutating func advance() throws -> Progress {
        while true {
            switch state {
            case .head:
                guard let end = findDoubleCRLF() else {
                    guard available <= Self.maximumHeaderBytes - headerBytes else {
                        throw RemoteMediaTransportError.headersTooLarge
                    }
                    return .needsMoreData
                }
                let blockLength = end + 4
                guard blockLength <= Self.maximumHeaderBytes - headerBytes else {
                    throw RemoteMediaTransportError.headersTooLarge
                }
                headerBytes += blockLength
                let parsed = try Self.parseHead(Array(pending[cursor..<(cursor + end)]))
                advanceCursor(by: blockLength)
                if (100...199).contains(parsed.statusCode) {
                    guard parsed.statusCode != 101 else { throw RemoteMediaTransportError.unsupportedUpgrade }
                    informationalResponses += 1
                    guard informationalResponses <= Self.maximumInformationalResponses else {
                        throw RemoteMediaTransportError.malformedResponse
                    }
                    continue
                }
                head = parsed
                state = .awaitingBodyDecision
                return .headReceived

            case .awaitingBodyDecision:
                return .headReceived

            case .fixedLength(let remaining):
                guard available > 0 else { return .needsMoreData }
                // `Connection: close` means nothing may follow the declared body.
                guard available <= remaining else { throw RemoteMediaTransportError.malformedResponse }
                let count = available
                try appendBody(count: count)
                state = count == remaining ? .complete : .fixedLength(remaining: remaining - count)
                if count < remaining { return .needsMoreData }

            case .chunkSize:
                guard let lineEnd = findCRLF() else {
                    guard available <= Self.maximumFramingBytes - framingBytes else {
                        throw RemoteMediaTransportError.framingTooLarge
                    }
                    return .needsMoreData
                }
                let lineLength = lineEnd + 2
                guard lineLength <= Self.maximumFramingBytes - framingBytes else {
                    throw RemoteMediaTransportError.framingTooLarge
                }
                framingBytes += lineLength
                let size = try Self.parseChunkSize(pending[cursor..<(cursor + lineEnd)])
                guard size <= Self.maximumBodyBytes - body.count else { throw RemoteMediaTransportError.bodyTooLarge }
                advanceCursor(by: lineLength)
                state = size == 0 ? .trailers : .chunkData(remaining: size)

            case .chunkData(let remaining):
                guard available > 0 else { return .needsMoreData }
                let count = min(remaining, available)
                try appendBody(count: count)
                state = count == remaining ? .chunkDataEnd : .chunkData(remaining: remaining - count)

            case .chunkDataEnd:
                guard available >= 2 else {
                    if available == 1, byte(0) != Self.cr { throw RemoteMediaTransportError.malformedResponse }
                    return .needsMoreData
                }
                guard byte(0) == Self.cr, byte(1) == Self.lf else { throw RemoteMediaTransportError.malformedResponse }
                guard 2 <= Self.maximumFramingBytes - framingBytes else {
                    throw RemoteMediaTransportError.framingTooLarge
                }
                framingBytes += 2
                advanceCursor(by: 2)
                state = .chunkSize

            case .trailers:
                if available >= 1, byte(0) == Self.cr {
                    guard available >= 2 else { return .needsMoreData }
                    guard byte(1) == Self.lf else { throw RemoteMediaTransportError.malformedResponse }
                    guard 2 <= Self.maximumHeaderBytes - headerBytes else {
                        throw RemoteMediaTransportError.headersTooLarge
                    }
                    headerBytes += 2
                    advanceCursor(by: 2)
                    state = .complete
                    continue
                }
                guard let end = findDoubleCRLF() else {
                    guard available <= Self.maximumHeaderBytes - headerBytes else {
                        throw RemoteMediaTransportError.headersTooLarge
                    }
                    return .needsMoreData
                }
                let blockLength = end + 4
                guard blockLength <= Self.maximumHeaderBytes - headerBytes else {
                    throw RemoteMediaTransportError.headersTooLarge
                }
                headerBytes += blockLength
                // Trailers are validated like header fields and then ignored.
                for line in try Self.splitLines(Array(pending[cursor..<(cursor + end)])) {
                    _ = try Self.parseField(line)
                }
                advanceCursor(by: blockLength)
                state = .complete

            case .complete:
                guard available == 0 else { throw RemoteMediaTransportError.malformedResponse }
                return .complete

            case .failed:
                throw RemoteMediaTransportError.malformedResponse
            }
        }
    }

    private mutating func appendBody(count: Int) throws {
        guard count <= Self.maximumBodyBytes - body.count else { throw RemoteMediaTransportError.bodyTooLarge }
        body.append(contentsOf: pending[cursor..<(cursor + count)])
        advanceCursor(by: count)
    }

    /// Offset (relative to `cursor`) of the first `CRLF CRLF`, resuming where the last search
    /// stopped.
    private mutating func findDoubleCRLF() -> Int? {
        var index = max(0, scanned - 3)
        while index + 3 < available {
            if byte(index) == Self.cr, byte(index + 1) == Self.lf, byte(index + 2) == Self.cr,
                byte(index + 3) == Self.lf
            {
                return index
            }
            index += 1
        }
        scanned = available
        return nil
    }

    private mutating func findCRLF() -> Int? {
        var index = max(0, scanned - 1)
        while index + 1 < available {
            if byte(index) == Self.cr, byte(index + 1) == Self.lf { return index }
            index += 1
        }
        scanned = available
        return nil
    }

    // MARK: - Grammar

    /// Splits a header block (without its terminating blank line) on strict `CRLF`. A bare CR
    /// or bare LF anywhere is a request-smuggling-shaped ambiguity and is rejected.
    static func splitLines(_ bytes: [UInt8]) throws -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var start = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case cr:
                guard index + 1 < bytes.count, bytes[index + 1] == lf else {
                    throw RemoteMediaTransportError.malformedResponse
                }
                lines.append(Array(bytes[start..<index]))
                index += 2
                start = index
            case lf:
                throw RemoteMediaTransportError.malformedResponse
            default:
                index += 1
            }
        }
        lines.append(Array(bytes[start..<bytes.count]))
        return lines
    }

    static func parseHead(_ bytes: [UInt8]) throws -> RemoteMediaHTTPResponseHead {
        let lines = try splitLines(bytes)
        guard let statusLine = lines.first else { throw RemoteMediaTransportError.malformedResponse }
        let (statusCode, minorVersion) = try parseStatusLine(statusLine)
        var fields: [RemoteMediaHTTPField] = []
        for line in lines.dropFirst() {
            fields.append(try parseField(line))
        }
        return RemoteMediaHTTPResponseHead(statusCode: statusCode, minorVersion: minorVersion, fields: fields)
    }

    /// `HTTP/1.0` or `HTTP/1.1`, SP, three digits `100...599`, then either the end of the line
    /// or SP and a reason phrase of SP/HTAB/VCHAR/obs-text.
    static func parseStatusLine(_ line: [UInt8]) throws -> (Int, Int) {
        let prefix = Array("HTTP/1.".utf8)
        guard line.count >= 12, Array(line[0..<7]) == prefix,
            line[7] == 0x30 || line[7] == 0x31,
            line[8] == sp,
            (0x31...0x35).contains(line[9]),
            (0x30...0x39).contains(line[10]),
            (0x30...0x39).contains(line[11])
        else { throw RemoteMediaTransportError.malformedResponse }
        if line.count > 12 {
            guard line[12] == sp, line[13...].allSatisfy(isFieldValueByte) else {
                throw RemoteMediaTransportError.malformedResponse
            }
        }
        let status = Int(line[9] - 0x30) * 100 + Int(line[10] - 0x30) * 10 + Int(line[11] - 0x30)
        return (status, Int(line[7] - 0x30))
    }

    /// `token ":" OWS value OWS`. A leading SP/HTAB is obsolete line folding; whitespace
    /// before the colon, an empty name, and any control byte other than HTAB are rejected.
    static func parseField(_ line: [UInt8]) throws -> RemoteMediaHTTPField {
        guard let first = line.first, first != sp, first != htab,
            let colon = line.firstIndex(of: 0x3A), colon > 0,
            line[0..<colon].allSatisfy(isTokenByte)
        else { throw RemoteMediaTransportError.malformedResponse }
        var valueStart = colon + 1
        var valueEnd = line.count
        while valueStart < valueEnd, line[valueStart] == sp || line[valueStart] == htab { valueStart += 1 }
        while valueEnd > valueStart, line[valueEnd - 1] == sp || line[valueEnd - 1] == htab { valueEnd -= 1 }
        let valueBytes = line[valueStart..<valueEnd]
        guard valueBytes.allSatisfy(isFieldValueByte),
            let value = String(bytes: valueBytes, encoding: .isoLatin1)
        else { throw RemoteMediaTransportError.malformedResponse }
        let name = String(decoding: line[0..<colon], as: UTF8.self).lowercased()
        return RemoteMediaHTTPField(name: name, value: value)
    }

    /// `1*HEXDIG [ BWS ";" chunk-ext ]`. Accumulation stops as soon as the value exceeds the
    /// body cap, so no digit count can overflow.
    static func parseChunkSize(_ line: ArraySlice<UInt8>) throws -> Int {
        var index = line.startIndex
        var value = 0
        var digits = 0
        while index < line.endIndex, let digit = hexValue(line[index]) {
            value = value * 16 + digit
            guard value <= maximumBodyBytes else { throw RemoteMediaTransportError.bodyTooLarge }
            digits += 1
            index += 1
        }
        guard digits > 0 else { throw RemoteMediaTransportError.malformedResponse }
        var extensionStart = index
        while extensionStart < line.endIndex, line[extensionStart] == sp || line[extensionStart] == htab {
            extensionStart += 1
        }
        if extensionStart < line.endIndex {
            guard line[extensionStart] == 0x3B,
                line[(extensionStart + 1)...].allSatisfy(isFieldValueByte)
            else { throw RemoteMediaTransportError.malformedResponse }
        } else if extensionStart != index {
            throw RemoteMediaTransportError.malformedResponse
        }
        return value
    }

    static func parseContentLength(_ text: String) throws -> Int {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { throw RemoteMediaTransportError.malformedResponse }
        var value = 0
        for byte in bytes {
            guard (0x30...0x39).contains(byte) else { throw RemoteMediaTransportError.malformedResponse }
            value = value * 10 + Int(byte - 0x30)
            guard value <= maximumBodyBytes else { throw RemoteMediaTransportError.bodyTooLarge }
        }
        return value
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case 0x30...0x39: return Int(byte - 0x30)
        case 0x41...0x46: return Int(byte - 0x41 + 10)
        case 0x61...0x66: return Int(byte - 0x61 + 10)
        default: return nil
        }
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A:
            return true
        case 0x21, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2A, 0x2B, 0x2D, 0x2E, 0x5E, 0x5F, 0x60, 0x7C, 0x7E:
            return true
        default:
            return false
        }
    }

    private static func isFieldValueByte(_ byte: UInt8) -> Bool {
        byte == htab || byte == sp || (0x21...0x7E).contains(byte) || byte >= 0x80
    }

    private static func trimmed(_ text: Substring) -> String {
        text.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
    }
}
