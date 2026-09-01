//
//  SourceContract.swift
//  whitenoise-macTests
//
//  The one place a test may name a view source file.
//

import Foundation
import Testing

/// Reading a view's source as text is the only way to guard chrome that is never built: an absent
/// subtitle, a gesture that must stay a `Button`, a radius no tier is allowed to keep. Those tests
/// are worth having, but each one used to spell out its own path to `whitenoise-mac/Views`, its own
/// filename, and its own idea of where a declaration ends — so renaming a file, moving a struct
/// between files, or merely reordering two structs failed a test that named nothing anyone touched.
///
/// Everything those tests need lives here instead:
///
/// - ``ViewUnit`` is the filename table. A file that is renamed or split into several is one line
///   here, and no test changes.
/// - ``declaration(_:in:)`` finds a top-level declaration *by name* and bounds it by the next
///   top-level declaration. It never names the struct that happens to follow, so reordering the
///   file is invisible to it — and with no ``ViewUnit`` given it searches the whole view tree, so
///   moving a struct to another file is invisible too.
enum SourceContract {

    // MARK: - The filename table

    /// A unit of view source a test reads as text, and the file (or files) it is written in.
    ///
    /// This enum is the only place in the test target where a view filename appears. When a file is
    /// renamed, split, or moved between the `Views` subdirectories, edit its ``paths`` and nothing
    /// else: a split becomes `["FirstHalf.swift", "SecondHalf.swift"]` and every assertion against
    /// the unit keeps reading the whole of it.
    enum ViewUnit: CaseIterable {
        case composer
        case destructiveButtonStyle
        case encryptedPrivateKeyExportSheet
        case group
        case messageMedia
        case messengerShell
        case onboardingSignIn
        case onboardingSignUp
        case onboardingWelcome
        case pendingInviteActionButtons
        case pendingOutgoingMessage
        case primaryButton
        case primaryButtonSize
        case profileKeysSettings
        case publicIdentity
        case secondaryButtonStyle
        case settingsAccountSwitcher
        case settingsSidebarGroupCard
        case sidebar
        case signOutSheet

        /// Paths relative to `whitenoise-mac/Views`, in the order they should be read.
        var paths: [String] {
            switch self {
            case .composer: ["ComposerViews.swift"]
            case .destructiveButtonStyle: ["WNDestructiveButtonStyle.swift"]
            case .encryptedPrivateKeyExportSheet: ["Settings/EncryptedPrivateKeyExportSheet.swift"]
            case .group: ["GroupViews.swift"]
            case .messageMedia: ["MessageMediaViews.swift"]
            case .messengerShell: ["MessengerShellView.swift"]
            case .onboardingSignIn: ["Onboarding/OnboardingSignInView.swift"]
            case .onboardingSignUp: ["Onboarding/OnboardingSignUpView.swift"]
            case .onboardingWelcome: ["Onboarding/OnboardingWelcomeView.swift"]
            case .pendingInviteActionButtons: ["PendingInviteActionButtons.swift"]
            case .pendingOutgoingMessage: ["PendingOutgoingMessageViews.swift"]
            case .primaryButton: ["WNPrimaryButton.swift"]
            case .primaryButtonSize: ["WNPrimaryButtonSize.swift"]
            case .profileKeysSettings: ["Settings/ProfileKeysSettingsView.swift"]
            case .publicIdentity: ["Settings/PublicIdentityViews.swift"]
            case .secondaryButtonStyle: ["WNSecondaryButtonStyle.swift"]
            case .settingsAccountSwitcher: ["Settings/SettingsAccountSwitcherViews.swift"]
            case .settingsSidebarGroupCard: ["Settings/SettingsSidebarGroupCard.swift"]
            case .sidebar: ["SidebarViews.swift"]
            case .signOutSheet: ["Settings/SignOutSheet.swift"]
            }
        }
    }

    // MARK: - Locating source

