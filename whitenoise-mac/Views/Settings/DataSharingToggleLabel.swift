import SwiftUI

/// A data-sharing switch's label: what the switch is called, and one sentence on what turning it
/// on actually sends. The glyph keeps the row in the scanned column of settings switches.
struct DataSharingToggleLabel: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .wnFont(.medium10)
                    .foregroundStyle(WNColor.backgroundContentSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

#Preview {
    Form {
        Toggle(isOn: .constant(true)) {
            DataSharingToggleLabel(
                title: "Share usage and telemetry",
                detail: "Automatically shares feature-use counts and app performance with White Noise.",
                systemImage: "waveform.path.ecg"
            )
        }
    }
    .formStyle(.grouped)
    .frame(width: 480)
}
