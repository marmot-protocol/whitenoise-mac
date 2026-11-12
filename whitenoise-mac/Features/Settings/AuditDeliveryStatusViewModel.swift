import Foundation
import MarmotKit
import Observation

/// Whether this Mac's diagnostic logs are reaching White Noise (MarmotKit 0.16.0 v5 delivery
/// status). Read from local files; reading never sends anything.
///
/// Privacy & Security shows `summary`, one line for the whole Mac; Developer mode lists every
/// account's figures. A paused account stays paused across restarts until a configuration change
/// or `postAuditLogTrackerUpdateV5`, which is what Upload Now calls.
@MainActor
@Observable
final class AuditDeliveryStatusViewModel {
    private(set) var statuses: [AuditDeliveryStatusV5Ffi] = []
    private(set) var error: String?

    @ObservationIgnored private let runtime: (any MarmotRuntime)?

    init(runtime: (any MarmotRuntime)?) {
        self.runtime = runtime
    }

    /// `nil` when no account has a destination to send to: then logs only stay on this Mac, which
    /// the page already says.
    var summary: AuditDeliverySummary? {
        AuditDeliverySummary(statuses: statuses)
    }

    func load() async {
        guard let runtime else { return }
        do {
            let loaded = try await FFIExecutor.run { [runtime] in try runtime.auditDeliveryStatusV5() }
            guard !Task.isCancelled else { return }
            statuses = loaded
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = UserFacingError.message(for: error)
        }
    }

    static func preview(_ statuses: [AuditDeliveryStatusV5Ffi]) -> AuditDeliveryStatusViewModel {
        let model = AuditDeliveryStatusViewModel(runtime: nil)
        model.statuses = statuses
        return model
    }
}

/// Delivery across every account with a destination, as one statement.
struct AuditDeliverySummary: Equatable {
    enum State: Equatable {
        /// At least one account stopped sending until the user acts. Carries the HTTP status of
        /// the refusal when the receiver gave one.
        case paused(httpStatus: UInt16?)
        /// Attempts are failing but will be retried on their own.
        case retrying
        case upToDate
        case neverSent
    }

    let state: State
    /// The most recent successful delivery of any account.
    let lastSuccess: Date?

    init?(statuses: [AuditDeliveryStatusV5Ffi]) {
        let configured = statuses.filter(\.destinationConfigured)
        guard !configured.isEmpty else { return nil }
        lastSuccess = configured.compactMap(\.lastSuccessAtMs).max().map(Date.init(unixMilliseconds:))
        if let paused = configured.first(where: \.paused) {
            state = .paused(httpStatus: paused.lastFailure?.httpStatus)
        } else if configured.contains(where: { $0.consecutiveFailures > 0 }) {
            state = .retrying
        } else if lastSuccess != nil {
            state = .upToDate
        } else {
            state = .neverSent
        }
    }

    var message: String {
        switch state {
        case .paused(let httpStatus?):
            String(
                format: L10n.string(
                    "Sending diagnostic logs is paused because the server refused them (HTTP %d). Upload Now tries again."
                ),
                Int(httpStatus)
            )
        case .paused(nil):
            L10n.string("Sending diagnostic logs is paused. Upload Now tries again.")
        case .retrying:
            L10n.string("Diagnostic logs couldn't be sent. White Noise will keep trying.")
        case .upToDate, .neverSent:
            lastSentMessage
        }
    }

    private var lastSentMessage: String {
        guard let lastSuccess else { return L10n.string("No diagnostic logs have been sent yet.") }
        return String(
            format: L10n.string("Last sent %@."),
            lastSuccess.formatted(.relative(presentation: .named).locale(AppLanguage.currentLocale))
        )
    }
}

extension Date {
    nonisolated init(unixMilliseconds: UInt64) {
        self.init(timeIntervalSince1970: TimeInterval(unixMilliseconds) / 1000)
    }
}

/// Short developer-facing names for why a delivery attempt failed.
nonisolated enum AuditDeliveryFailurePresentation {
    static func label(_ kind: AuditDeliveryFailureKindV5Ffi) -> String {
        switch kind {
        case .stateOverLimit: L10n.string("Delivery state over limit")
        case .tooManyOpenFiles: L10n.string("Too many open files")
        case .localIo: L10n.string("Local file error")
        case .localBlocked: L10n.string("Blocked on this Mac")
        case .receiverBlocked: L10n.string("Refused by the server")
        case .receiverRejected: L10n.string("Rejected by the server")
        case .receiverRetryable: L10n.string("Server asked to retry")
        case .noResponse: L10n.string("No response")
        case .internal: L10n.string("Internal error")
        }
    }
}
