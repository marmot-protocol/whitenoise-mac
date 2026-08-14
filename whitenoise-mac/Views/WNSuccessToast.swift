import SwiftUI

/// The green success notice, drawn from the same two semantic tokens the Flutter client's
/// `WnSystemNotice` uses for its success type: `intentionSuccessContent` for the glyph and the
/// title, over `intentionSuccessBackground`. Both are dynamic, so this reads correctly in either
/// appearance without the view consulting `\.colorScheme`.
///
/// Presented by `successToastSurface(_:)`, which owns the placement and the transition. This struct
/// is only the card, so it can also be rendered on its own for a visual check.
struct WNSuccessToast: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .wnFont(.semiBold14)
            Text(message)
                .wnFont(.bold14)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(WNColor.intentionSuccessContent)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        // One width for every notice, leading-aligned, the shape the Flutter client's notice bar
        // has: repeated copies of different things then raise a card that stays put instead of one
        // that resizes under the cursor. A message too long for it wraps rather than widening it.
        //
        // 440 rather than a rounder number because it is what keeps the longest of these notices
        // on one line in every language the app ships — Portuguese sets
        // "Chave privada copiada para a área de transferência" at ~372pt, and the glyph and the
        // horizontal padding take 54 of the card's width before the label gets any.
        .frame(maxWidth: 440, alignment: .leading)
        .background {
            WNColor.intentionSuccessBackground
        }
        .clipShape(.rect(cornerRadius: 10, style: .continuous))
        .shadow(color: WNColor.shadow.opacity(0.1), radius: 12, y: 4)
        // The card carries no dismiss control (it clears itself), so nothing in it is
        // interactive. VoiceOver is told the same thing sighted users see.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(message)
    }
}

extension View {
    /// Installs this container as the surface that draws `presenter`'s success notices.
    ///
    /// Attach it to every surface a copy — or any other quietly-successful action — can be
    /// triggered from: the window root, plus each sheet that hosts one of those actions, since a
    /// sheet draws in a child window above its parent and would otherwise leave the notice hidden
    /// behind itself. Nesting is safe: the innermost installed surface is the only one that draws.
    func successToastSurface(_ presenter: SuccessToastPresenter) -> some View {
        modifier(SuccessToastSurfaceModifier(presenter: presenter))
    }
}

private struct SuccessToastSurfaceModifier: ViewModifier {
    let presenter: SuccessToastPresenter

    @State private var surfaceID = UUID()

    func body(content: Content) -> some View {
        content
            // Bottom, not top: the window's top edge already belongs to
            // `BackgroundStatusBanner`, and a transient confirmation must not land on top of a
            // standing warning about a background failure.
            .overlay(alignment: .bottom) {
                if let message = presenter.message, presenter.drawingSurface == surfaceID {
                    WNSuccessToast(message: message)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        // Purely informational, and it floats over the composer: it must never
                        // swallow a click meant for whatever is underneath it.
                        .allowsHitTesting(false)
                        // The card is not in the focus order, so its arrival is silent to
                        // VoiceOver unless announced.
                        .onAppear {
                            AccessibilityNotification.Announcement(message).post()
                        }
                }
            }
            .animation(.smooth(duration: 0.2), value: presenter.message)
            .onAppear { presenter.installSurface(surfaceID) }
            .onDisappear { presenter.removeSurface(surfaceID) }
    }
}

#Preview {
    VStack(spacing: 16) {
        WNSuccessToast(message: L10n.string("Public key copied to clipboard"))
        WNSuccessToast(message: L10n.string("Copied to clipboard"))
    }
    .padding(24)
}
