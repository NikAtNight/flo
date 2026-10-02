import Foundation

/// How often a held dictation is transcribed for live text. Whisper Turbo
/// took 350 to 975 ms per chunk, so it waits 8 s and ticks every 4 s.
/// Parakeet took 40 to 90 ms on the same clips, so it can start at 4 s and
/// tick every 2 s.
struct IncrementalCadence: Equatable {
    let startSeconds: TimeInterval
    let tickSeconds: TimeInterval

    static let whisper = IncrementalCadence(startSeconds: 8, tickSeconds: 4)
    static let parakeet = IncrementalCadence(startSeconds: 4, tickSeconds: 2)

    static func forModel(_ id: String) -> IncrementalCadence {
        switch TranscriptionModel.engine(forID: id) {
        case .whisper: .whisper
        case .parakeet: .parakeet
        }
    }
}

struct DictationSessionContext {
    let cleanupEnabled: Bool
    let styleProfile: AppStyleProfile
    let corrections: [(wrong: String, right: String)]
    let snippets: [(trigger: String, expansion: String)]
    let ollamaModel: String
    let incrementalCadence: IncrementalCadence

    init(
        cleanupEnabled: Bool,
        styleProfile: AppStyleProfile,
        corrections: [(wrong: String, right: String)],
        snippets: [(trigger: String, expansion: String)],
        ollamaModel: String = "",
        incrementalCadence: IncrementalCadence = .whisper
    ) {
        self.cleanupEnabled = cleanupEnabled
        self.styleProfile = styleProfile
        self.corrections = corrections
        self.snippets = snippets
        self.ollamaModel = ollamaModel
        self.incrementalCadence = incrementalCadence
    }
}

enum DictationTranscriptionSegment: Equatable, Codable, Sendable {
    case incrementalChunk(index: Int)
    case releaseTail
    case fullUtterance
}

/// Shared admission and decoder preparation for live dictation, commands, and replay.
struct DictationAudioPreparation {
    let samples: [Float]
    let voicedSeconds: Double
    let voicedDBFS: Float
    let rawVoicedSeconds: Double

    init(samples: [Float]) {
        rawVoicedSeconds = AudioRecorder.voicedMetrics(of: samples).voicedSeconds
        self.samples = AudioRecorder.trimmingSilence(samples)
        let voice = AudioRecorder.voicedMetrics(of: self.samples)
        voicedSeconds = voice.voicedSeconds
        voicedDBFS = voice.voicedDBFS
    }

    var isAdmitted: Bool { voicedSeconds >= 0.3 }
    // Recovery historically uses the original analysis windows. Trimming can
    // shift their alignment, so admission and recovery keep distinct metrics.
    var canRetryEmptyResult: Bool { rawVoicedSeconds >= 0.3 }
    var lowEnergy: Bool { voicedDBFS < -40 }
    var duration: TimeInterval { Double(samples.count) / AudioRecorder.sampleRate }
}

struct DictationTranscriptionRequest {
    let generation: Int
    let segment: DictationTranscriptionSegment
    let samples: [Float]
    let lowEnergy: Bool
}

struct DictationCleanupRequest {
    let generation: Int
    let text: String
    let context: DictationSessionContext
}

enum DictationSessionOutcome: Equatable {
    case finalTranscript(generation: Int, text: String)
    case insufficientVoice(generation: Int)
    case emptyTranscript(generation: Int)
    case failed(generation: Int, message: String)
}

/// Owns the asynchronous lifetime of dictations after recording begins.
/// AppKit supplies audio snapshots and handles the eventual paste, while this
/// coordinator keeps chunking, fallback, cleanup, cancellation, and delivery
/// order consistent across overlapping generations.
@MainActor
final class DictationSessionPipeline {
    typealias Transcribe = (DictationTranscriptionRequest) async throws -> String
    typealias Cleanup = (DictationCleanupRequest) async -> TranscriptCleanupResult
    typealias OutcomeHandler = (DictationSessionOutcome) -> Void

