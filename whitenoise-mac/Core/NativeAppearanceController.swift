import AppKit

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
