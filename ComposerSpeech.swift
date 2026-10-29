import AVFoundation
import Speech

// No audio file is saved and no cloud transcription fallback is used.
@MainActor final class ComposerSpeech {
    let engine = AVAudioEngine()
    var recognizer: SFSpeechRecognizer?
    var request: SFSpeechAudioBufferRecognitionRequest?
    var task: SFSpeechRecognitionTask?
    var tapInstalled = false
    var isRunning = false
    var generation = UUID()
    var finishing = false
    var onTranscript: ((String) -> Void)?
    var onStop: ((String?) -> Void)?
    var onState: ((String) -> Void)?

    static func diagnostics() -> [String: Any] {
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Locale.preferredLanguages.first ?? "en-US"))
        let microphone: String
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = "authorized"
        case .denied: microphone = "denied"
        case .restricted: microphone = "restricted"
        case .notDetermined: microphone = "notDetermined"
        @unknown default: microphone = "unknown"
        }
        let speech: String
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: speech = "authorized"
        case .denied: speech = "denied"
        case .restricted: speech = "restricted"
        case .notDetermined: speech = "notDetermined"
        @unknown default: speech = "unknown"
        }
        return ["microphoneAuthorization": microphone,
                "speechAuthorization": speech,
                "locale": recognizer?.locale.identifier ?? "unavailable",
                "available": recognizer?.isAvailable ?? false,
                "onDeviceSupported": recognizer?.supportsOnDeviceRecognition ?? false]
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        finishing = false
        onState?("Allow Speech Recognition when macOS asks…")
        let current = UUID()
        generation = current
        Task { @MainActor in
            let authorization = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard generation == current, isRunning else { return }
            guard authorization == .authorized else { cancel("Enable Capture Studio in System Settings → Privacy & Security → Speech Recognition, then try again."); return }
            onState?("Allow Microphone access when macOS asks…")
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == current, isRunning else { return }
            guard microphone else { cancel("Enable Capture Studio in System Settings → Privacy & Security → Microphone, then try again."); return }
            let locale = Locale(identifier: Locale.preferredLanguages.first ?? "en-US")
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                cancel("On-device speech recognition is unavailable for \(locale.identifier). Enable/download this language in macOS Keyboard → Dictation. No cloud fallback was used.")
                return
            }
            self.recognizer = recognizer
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            self.request = request
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { cancel("No microphone input is available. Check macOS Sound → Input."); return }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
            tapInstalled = true
            task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                let transcript = result?.bestTranscription.formattedString
                let final = result?.isFinal == true
                let message = error?.localizedDescription
                Task { @MainActor in
                    guard let self, self.generation == current, self.isRunning else { return }
                    if let transcript { self.onTranscript?(transcript) }
                    if final || message != nil { self.cancel(message) }
                }
            }
            do { engine.prepare(); try engine.start(); onState?("Listening on-device · Click Stop to review.") }
            catch { cancel(error.localizedDescription) }
        }
    }

    func stop() {
        guard isRunning, !finishing else { return }
        guard task != nil else { cancel(); return }
        finishing = true
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        task?.finish()
        onState?("Finishing transcript…")
        let current = generation
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if generation == current, finishing { cancel() }
        }
    }

    func cancel(_ error: String? = nil) {
        guard isRunning else { return }
        isRunning = false
        finishing = false
        generation = UUID()
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        onStop?(error)
    }
}
