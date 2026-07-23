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

/// A picker-selected mention tied to the exact visible range in the composer. Keeping the
/// canonical npub here avoids re-identifying a selected member by a non-unique display name.
nonisolated struct ComposerMentionSelection: Hashable, Sendable {
    let location: Int
    let length: Int
    let displayText: String
    let npub: String

    init(range: NSRange, displayText: String, npub: String) {
        location = range.location
        length = range.length
        self.displayText = displayText
        self.npub = npub
    }

    var range: NSRange { NSRange(location: location, length: length) }
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
    static func canonicalize(
        _ text: String,
        selections: [ComposerMentionSelection] = [],
        candidates: [ComposerMentionCandidate]
    ) -> String {
        guard text.contains("@") else { return text }
        let canonical = canonicalizeSelections(in: text, selections: selections)
        let replacements =
            Dictionary(grouping: candidates, by: \.displayName)
            .values
            // A typed name is safe to infer only when every matching roster entry identifies the
            // same npub. Picker selections above remain unambiguous even for duplicate names.
            .compactMap { matches -> ComposerMentionCandidate? in
                let npubs = Set(matches.map(\.npub).filter { !$0.isEmpty })
                guard npubs.count == 1, let onlyNpub = npubs.first else { return nil }
                return matches.first { $0.npub == onlyNpub }
            }
            .filter { candidate in
                !candidate.npub.isEmpty
                    && !candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    // A peer-controlled name that is itself a profile reference must never
                    // retarget the literal reference the sender typed. Picker selections were
                    // already canonicalized by their exact range above and remain supported.
                    && !MarkdownLinkPolicy.isResolvableProfileReference(candidate.displayName)
            }
            .sorted { $0.displayName.count > $1.displayName.count }
        guard !replacements.isEmpty else { return canonical }

        var inferred = ""
        var index = canonical.startIndex
        while index < canonical.endIndex {
            if canonical[index] == "@",
                leftBoundaryAllowsMention(at: index, in: canonical),
                let match = matchCandidate(in: canonical, at: index, candidates: replacements)
            {
                inferred += "@\(match.candidate.npub)"
                index = match.endIndex
                continue
            }
            inferred.append(canonical[index])
            index = canonical.index(after: index)
        }
        return inferred
    }

    private static func canonicalizeSelections(
        in text: String,
        selections: [ComposerMentionSelection]
    ) -> String {
        var canonical = text
        for selection in selections.sorted(by: { $0.location > $1.location }) {
            guard !selection.npub.isEmpty,
                selection.location >= 0,
                selection.length >= 0,
                NSMaxRange(selection.range) <= (canonical as NSString).length,
                (canonical as NSString).substring(with: selection.range) == selection.displayText,
                isValidVisibleMention(selection.range, in: canonical)
            else { continue }
            canonical = (canonical as NSString).replacingCharacters(
                in: selection.range,
                with: "@\(selection.npub)"
            )
        }
        return canonical
    }

    static func isValidVisibleMention(_ range: NSRange, in text: String) -> Bool {
        guard range.location >= 0,
            range.length > 1,
            NSMaxRange(range) <= (text as NSString).length,
            let stringRange = Range(range, in: text),
            text[stringRange].first == "@"
        else { return false }
        if stringRange.lowerBound > text.startIndex {
            guard isNostrMentionBoundary(text[text.index(before: stringRange.lowerBound)]) else {
                return false
            }
        }
        if stringRange.upperBound < text.endIndex {
            guard isNostrMentionBoundary(text[stringRange.upperBound]) else { return false }
        }
        return true
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

/// Converts canonical mention tokens back to roster display names for plain-text surfaces such as
/// chat previews, edited-message bubbles, and edit history.
nonisolated enum MentionDisplayResolver {
    private static let bech32Characters = CharacterSet(charactersIn: "023456789acdefghjklmnpqrstuvwxyz")

    static func resolve(in text: String, mentionNames: MarkdownMentionNames) -> String {
        resolveMentions(in: text, mentionNames: mentionNames).text
    }

    /// Resolve canonical draft mentions for display while recreating the exact marker ranges the
    /// composer needs to preserve an unambiguous npub on its next save/send.
    static func composerDraftPresentation(
        in text: String,
        mentionNames: MarkdownMentionNames
    ) -> (text: String, selections: [ComposerMentionSelection]) {
        resolveMentions(in: text, mentionNames: mentionNames)
    }

    private static func resolveMentions(
        in text: String,
        mentionNames: MarkdownMentionNames
    ) -> (text: String, selections: [ComposerMentionSelection]) {
        guard !mentionNames.isEmpty, text.contains("@npub1") else { return (text, []) }
        let replacements = mentionNames.compactMap { npub, rawName -> (npub: String, name: String)? in
            guard let name = PeerDisplayText.sanitize(rawName), !npub.isEmpty else { return nil }
            return (npub, name)
        }
        guard !replacements.isEmpty else { return (text, []) }

        var resolved = ""
        var selections: [ComposerMentionSelection] = []
        var index = text.startIndex
        while index < text.endIndex {
            var match: (npub: String, name: String, end: String.Index)?
            if text[index] == "@" {
                let tokenStart = text.index(after: index)
                for replacement in replacements where text[tokenStart...].hasPrefix(replacement.npub) {
                    let end = text.index(tokenStart, offsetBy: replacement.npub.count)
                    guard end == text.endIndex || !isBech32Character(text[end]) else { continue }
                    match = (replacement.npub, replacement.name, end)
                    break
                }
            }
            if let match {
                let displayText = "@\(match.name)"
                let range = NSRange(
                    location: (resolved as NSString).length,
                    length: (displayText as NSString).length
                )
                resolved += displayText
                selections.append(
                    ComposerMentionSelection(
                        range: range,
                        displayText: displayText,
                        npub: match.npub
                    ))
                index = match.end
            } else {
                resolved.append(text[index])
                index = text.index(after: index)
            }
        }
        return (resolved, selections)
    }

    private static func isBech32Character(_ character: Character) -> Bool {
        !character.unicodeScalars.isEmpty
            && character.unicodeScalars.allSatisfy { bech32Characters.contains($0) }
    }
}
