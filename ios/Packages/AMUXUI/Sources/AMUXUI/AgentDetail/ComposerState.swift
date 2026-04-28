import AMUXCore

enum ComposerRightButton: Equatable {
    case stop          // agent is running — cancel task
    case stopRecording // voice recording in progress — finish recording
    case send          // idle, text non-empty
    case mic           // idle, text empty — start recording
}

enum ComposerInputMode: Equatable {
    case textField
    case waveform
}

enum ComposerState {
    static func rightButton(
        isAgentActive: Bool,
        hasText: Bool,
        voiceState: VoiceRecorder.State
    ) -> ComposerRightButton {
        if isAgentActive { return .stop }
        if voiceState == .recording { return .stopRecording }
        return hasText ? .send : .mic
    }

    static func inputMode(voiceState: VoiceRecorder.State) -> ComposerInputMode {
        voiceState == .recording ? .waveform : .textField
    }
}
