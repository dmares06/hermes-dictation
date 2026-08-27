import AVFoundation
import Foundation
import Speech

/// Streams microphone audio to Apple's on-device speech recognizer from inside
/// the keyboard extension. Requires Allow Full Access; WhisperKit stays in the
/// main app because keyboard extensions cannot fit a Whisper model in memory.
@MainActor
final class KeyboardSpeechRecognizer {
    enum Event {
        case started
        case partial(String)
        case finished(String)
        case failed(String)
    }

    private let audioEngine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var deliveredOutcome = false

    private(set) var isListening = false

    var onEvent: ((Event) -> Void)?

    var isRecognizerAvailable: Bool {
        recognizer?.isAvailable ?? false
    }

    /// nil while undetermined so the gate lets the request fire.
    static var microphoneAuthorized: Bool? {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        case .undetermined: nil
        @unknown default: false
        }
    }

    static var speechAuthorized: Bool? {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: true
        case .denied, .restricted: false
        case .notDetermined: nil
        @unknown default: false
        }
    }

    func start() {
        guard !isListening else { return }
        latestTranscript = ""
        deliveredOutcome = false

        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                guard status == .authorized else {
                    self.deliver(.failed(KeyboardDictationBlocker.needsSpeechPermission.message))
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    DispatchQueue.main.async {
                        guard granted else {
                            self.deliver(.failed(KeyboardDictationBlocker.needsMicrophonePermission.message))
                            return
                        }
                        self.beginRecognition()
                    }
                }
            }
        }
    }

    /// Ends audio input and lets the recognizer finish with a final result.
    func stop() {
        guard isListening else { return }
        stopAudio()
        request?.endAudio()
    }

    func cancel() {
        stopAudio()
        task?.cancel()
        finishSession()
        deliveredOutcome = true
    }

    private func beginRecognition() {
        guard let recognizer, recognizer.isAvailable else {
            deliver(.failed(KeyboardDictationBlocker.recognizerUnavailable.message))
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.taskHint = .dictation
        self.request = request

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw NSError(
                    domain: "KeyboardSpeechRecognizer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."]
                )
            }
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            finishSession()
            deliver(.failed("Could not start the microphone: \(error.localizedDescription)"))
            return
        }

        isListening = true
        deliver(.started)

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let result {
                    self.latestTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.stopAudio()
                        self.finishSession()
                        self.deliver(.finished(self.latestTranscript))
                        return
                    }
                    self.deliver(.partial(self.latestTranscript))
                }
                if error != nil {
                    self.stopAudio()
                    self.finishSession()
                    if self.latestTranscript.isEmpty {
                        self.deliver(.failed("No speech was recognized. Try again closer to the microphone."))
                    } else {
                        self.deliver(.finished(self.latestTranscript))
                    }
                }
            }
        }
    }

    private func stopAudio() {
        guard isListening else { return }
        isListening = false
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func finishSession() {
        request = nil
        task = nil
    }

    private func deliver(_ event: Event) {
        switch event {
        case .finished, .failed:
            guard !deliveredOutcome else { return }
            deliveredOutcome = true
        case .started, .partial:
            break
        }
        onEvent?(event)
    }
}
