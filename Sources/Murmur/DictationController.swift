import AVFoundation
import Cocoa

/// The hold-fn → record → transcribe → clean up → paste loop.
@MainActor
final class DictationController {
    enum State: Equatable {
        case idle
        case recording(locked: Bool)
        case processing
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?

    var engine: SpeechEngine?
    var engineError: String?
    var isReady: Bool { engine != nil && hotkeys.isRunning && micAuthorized }

    let overlay = OverlayController()
    let hotkeys = HotkeyMonitor()
    private let ai = AICleaner()

    private var capture: AudioCapture?
    private var live: LiveTranscription?
    private var recordingStarted = Date()
    /// Bumped on every new dictation or cancel so stale async work can tell it's been superseded.
    private var generation = 0

    var micAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    init() {
        hotkeys.handler = { [weak self] event in
            guard let self else { return false }
            return self.handle(event)
        }
    }

    // MARK: Hotkey handling (runs inside the event tap, so keep it quick)

    private func handle(_ event: HotkeyMonitor.Event) -> Bool {
        switch (event, state) {
        case (.fnDown, .idle):
            startRecording()
        case (.fnDown, .recording(locked: true)):
            stopRecording()
        case (.fnUp, .recording(locked: false)):
            if Date().timeIntervalSince(recordingStarted) < 0.3 {
                cancel(silently: true)   // a tap, not a hold
            } else {
                stopRecording()
            }
        case (.fnSpace, .recording(locked: false)):
            state = .recording(locked: true)
            overlay.model.locked = true
            return true
        case (.fnChord, .recording(locked: false)):
            cancel(silently: true)       // fn+arrow, fn+F-key etc: not a dictation
        case (.escape, .recording), (.escape, .processing):
            cancel(silently: false)
            return true
        default:
            break
        }
        return false
    }

    // MARK: Recording

    private func startRecording() {
        guard micAuthorized else {
            overlay.flash(.error("Murmur needs microphone access. Open the menu bar icon to fix."), for: 3)
            return
        }
        guard let engine else {
            overlay.flash(.error(engineError ?? "Speech model is still loading…"), for: 2.5)
            return
        }

        generation += 1
        let myGeneration = generation
        recordingStarted = Date()
        state = .recording(locked: false)

        // Start the mic just outside the event tap callback: it can take a moment, and
        // blocking the tap makes typing stutter.
        DispatchQueue.main.async { [self] in
            guard generation == myGeneration, case .recording = state else { return }
            beginCapture(engine: engine)
        }
        // Only show the pill and play the sound once it's clearly a hold, so fn+arrow
        // and other fn shortcuts don't make it flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [self] in
            guard generation == myGeneration, case .recording = state, live != nil else { return }
            overlay.show(.listening)
            Sounds.start()
        }
    }

    private func beginCapture(engine: SpeechEngine) {
        overlay.model.reset()
        let vocabulary = Settings.dictionaryWords()
        let model = overlay.model
        let session = engine.makeSession(vocabulary: vocabulary) { partial in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.text = partial.trimmingCharacters(in: .whitespaces) }
            }
        }
        let capture = AudioCapture(targetFormat: engine.audioFormat)
        capture.onBuffer = { [session] buffer in session.append(buffer) }
        capture.onLevel = { level in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { model.push(level: level) }
            }
        }

        do {
            try capture.start()
        } catch {
            session.cancel()
            state = .idle
            overlay.flash(.error(error.localizedDescription), for: 2.5)
            return
        }

        self.capture = capture
        self.live = session
        if Settings.aiCleanup { ai.prewarm(vocabulary: vocabulary) }
    }

    private func stopRecording() {
        guard let live, let capture else {
            cancel(silently: true)
            return
        }
        let myGeneration = generation
        state = .processing
        overlay.show(.processing)
        Sounds.stop()
        self.live = nil
        self.capture = nil

        Task { @MainActor in
            // Keep listening a beat longer: people often release the key on the last syllable.
            try? await Task.sleep(for: .milliseconds(180))
            capture.stop()

            let raw: String
            do {
                raw = try await live.finish()
            } catch {
                guard myGeneration == self.generation else { return }
                self.finish(withError: "Transcription failed: \(error.localizedDescription)")
                return
            }
            guard myGeneration == self.generation else { return }

            let ruled = TextCleaner.clean(raw)
            guard !ruled.isEmpty else {
                self.finish(withError: "Didn't catch that")
                return
            }

            var text = ruled
            let wordCount = ruled.split(whereSeparator: \.isWhitespace).count
            if Settings.aiCleanup, wordCount >= 3,
               let polished = await self.ai.clean(ruled, vocabulary: Settings.dictionaryWords()) {
                text = polished
            }
            guard myGeneration == self.generation else { return }

            self.deliver(text)
        }
    }

    private func deliver(_ text: String) {
        var output = text
        if Settings.trailingSpace, !output.hasSuffix("\n") { output += " " }

        let outcome = Paster.paste(output)
        Settings.addToHistory(text)
        state = .idle

        switch outcome {
        case .pasted:
            overlay.hide(after: 0)
        case .copiedOnly:
            overlay.flash(.done("Copied. Press ⌘V to paste"), for: 2.5)
        }
    }

    private func finish(withError message: String) {
        state = .idle
        overlay.flash(.error(message), for: 1.8)
    }

    private func cancel(silently: Bool) {
        generation += 1
        capture?.stop()
        live?.cancel()
        capture = nil
        live = nil
        state = .idle
        if silently {
            overlay.hide()
        } else {
            overlay.flash(.error("Cancelled"), for: 0.9)
        }
    }
}

enum Sounds {
    private static let startSound: NSSound? = {
        let s = NSSound(named: "Tink")
        s?.volume = 0.25
        return s
    }()
    private static let stopSound: NSSound? = {
        let s = NSSound(named: "Pop")
        s?.volume = 0.25
        return s
    }()

    static func start() { if Settings.sounds { startSound?.stop(); startSound?.play() } }
    static func stop() { if Settings.sounds { stopSound?.stop(); stopSound?.play() } }
}
