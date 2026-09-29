import Foundation
import marmot_uniffiFFI

// UniFFI 0.29 does not forward Swift task cancellation to native futures. Projection
// subscriptions are account/screen scoped, so cancellation must wake a pending `next()`
// immediately instead of retaining the old account or conversation until another update.
public extension PresentedChatListSubscription {
    func nextCancellable() async throws -> PresentedChatListUpdateFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_presentedchatlistsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypePresentedChatListUpdateFfi.read
        )
    }
}

public extension ChatListWindowSubscription {
    func nextCancellable() async throws -> ChatListWindowSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_chatlistwindowsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeChatListWindowSnapshotFfi.read
        )
    }
}

public extension AccountAttentionSubscription {
    func nextCancellable() async throws -> AccountAttentionSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_accountattentionsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeAccountAttentionSnapshotFfi.read
        )
    }
}

public extension ConversationWindowSubscription {
    func nextCancellable() async throws -> ConversationWindowSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_conversationwindowsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeConversationWindowSnapshotFfi.read
        )
    }
}

public extension BlockListSubscription {
    func nextCancellable() async throws -> BlockListSnapshotFfi? {
        try Task.checkCancellation()
        return try await cancellableProjectionNext(
            uniffi_marmot_uniffi_fn_method_blocklistsubscription_next(uniffiClonePointer()),
            read: FfiConverterTypeBlockListSnapshotFfi.read
        )
    }
}

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
        defer { freeProjectionBuffer(buffer) }
        switch status.code {
        case 0:
            guard let bytes = buffer.data, buffer.len > 0 else { throw ProjectionBridgeError.invalidResponse }
            var reader = (data: Data(bytes: bytes, count: Int(buffer.len)), offset: 1)
            let value: Value?
            switch reader.data[0] {
            case 0: value = nil
            case 1: value = try read(&reader)
            default: throw ProjectionBridgeError.invalidResponse
            }
            guard reader.offset == reader.data.count else { throw ProjectionBridgeError.invalidResponse }
            try Task.checkCancellation()
            return value
        case 1:
            throw try FfiConverterTypeMarmotKitError_lift(status.errorBuf)
        case 3:
            freeProjectionBuffer(status.errorBuf)
            throw CancellationError()
        default:
            freeProjectionBuffer(status.errorBuf)
            throw ProjectionBridgeError.invalidResponse
        }
    } onCancel: {
        future.cancel()
    }
}

private enum ProjectionBridgeError: Error { case invalidResponse }

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
