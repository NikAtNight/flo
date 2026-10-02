import Foundation

enum TranscriptionEngine: String {
    case whisper, parakeet
}

/// A selectable speech model. The id is persisted in the existing
/// "whisperModel" UserDefaults key, so no migration is needed.
struct TranscriptionModel: Equatable, Identifiable {
    let id: String
    let engine: TranscriptionEngine
    let label: String
    /// Heading for picker sections and menu separators.
    let group: String

    static let parakeetV3ID = "parakeet-tdt-0.6b-v3"
    static let defaultID = "openai_whisper-large-v3-v20240930_turbo"

    /// Whisper models come from the argmaxinc/whisperkit-coreml registry,
    /// ordered from development-speed models to the best dictation models.
    /// Large v3 Turbo is the default: on Apple silicon it decodes fast
    /// enough for dictation and is the single biggest accuracy lever.
    static let all: [TranscriptionModel] = [
        whisper("openai_whisper-tiny.en", "Tiny English (development only)"),
        whisper("openai_whisper-base.en", "Base English (fast, lower accuracy)"),
        whisper("openai_whisper-small.en", "Small English (fastest useful)"),
        whisper("openai_whisper-large-v3-v20240930_626MB", "Large v3 626 MB (compact, high accuracy)"),
        whisper(defaultID, "Large v3 Turbo (best accuracy, default)"),
    ]

    /// Unknown ids are treated as WhisperKit registry names so
    /// `--whisper-model` and test ids keep working.
    static func engine(forID id: String) -> TranscriptionEngine {
        if id == parakeetV3ID { return .parakeet }
        return all.first { $0.id == id }?.engine ?? .whisper
    }

    private static func whisper(_ id: String, _ label: String) -> TranscriptionModel {
        TranscriptionModel(id: id, engine: .whisper, label: label, group: "Whisper")
    }
}
