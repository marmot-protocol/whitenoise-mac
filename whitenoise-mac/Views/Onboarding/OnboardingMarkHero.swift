//
//  OnboardingMarkHero.swift
//  whitenoise-mac
//
//  The mark, sized to the pane it is standing in.
//

import SwiftUI

/// `OnboardingScaffold`'s default hero: the White Noise mark, drawn at
/// `OnboardingLayout.markWidth(forContainerWidth:)`.
///
/// A view of its own rather than lines inside the scaffold, because the scaffold now takes a hero
/// from its caller and the measurement belongs to whatever is being measured. The `maxWidth`
/// frame is what makes `onGeometryChange` report the *pane's* width rather than the mark's own:
/// the modifier reads the frame it is applied to, and that frame is the full column the scaffold's
/// `VStack` proposes.
struct OnboardingMarkHero: View {
    @State private var paneWidth: CGFloat = 0

    var body: some View {
        WhiteNoiseMarkView(
            width: OnboardingLayout.markWidth(forContainerWidth: paneWidth)
        )
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            paneWidth = width
        }
    }
}
