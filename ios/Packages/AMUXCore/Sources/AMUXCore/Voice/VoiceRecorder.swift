import AVFoundation
import Foundation
import Observation
import Speech

@Observable @MainActor
public final class VoiceRecorder {
    public enum State: Equatable { case idle, recording, denied, error(String) }

    public private(set) var state: State = .idle
    public private(set) var transcript: String = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var audioEngine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    public init() {}

    public func toggle() {
        switch state {
        case .recording: stop()
        case .idle, .denied, .error: requestAndStart()
        }
    }

    public func cancel() {
        guard state == .recording else { return }
        stop()
        transcript = ""
    }

    private func requestAndStart() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else { self.state = .denied; return }
                self.beginCapture()
            }
        }
    }

    private func beginCapture() {
        guard let recognizer, recognizer.isAvailable else {
            state = .error("Speech recognizer unavailable")
            return
        }
        let engine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            state = .error(error.localizedDescription)
            return
        }

        self.audioEngine = engine
        self.request = request
        self.transcript = ""
        self.state = .recording

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || result?.isFinal == true {
                    self.stop()
                }
            }
        }
    }

    private func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
        request?.endAudio()
        request = nil
        task?.finish()
        task = nil
        state = .idle
    }
}
