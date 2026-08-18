//
//  OnboardingBrandMark.swift
//  whitenoise-mac
//
//  The app mark, as the signed-out screens draw it.
//

import SwiftUI

/// The White Noise mark on a signed-out screen.
///
/// One component rather than a repeated `Image("WhiteNoiseLogo")` because every copy needs the
/// same four things right — high interpolation (the asset is a raster, and the welcome screen
/// draws it well above its 1x size), a fit aspect ratio, the lift shadow, and a label that is
/// the product's name rather than the asset's filename.
///
/// The name is deliberately `Text(verbatim:)` and not an `L10n` key: "White Noise" is a proper
/// noun, and putting it in the catalog would ask ten translators to translate a brand.
struct OnboardingBrandMark: View {
    var size: CGFloat = OnboardingMetrics.welcomeMarkSize

    var body: some View {
        Image("WhiteNoiseLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: WNColor.shadow.opacity(0.1), radius: 18, y: 10)
            .accessibilityLabel(Text(verbatim: "White Noise"))
    }
}

#Preview {
    VStack(spacing: 32) {
        OnboardingBrandMark()
        OnboardingBrandMark(size: OnboardingMetrics.compactMarkSize)
    }
    .padding(40)
}
