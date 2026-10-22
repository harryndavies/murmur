import AVFoundation
import Speech

/// Apple's on-device speech model (macOS 26 SpeechAnalyzer). Free, private, no network.
final class SpeechEngine {
    enum EngineError: LocalizedError {
        case unsupportedLocale
        case noAudioFormat

        var errorDescription: String? {
            switch self {
            case .unsupportedLocale: return "Your language isn't supported by on-device speech recognition"
            case .noAudioFormat: return "Speech model has no compatible audio format"
            }
        }
    }

    let locale: Locale
    let audioFormat: AVAudioFormat

    private init(locale: Locale, audioFormat: AVAudioFormat) {
        self.locale = locale
        self.audioFormat = audioFormat
    }

    /// Resolves the locale, downloads the speech model if needed and loads it into memory.
    static func prepare(statusUpdate: @escaping (String) -> Void = { _ in }) async throws -> SpeechEngine {
        var resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
        if resolved == nil {
            resolved = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US"))
        }
        guard let locale = resolved else { throw EngineError.unsupportedLocale }

        let transcriber = makeTranscriber(locale: locale)
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                statusUpdate("Downloading speech model…")
                try await request.downloadAndInstall()
            }
        }

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noAudioFormat
        }

        // Load the model now so the first dictation isn't slow.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: analyzerOptions)
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()

        return SpeechEngine(locale: locale, audioFormat: format)
    }

    static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: []
        )
    }

    static let analyzerOptions = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .processLifetime)

    func makeSession(vocabulary: [String], onPartial: @escaping @Sendable (String) -> Void) -> LiveTranscription {
        LiveTranscription(
            transcriber: Self.makeTranscriber(locale: locale),
            format: audioFormat,
            vocabulary: vocabulary,
            onPartial: onPartial
        )
    }
}

/// One dictation. Audio can be appended immediately (it's buffered) while the
/// analyzer spins up in the background, so the first word isn't clipped.
final class LiveTranscription: @unchecked Sendable {
    let format: AVAudioFormat
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var startTask: Task<Void, Error>!
    private var resultsTask: Task<String, Error>!

    init(transcriber: SpeechTranscriber, format: AVAudioFormat, vocabulary: [String], onPartial: @escaping @Sendable (String) -> Void) {
        self.transcriber = transcriber
        self.format = format
        self.analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechEngine.analyzerOptions)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.input = continuation

        resultsTask = Task {
            var finalized = ""
            var volatile = ""
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    volatile = ""
                } else {
                    volatile = text
                }
                onPartial(finalized + volatile)
            }
            return finalized
        }

        startTask = Task { [analyzer] in
            if !vocabulary.isEmpty {
                let context = AnalysisContext()
                context.contextualStrings[.general] = vocabulary
                try? await analyzer.setContext(context)
            }
            try await analyzer.start(inputSequence: stream)
        }
    }

    /// Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Stops listening and returns the final transcript.
    func finish() async throws -> String {
        input.finish()
        try await startTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await resultsTask.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cancel() {
        input.finish()
        Task { [analyzer] in await analyzer.cancelAndFinishNow() }
        resultsTask.cancel()
    }
}
