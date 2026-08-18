//
//  SignUpAvatarPreview.swift
//  whitenoise-mac
//
//  The monogram at the top of the sign-up form.
//

import SwiftUI

/// A live monogram of the name being typed on the sign-up form.
///
/// The prototype puts a photo picker here. That cannot work before the identity exists: the
/// mac app's picker (`showProfileImagePicker`) needs an account to attach the image to, and
/// uploading one needs a signer. So the slot keeps the prototype's shape — a large round
/// subject over the fields — and fills it with what *is* known before sign-up: the initials.
///
/// The seed is the typed name rather than an account id, which is the one honest compromise
/// here: the palette entry a real account gets is derived from its id, so the colour settles
/// once the identity exists. It is a preview of the monogram, not a promise about the colour.
struct SignUpAvatarPreview: View {
    let displayName: String
    var size: CGFloat = 96

    var body: some View {
        AvatarView(
            seed: displayName.isEmpty ? "whitenoise" : displayName,
            initials: displayName,
            size: size,
            isSelected: false
        )
        .animation(.smooth(duration: 0.2), value: displayName)
        .accessibilityHidden(true)
    }
}

#Preview {
    HStack(spacing: 24) {
        SignUpAvatarPreview(displayName: "")
        SignUpAvatarPreview(displayName: "Marmota")
    }
    .padding(40)
}
