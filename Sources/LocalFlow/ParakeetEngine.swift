import CoreML
import FluidAudio
import Foundation

// Only this file imports FluidAudio, and it must never import WhisperKit:
// both export `WordTiming` and `Tokenizer`.

/// NVIDIA Parakeet TDT 0.6B v3 on CoreML through FluidAudio. No decoder
/// prompt, so custom vocabulary does nothing here; corrections still apply as
/// text replacements after transcription.
final class ParakeetEngine: SpeechEngine {
    /// Short clips are padded with trailing silence to this length. FluidAudio
    /// rejects anything under 0.3 s and can return no tokens for very short
    /// speech.
    static let minimumSeconds = 1.5
    /// Clips over 15 s are decoded in windows. `nil` lets FluidAudio pick per
    /// model version (it resolves to `false` for v3). Revisit with replay.
    static let melChunkContext: Bool? = nil

    static let modelsDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("LocalFlow/models/FluidAudio", isDirectory: true)

    /// FluidAudio takes the repo folder itself and downloads into its parent.
    private static var repoDirectory: URL {
        modelsDirectory.appendingPathComponent(
            AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent, isDirectory: true
        )
    }

    private let asr: AsrManager
    private let decoderLayers: Int

    private init(asr: AsrManager, decoderLayers: Int) {
        self.asr = asr
        self.decoderLayers = decoderLayers
    }

    /// Downloads (about 480 MB, once) and loads the model. A cold first load
    /// also compiles the CoreML models for this Mac. FluidAudio repairs a
    /// corrupt cache itself by deleting and re-downloading it, so there is no
    /// separate fallback path here.
    static func load(trace: DictationTrace) async throws -> ParakeetEngine {
        let directory = repoDirectory
        let cached = AsrModels.modelsExist(at: directory, version: .v3, encoderPrecision: .int8)
        trace.record(.modelCacheChecked, fields: [.cachePresent: cached ? 1 : 0])
        trace.record(.modelAttemptStarted)
        do {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
            let modelDirectory = try await AsrModels.download(to: directory, version: .v3, encoderPrecision: .int8)
            trace.record(.modelInitializationStarted)
            let engine: ParakeetEngine
            do {
                let models = try await AsrModels.load(from: modelDirectory, version: .v3, encoderPrecision: .int8)
                let asr = AsrManager(config: ASRConfig(melChunkContext: melChunkContext))
                try await asr.loadModels(models)
                engine = ParakeetEngine(asr: asr, decoderLayers: await asr.decoderLayerCount)
                trace.record(.modelInitializationFinished, status: .success)
            } catch {
                trace.record(.modelInitializationFinished, status: error is CancellationError ? .cancelled : .failed)
                throw error
            }
            trace.record(.modelAttemptFinished, status: .success)
            return engine
        } catch {
            trace.record(.modelAttemptFinished, status: error is CancellationError ? .cancelled : .failed)
            throw error
        }
    }

    func setVocabulary(_ terms: String) async {}

    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription {
        let input = Self.padded(samples)
        // A fresh state per call: a cancelled call must not leak decoder
        // state into the next one.
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(input, decoderState: &state)
        let tokens = result.tokenTimings?.map {
            Token(text: $0.token, start: $0.startTime, end: $0.endTime)
        }
        return EngineTranscription(
            segments: Self.segments(text: result.text, tokens: tokens, duration: Float(result.duration)),
            rawText: result.text,
            decodingFallbacks: 0,
            resultCount: 1
        )
    }

    // MARK: - Pure helpers (no FluidAudio types, unit-tested)

    struct Token: Equatable {
        let text: String
        let start: Double
        let end: Double
    }

    /// Pads with trailing zeros up to `minimumSeconds`. Longer input is
    /// returned unchanged. Leading silence is already trimmed upstream.
    static func padded(
        _ samples: [Float],
        sampleRate: Int = 16_000,
        minimumSeconds: Double = minimumSeconds
    ) -> [Float] {
        let minimum = Int((Double(sampleRate) * minimumSeconds).rounded(.up))
        guard samples.count < minimum else { return samples }
        return samples + [Float](repeating: 0, count: minimum - samples.count)
    }

    /// Splits the transcript where a long pause follows the end of a
    /// sentence, so `Transcriber.joinSegments` can apply its paragraph rule.
    /// Token text marks word starts with the SentencePiece "▁" (or a leading
    /// space). If the tokens don't rebuild `text` exactly, returns one
    /// segment: output is never worse than the engine's own text.
    static func segments(
        text: String,
        tokens: [Token]?,
        duration: Float,
        pauseSeconds: Float = Transcriber.paragraphPauseSeconds
    ) -> [EngineSegment] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let whole = [EngineSegment(text: trimmed, start: 0, end: duration)]
        guard let tokens, let first = tokens.first else { return whole }

        var segments: [EngineSegment] = []
        var current = ""
        var start = first.start
        var end = first.end
        for token in tokens {
            let piece = token.text.replacingOccurrences(of: "\u{2581}", with: " ")
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty,
               token.start - end >= Double(pauseSeconds),
               Transcriber.endsSentence(sentence) {
                segments.append(EngineSegment(text: sentence, start: Float(start), end: Float(end)))
                current = ""
                start = token.start
            }
            current += piece
            end = token.end
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty {
            segments.append(EngineSegment(text: last, start: Float(start), end: Float(end)))
        }

        let rebuilt = segments.map(\.text).joined(separator: " ")
        return collapsed(rebuilt) == collapsed(trimmed) ? segments : whole
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
