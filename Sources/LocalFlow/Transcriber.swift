import Foundation
import WhisperKit

/// A one-permit FIFO gate. WhisperKit's inference entry point is async but
/// mutates shared decoder/progress state, so actor reentrancy alone is not a
/// sufficient serialization boundary.
actor TranscriptionGate {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var occupied = false
    private var waiters: [Waiter] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied {
            occupied = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        // Cancellation can race the handoff. Return the permit if this
        // cancelled request acquired it before cancelWaiter ran.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    func release() {
        guard !waiters.isEmpty else {
            occupied = false
            return
        }
        waiters.removeFirst().continuation.resume()
    }

    var waitingCount: Int { waiters.count }
}

/// Wraps WhisperKit: loads a CoreML Whisper model (downloaded on first use
/// from the argmaxinc/whisperkit-coreml registry) and transcribes 16 kHz
/// mono Float32 sample buffers.
actor Transcriber {
    enum TranscriberError: Error, LocalizedError {
        case notLoaded
        case noSpeech
        case recoveryBusy

        var errorDescription: String? {
            switch self {
            case .notLoaded: return "Whisper model is not loaded yet."
            case .noSpeech: return "No speech was recognized in this recording."
            case .recoveryBusy: return "Speech recognition is still stopping earlier attempts. Try reloading the model again later."
            }
        }
    }

    typealias ModelLoader = (String, DictationTrace) async throws -> WhisperKit
    private let modelLoader: ModelLoader

    init(modelLoader: @escaping ModelLoader = Transcriber.loadEngine) {
        self.modelLoader = modelLoader
    }

    private var whisperKit: WhisperKit?
    private(set) var loadedModel: String?
    private var loadGeneration = 0
    private var transcriptionGate = TranscriptionGate()
    private var engineGeneration = 0
    private var activeEngineGenerations: Set<Int> = []
    private var quarantinedEngineGenerations: Set<Int> = []
    // One CoreML pipeline construction at a time: rapid model switches could
    // otherwise build several multi-hundred-MB pipelines concurrently.
    private let loadGate = TranscriptionGate()
    private var vocabularyText = ""
    private var vocabularyTokens: [Int]?

    var isLoaded: Bool { whisperKit != nil }

    /// Where models are downloaded to. ~/Documents (WhisperKit's default) is
    /// iCloud-synced on many Macs, and "Optimize Mac Storage" can evict the
    /// 500 MB model files to dataless stubs — mysterious load failures.
    /// Migrates the pre-existing cache out of Documents once.
    private static let modelDownloadBase: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
        let repoPath = "models/argmaxinc/whisperkit-coreml"
        let old = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/huggingface/\(repoPath)")
        let new = base.appendingPathComponent(repoPath)
        if fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) {
            do {
                try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: old, to: new)
                DiagLog.log("moved model cache out of ~/Documents to %@", new.path)
            } catch {
                DiagLog.log("model cache migration failed (%@) — will download fresh", error.localizedDescription)
            }
        }
        return base
    }()

    /// Loads (and if needed downloads) the given model. Safe to call again
    /// with a different model name to switch models: the previous pipeline
    /// keeps serving transcriptions until the replacement is actually ready,
    /// so a failed download never strands the app with no model.
    func load(model: String) async throws {
        let trace = DictationTrace(source: .modelLoad)
        trace.record(.modelLoadRequested, model: model)
        if loadedModel == model, whisperKit != nil {
            trace.record(.modelLoadFinished, status: .warm, model: model)
            return
        }
        guard quarantinedEngineGenerations.count < 2 else { throw TranscriberError.recoveryBusy }
        loadGeneration += 1
        let generation = loadGeneration

        trace.record(.modelLoadWaitStarted)
        try await loadGate.acquire()
        trace.record(.modelLoadAcquired)
        // A newer load was requested while this one queued; let it win
        // without building (and briefly double-retaining) a stale pipeline.
        guard generation == loadGeneration else {
            await loadGate.release()
            trace.record(.modelLoadFinished, status: .stale)
            return
        }

        let pipe: WhisperKit
        do {
            guard quarantinedEngineGenerations.count < 2 else { throw TranscriberError.recoveryBusy }
            pipe = try await modelLoader(model, trace)
        } catch {
            await loadGate.release()
            trace.record(.modelLoadFinished, status: error is CancellationError ? .cancelled : .failed)
            throw error
        }
        await loadGate.release()

        // The actor is reentrant across those awaits: a later load may have
        // started (and even finished) meanwhile. Last requested wins.
        guard generation == loadGeneration else {
            trace.record(.modelLoadFinished, status: .stale)
            return
        }
        try Task.checkCancellation()
        guard quarantinedEngineGenerations.count < 2 else { throw TranscriberError.recoveryBusy }
        engineGeneration += 1
        transcriptionGate = TranscriptionGate()
        whisperKit = pipe
        loadedModel = model
        refreshVocabularyTokens()
        trace.record(.modelLoadFinished, status: .success)
    }

    private static func loadEngine(model: String, trace: DictationTrace) async throws -> WhisperKit {
        let cachedFolder = cachedModelFolder(for: model)
        trace.record(.modelCacheChecked, fields: [.cachePresent: cachedFolder == nil ? 0 : 1])
        let pipe: WhisperKit
        if let cachedFolder {
            do {
                pipe = try await measuredLoad(config(modelFolder: cachedFolder), trace: trace)
            } catch {
                trace.record(.modelLoadFallback, status: .fallback)
                // Directory presence is only a fast completeness signal. If
                // CoreML or tokenizer loading finds corruption, let the Hub
                // path verify/repair the cache instead of stranding startup.
                DiagLog.log(
                    "cached model %@ failed to load (%@) — resolving through model registry",
                    model,
                    error.localizedDescription
                )
                pipe = try await measuredLoad(config(model: model), trace: trace)
            }
        } else {
            pipe = try await measuredLoad(config(model: model), trace: trace)
        }
        return pipe
    }

    private static func measuredLoad(_ config: WhisperKitConfig, trace: DictationTrace) async throws -> WhisperKit {
        try await DictationTrace.$current.withValue(trace) {
            trace.record(.modelAttemptStarted)
            do {
                let pipeline = try await StartupMeasuredWhisperKit(config)
                trace.record(.modelAttemptFinished, status: .success)
                return pipeline
            } catch {
                trace.record(.modelAttemptFinished, status: error is CancellationError ? .cancelled : .failed)
                throw error
            }
        }
    }

    /// Names and jargon to bias decoding toward (people, products,
    /// acronyms). Encoded with the loaded model's tokenizer and fed to the
    /// decoder as preceding context on every transcription.
    func setVocabulary(_ terms: String) {
        vocabularyText = terms
        refreshVocabularyTokens()
    }

    private func refreshVocabularyTokens() {
        let trimmed = vocabularyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tokenizer = whisperKit?.tokenizer else {
            vocabularyTokens = nil
            return
        }
        // Whisper treats promptTokens as text that came before, so phrase
        // the vocabulary as prose it might continue. Capped: heavy bias
        // makes the decoder hallucinate the vocabulary into silence.
        let tokens = tokenizer.encode(text: " Glossary: \(trimmed).")
        vocabularyTokens = tokens.isEmpty ? nil : Array(tokens.prefix(96))
    }

    private func currentDecodingOptions(lowEnergy: Bool = false) -> DecodingOptions {
        var options = Self.decodingOptions
        options.promptTokens = vocabularyTokens
        // Near-silent audio can spend six decoder attempts inventing text.
        // Keep the deterministic pass; the pipeline still recovers an unknown
        // empty result using its original audio.
        if lowEnergy { options.temperatureFallbackCount = 0 }
        return options
    }

    private static func config(model: String) -> WhisperKitConfig {
        WhisperKitConfig(
            model: model,
            downloadBase: modelDownloadBase,
            verbose: false,
            load: true
        )
    }

    private static func config(modelFolder: URL) -> WhisperKitConfig {
        WhisperKitConfig(
            downloadBase: modelDownloadBase,
            modelFolder: modelFolder.path,
            verbose: false,
            load: true
        )
    }

    /// Bypass Hub resolution when a complete model is already present. A
    /// partial/interrupted download falls through to WhisperKit's downloader.
    private static func cachedModelFolder(for model: String) -> URL? {
        let folder = modelDownloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent(model, isDirectory: true)
        let requiredModels = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        let complete = requiredModels.allSatisfy { name in
            ["mlmodelc", "mlpackage"].contains { ext in
                FileManager.default.fileExists(
                    atPath: folder.appendingPathComponent("\(name).\(ext)", isDirectory: true).path
                )
            }
        }
        return complete ? folder : nil
    }

    /// `lowEnergy` marks audio whose RMS was near silence: Whisper reliably
    /// invents filler for such clips, so canonical hallucination phrases are
    /// reported as no speech. Never applied to normal-energy audio —
    /// people legitimately dictate "thank you".
    func transcribe(
        samples: [Float],
        lowEnergy: Bool = false
    ) async throws -> String {
        guard whisperKit != nil else { throw TranscriberError.notLoaded }
        let trace = DictationTrace.current
        trace?.record(.engineWaitStarted)
        let lease = try await acquireEngine(lowEnergy: lowEnergy)
        let gate = lease.gate
        let whisperKit = lease.engine
        let options = lease.options
        trace?.record(.engineAcquired, model: lease.model)
        let diagnostic = DictationDiagnosticStore.Recording.current
        let audioFile = "inference-\(UUID().uuidString).wav"
        diagnostic?.saveAudio(samples, named: audioFile)
        diagnostic?.record(.init(stage: "inferenceInput", model: lease.model, audioFile: audioFile, sampleCount: samples.count))
        let results: [TranscriptionResult]
        let text: String
        let isHallucination: Bool
        let raw: String
        do {
            if let trace {
                let voice = AudioRecorder.voicedMetrics(of: samples)
                var inputFields = DictationTrace.runtimeFields()
                inputFields[.samples] = Double(samples.count)
                inputFields[.voicedSeconds] = voice.voicedSeconds
                if voice.voicedDBFS.isFinite {
                    inputFields[.voicedDBFS] = Double(voice.voicedDBFS)
                }
                inputFields[.lowEnergy] = lowEnergy ? 1 : 0
                inputFields[.temperatureFallbackLimit] = Double(options.temperatureFallbackCount)
                trace.record(.inferenceStarted, fields: inputFields)
            }
            results = try await runInference(generation: lease.generation) {
                try await whisperKit.transcribe(audioArray: samples, decodeOptions: options)
            }
            try Task.checkCancellation()
            let inferenceFinishedAt = DispatchTime.now().uptimeNanoseconds
            text = Self.finalize(results)
            isHallucination = lowEnergy && Self.isCanonicalHallucination(text)
            raw = results.map(\.text).joined(separator: " ")
            diagnostic?.record(.init(
                stage: "whisperRaw", text: raw,
                status: Task.isCancelled ? "cancelled" : "success", model: lease.model, audioFile: audioFile,
                segments: results.flatMap { $0.segments.map {
                    .init(text: $0.text, start: $0.start, end: $0.end)
                } }
            ))
            diagnostic?.record(.init(stage: "whisperPostprocessed", text: isHallucination ? "" : text,
                                      status: isHallucination ? "hallucinationFiltered" : "success", audioFile: audioFile))
            if let trace {
                var outputFields = DictationTrace.runtimeFields()
                outputFields[.rawCharacters] = Double(raw.count)
                outputFields[.resultCount] = Double(results.count)
                outputFields[.segmentCount] = Double(results.reduce(0) { $0 + $1.segments.count })
                outputFields[.hallucinationFiltered] = isHallucination ? 1 : 0
                outputFields[.decodingFallbacks] = results.reduce(0) { $0 + $1.timings.totalDecodingFallbacks }
                trace.record(.inferenceFinished, at: inferenceFinishedAt,
                             status: Task.isCancelled ? .cancelled : .success, fields: outputFields)
            }
            await gate.release()
        } catch {
            trace?.record(.inferenceFinished, status: Task.isCancelled || error is CancellationError ? .cancelled : .failed,
                          fields: DictationTrace.runtimeFields())
            await gate.release()
            throw error
        }
        if text.isEmpty || isHallucination {
            // A healthy-audio dictation has produced an empty transcript in
            // the field; the raw hypothesis SIZE tells whether Whisper
            // returned nothing or post-processing ate a real result. Never
            // log the content itself — the diag file must stay free of
            // dictated text.
            DiagLog.log("[diag] empty transcript: rawChars=%d results=%d lowEnergy=%d",
                  raw.count, results.count, lowEnergy ? 1 : 0)
        }
        // Preserve the distinction from an unexplained empty recognition result.
        // Retrying a result we already filtered as non-speech repeats the delay.
        if isHallucination { throw TranscriberError.noSpeech }
        try Task.checkCancellation()
        return text
    }

    /// Transcribes an audio file (any AVFoundation-readable format).
    /// Used by the `--transcribe` CLI mode for testing and benchmarking.
    func transcribe(file path: String) async throws -> String {
        guard whisperKit != nil else { throw TranscriberError.notLoaded }
        let trace = DictationTrace.current
        trace?.record(.engineWaitStarted)
        let lease = try await acquireEngine(lowEnergy: false)
        let gate = lease.gate
        let whisperKit = lease.engine
        let options = lease.options
        trace?.record(.engineAcquired, model: lease.model)
        let results: [TranscriptionResult]
        do {
            trace?.record(.inferenceStarted)
            results = try await runInference(generation: lease.generation) {
                try await whisperKit.transcribe(audioPath: path, decodeOptions: options)
            }
            try Task.checkCancellation()
            trace?.record(.inferenceFinished, status: .success)
            await gate.release()
        } catch {
            trace?.record(.inferenceFinished, status: Task.isCancelled || error is CancellationError ? .cancelled : .failed)
            await gate.release()
            throw error
        }
        try Task.checkCancellation()
        return Self.finalize(results)
    }

    private func acquireEngine(lowEnergy: Bool) async throws -> (
        gate: TranscriptionGate, engine: WhisperKit, options: DecodingOptions,
        generation: Int, model: String?
    ) {
        while true {
            let gate = transcriptionGate
            try await gate.acquire()
            if Task.isCancelled {
                await gate.release()
                throw CancellationError()
            }
            if gate === transcriptionGate, let whisperKit {
                // Snapshot everything before returning across another await.
                return (gate, whisperKit, currentDecodingOptions(lowEnergy: lowEnergy), engineGeneration, loadedModel)
            }
            await gate.release()
            guard whisperKit != nil else { throw TranscriberError.notLoaded }
            // A normal model switch leaves queued requests eligible to use
            // the replacement engine with its own gate and vocabulary.
        }
    }

    private func runInference(
        generation: Int,
        _ infer: () async throws -> [TranscriptionResult]
    ) async throws -> [TranscriptionResult] {
        try Task.checkCancellation()
        activeEngineGenerations.insert(generation)
        defer {
            activeEngineGenerations.remove(generation)
            quarantinedEngineGenerations.remove(generation)
        }
        return try await withTaskCancellationHandler {
            let result = try await infer()
            try Task.checkCancellation()
            return result
        } onCancel: {
            Task { await self.quarantineEngine(generation: generation) }
        }
    }

    private func quarantineEngine(generation: Int) {
        guard activeEngineGenerations.contains(generation) else { return }
        quarantinedEngineGenerations.insert(generation)
        guard generation == engineGeneration else { return }
        whisperKit = nil
        loadedModel = nil
        vocabularyTokens = nil
        // The old call owns its old gate until inference actually returns.
        // Only a new model instance may use this replacement gate.
        transcriptionGate = TranscriptionGate()
        engineGeneration += 1
    }

    private static let decodingOptions: DecodingOptions = {
        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0
        options.language = "en"
        // Don't decode <|...|> markers into the transcript at all (the
        // regex stripper below stays as a second line of defense).
        options.skipSpecialTokens = true
        options.suppressBlank = true
        // Chunk long captures at detected speech gaps instead of blind 30s
        // windows: fewer mid-word window boundaries on multi-minute
        // dictations. Timestamps stay ON: paragraph detection needs them.
        options.chunkingStrategy = .vad
        return options
    }()

    /// The transcripts Whisper canonically hallucinates for (near-)silent
    /// audio — trained-in YouTube outro artifacts. Whole-transcript match,
    /// case- and punctuation-insensitive.
    private static let hallucinationPhrases: Set<String> = [
        "thank you", "thanks for watching", "thank you for watching",
        "you", "bye", "thanks",
    ]

    static func isCanonicalHallucination(_ text: String) -> Bool {
        let normalized = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return hallucinationPhrases.contains(normalized)
    }

    private static func finalize(_ results: [TranscriptionResult]) -> String {
        joinSegments(results.flatMap { result in
            result.segments.map { (text: $0.text, start: $0.start, end: $0.end) }
        })
    }

    /// A long silence between segments is the speaker moving to a new
    /// thought, so insert a paragraph break there so dictated text doesn't
    /// come out as one wall of prose. Conservative on purpose: the previous
    /// segment must end a sentence (a thinking pause mid-sentence is not a
    /// paragraph), and the gap must be well beyond a breath.
    static let paragraphPauseSeconds: Float = 1.75

    static func joinSegments(_ segments: [(text: String, start: Float, end: Float)]) -> String {
        var output = ""
        var previousEnd: Float?
        for segment in segments {
            let text = stripSpecialTokens(from: segment.text)
            // Empty segments (markers, silence) don't move `previousEnd`:
            // the silence they span still counts toward the pause.
            guard !text.isEmpty else { continue }
            if !output.isEmpty {
                if let previousEnd,
                   segment.start - previousEnd >= paragraphPauseSeconds,
                   endsSentence(output) {
                    output += "\n\n"
                } else {
                    output += " "
                }
            }
            output += text
            previousEnd = segment.end
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func joinTranscriptParts(
        _ first: String,
        _ second: String,
        pauseSeconds: Double = 0
    ) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        let separator = pauseSeconds >= Double(paragraphPauseSeconds) && endsSentence(first)
            ? "\n\n"
            : " "
        return first + separator + second
    }

    private static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return last == "." || last == "!" || last == "?" || last == "…"
    }

    /// Whisper sometimes emits bracketed markers like [BLANK_AUDIO] or (music).
    /// Only strip what looks like a marker — dictated text legitimately
    /// contains brackets and parentheses (e.g. "f(x)").
    static func stripSpecialTokens(from text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let withoutMarkers = specialTokenRegex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: ""
        )
        let cleanedRange = NSRange(withoutMarkers.startIndex..<withoutMarkers.endIndex, in: withoutMarkers)
        return repeatedSpacesRegex.stringByReplacingMatches(
            in: withoutMarkers,
            range: cleanedRange,
            withTemplate: " "
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let specialTokenRegex: NSRegularExpression = {
        let languages = Constants.languages.values
            .map(NSRegularExpression.escapedPattern(for:)).sorted().joined(separator: "|")
        return try! NSRegularExpression(
            pattern: #"(?i:\[(?:blank_audio|music|laughs|laughter|applause|noise|silence|inaudible|coughs)\]|\((?:music|laughs|laughter|applause|noise|silence|inaudible|coughs)\))|<\|(?:endoftext|startoftranscript|startofprev|startoflm|transcribe|translate|notimestamps|nospeech|nocaptions|\#(languages)|[0-9]+\.[0-9]{2})\|>"#
        )
    }()
    private static let repeatedSpacesRegex = try! NSRegularExpression(pattern: " {2,}")
}
