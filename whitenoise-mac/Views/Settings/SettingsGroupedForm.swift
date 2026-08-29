//
//  SettingsGroupedForm.swift
//  whitenoise-mac
//
//  The row vocabulary every grouped settings page is written in: a group, the note under
//  it, a read-only value, and a one-line result. The switch is not here — it is `WNToggle` —
//  and neither are the rows of a choice, which are `WNSelect`'s: settings is not the only
//  surface that shows either one.
//
//  The one idea here is that a group's explanation belongs *under* the group, not inside
//  it. Each page used to end a `Section` with a bare `Text` in secondary grey, which put a
//  paragraph on the same visual tier as the toggle it described — inside the same card, in
//  the same row rhythm, reachable by the same keyboard focus. Worse, the eleven pages
//  disagreed about which rung that paragraph was set at: `.medium10` on some, `.medium12`
//  on others, the form's inherited body size on the rest. `SettingsSection`'s `footer`
//  takes it out of the card and settles the rung in one place.
//
//  A group here holds one decision. Two toggles that explain themselves differently are
//  two groups — a `Divider()` between rows of one `Section` was standing in for that
//  split, and a divider cannot carry a footer.
//

import SwiftUI

/// A group of settings rows, with an optional name above it and an optional note below it.
///
/// The note is the reason this exists: `Section`'s own `footer` renders outside the group's
/// card, which is where an explanation belongs. Prefer one `SettingsSection` per decision
/// so each one can be explained on its own.
struct SettingsSection<Content: View>: View {
    var title: String?
    var footer: String?
    /// Passed through to the footer — see `SettingsFooterText.isSelectable`.
    var isFooterSelectable = false
    @ViewBuilder let content: Content

    // Each combination builds a *different* `Section`, rather than one `Section` whose header and
    // footer are `if let`s. An `if let` yields `_ConditionalContent<Text, EmptyView>`, and only a
    // literal `EmptyView` is reliably read as "there is no header" — the conditional can still be
    // allotted the header's space, leaving a blank band above a group that has no name. Passing
    // no header at all cannot be misread.
    var body: some View {
        switch (title, footer) {
        case (let title?, let footer?):
            Section {
                content
            } header: {
                Text(title)
            } footer: {
                SettingsFooterText(footer, isSelectable: isFooterSelectable)
            }

        case (let title?, nil):
            Section {
                content
            } header: {
                Text(title)
            }

        case (nil, let footer?):
            Section {
                content
            } footer: {
                SettingsFooterText(footer, isSelectable: isFooterSelectable)
            }

        case (nil, nil):
            Section {
                content
            }
        }
    }
}

/// The note under a group. The single place the footer's rung and colour are decided, so
/// the pages cannot drift apart again.
///
/// `.medium10` is the rung the sidebar row's subtitle already sits at, which makes the note
/// under a group and the subtitle beside its name read as the same voice.
struct SettingsFooterText: View {
    let text: String
    /// For a note that is a value rather than a sentence — a storage path under the button that
    /// opens it. Prose is not worth selecting; a path is the thing a developer came to copy.
    var isSelectable = false

    init(_ text: String, isSelectable: Bool = false) {
        self.text = text
        self.isSelectable = isSelectable
    }

    var body: some View {
        // `textSelection` is generic over its argument, so the two selectabilities are two
        // types and cannot meet in a ternary — the branch has to be over the view.
        let note =
            Text(text)
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentSecondary)
            // A note is prose, so it wraps rather than truncating, and it stays left-aligned
            // against the group above it however wide the pane gets.
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

        if isSelectable {
            note.textSelection(.enabled)
        } else {
            note
        }
    }
}

/// A `WNSelect` with the group and the note around it, the shape a settings page reaches for.
///
/// A pop-up hides every option but the chosen one, which is the wrong trade for a setting
/// whose options are the explanation — appearance, or how much of a message a notification
/// may repeat. The alternatives are laid out in the group so the choice and the options it
/// was made from are read together. Keep it to a handful; a long list wants the menu back.
///
/// The rows are written out rather than left to `Picker(.inline)`, which is the one thing the
/// grouped `Form` draws differently from the shape this surface is designed against. An inline
/// `Picker` on macOS puts a grey radio dot on *every* row, so three options cost three controls
/// and the reader has to compare their fills to find the live one. The reference design marks
/// only the selection, with a trailing checkmark — one mark on the page, in the column the eye
/// is already scanning for it.
///
/// Writing them out is `WNSelect`'s job, not this type's, for the same reason the switch is
/// `WNToggle`'s: settings is not the only surface that offers a choice. Reach past this to
/// `WNSelect` directly only for a group that has something else to say *inside* the card — the
/// notification preview, whose chosen mode is spelled out as the notification it would post,
/// under the row that picks it.
struct SettingsChoiceSection<Value: Hashable>: View {
    var title: String?
    var footer: String?
    let choices: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        SettingsSection(title: title, footer: footer) {
            WNSelect(options: choices, selection: $selection, label: label)
        }
    }
}

/// How a read-only value is reported beside its name: the name at the row's weight, the
/// value de-emphasised at the trailing edge.
///
/// `monospaced` is for a value read character by character — a byte count, a key, a path.
/// `truncatesMiddle` keeps both ends of a value whose middle is the disposable part, which
/// is a path or an identifier rather than a sentence.
struct SettingsValueRow: View {
    let title: String
    let value: String
    var monospaced = false
    var truncatesMiddle = false
    var isSelectable = false

    var body: some View {
        LabeledContent(title) {
            // See `SettingsFooterText` for why selectability is a branch and not a ternary.
            let readout =
                Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : nil)
                .foregroundStyle(WNColor.backgroundContentSecondary)
                .lineLimit(truncatesMiddle ? 1 : nil)
                .truncationMode(truncatesMiddle ? .middle : .tail)

            if isSelectable {
                readout.textSelection(.enabled)
            } else {
                readout
            }
        }
    }
}

/// The outcome of something the reader just did — space reclaimed, a file uploaded, a login
/// item that still needs approval.
///
/// One shape for all of them, because the pages had four: a bare tinted `Label`, a `Label`
/// at `.medium10`, an untinted one, and a `VStack` that also owned a button. The tint is the
/// only thing a caller chooses, and it comes from `intention` so a result cannot be drawn in
/// a colour the palette does not have a meaning for.
struct SettingsStatusNote: View {
    enum Intention {
        case success
        case warning
        case failure

        var color: Color {
            switch self {
            case .success: WNColor.intentionSuccessContent
            case .warning: WNColor.intentionWarningContent
            case .failure: WNColor.backgroundContentDestructive
            }
        }

        var systemImage: String {
            switch self {
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .failure: "xmark.circle"
            }
        }
    }

    let text: String
    var intention: Intention = .success
    var systemImage: String?

    var body: some View {
        Label(text, systemImage: systemImage ?? intention.systemImage)
            .wnFont(.medium12)
            .foregroundStyle(intention.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `White Noise · 1.4 (212)`, the line that closes the settings surface.
///
/// Unlocalised on purpose: the product name is a name, and the two numbers are numbers, so
/// there is no sentence here for a catalog to hold.
struct SettingsVersionFooter: View {
    var body: some View {
        Text(verbatim: "White Noise · \(Self.shortVersion) (\(Self.buildNumber))")
            .wnFont(.medium10)
            .foregroundStyle(WNColor.backgroundContentTertiary)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }
}
