//
//  WNColorRamp.swift
//  whitenoise-mac
//
//  The raw color ramp shared with the other White Noise clients. Ported
//  value-for-value from `lib/theme/semantic_colors.dart` in the sibling
//  repository, where these live as the private `_NeutralColors`,
//  `_BlueColors`, … classes.
//
//  Nothing outside the palette should reference these directly: a view picks a
//  *semantic* token (`WNColor.backgroundPrimary`), never a ramp step. The ramp
//  exists only so the semantic layer can be read side by side with the Dart
//  file and checked for drift.
//

import AppKit

/// `nonisolated` because message bodies are styled off the main actor while a timeline
/// window is mapped (whitenoise-mac#285), so the palette has to be reachable from there.
nonisolated enum WNColorRamp {
    // MARK: - Base

    static let white = srgb(0xFF_FFFF)
    static let black = srgb(0x00_0000)
    /// Dart's `_BaseColors.transparent` is `0x00FFFFFF` — transparent *white*,
    /// not transparent black, which matters when it is interpolated.
    static let transparent = srgb(0xFF_FFFF, alpha: 0)

    // MARK: - Black alpha

    static let blackAlpha50 = srgb(0x00_0000, alpha: 0x0D / 255)
    static let blackAlpha200 = srgb(0x00_0000, alpha: 0x33 / 255)
    static let blackAlpha300 = srgb(0x00_0000, alpha: 0x4D / 255)
    static let blackAlpha500 = srgb(0x00_0000, alpha: 0x80 / 255)
    static let blackAlpha600 = srgb(0x00_0000, alpha: 0x99 / 255)

    // MARK: - White alpha

    static let whiteAlpha500 = srgb(0xFF_FFFF, alpha: 0x80 / 255)
    static let whiteAlpha600 = srgb(0xFF_FFFF, alpha: 0x99 / 255)
    static let whiteAlpha800 = srgb(0xFF_FFFF, alpha: 0xCC / 255)
    static let whiteAlpha900 = srgb(0xFF_FFFF, alpha: 0xE6 / 255)

    // MARK: - Neutral

    static let neutral50 = srgb(0xFA_FAFA)
    static let neutral100 = srgb(0xF5_F5F5)
    static let neutral150 = srgb(0xED_EDEE)
    static let neutral200 = srgb(0xE5_E5E5)
    static let neutral250 = srgb(0xDC_DCDD)
    static let neutral300 = srgb(0xD4_D4D4)
    static let neutral400 = srgb(0xA3_A3A3)
    static let neutral450 = srgb(0x8B_8B8B)
    static let neutral500 = srgb(0x73_7373)
    static let neutral650 = srgb(0x49_4949)
    static let neutral700 = srgb(0x40_4040)
    static let neutral750 = srgb(0x33_3333)
    static let neutral800 = srgb(0x26_2626)
    static let neutral850 = srgb(0x1E_1E1F)
    static let neutral900 = srgb(0x17_1717)
    static let neutral950 = srgb(0x0A_0A0A)

    // MARK: - Red

    static let red50 = srgb(0xFE_F2F2)
    static let red500 = srgb(0xEF_4444)
    static let red600 = srgb(0xDC_2626)
    static let red950 = srgb(0x45_0A0A)

    // MARK: - Orange

    static let orange50 = srgb(0xFF_F7ED)
    static let orange200 = srgb(0xFE_D7AA)
    static let orange500 = srgb(0xF9_7316)
    static let orange600 = srgb(0xEA_580C)
    static let orange900 = srgb(0x7C_2D12)
    static let orange950 = srgb(0x43_1407)

    // MARK: - Amber

    static let amber50 = srgb(0xFF_FBEB)
    static let amber200 = srgb(0xFD_E68A)
    static let amber500 = srgb(0xF5_9E0B)
    static let amber900 = srgb(0x78_350F)
    static let amber950 = srgb(0x45_1A03)

    // MARK: - Lime

    static let lime50 = srgb(0xF7_FEE7)
    static let lime200 = srgb(0xD9_F99D)
    static let lime500 = srgb(0x84_CC16)
    static let lime900 = srgb(0x36_5314)
    static let lime950 = srgb(0x1A_2E05)

    // MARK: - Green

    static let green50 = srgb(0xF0_FDF4)
    static let green500 = srgb(0x22_C55E)
    static let green600 = srgb(0x16_A34A)
    static let green950 = srgb(0x05_2E16)

    // MARK: - Emerald

    static let emerald50 = srgb(0xEC_FDF5)
    static let emerald200 = srgb(0xA7_F3D0)
    static let emerald500 = srgb(0x10_B981)
    static let emerald900 = srgb(0x06_4E3B)
    static let emerald950 = srgb(0x02_2C22)

    // MARK: - Teal

    static let teal50 = srgb(0xF0_FDFA)
    static let teal200 = srgb(0x99_F6E4)
    static let teal500 = srgb(0x14_B8A6)
    static let teal900 = srgb(0x13_4E4A)
    static let teal950 = srgb(0x04_2F2E)

    // MARK: - Cyan

    static let cyan50 = srgb(0xEC_FEFF)
    static let cyan200 = srgb(0xA5_F3FC)
    static let cyan500 = srgb(0x06_B6D4)
    static let cyan900 = srgb(0x16_4E63)
    static let cyan950 = srgb(0x08_3344)

    // MARK: - Sky

    static let sky50 = srgb(0xF0_F9FF)
    static let sky200 = srgb(0xBA_E6FD)
    static let sky500 = srgb(0x0E_A5E9)
    static let sky900 = srgb(0x0C_4A6E)
    static let sky950 = srgb(0x08_2F49)

    // MARK: - Blue

    static let blue50 = srgb(0xEF_F6FF)
    static let blue200 = srgb(0xBF_DBFE)
    static let blue500 = srgb(0x3B_82F6)
    static let blue600 = srgb(0x25_63EB)
    static let blue900 = srgb(0x1E_3A8A)
    static let blue950 = srgb(0x17_2554)

    // MARK: - Indigo

    static let indigo50 = srgb(0xEE_F2FF)
    static let indigo200 = srgb(0xC7_D2FE)
    static let indigo500 = srgb(0x63_66F1)
    static let indigo900 = srgb(0x31_2E81)
    static let indigo950 = srgb(0x1E_1B4B)

    // MARK: - Violet

    static let violet50 = srgb(0xF5_F3FF)
    static let violet200 = srgb(0xDD_D6FE)
    static let violet500 = srgb(0x8B_5CF6)
    static let violet900 = srgb(0x4C_1D95)
    static let violet950 = srgb(0x2E_1065)

    // MARK: - Fuchsia

    static let fuchsia50 = srgb(0xFD_F4FF)
    static let fuchsia200 = srgb(0xF5_D0FE)
    static let fuchsia500 = srgb(0xD9_46EF)
    static let fuchsia900 = srgb(0x70_1A75)
    static let fuchsia950 = srgb(0x4A_044E)

    // MARK: - Rose

    static let rose50 = srgb(0xFF_F1F2)
    static let rose200 = srgb(0xFE_CDD3)
    static let rose500 = srgb(0xF4_3F5E)
    static let rose900 = srgb(0x88_1337)
    static let rose950 = srgb(0x4C_0519)

    /// Flutter's `Color(0xAARRGGBB)` is sRGB, so the ramp is pinned to the sRGB
    /// space rather than the display's — otherwise the same hex renders as a
    /// different color here than it does on the other clients.
    private static func srgb(_ rgb: Int, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}
