import AppKit
import SwiftUI

@MainActor
enum NativeAppearanceController {
    static func apply(_ preference: AppearancePreference) {
        let appearance = nsAppearance(for: preference)
        NSApp.appearance = appearance

        for window in NSApp.windows {
            window.appearance = appearance
            window.contentView?.appearance = appearance
            window.displayIfNeeded()
        }
    }

    static func preferredColorScheme(for preference: AppearancePreference) -> ColorScheme {
        switch preference {
        case .system:
            systemColorScheme
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    private static var systemColorScheme: ColorScheme {
        let appearance =
            NSApp.keyWindow?.effectiveAppearance
            ?? NSApp.mainWindow?.effectiveAppearance
            ?? NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    private static func nsAppearance(for preference: AppearancePreference) -> NSAppearance? {
        switch preference {
        case .system:
            nil
        case .light:
            NSAppearance(named: .aqua)
        case .dark:
            NSAppearance(named: .darkAqua)
        }
    }
}
