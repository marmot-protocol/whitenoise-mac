import MarmotKit

// UniFFI generates plain value records for these FFI types and declares no Sendable
// conformances. WorkspaceState marshals them across its off-main FFI boundary (see
// `runOffMain`); each is an immutable snapshot produced by a single Rust call, so an
// unchecked Sendable conformance is sound. `@retroactive` documents that the app — not
// the generated module — vends the conformance, and silences the cross-module warning.
extension TimelineMessageQueryFfi: @retroactive @unchecked Sendable {}
extension TimelinePageFfi: @retroactive @unchecked Sendable {}
extension ChatListRowFfi: @retroactive @unchecked Sendable {}
extension AppMessageRecordFfi: @retroactive @unchecked Sendable {}
