/// Why a voice recording did not start. What the composer says about it is the conversation
/// feature's business (`VoiceRecordingNoticeView`); this is only the reason.
enum VoiceRecordingStartFailure: Equatable {
    /// The composer holds text or attachments, and a voice message is sent on its own.
    case sentAlone
    /// The user, or a profile, has not granted White Noise the microphone.
    case microphoneDenied
    /// The recorder refused to start: most often no input device is connected.
    case couldNotStart
}