    private struct IncrementalChunk {
        let index: Int
        let audio: DictationAudioPreparation
        let pauseSecondsBefore: Double
        let sourceEndIndex: Int?
    }

    private struct ReleaseAudio {
        let full: DictationAudioPreparation
        let tail: DictationAudioPreparation
    }

    private final class Session {
        let generation: Int
        let context: DictationSessionContext
        let trace: DictationTrace?
        let diagnostics: DictationDiagnosticStore.Recording?
        let personalVoice: PersonalVoiceStore.Recording?
        var capturedAudioSaved = false
        var pendingChunks: [IncrementalChunk] = []
        var activeTask: Task<Void, Never>?
        /// Text cleanup never touches the speech engine, so it is always
        /// safe to cancel.
        var activeTaskIsCleanup = false
        var releaseAudio: ReleaseAudio?
        var committedText = ""
        var chunkCount = 0
        var nextChunkIndex = 0
        var nextPauseSeconds = 0.0
        var incrementalSampleEnd = 0
        var completedSampleEnd = 0
        var incrementalFailed = false
        var cancelled = false
        var releaseTimeout: DispatchWorkItem?

        init(generation: Int, context: DictationSessionContext, trace: DictationTrace?, diagnostics: DictationDiagnosticStore.Recording?, personalVoice: PersonalVoiceStore.Recording?) {
            self.generation = generation
            self.context = context
            self.trace = trace
            self.diagnostics = diagnostics
            self.personalVoice = personalVoice
        }
    }

    private let transcribe: Transcribe
    private let cleanup: Cleanup
    private let onOutcome: OutcomeHandler
    private let onPartialTranscript: ((Int, String) -> Void)?
    private let stalledGenerationTimeout: TimeInterval
    private var sessions: [Int: Session] = [:]
    private var generationOrder: [Int] = []
    private var completed: [Int: (outcome: DictationSessionOutcome, trace: DictationTrace?)] = [:]
    private var cancelled: Set<Int> = []

    init(
        transcribe: @escaping Transcribe,
        cleanup: @escaping Cleanup,
        onOutcome: @escaping OutcomeHandler,
        onPartialTranscript: ((Int, String) -> Void)? = nil,
        stalledGenerationTimeout: TimeInterval = 90
    ) {
        self.transcribe = transcribe
        self.cleanup = cleanup
        self.onOutcome = onOutcome
        self.onPartialTranscript = onPartialTranscript
        self.stalledGenerationTimeout = stalledGenerationTimeout
    }

    func begin(generation: Int, context: DictationSessionContext, trace: DictationTrace? = DictationTrace.current,
               diagnostics: DictationDiagnosticStore.Recording? = nil, personalVoice: PersonalVoiceStore.Recording? = nil) {
        if sessions[generation] != nil || generationOrder.contains(generation) {
            cancel(generation: generation)
        }
        sessions[generation] = Session(generation: generation, context: context, trace: trace, diagnostics: diagnostics, personalVoice: personalVoice)
        trace?.retain(in: diagnostics)
        trace?.record(.sessionStarted, fields: [.cleanupEnabled: context.cleanupEnabled ? 1 : 0], model: context.ollamaModel)
        generationOrder.append(generation)
    }

    func canAcceptIncrementalChunk(generation: Int) -> Bool {
        guard let session = sessions[generation] else { return false }
        return !session.cancelled
            && !session.incrementalFailed
            && session.releaseAudio == nil
            && session.activeTask == nil
            && session.pendingChunks.isEmpty
    }

    func incrementalSampleEnd(generation: Int) -> Int? {
        sessions[generation]?.incrementalSampleEnd
    }

