import Foundation
import MarmotKit

/// Plain-language lines for a relay or inbox step's findings: what is wrong with the list, each
/// affected relay by host, then what the person can do next. Ported from `whitenoise-ios`'s
/// `AccountSetupRelayFindingPresentation`.
///
/// Lines are catalog keys, resolved at render time in the view's locale, so a host is carried
/// beside its key instead of baked into a string.
nonisolated enum AccountSetupRelayFindings {
    struct Line: Hashable {
        /// A catalog key. When `embedsHost` is set it is a format with one `%@` for the host.
        let key: String
        /// The relay the line is about, as bounded display text.
        var host: String?
        /// Whether `key` interpolates `host`; otherwise the host, if any, prints under the line.
        var embedsHost = false

        func text(locale: Locale) -> String {
            let format = L10n.string(key, locale: locale)
            guard embedsHost, let host else { return format }
            return String(format: format, locale: locale, host)
        }
    }

    static func lines(
        step: OnboardingStepFfi, findings: [OnboardingFindingFfi], actions: [OnboardingActionFfi]
    ) -> [Line] {
        let inbox = step == .inboxRelays
        // A relay that answered is not a problem, and MDK warns it doesn't prove write support.
        let problems = findings.filter { $0.issue != .inspectionCompleted && $0.outcome != .success }
        // Relays searched for the record are not necessarily in the person's list.
        let isLookup: (OnboardingFindingFfi) -> Bool = {
            $0.context == .recordDiscovery || $0.context == .repairApproval
        }
        let listProblems = problems.filter { !isLookup($0) }
        let lookupProblems = problems.filter(isLookup)
        let render: ([OnboardingFindingFfi]) -> [Line] = { group in
            group.filter { $0.endpoint == nil }.compactMap { listLine($0, inbox: inbox) }
                + group.filter { $0.endpoint != nil }.compactMap(relayLine)
        }

        var lines = render(listProblems)
        let routeFailed = listProblems.contains {
            $0.issue == .noUsableRoute || ($0.context == .declaredRoute && $0.endpoint != nil)
        }
        if routeFailed { lines.append(routeAdvice(inbox: inbox, actions: actions)) }
        // Introduce the searched relays even when MDK reports only their individual failures.
        if lookupProblems.contains(where: { $0.endpoint != nil }) {
            lines.append(Line(key: searchIncompleteKey(inbox: inbox)))
        }
        lines += render(lookupProblems)

        var seen: Set<Line> = []
        return lines.filter { seen.insert($0).inserted }
    }

    /// The relay's host as bounded, untrusted display text: bidi, control and other invisible
    /// format scalars removed, capped at 120 characters. Nil when nothing visible is left.
    static func host(_ endpoint: String) -> String? {
        let bounded = String(String.UnicodeScalarView(endpoint.unicodeScalars.prefix(512)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let host = URLComponents(string: bounded)?.host.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let visible = String(
            String.UnicodeScalarView(
                (host ?? bounded).unicodeScalars.filter { scalar in
                    switch scalar.properties.generalCategory {
                    case .control, .format, .lineSeparator, .paragraphSeparator: false
                    default: !scalar.properties.isWhitespace || scalar == " "
                    }
                }
            )
        )
        .trimmingCharacters(in: .whitespaces)
        guard !visible.isEmpty else { return nil }
        return String(visible.prefix(120))
    }

    private static func searchIncompleteKey(inbox: Bool) -> String {
        inbox
            ? "Some relays couldn’t be searched for your message inbox."
            : "Some relays couldn’t be searched for your relay list."
    }

    private static func listLine(_ finding: OnboardingFindingFfi, inbox: Bool) -> Line? {
        let key: String? =
            switch finding.issue {
            // A relay that answered but demanded sign-in or payment also leaves no route, so
            // don't claim silence.
            case .noUsableRoute:
                inbox
                    ? "Your message inbox has no relay White Noise can use."
                    : "Your relay list has no relay White Noise can use."
            case .missing:
                inbox ? "White Noise couldn’t find your message inbox." : "White Noise couldn’t find your relay list."
            case .malformed:
                inbox ? "Your message inbox couldn’t be read." : "Your relay list couldn’t be read."
            case .tooManyRelays:
                inbox ? "Your message inbox lists too many relays." : "Your relay list has too many relays."
            case .discoveryIncomplete:
                searchIncompleteKey(inbox: inbox)
            case .unreachable, .timedOut:
                inbox
                    ? "White Noise couldn’t reach a relay to look up your message inbox."
                    : "White Noise couldn’t reach a relay to look up your relay list."
            case .recordChanged:
                inbox
                    ? "Your message inbox changed during sign-in. Check it again before saving a fix."
                    : "Your relay list changed during sign-in. Check it again before saving a fix."
            case .publicationFailed:
                inbox ? "Your updated message inbox wasn’t published." : "Your updated relay list wasn’t published."
            default:
                AccountSetupGuide.issueKey(finding.issue)
            }
        return key.map { Line(key: $0) }
    }

    private static func relayLine(_ finding: OnboardingFindingFfi) -> Line? {
        guard let host = finding.endpoint.flatMap(host) else {
            return AccountSetupGuide.issueKey(finding.issue).map { Line(key: $0) }
        }
        let key: String? =
            switch finding.issue {
            case .unreachable: "%@ couldn’t be reached."
            case .timedOut: "%@ didn’t answer in time."
            case .authenticationRequired: "%@ requires sign-in that White Noise couldn’t complete."
            case .paymentRequired: "%@ requires payment."
            case .accessRestricted: "%@ restricts who can use it."
            // Policy rejects an address in the published list; a query failure is the relay
            // refusing the request.
            case .invalidRelay where finding.context == .publishedDeclaration: "%@ isn’t a valid relay address."
            case .invalidRelay: "%@ refused White Noise’s request."
            case .retiredRelay: "%@ is no longer supported."
            case .unsafeRelay: "%@ isn’t safe to connect to."
            default: nil
            }
        if let key { return Line(key: key, host: host, embedsHost: true) }
        return AccountSetupGuide.issueKey(finding.issue).map { Line(key: $0, host: host) }
    }

    /// Only suggest changes the current step offers; otherwise the list can only be fixed
    /// elsewhere.
    private static func routeAdvice(inbox: Bool, actions: [OnboardingActionFfi]) -> Line {
        if actions.contains(.useRecommendedRelays) {
            return Line(
                key: inbox
                    ? "Add White Noise’s default relays to your message inbox to continue."
                    : "Add White Noise’s default relays to your relay list to continue."
            )
        }
        if actions.contains(.editRelays) {
            return Line(
                key: inbox
                    ? "Add a relay that works to your message inbox to continue."
                    : "Add a relay that works to your relay list to continue."
            )
        }
        return Line(
            key: inbox
                ? "If this keeps happening, add a relay that works to your message inbox in another Nostr app, then sign in again."
                : "If this keeps happening, add a relay that works to your relay list in another Nostr app, then sign in again."
        )
    }
}
