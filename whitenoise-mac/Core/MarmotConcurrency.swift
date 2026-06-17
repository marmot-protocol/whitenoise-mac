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
extension AccountSummaryFfi: @retroactive @unchecked Sendable {}
extension UserProfileMetadataFfi: @retroactive @unchecked Sendable {}
extension AccountRelayListsFfi: @retroactive @unchecked Sendable {}
extension NotificationSettingsFfi: @retroactive @unchecked Sendable {}
extension RelayTelemetrySettingsFfi: @retroactive @unchecked Sendable {}
extension AuditLogSettingsFfi: @retroactive @unchecked Sendable {}
extension AuditLogFileFfi: @retroactive @unchecked Sendable {}
extension AuditLogTrackerConfigFfi: @retroactive @unchecked Sendable {}
extension MemberRefFfi: @retroactive @unchecked Sendable {}
