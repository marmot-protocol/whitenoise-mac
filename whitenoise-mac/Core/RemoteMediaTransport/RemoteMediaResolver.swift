//
//  RemoteMediaResolver.swift
//  whitenoise-mac
//
//  DNS for the pinned remote-media transport: a bounded pool of uninterruptible resolver
//  workers, and the all-or-nothing admission of the answer set they return.
//

import Darwin
import Foundation

/// The raw outcome of one resolution, before admission.
nonisolated enum RemoteMediaResolverAnswer: Equatable, Sendable {
    /// Every answer the resolver produced, as numeric text, in resolver order.
    case addresses([String])
    /// The resolver produced more than `RemoteMediaResolution.maximumAnswers` answers. Reported
    /// instead of truncated so the admission check always sees the complete set.
    case overflow
    case failed
}

/// Resolves one hostname. Implementations must call `completion` exactly once, and must never
/// block the caller: the system resolver blocks a worker thread in `getaddrinfo`, which nothing
/// can interrupt.
nonisolated protocol RemoteMediaResolving: Sendable {
    func resolve(host: String, completion: @escaping @Sendable (RemoteMediaResolverAnswer) -> Void)
}

/// `getaddrinfo` on a background worker, reporting each answer through `getnameinfo` with
/// `NI_NUMERICHOST` so admission sees exactly the address the kernel would dial.
nonisolated struct SystemRemoteMediaResolver: RemoteMediaResolving {
    private static let workers = DispatchQueue(
        label: "chat.whitenoise.remote-media.dns",
        qos: .utility,
        attributes: .concurrent
    )

    func resolve(host: String, completion: @escaping @Sendable (RemoteMediaResolverAnswer) -> Void) {
        Self.workers.async {
            completion(Self.blockingResolve(host))
        }
    }

    static func blockingResolve(_ host: String) -> RemoteMediaResolverAnswer {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = Int32(IPPROTO_TCP)

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return .failed
        }
        defer { freeaddrinfo(first) }

        var answers: [String] = []
        var node: UnsafeMutablePointer<addrinfo>? = first
        while let current = node {
            guard answers.count < RemoteMediaResolution.maximumAnswers else { return .overflow }
            guard let address = current.pointee.ai_addr else { return .failed }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                address,
                current.pointee.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard status == 0 else { return .failed }
            let text = buffer.withUnsafeBufferPointer { pointer -> String? in
                guard let base = pointer.baseAddress else { return nil }
                return String(cString: base)
            }
            guard let text else { return .failed }
            answers.append(text)
            node = current.pointee.ai_next
        }
        return .addresses(answers)
    }
}

/// A process-wide cap on in-flight resolutions.
///
/// A claimed slot is released by the resolver's own completion, *not* by the caller: a caller
/// that is cancelled or times out returns promptly while its `getaddrinfo` keeps a worker thread
/// pinned until the system resolver gives up. Counting those abandoned workers is the point —
/// with the cap reached, a new fetch fails fast instead of queueing yet another stuck thread.
nonisolated final class RemoteMediaDNSSlots: @unchecked Sendable {
    static let maximumConcurrentResolutions = 6
    static let processWide = RemoteMediaDNSSlots(limit: maximumConcurrentResolutions)

    let limit: Int
    private let lock = NSLock()
    private var inUse = 0

    init(limit: Int) {
        self.limit = limit
    }

    var inUseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return inUse
    }

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard inUse < limit else { return false }
        inUse += 1
        return true
    }

    func release() {
        lock.lock()
        defer { lock.unlock() }
        inUse = max(0, inUse - 1)
    }
}

/// All-or-nothing admission of a resolver answer set.
nonisolated enum RemoteMediaResolution {
    static let maximumAnswers = 64

    /// The complete set is rejected if it is empty, larger than `maximumAnswers`, contains any
    /// answer that is not canonical numeric text, or contains *any* non-public address — a
    /// public answer next to a private one is a rebinding attempt, not a fallback. Nothing is
    /// truncated; duplicates are collapsed only after every answer has been admitted.
    static func admittedAddresses(_ answer: RemoteMediaResolverAnswer) throws -> [RemoteMediaAddress] {
        let texts: [String]
        switch answer {
        case .failed:
            throw RemoteMediaTransportError.resolutionFailed
        case .overflow:
            throw RemoteMediaTransportError.tooManyAnswers
        case .addresses(let answers):
            texts = answers
        }
        guard !texts.isEmpty else { throw RemoteMediaTransportError.resolutionFailed }
        guard texts.count <= maximumAnswers else { throw RemoteMediaTransportError.tooManyAnswers }

        var addresses: [RemoteMediaAddress] = []
        addresses.reserveCapacity(texts.count)
        for text in texts {
            guard let address = RemoteMediaAddress(canonical: text) else {
                throw RemoteMediaTransportError.malformedResolution
            }
            addresses.append(address)
        }
        // The same classifier the URL policy applies to literal hosts, unchanged.
        for text in texts where RemoteImageURLPolicy.isDisallowedHost(text) {
            throw RemoteMediaTransportError.unsafeResolution
        }

        var seen = Set<RemoteMediaAddress>()
        return addresses.filter { seen.insert($0).inserted }
    }
}
