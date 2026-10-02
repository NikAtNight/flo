import Foundation
import WhisperKit

/// Wraps one WhisperKit pipeline: loads a CoreML Whisper model (downloaded on
/// first use from the argmaxinc/whisperkit-coreml registry) and transcribes
/// 16 kHz mono Float32 sample buffers. Being an actor serializes decoding
/// options with vocabulary changes.
actor WhisperEngine: SpeechEngine {
    private let pipeline: WhisperKit
    private var vocabularyTokens: [Int]?

    init(pipeline: WhisperKit) {
        self.pipeline = pipeline
    }

    /// Where models are downloaded to. ~/Documents (WhisperKit's default) is
    /// iCloud-synced on many Macs, and "Optimize Mac Storage" can evict the
    /// 500 MB model files to dataless stubs, which fail to load in confusing ways.
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
                DiagLog.log("model cache migration failed (%@), will download fresh", error.localizedDescription)
            }
        }
        return base
    }()

    static func load(model: String, trace: DictationTrace) async throws -> WhisperEngine {
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
                    "cached model %@ failed to load (%@), resolving through model registry",
                    model,
                    error.localizedDescription
                )
                pipe = try await measuredLoad(config(model: model), trace: trace)
            }
        } else {
            pipe = try await measuredLoad(config(model: model), trace: trace)
        }
        return WhisperEngine(pipeline: pipe)
    }

    /// Reads any AVFoundation-readable audio file as 16 kHz mono samples.
    static func loadSamples(path: String) throws -> [Float] {
        try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
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

    /// Encoded with the loaded model's tokenizer and fed to the decoder as
    /// preceding context on every transcription.
    func setVocabulary(_ terms: String) {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tokenizer = pipeline.tokenizer else {
            vocabularyTokens = nil
            return
        }
        // Whisper treats promptTokens as text that came before, so phrase
        // the vocabulary as prose it might continue. Capped: heavy bias
        // makes the decoder hallucinate the vocabulary into silence.
        let tokens = tokenizer.encode(text: " Glossary: \(trimmed).")
        vocabularyTokens = tokens.isEmpty ? nil : Array(tokens.prefix(96))
    }

    func inferenceStartFields(lowEnergy: Bool) -> [DictationTrace.Field: Double] {
        [.temperatureFallbackLimit: Double(decodingOptions(lowEnergy: lowEnergy).temperatureFallbackCount)]
    }

    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription {
        let results = try await pipeline.transcribe(
            audioArray: samples,
            decodeOptions: decodingOptions(lowEnergy: lowEnergy)
        )
        return EngineTranscription(
            segments: results.flatMap { result in
                result.segments.map { EngineSegment(text: $0.text, start: $0.start, end: $0.end) }
            },
            rawText: results.map(\.text).joined(separator: " "),
            decodingFallbacks: Int(results.reduce(0) { $0 + $1.timings.totalDecodingFallbacks }),
            resultCount: results.count
        )
    }

    private func decodingOptions(lowEnergy: Bool) -> DecodingOptions {
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

    private static let decodingOptions: DecodingOptions = {
        var options = DecodingOptions()
        options.task = .transcribe
        options.temperature = 0
        options.language = "en"
        // Don't decode <|...|> markers into the transcript at all
        // (Transcriber.stripSpecialTokens stays as a second line of defense).
        options.skipSpecialTokens = true
        options.suppressBlank = true
        // Chunk long captures at detected speech gaps instead of blind 30s
        // windows: fewer mid-word window boundaries on multi-minute
        // dictations. Timestamps stay ON: paragraph detection needs them.
        options.chunkingStrategy = .vad
        return options
    }()
}
