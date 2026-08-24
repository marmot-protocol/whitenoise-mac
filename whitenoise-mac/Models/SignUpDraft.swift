//
//  SignUpDraft.swift
//  whitenoise-mac
//
//  What the sign-up pane has collected before there is an account to hang it on.
//

import Foundation

/// The profile a new identity will be created with.
///
/// Separate from `ProfileDraft` — which edits the *published* profile of an account that already
/// exists — because none of this can be committed yet. `ProfileDraft.picture` is a URL, and a URL
/// only exists once the bytes have been uploaded to Blossom under an account's key; on this pane
/// there is no account, so the photo is carried as bytes and turned into a URL during
/// `completeSignUp()`. Everything here is thrown away once that succeeds.
///
/// This is the order `whitenoise`'s `use_signup.dart` runs in — create the identity, upload the
/// picture, publish the profile — and the reason to keep it rather than create the identity first
/// and let the existing settings plumbing do the upload: an abandoned sign-up leaves nothing
/// behind.
nonisolated struct SignUpDraft: Equatable {
    /// What `AvatarPalette` keys the initials fallback's colour off, in place of the account id
    /// hex there is not one of yet. A constant rather than the name being typed: a name-derived
    /// seed would repaint the avatar on every keystroke.
    static let avatarPaletteSeed = "onboarding.sign-up"

    var displayName = ""
    var about = ""
    /// `nil` until the picker hands back bytes. Not a URL: see the type note above.
    var image: SignUpProfileImage?

    var trimmedDisplayName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedAbout: String {
        about.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A name is the one thing this pane insists on — the same bar Flutter's
    /// `signup_create_profile_button` sets. Everything else is optional, and an identity created
    /// with no name at all shows up in the account rail as a hex id.
    var isSubmittable: Bool {
        !trimmedDisplayName.isEmpty
    }
}

/// A profile photo that has been prepared but not uploaded.
///
/// Holds the prepared bytes for the eventual upload and a `DownloadedMediaPayload` for the pane to
/// draw right now, so the avatar shows the picture the moment it is chosen rather than after a
/// round trip that cannot happen yet.
nonisolated struct SignUpProfileImage {
    let data: Data
    let mediaType: String
    /// The same bytes, in the form `ProfileImageAvatarView` draws a local image from.
    let preview: DownloadedMediaPayload

    init(attachment: PendingMediaAttachment) {
        data = attachment.data
        mediaType = attachment.mediaType
        preview = DownloadedMediaPayload(id: attachment.plaintextSHA256, data: attachment.data)
    }
}

extension SignUpProfileImage: Equatable {
    /// By digest, not by bytes. The synthesized conformance would compare the `Data` itself, and
    /// this value sits in observable state that SwiftUI diffs on every draft keystroke — which
    /// would memcmp a multi-megabyte image per character typed into the name field.
    static func == (lhs: SignUpProfileImage, rhs: SignUpProfileImage) -> Bool {
        lhs.preview.id == rhs.preview.id && lhs.mediaType == rhs.mediaType
    }
}