    /// Shared by live capture and file replay so benchmarks use the same
    /// thresholds and chunk acceptance rules as dictation.
    func processIncrementalSnapshot(generation: Int, samples: [Float]) {
        guard let session = sessions[generation] else { return }
        let trace = session.trace
        trace?.record(.incrementalAttempt, fields: [.samples: Double(samples.count)])
        guard samples.count >= Int(session.context.incrementalCadence.startSeconds * AudioRecorder.sampleRate) else {
            trace?.record(.incrementalSkipped, status: .tooShort)
            return
        }
        guard canAcceptIncrementalChunk(generation: generation) else {
            trace?.record(.incrementalSkipped, status: .busy)
            return
        }
        let start = incrementalSampleEnd(generation: generation) ?? 0
        guard let cut = AudioRecorder.incrementalCutPoint(in: samples, after: start) else {
            trace?.record(.incrementalSkipped, status: .noBoundary)
            return
        }
        let chunk = DictationAudioPreparation(samples: Array(samples[start..<cut]))
        guard chunk.isAdmitted else {
            trace?.record(.incrementalSkipped, status: .insufficientVoice)
            return
        }
        processIncrementalChunk(
            generation: generation, audio: chunk,
            pauseSecondsAfterChunk: AudioRecorder.incrementalPauseSeconds(in: samples, around: cut),
            sourceEndIndex: cut
        )
    }

    func processIncrementalChunk(
        generation: Int,
        samples: [Float],
        pauseSecondsAfterChunk: Double,
        sourceEndIndex: Int? = nil
    ) {
        processIncrementalChunk(
            generation: generation, audio: DictationAudioPreparation(samples: samples),
            pauseSecondsAfterChunk: pauseSecondsAfterChunk, sourceEndIndex: sourceEndIndex
        )
    }

    private func processIncrementalChunk(
        generation: Int,
        audio: DictationAudioPreparation,
        pauseSecondsAfterChunk: Double,
        sourceEndIndex: Int?
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              !session.incrementalFailed,
              session.releaseAudio == nil else { return }

        let chunk = IncrementalChunk(
            index: session.nextChunkIndex,
            audio: audio,
            pauseSecondsBefore: session.nextPauseSeconds,
            sourceEndIndex: sourceEndIndex
        )
        session.nextChunkIndex += 1
        session.nextPauseSeconds = pauseSecondsAfterChunk
        if let sourceEndIndex {
            session.incrementalSampleEnd = sourceEndIndex
        }
        session.pendingChunks.append(chunk)
        session.trace?.record(.chunkSubmitted, fields: [
            .chunkIndex: Double(chunk.index), .samples: Double(audio.samples.count),
            .submittedEnd: Double(session.incrementalSampleEnd)
        ])
        advance(session)
    }

    func recordCapturedAudio(generation: Int, samples: [Float], nativeAudio: NativeAudioRecording? = nil) {
        guard let session = sessions[generation], !session.capturedAudioSaved else { return }
        session.capturedAudioSaved = true
        session.diagnostics?.saveAudio(samples)
        session.personalVoice?.capture(native: nativeAudio, fallback: samples)
        session.diagnostics?.record(.init(stage: "capture", sampleCount: samples.count))
    }

    func release(
        generation: Int,
        fullSamples: [Float],
        tailSamples: [Float]? = nil
    ) {
        guard let session = sessions[generation],
              !session.cancelled,
              session.releaseAudio == nil else { return }

        recordCapturedAudio(generation: generation, samples: fullSamples)
        let full = DictationAudioPreparation(samples: fullSamples)
        guard full.isAdmitted else {
            session.activeTask?.cancel()
            session.activeTask = nil
            session.pendingChunks.removeAll()
            complete(session, with: .insufficientVoice(generation: generation))
            return
        }
        let derivedTail: [Float]
        if let tailSamples {
            derivedTail = tailSamples
        } else if session.incrementalSampleEnd <= fullSamples.count {
            derivedTail = Array(fullSamples[session.incrementalSampleEnd...])
        } else {
            derivedTail = []
            session.incrementalFailed = true
        }
        session.releaseAudio = ReleaseAudio(
            full: full,
            tail: DictationAudioPreparation(samples: derivedTail)
        )
        session.trace?.record(.audioReleased, fields: [
            .samples: Double(fullSamples.count), .tailSamples: Double(derivedTail.count),
            .submittedEnd: Double(session.incrementalSampleEnd),
            .completedEnd: Double(session.completedSampleEnd)
        ])
        advance(session)
        scheduleReleaseTimeout(for: session)
    }

