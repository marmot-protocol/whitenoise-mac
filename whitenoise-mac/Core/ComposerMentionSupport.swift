//
//  ComposerMentionSupport.swift
//  whitenoise-mac
//
//  Pure @-mention logic ported from the iOS client: detecting the active mention query in a
//  draft, filtering group-member candidates, rewriting the draft on selection, and
//  canonicalizing "@DisplayName" to "@npub…" at send time. No UI or platform state here.
//

import Foundation
import MarmotKit

nonisolated struct ComposerMentionCandidate: Identifiable, Equatable, Sendable {
    let id: String
    let memberIdHex: String
    /// Avatar/profile seed — the member's account id (falls back to the member id).
    let accountIdHex: String
    let displayName: String
    let npub: String

    // Lowercased match fields, precomputed once — `filter` runs on every keystroke.
    let displayNameLowercased: String
    let npubLowercased: String
    let memberIdHexLowercased: String

    init(details: GroupMemberDetailsFfi) {
        memberIdHex = details.memberIdHex
        accountIdHex = details.account ?? details.memberIdHex
        npub = details.npub
        let reference = details.npub.isEmpty ? memberIdHex : details.npub
        displayName = PeerDisplayText.sanitize(details.displayName) ?? DisplayText.short(reference, head: 10, tail: 6)
        id = memberIdHex
        displayNameLowercased = displayName.lowercased()
        npubLowercased = npub.lowercased()
        memberIdHexLowercased = memberIdHex.lowercased()
    }
}

nonisolated enum ComposerMentionQuery {
    struct Session: Equatable {
        let atIndex: String.Index
        let caretIndex: String.Index
        let query: String

        var range: Range<String.Index> { atIndex..<caretIndex }
    }

    static let maxVisibleCandidates = 8
    private static let completeNpubBodyLength = 58

    /// The active mention query anchored at the end of `draft`.
    static func active(in draft: String) -> Session? {
        active(in: draft, upTo: draft.endIndex)
    }

    /// The active mention query immediately left of `caret`: the last `@` before the caret whose
    /// left neighbour is a word boundary, with no whitespace between it and the caret. `nil` when
    /// no query is open. Scoping to the caret lets the user complete a mention mid-message, not
    /// only at the end of the draft.
    static func active(in draft: String, upTo caret: String.Index) -> Session? {
        guard caret <= draft.endIndex else { return nil }
        guard let atIndex = draft[..<caret].lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let queryStart = draft.index(after: atIndex)
        let query = String(draft[queryStart..<caret])
        guard !query.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return Session(atIndex: atIndex, caretIndex: caret, query: query)
    }

    /// A pasted full npub suppresses autocomplete.
    static func looksLikeCompleteNpub(_ query: String) -> Bool {
        query.hasPrefix("npub1") && query.count >= 5 + completeNpubBodyLength
    }

    static func filter(_ candidates: [ComposerMentionCandidate], matching query: String)
        -> [ComposerMentionCandidate]
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [ComposerMentionCandidate]
        if trimmed.isEmpty {
            filtered = candidates
        } else {
            let needle = trimmed.lowercased()
            filtered = candidates.filter { candidate in
                candidate.displayNameLowercased.contains(needle)
                    || candidate.npubLowercased.contains(needle)
                    || candidate.memberIdHexLowercased.contains(needle)
            }
        }
        return Array(filtered.prefix(maxVisibleCandidates))
    }

    static func replacing(session: Session, in draft: String, with displayName: String) -> String {
        var updated = draft
        updated.replaceSubrange(session.range, with: "@\(displayName) ")
        return updated
    }
}

nonisolated enum ComposerMentionCanonicalizer {
    private static let underscoreScalar = UnicodeScalar("_")
    private static let slashScalar = UnicodeScalar("/")

    /// Rewrite every "@DisplayName" in `text` that matches a candidate to "@npub…", so the wire
    /// format carries stable public keys rather than display names.
    static func canonicalize(_ text: String, candidates: [ComposerMentionCandidate]) -> String {
        guard text.contains("@") else { return text }
        let replacements =
            candidates
            .filter { candidate in
                !candidate.npub.isEmpty
                    && !candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { $0.displayName.count > $1.displayName.count }
        guard !replacements.isEmpty else { return text }

        var canonical = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@",
                leftBoundaryAllowsMention(at: index, in: text),
                let match = matchCandidate(in: text, at: index, candidates: replacements)
            {
                canonical += "@\(match.candidate.npub)"
                index = match.endIndex
                continue
            }
            canonical.append(text[index])
            index = text.index(after: index)
        }
        return canonical
    }

    private static func matchCandidate(
        in text: String,
        at atIndex: String.Index,
        candidates: [ComposerMentionCandidate]
    ) -> (candidate: ComposerMentionCandidate, endIndex: String.Index)? {
        let nameStart = text.index(after: atIndex)
        for candidate in candidates {
            guard text[nameStart...].hasPrefix(candidate.displayName) else { continue }
            let nameEnd = text.index(nameStart, offsetBy: candidate.displayName.count)
            guard rightBoundaryAllowsMention(at: nameEnd, in: text) else { continue }
            return (candidate, nameEnd)
        }
        return nil
    }

    private static func leftBoundaryAllowsMention(at atIndex: String.Index, in text: String) -> Bool {
        if atIndex == text.startIndex { return true }
        return isNostrMentionBoundary(text[text.index(before: atIndex)])
    }

    private static func rightBoundaryAllowsMention(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return isNostrMentionBoundary(text[index])
    }

    private static func isNostrMentionBoundary(_ character: Character) -> Bool {
        !character.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == underscoreScalar
                || scalar == slashScalar
        }
    }
}
