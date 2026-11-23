import AppKit
import SwiftUI

/// Why a voice recording did not start, said over the composer that asked for it.
///
/// The recorder used to put these on `WorkspaceState.lastError`, which the conversation pane never
/// draws, so a refused or failed recording looked exactly like a mic button that does nothing — on
/// a Mac with no microphone, every press.
enum VoiceRecordingNotice: Equatable {
    /// The composer holds text or attachments, and a voice message is sent on its own.
    case sentAlone
    /// The user, or a profile, has not granted White Noise the microphone.
    case microphoneDenied
    /// The recorder refused to start: most often no input device is connected.
    case couldNotStart

    var message: String {
        switch self {
        case .sentAlone:
            L10n.string("A voice message is sent on its own")
        case .microphoneDenied:
            L10n.string("Microphone access is needed to record voice messages.")
        case .couldNotStart:
            L10n.string("Voice recording could not start.")
        }
    }

    var opensMicrophoneSettings: Bool { self == .microphoneDenied }
}

/// The composer's note about a voice recording that did not start.
struct VoiceRecordingNoticeView: View {
    let notice: VoiceRecordingNotice
    let onDismiss: () -> Void

    var body: some View {
        ComposerNotice(
            message: notice.message,
            action: notice.opensMicrophoneSettings ? openSettingsAction : nil,
            onDismiss: onDismiss
        )
    }

    private var openSettingsAction: ComposerNotice.Action {
        ComposerNotice.Action(title: L10n.string("Open System Settings")) {
            guard let url = DictationNotice.microphoneSettingsURL else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

#Preview("Voice recording notices") {
    VStack(spacing: 12) {
        VoiceRecordingNoticeView(notice: .couldNotStart, onDismiss: {})
        VoiceRecordingNoticeView(notice: .microphoneDenied, onDismiss: {})
        VoiceRecordingNoticeView(notice: .sentAlone, onDismiss: {})
    }
    .padding()
    .frame(width: 480)
}