    /// `interruptInference: false` abandons the session without cancelling
    /// its running task. Cancelling a task inside speech inference makes the
    /// transcriber quarantine its engine, which is right for a stall but would
    /// unload the model on every Escape. The abandoned task's result is
    /// dropped by `isCurrent` when it returns, and the transcription gate
    /// holds any new dictation until then. Text cleanup is still cancelled.
    func cancel(generation: Int, interruptInference: Bool = true) {
        let trace = sessions[generation]?.trace ?? completed[generation]?.trace
        trace?.record(.cancellationRequested)
        if let session = sessions.removeValue(forKey: generation) {
            session.releaseTimeout?.cancel()
            session.diagnostics?.record(.init(stage: "outcome", status: "cancelled"))
            session.personalVoice?.finish(status: "cancelled")
            session.cancelled = true
            session.pendingChunks.removeAll()
            if interruptInference || session.activeTaskIsCleanup {
                session.activeTask?.cancel()
            }
            session.activeTask = nil
        }
        guard generationOrder.contains(generation) else { return }
        completed.removeValue(forKey: generation)
        cancelled.insert(generation)
        drainCompletedOutcomes()
    }

    private func advance(_ session: Session) {
        guard !session.cancelled, session.activeTask == nil else { return }

        if session.incrementalFailed {
            guard let release = session.releaseAudio else { return }
            transcribeFullUtterance(session, audio: release.full, isRetry: true)
            return
        }

        if !session.pendingChunks.isEmpty {
            transcribeNextChunk(session)
            return
        }

        guard let release = session.releaseAudio else { return }
        if session.chunkCount == 0 {
            transcribeFullUtterance(session, audio: release.full)
        } else {
            transcribeTail(session, release: release)
        }
    }

