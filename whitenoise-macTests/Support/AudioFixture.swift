//
//  AudioFixture.swift
//  whitenoise-macTests
//

import Foundation

/// Real, decodable audio bytes.
///
/// `AVAudioPlayer` is the thing under test in the playback suites — whether rate control was armed
/// before the buffers were prepared, whether a rate survives `play()` — so it has to be a real
/// player over real audio. A stub would answer for the fake instead of for the trap.
enum AudioFixture {
    /// A silent 16-bit mono PCM WAV. Silence is fine: nothing here listens, and a player over
    /// silence reports the same `duration`, `rate` and `enableRate` as one over a voice note.
    static func silentWAV(seconds: Double = 2, sampleRate: Int = 44_100) -> Data {
        let frameCount = Int(Double(sampleRate) * seconds)
        let bytesPerFrame = 2
        let dataBytes = frameCount * bytesPerFrame

        var wav = Data()
        func appendASCII(_ text: String) { wav.append(contentsOf: Array(text.utf8)) }
        func appendUInt32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
        func appendUInt16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }

        appendASCII("RIFF")
        appendUInt32(UInt32(36 + dataBytes))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)  // PCM header length
        appendUInt16(1)  // PCM, uncompressed
        appendUInt16(1)  // mono
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(sampleRate * bytesPerFrame))  // byte rate
        appendUInt16(UInt16(bytesPerFrame))  // block align
        appendUInt16(16)  // bits per sample
        appendASCII("data")
        appendUInt32(UInt32(dataBytes))
        wav.append(Data(count: dataBytes))
        return wav
    }
}
