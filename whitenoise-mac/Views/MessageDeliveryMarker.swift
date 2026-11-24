//
//  MessageDeliveryMarker.swift
//  whitenoise-mac
//
//  The delivery glyph at the head of a message's timestamp footer.
//

import SwiftUI

/// The glyph that says where an outgoing message is: an animated speech bubble while it goes out,
/// a filled checkmark once it has, and the warning or failure marks. Shared by the committed
/// bubble (`MessageBubble`) and the locally staged one (`PendingOutgoingMessageViews`), so a send
/// and the row that replaces it wear the same marker. The glyphs match White Noise for iOS.
struct MessageDeliveryMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let indicator: MessageDeliveryIndicator

    var body: some View {
        if let systemImage = Self.systemImage(for: indicator) {
            Image(systemName: systemImage)
                .symbolEffect(
                    .variableColor.iterative,
                    options: .repeat(.continuous),
                    isActive: indicator == .sending && !reduceMotion
                )
        }
    }

    /// The glyph for each marker, or nil for the rows that carry none. `MessageBubble`'s inline
    /// spacer reserves the width of the same glyph, so the two cannot disagree.
    static func systemImage(for indicator: MessageDeliveryIndicator) -> String? {
        switch indicator {
        case .none:
            nil
        case .sending:
            "ellipsis.message"
        case .delivered:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        }
    }
}

#Preview("Delivery markers") {
    HStack(spacing: 12) {
        MessageDeliveryMarker(indicator: .sending)
        MessageDeliveryMarker(indicator: .delivered)
        MessageDeliveryMarker(indicator: .warning)
        MessageDeliveryMarker(indicator: .failed)
    }
    .wnFont(.medium10)
    .foregroundStyle(WNColor.backgroundContentTertiary)
    .padding()
}
