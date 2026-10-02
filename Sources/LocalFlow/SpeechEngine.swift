import Foundation

/// One timed span of recognized text. Times are seconds from the start of
/// the samples handed to the engine.
struct EngineSegment: Equatable, Sendable {
    let text: String
    let start: Float
    let end: Float
}

struct EngineTranscription: Sendable {
    let segments: [EngineSegment]
    /// The engine's own joined hypothesis, for `rawCharacters` and the
    /// `whisperRaw` diagnostic stage.
    let rawText: String
    /// Whisper temperature fallbacks; 0 for engines without them.
    let decodingFallbacks: Int
    /// Whisper returns one result per VAD window; other engines return 1.
    let resultCount: Int
}

/// A loaded speech recognition model. `Transcriber` owns serialization,
/// quarantine and post-processing; an engine only turns 16 kHz mono samples
/// into timed text.
protocol SpeechEngine: AnyObject, Sendable {
    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription
    /// Names and jargon to bias decoding toward. Engines without a decoder
    /// prompt ignore it.
    func setVocabulary(_ terms: String) async
    /// Engine-specific fields for the `inferenceStarted` trace event.
    func inferenceStartFields(lowEnergy: Bool) async -> [DictationTrace.Field: Double]
}

extension SpeechEngine {
    func inferenceStartFields(lowEnergy: Bool) async -> [DictationTrace.Field: Double] { [:] }
}
