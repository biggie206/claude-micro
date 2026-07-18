// Hold-to-talk transcription: SFSpeechRecognizer + AVAudioEngine, live partials.
// (watchOS has no SFSpeechRecognizer — the watch uses system dictation instead.)
import Foundation
import Speech
import AVFoundation

@MainActor
final class PTTController: ObservableObject {
    @Published var isRecording = false
    @Published var partial = ""
    @Published var authorized = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    func requestAuthorization() {
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in self.authorized = (status == .authorized) }
        }
        AVAudioApplication.requestRecordPermission { _ in }
    }

    func start() {
        guard !isRecording, let recognizer, recognizer.isAvailable else { return }
        partial = ""
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try? engine.start()
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let result else { return }
            Task { @MainActor in self?.partial = result.bestTranscription.formattedString }
        }
    }

    /// Stop and return the final transcript (empty string ⇒ caller sends nothing, per spec AS US2-3).
    func stop() -> String {
        guard isRecording else { return "" }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        recognitionTask?.finish()
        isRecording = false
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }
}
