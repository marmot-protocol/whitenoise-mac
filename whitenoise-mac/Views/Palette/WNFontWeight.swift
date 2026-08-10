//
//  WNFontWeight.swift
//  whitenoise-mac
//
//  The weights of Manrope that ship inside the app bundle. The Flutter client
//  vendors exactly these three faces (`pubspec.yaml`), so these three are the
//  whole vocabulary — there is no regular, light, or italic Manrope to fall back
//  on. Body copy is `medium`; anything lighter in a design maps up to it.
//
//  Each face is addressed by its PostScript name rather than by the family name
//  plus a `.weight()` modifier: all three faces share the family "Manrope", and
//  both SemiBold and Bold report the same symbolic bold trait, so a family-plus-
//  weight lookup cannot tell them apart and silently collapses one into the other.
//

import Foundation

nonisolated enum WNFontWeight: String, CaseIterable, Sendable {
    /// Manrope Medium (500) — body copy and every non-emphasised run.
    case medium = "Manrope-Medium"
    /// Manrope SemiBold (600) — titles, row headings, and emphasised labels.
    case semiBold = "Manrope-SemiBold"
    /// Manrope Bold (700) — badges, counters, and the loudest emphasis only.
    case bold = "Manrope-Bold"

    /// The PostScript name the face is registered under once the bundle's fonts are loaded.
    var postScriptName: String { rawValue }

    /// The file the face is vendored as, under `Resources/Fonts`.
    var fileName: String { "\(rawValue).ttf" }
}
