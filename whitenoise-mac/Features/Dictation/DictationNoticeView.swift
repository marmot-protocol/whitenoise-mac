import AppKit
import SwiftUI

/// The composer's note about the last dictation: a way to System Settings when the microphone is
/// off, and a "downloading" note that goes away by itself once the speech model is ready.
struct DictationNoticeView: View {
    let notice: DictationNotice
    let controller: ComposerDictationController

    var body: some View {
        ComposerNotice(
            message: notice.message,
            action: notice.opensMicrophoneSettings ? openSettingsAction : nil,
            onDismiss: controller.dismissNotice
        )
        .modifier(DictationModelReadyObserver(controller: controller))
    }

    private var openSettingsAction: ComposerNotice.Action {
        ComposerNotice.Action(title: L10n.string("Open System Settings")) {
            guard let url = DictationNotice.microphoneSettingsURL else { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// Hands the speech model's status to the controller while a notice shows. The model installer
/// exists only where `SpeechAnalyzer` does (macOS 26).
private struct DictationModelReadyObserver: ViewModifier {
    let controller: ComposerDictationController

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.onChange(of: DictationModelInstaller.shared.status, initial: true) { _, status in
                controller.modelStatusChanged(status)
            }
        } else {
            content
        }
    }
}

#Preview("Dictation notices") {
    let controller = ComposerDictationController()
    VStack(spacing: 12) {
        DictationNoticeView(notice: .microphoneDenied, controller: controller)
        DictationNoticeView(notice: .modelDownloading, controller: controller)
        DictationNoticeView(notice: .stoppedEarly, controller: controller)
    }
    .frame(width: 520)
}