    private func transcribeNextChunk(_ session: Session) {
        let chunk = session.pendingChunks.removeFirst()
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .incrementalChunk(index: chunk.index),
            samples: chunk.audio.samples,
            lowEnergy: chunk.audio.lowEnergy
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let text = request.samples.isEmpty
                    ? "" : try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                guard !text.isEmpty else {
                    session.incrementalFailed = true
                    session.pendingChunks.removeAll()
                    advance(session)
                    return
                }
                session.committedText = Transcriber.joinTranscriptParts(
                    session.committedText,
                    text,
                    pauseSeconds: chunk.pauseSecondsBefore
                )
                onPartialTranscript?(session.generation, session.committedText)
                session.chunkCount += 1
                session.completedSampleEnd = chunk.sourceEndIndex ?? session.completedSampleEnd
                session.trace?.record(.chunkCompleted, fields: [
                    .chunkIndex: Double(chunk.index), .completedEnd: Double(session.completedSampleEnd)
                ])
                advance(session)
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                session.incrementalFailed = true
                session.pendingChunks.removeAll()
                advance(session)
            }
        }
    }

    private func transcribeTail(_ session: Session, release: ReleaseAudio) {
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .releaseTail,
            samples: release.tail.samples,
            lowEnergy: release.tail.lowEnergy
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                // Quiet nonzero tails can contain final words below the admission
                // threshold. Only skip digital silence, including an empty tail.
                let tailText = request.samples.allSatisfy({ $0 == 0 })
                    ? "" : try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                let voicedTail = release.tail.rawVoicedSeconds > 0
                guard !tailText.isEmpty || !voicedTail else {
                    session.incrementalFailed = true
                    advance(session)
                    return
                }
                let wholeText = Transcriber.joinTranscriptParts(
                    session.committedText,
                    tailText,
                    pauseSeconds: session.nextPauseSeconds
                )
                onPartialTranscript?(session.generation, wholeText)
                finalize(session, transcript: wholeText)
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                session.incrementalFailed = true
                advance(session)
            }
        }
    }

    private func transcribeFullUtterance(_ session: Session, audio: DictationAudioPreparation, isRetry: Bool = false) {
        if isRetry {
            session.trace?.record(.fullRetry, fields: [.samples: Double(audio.samples.count)])
        }
        let request = DictationTranscriptionRequest(
            generation: session.generation,
            segment: .fullUtterance,
            samples: audio.samples,
            lowEnergy: audio.lowEnergy
        )
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            do {
                let text = try await runTranscription(request, session: session)
                guard isCurrent(session) else { return }
                session.activeTask = nil
                if text.isEmpty {
                    // Chunk fallback already spends the session's one recovery attempt.
                    if !isRetry, audio.canRetryEmptyResult {
                        transcribeFullUtterance(session, audio: audio, isRetry: true)
                    } else {
                        complete(session, with: .emptyTranscript(generation: session.generation))
                    }
                } else {
                    finalize(session, transcript: text)
                }
            } catch Transcriber.TranscriberError.noSpeech {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                complete(session, with: .insufficientVoice(generation: session.generation))
            } catch {
                guard isCurrent(session) else { return }
                session.activeTask = nil
                complete(
                    session,
                    with: .failed(generation: session.generation, message: error.localizedDescription)
                )
            }
        }
    }

    private func finalize(_ session: Session, transcript: String) {
        session.diagnostics?.record(.init(stage: "assembledTranscript", text: transcript))
        session.personalVoice?.setRawTranscript(transcript)
        let composed = Snippets.expand(
            VoiceFormatter.apply(
                TranscriptCorrections.apply(
                    transcript,
                    corrections: session.context.corrections
                )
            ),
            snippets: session.context.snippets
        )
        session.diagnostics?.record(.init(stage: "cleanupInput", text: composed))
        guard !composed.isEmpty else {
            complete(session, with: .emptyTranscript(generation: session.generation))
            return
        }
        guard session.context.cleanupEnabled else {
            session.trace?.record(.cleanupSkipped)
            complete(
                session,
                with: .finalTranscript(generation: session.generation, text: composed)
            )
            return
        }

        let request = DictationCleanupRequest(
            generation: session.generation,
            text: composed,
            context: session.context
        )
        session.activeTaskIsCleanup = true
        session.activeTask = Task { @MainActor [weak self, weak session] in
            guard let self, let session else { return }
            session.trace?.record(.cleanupStarted)
            let result = await DictationTrace.$current.withValue(session.trace) {
                await DictationDiagnosticStore.Recording.$current.withValue(session.diagnostics) {
                    await self.cleanup(request)
                }
            }
            guard isCurrent(session) else { return }
            session.diagnostics?.record(.init(stage: "cleanupOutput", text: result.text,
                                              status: result.succeeded ? "success" : "fallback"))
            session.trace?.record(.cleanupFinished, status: Task.isCancelled ? .cancelled : (result.succeeded ? .success : .fallback))
            guard isCurrent(session) else { return }
            session.activeTask = nil
            complete(
                session,
                with: .finalTranscript(generation: session.generation, text: result.text)
            )
        }
    }

    private func complete(_ session: Session, with outcome: DictationSessionOutcome) {
        guard isCurrent(session) else { return }
        session.releaseTimeout?.cancel()
        session.releaseTimeout = nil
        let status: DictationTrace.Status
        switch outcome {
        case .finalTranscript: status = .success
        case .insufficientVoice: status = .insufficientVoice
        case .emptyTranscript: status = .empty
        case .failed: status = .failed
        }
        switch outcome {
        case .finalTranscript(_, let text):
            session.diagnostics?.record(.init(stage: "finalTranscript", text: text, status: status.rawValue))
            session.personalVoice?.setFinalTranscript(text)
        case .failed(_, let message):
            session.diagnostics?.record(.init(stage: "outcome", text: message, status: status.rawValue))
        case .insufficientVoice:
            session.diagnostics?.record(.init(stage: "outcome", status: "cancelled"))
        case .emptyTranscript:
            session.diagnostics?.record(.init(stage: "outcome", status: status.rawValue))
        }
        session.personalVoice?.finish(status: status == .insufficientVoice ? "cancelled" : status.rawValue)
        session.trace?.record(.resultReady, status: status)
        if status == .insufficientVoice {
            session.trace?.record(.cancellationRequested)
        }
        sessions.removeValue(forKey: session.generation)
        if status == .insufficientVoice {
            // A rejected recording never waits for earlier recognition work.
            cancelled.insert(session.generation)
            drainCompletedOutcomes()
            DictationTrace.$current.withValue(session.trace) { onOutcome(outcome) }
        } else {
            completed[session.generation] = (outcome, session.trace)
            drainCompletedOutcomes()
        }
    }

    private func isCurrent(_ session: Session) -> Bool {
        !session.cancelled && sessions[session.generation] === session
    }

    private func drainCompletedOutcomes() {
        while let generation = generationOrder.first {
            if cancelled.remove(generation) != nil {
                generationOrder.removeFirst()
                continue
            }
            guard let outcome = completed.removeValue(forKey: generation) else { return }
            generationOrder.removeFirst()
            outcome.trace?.record(.resultDelivered)
            DictationTrace.$current.withValue(outcome.trace) { onOutcome(outcome.outcome) }
        }
    }

    private func runTranscription(_ request: DictationTranscriptionRequest, session: Session) async throws -> String {
        try Task.checkCancellation()
        guard isCurrent(session) else { throw CancellationError() }
        session.diagnostics?.record(.init(stage: "transcriptionRequest", segment: request.segment, sampleCount: request.samples.count))
        session.trace?.record(.transcriptionRequested, fields: [.samples: Double(request.samples.count)], segment: request.segment)
        do {
            let text = try await DictationTrace.$current.withValue(session.trace) {
                try await DictationDiagnosticStore.Recording.$current.withValue(session.diagnostics) {
                    try await transcribe(request)
                }
            }
            let abandoned = Task.isCancelled || !isCurrent(session)
            session.trace?.record(.transcriptionFinished, status: abandoned ? .cancelled : (text.isEmpty ? .empty : .success))
            if !abandoned {
                session.diagnostics?.record(.init(stage: "transcriptionResult", text: text,
                                                  status: text.isEmpty ? "empty" : "success", segment: request.segment))
            }
            return text
        } catch Transcriber.TranscriberError.noSpeech {
            let abandoned = Task.isCancelled || !isCurrent(session)
            session.trace?.record(.transcriptionFinished, status: abandoned ? .cancelled : .insufficientVoice)
            if !abandoned {
                session.diagnostics?.record(.init(stage: "transcriptionResult", text: "",
                                                  status: "insufficientVoice", segment: request.segment))
            }
            throw Transcriber.TranscriberError.noSpeech
        } catch {
            let abandoned = Task.isCancelled || !isCurrent(session)
            session.trace?.record(.transcriptionFinished, status: abandoned || error is CancellationError ? .cancelled : .failed)
            if !abandoned {
                session.diagnostics?.record(.init(stage: "transcriptionResult", text: error.localizedDescription,
                                                  status: "failed", segment: request.segment))
            }
            throw error
        }
    }

    private func scheduleReleaseTimeout(for session: Session) {
        guard isCurrent(session), session.releaseTimeout == nil else { return }
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, self.isCurrent(session) else { return }
            session.releaseTimeout = nil
            session.trace?.record(.cancellationRequested)
            session.activeTask?.cancel()
            session.activeTask = nil
            session.pendingChunks.removeAll()
            self.complete(session, with: .failed(
                generation: session.generation,
                message: "Transcription timed out after recording ended."
            ))
        }
        session.releaseTimeout = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + stalledGenerationTimeout,
            execute: work
        )
    }
}