    /// `whitenoise-mac/Views`, derived from this file's own location so it survives a checkout
    /// anywhere — including the worktrees this repo is usually built from.
    static var viewsDirectory: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()  // Support
            .deletingLastPathComponent()  // whitenoise-macTests
            .deletingLastPathComponent()  // repository root
            .appending(path: "whitenoise-mac")
            .appending(path: "Views")
    }

    static func urls(of unit: ViewUnit) -> [URL] {
        unit.paths.map { viewsDirectory.appending(path: $0) }
    }

    /// The full text of a unit. A unit written across several files reads as their concatenation,
    /// so a `contains` assertion survives the split that produced them.
    static func source(of unit: ViewUnit) throws -> String {
        try urls(of: unit)
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    /// Whether a file exists under `Views`, for the tests that guard a *deleted* file staying
    /// deleted. `relativePath` is relative to `Views` — the one place a filename may be written
    /// outside the table, because a file that no longer exists cannot have a table entry.
    static func viewFileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: viewsDirectory.appending(path: relativePath).path)
    }

    // MARK: - Slicing one declaration

    /// The source of the top-level declaration named `name`, from its first line up to the next
    /// top-level declaration.
    ///
    /// `name` is the bare identifier — `"MessageVisualMediaTile"`, not `"struct MessageVisualMediaTile: View {"`.
    /// The access level, the attributes, and the conformance list are all matched for the caller, so
    /// adding a protocol or making a struct `private` does not fail the test. The end of the slice is
    /// whatever declaration comes next, never a named one, so the file may be freely reordered.
    ///
    /// With no `unit`, the whole view tree is searched: a struct that moves to another file — or to a
    /// file split out of its old one — is still found, with no edit here or at the call site. Two
    /// declarations of the same name is an error rather than a coin flip.
    static func declaration(
        _ name: String,
        in unit: ViewUnit? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let searched: [ViewUnit]
        if let unit { searched = [unit] } else { searched = ViewUnit.allCases }

        var found: [(unit: ViewUnit, body: String)] = []
        for candidate in searched {
            if let body = declaration(named: name, in: try source(of: candidate)) {
                found.append((candidate, body))
            }
        }

        guard let first = found.first else {
            let scope = unit.map { "\($0)" } ?? "the view tree"
            throw SourceContractError("no top-level declaration named \(name) in \(scope)", sourceLocation)
        }
        guard found.count == 1 else {
            let units = found.map { "\($0.unit)" }.joined(separator: ", ")
            throw SourceContractError("\(name) is declared more than once: \(units)", sourceLocation)
        }
        return first.body
    }

    /// The declaration's body only — everything after `var body: some View {`. The slice a test wants
    /// when it is checking the order of what is drawn rather than the properties above it.
    static func viewBody(
        _ name: String,
        in unit: ViewUnit? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let whole = try declaration(name, in: unit, sourceLocation: sourceLocation)
        guard let bodyStart = whole.range(of: "var body: some View {")?.upperBound else {
            throw SourceContractError("\(name) declares no `var body: some View`", sourceLocation)
        }
        return String(whole[bodyStart...])
    }

    // MARK: - Reading source as prose

    /// Comment lines dropped, so an absence check reads the declarations rather than the paragraph
    /// explaining what the file no longer carries. Naming a removed group in the prose above the code
    /// is not the same as reintroducing it.
    static func strippingCommentLines(_ source: some StringProtocol) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - Implementation

    /// Finds `name`'s declaration in one file's text and returns it bounded by the next top-level
    /// declaration, or `nil` if this file does not declare it.
    private static func declaration(named name: String, in source: String) -> String? {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        // An `extension Foo` is a boundary but never the thing being looked up: a test asking for
        // `Foo` wants the type, and several files may extend it without any of them declaring it.
        guard
            let start = lines.firstIndex(where: {
                declaredName(ofTopLevelLine: $0) == name && !isExtension(topLevelLine: $0)
            })
        else { return nil }
        var end =
            lines[lines.index(after: start)...]
            .firstIndex { declaredName(ofTopLevelLine: $0) != nil } ?? lines.endIndex
        // A doc comment sitting at column zero above the next declaration belongs to *that*
        // declaration, so it is not part of this slice. Without this, a negative assertion could be
        // satisfied by the prose introducing the struct that happens to follow.
        while end > lines.index(after: start), belongsToTheFollowingDeclaration(lines[lines.index(before: end)]) {
            end = lines.index(before: end)
        }
        return lines[start..<end].joined(separator: "\n")
    }

    private static func isExtension(topLevelLine line: some StringProtocol) -> Bool {
        line.split(separator: " ", omittingEmptySubsequences: true).contains("extension")
    }

    /// A blank line, or a comment written hard against the left margin — the trailing lines of a
    /// declaration slice that are really the header of the next one. A comment *inside* a
    /// declaration is indented, so it is never mistaken for one of these.
    private static func belongsToTheFollowingDeclaration(_ line: some StringProtocol) -> Bool {
        line.isEmpty || line.hasPrefix("//")
    }

    /// The identifier a line declares, if the line begins a top-level declaration.
    ///
    /// Top-level means column zero: a nested `struct` is indented and so is never a boundary. The
    /// keyword may carry any number of the modifiers Swift allows in front of it, which is what lets
    /// a call site pass a bare name and stop caring whether the declaration is `private`.
    private static func declaredName(ofTopLevelLine line: some StringProtocol) -> String? {
        guard let first = line.first, !first.isWhitespace else { return nil }

        var words = line.split(separator: " ", omittingEmptySubsequences: true)[...]
        let modifiers: Set<String> = [
            "public", "package", "internal", "fileprivate", "private", "final", "open", "indirect", "nonisolated",
        ]
        while let word = words.first, modifiers.contains(String(word)) { words = words.dropFirst() }

        let keywords: Set<String> = ["struct", "enum", "class", "actor", "protocol", "extension", "typealias"]
        guard let keyword = words.first, keywords.contains(String(keyword)) else { return nil }

        guard let identifier = words.dropFirst().first else { return nil }
        // `struct Foo: View {`, `enum Bar {`, `struct Row<Accessory: View> {` — stop at whatever
        // ends the name, so a conformance list or a generic parameter is not part of it.
        let declared = String(identifier.prefix { $0 == "_" || $0.isLetter || $0.isNumber })
        return declared.isEmpty ? nil : declared
    }
}

/// Thrown when the source a contract test asked for is not there — a missing declaration, or an
/// ambiguous one. Carries the call site so the failure names the test rather than this file.
private struct SourceContractError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String, _ sourceLocation: SourceLocation) {
        self.description = "\(description) (\(sourceLocation.fileName):\(sourceLocation.line))"
    }
}
