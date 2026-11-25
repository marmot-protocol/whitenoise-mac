//
//  WNSemanticFont.swift
//  whitenoise-mac
//
//  Apple's native macOS text styles paired identically across SwiftUI (`Font`)
//  and AppKit (`NSFont.preferredFont(forTextStyle:)`), so SwiftUI views and
//  AppKit text measurement stay in lockstep without adding to the legacy
//  fixed-size `WNTextStyle` ladder.
//

import AppKit
import SwiftUI

/// Native semantic text roles from `docs/macos-ui-patterns.md` (F04).
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

    let role: Role
    var isSemibold = false

    static let title3 = Self(role: .title3)
    static let headline = Self(role: .headline)
    static let body = Self(role: .body)
    static let callout = Self(role: .callout)
    static let subheadline = Self(role: .subheadline)
    static let caption = Self(role: .caption)

    func semibold() -> Self {
        var copy = self
        copy.isSemibold = true
        return copy
    }

    var font: Font {
        let base = Font.system(role.swiftUIStyle)
        return isSemibold ? base.weight(.semibold) : base
    }

    var nsFont: NSFont {
        let base = NSFont.preferredFont(forTextStyle: role.appKitStyle)
        return isSemibold ? .systemFont(ofSize: base.pointSize, weight: .semibold) : base
    }
}
