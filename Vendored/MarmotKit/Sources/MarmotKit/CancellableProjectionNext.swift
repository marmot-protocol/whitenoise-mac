import Foundation
import marmot_uniffiFFI

// UniFFI 0.29 does not forward Swift task cancellation to native futures. Projection
// subscriptions are account/screen scoped, so cancellation must wake a pending `next()`
// immediately instead of retaining the old account or conversation until another update.
//
// MarmotKit 0.16.0 ships `nextCancellable()` for PresentedChatList, ChatListWindow,
// AccountAttention, ConversationWindow and BlockList subscriptions in the generated
// MarmotKit.swift. This file keeps the adapters MDK does not provide yet; delete each one as
// soon as the generated source declares it (Swift rejects the duplicate).

public extension AttachmentTransferSubscription {
    func nextCancellable() async throws -> AttachmentTransferSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_attachmenttransfersubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeAttachmentTransferSnapshotFfi.read
        )
    }
}

public extension OnboardingSubscription {
    func nextCancellable() async throws -> OnboardingSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_onboardingsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeOnboardingSnapshotFfi.read
        )
    }
}

// The runtime event firehose is owned by an `AccountScope` task; without this, an account
// switch would leave the old scope's `next()` parked until some unrelated event arrived.
public extension EventsSubscription {
    func nextCancellable() async throws -> MarmotEventFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_eventssubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeMarmotEventFfi.read
        )
    }
}

private func cancellableProjectionNext<Value>(
    _ handle: UInt64,
    read: (inout (data: Data, offset: Data.Index)) throws -> Value
) async throws -> Value? {
    let future = ProjectionNativeFuture(handle)
    defer { future.free() }
    return try await withTaskCancellationHandler {
        var ready: Int8 = 1
        repeat {
            ready = await withCheckedContinuation { continuation in
                let box = Unmanaged.passRetained(ProjectionPoll(continuation))
                ffi_marmot_uniffi_rust_future_poll_rust_buffer(
                    future.handle,
                    { raw, result in
                        let pointer = UnsafeRawPointer(bitPattern: UInt(raw))!
                        Unmanaged<ProjectionPoll>.fromOpaque(pointer)
                            .takeRetainedValue().continuation.resume(returning: result)
                    },
                    UInt64(UInt(bitPattern: box.toOpaque()))
                )
            }
        } while ready != 0

        var status = RustCallStatus(code: 0, errorBuf: .init(capacity: 0, len: 0, data: nil))
        let buffer = ffi_marmot_uniffi_rust_future_complete_rust_buffer(future.handle, &status)
        defer {
            freeProjectionBuffer(buffer)
            freeProjectionBuffer(status.errorBuf)
        }
        switch status.code {
        case 0:
            var reader = try projectionReader(buffer)
            let tag = reader.data[reader.offset]
            reader.offset += 1
            let value: Value?
            switch tag {
            case 0: value = nil
            case 1: value = try read(&reader)
            default: throw ProjectionBridgeError.invalidResponse
            }
            guard reader.offset == reader.data.count else { throw ProjectionBridgeError.invalidResponse }
            try Task.checkCancellation()
            return value
        case 1:
            // Read rather than lift: the defer owns this buffer even when decoding throws.
            var reader = try projectionReader(status.errorBuf)
            let error = try FfiConverterTypeMarmotKitError.read(from: &reader)
            guard reader.offset == reader.data.count else { throw ProjectionBridgeError.invalidResponse }
            // Cancellation wins over a typed error that completes at the same moment.
            try Task.checkCancellation()
            throw error
        case 2:
            let message = status.errorBuf.data.map {
                String(decoding: UnsafeBufferPointer(start: $0, count: Int(status.errorBuf.len)), as: UTF8.self)
            } ?? "Rust panic"
            throw ProjectionBridgeError.rustPanic(message)
        case 3:
            throw CancellationError()
        default:
            throw ProjectionBridgeError.invalidResponse
        }
    } onCancel: {
        future.cancel()
    }
}

private enum ProjectionBridgeError: Error {
    case invalidResponse
    case rustPanic(String)
}

private func projectionReader(_ buffer: RustBuffer) throws -> (data: Data, offset: Data.Index) {
    guard let bytes = buffer.data, buffer.len > 0 else { throw ProjectionBridgeError.invalidResponse }
    return (Data(bytesNoCopy: bytes, count: Int(buffer.len), deallocator: .none), 0)
}

private final class ProjectionPoll {
    let continuation: CheckedContinuation<Int8, Never>

    init(_ continuation: CheckedContinuation<Int8, Never>) {
        self.continuation = continuation
    }
}

private final class ProjectionNativeFuture: @unchecked Sendable {
    let handle: UInt64
    private let lock = NSLock()
    private var freed = false

    init(_ handle: UInt64) {
        self.handle = handle
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        if !freed {
            ffi_marmot_uniffi_rust_future_cancel_rust_buffer(handle)
        }
    }

    func free() {
        lock.lock()
        defer { lock.unlock() }
        guard !freed else { return }
        freed = true
        ffi_marmot_uniffi_rust_future_free_rust_buffer(handle)
    }
}

private func freeProjectionBuffer(_ buffer: RustBuffer) {
    guard buffer.capacity > 0 || buffer.data != nil else { return }
    var status = RustCallStatus(code: 0, errorBuf: .init(capacity: 0, len: 0, data: nil))
    ffi_marmot_uniffi_rustbuffer_free(buffer, &status)
    precondition(status.code == 0, "Unable to free UniFFI buffer")
}
