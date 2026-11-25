//
//  WNSemanticFont.swift
//  whitenoise-mac
//
//  Apple's native macOS text styles paired identically across SwiftUI (`Font`)
//  and AppKit (`NSFont.preferredFont(forTextStyle:)`), so SwiftUI views and
//  AppKit text measurement (composer `NSTextView`, transcript layout) stay in
//  lockstep without copying the legacy fixed-size `WNTextStyle` ladder.
//

import AppKit
import SwiftUI

/// Native semantic text roles from `docs/macos-ui-patterns.md` (F04).
///
/// Prefer these over `WNTextStyle` in new and migrated views. Each role maps to
/// Apple's built-in `Font.TextStyle` / `NSFont.TextStyle` rather than fixed
/// pixel sizes.
nonisolated struct WNSemanticFont: Equatable, Sendable {
    enum Role: CaseIterable, Sendable {
        /// Standalone content heading and inspector chat name.
        case title3
        /// Chat name in the list and section emphasis.
        case headline
        /// Message copy, composer input, and ordinary form rows.
        case body
        /// Chat preview in the list.
        case callout
        /// Timestamps, sender names, member counts, and supporting metadata.
        case subheadline
        /// Bubble timestamps, delivery markers, and compact badges.
        case caption

        var swiftUIStyle: Font.TextStyle {
            switch self {
            case .title3: .title3
            case .headline: .headline
            case .body: .body
            case .callout: .callout
            case .subheadline: .subheadline
            case .caption: .caption
            }
        }

        var appKitStyle: NSFont.TextStyle {
            switch self {
            case .title3: .title3
            case .headline: .headline
            case .body: .body
            case .callout: .callout
            case .subheadline: .subheadline
            case .caption: .caption1
            }
        }
    }

    enum WeightOverride: Equatable, Sendable {
        case semibold
        case bold

        var swiftUI: Font.Weight {
            switch self {
            case .semibold: .semibold
            case .bold: .bold
            }
        }

        var appKit: NSFont.Weight {
            switch self {
            case .semibold: .semibold
            case .bold: .bold
            }
        }
    }

    enum Design: Equatable, Sendable {
        case standard
        case monospaced
    }

    let role: Role
    var weightOverride: WeightOverride?
    var design: Design = .standard
    var usesMonospacedDigits = false

    static let title3 = Self(role: .title3)
    static let headline = Self(role: .headline)
    static let body = Self(role: .body)
    static let callout = Self(role: .callout)
    static let subheadline = Self(role: .subheadline)
    static let caption = Self(role: .caption)

    /// Day dividers in the transcript: emphasized `.subheadline`.
    static let dayDivider = Self(role: .subheadline, weightOverride: .bold)

    func semibold() -> Self {
        var copy = self
        copy.weightOverride = .semibold
        return copy
    }

    func bold() -> Self {
        var copy = self
        copy.weightOverride = .bold
        return copy
    }

    /// Fixed-width digits for changing timestamps and counters.
    func monospacedDigit() -> Self {
        var copy = self
        copy.usesMonospacedDigits = true
        return copy
    }

    /// Monospaced face for public identifiers, keys, and code snippets.
    func monospaced() -> Self {
        var copy = self
        copy.design = .monospaced
        return copy
    }

    var font: Font {
        var resolved: Font =
            switch design {
            case .standard:
                Font.system(role.swiftUIStyle)
            case .monospaced:
                Font.system(role.swiftUIStyle, design: .monospaced)
            }
        if let weightOverride {
            resolved = resolved.weight(weightOverride.swiftUI)
        }
        return usesMonospacedDigits ? resolved.monospacedDigit() : resolved
    }

    var nsFont: NSFont {
        let base = NSFont.preferredFont(forTextStyle: role.appKitStyle)
        let size = base.pointSize

        if design == .monospaced {
            let weight = weightOverride?.appKit ?? (role == .headline ? .bold : .regular)
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }

        if usesMonospacedDigits {
            let weight = weightOverride?.appKit ?? (role == .headline ? .bold : .regular)
            return .monospacedDigitSystemFont(ofSize: size, weight: weight)
        }

        if let weightOverride {
            return .systemFont(ofSize: size, weight: weightOverride.appKit)
        }

        return base
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: nsFont]
    }
}
