import XCTest
@testable import LocalFlow

@MainActor
final class DictationSessionStallTests: XCTestCase {
    func testHungHeadTimesOutBeforeCompletedLaterTranscriptIsDelivered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationDiagnosticStore(folder: root)
        let id = UUID()
        let recording = store.begin(.init(traceID: id, context: context, whisperModel: "test",
                                          microphone: "test", vocabulary: ""))
        let hungGeneration = 60
        let laterGeneration = 61
        let transcriber = StallCaseTranscriber(
            hungGeneration: hungGeneration,
            completedText: "later transcript"
        )
        var outcomes: [DictationSessionOutcome] = []
        let delivered = expectation(description: "stalled head and later transcript delivered")
        delivered.expectedFulfillmentCount = 2
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                try await transcriber.transcribe(request)
            },
            cleanup: { request in
                TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcome in
                outcomes.append(outcome)
                delivered.fulfill()
            },
            stalledGenerationTimeout: 0.04
        )
        defer {
            pipeline.cancel(generation: hungGeneration)
            pipeline.cancel(generation: laterGeneration)
        }

        pipeline.begin(generation: hungGeneration, context: context, diagnostics: recording)
        pipeline.release(
            generation: hungGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let headStarted = await waitForCall(generation: hungGeneration, in: transcriber)
        XCTAssertTrue(headStarted)

        pipeline.begin(generation: laterGeneration, context: context)
        pipeline.release(
            generation: laterGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let laterCompleted = await waitForCall(generation: laterGeneration, in: transcriber)
        XCTAssertTrue(laterCompleted)

        await fulfillment(of: [delivered], timeout: 0.5)
        XCTAssertEqual(outcomes, [
            .failed(
                generation: hungGeneration,
                message: "Transcription timed out after recording ended."
            ),
            .finalTranscript(generation: laterGeneration, text: "later transcript")
        ])
        store.flush()
        let data = try Data(contentsOf: root.appendingPathComponent("\(id)/events.jsonl"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let events = try data.split(separator: 0x0a).map {
            try decoder.decode(DictationDiagnosticStore.Event.self, from: Data($0))
        }
        let outcome = events.first { $0.stage == "outcome" }
        XCTAssertEqual(outcome?.status, "failed")
        XCTAssertEqual(outcome?.text, "Transcription timed out after recording ended.")
    }

    func testLaterCompletionDoesNotRestartArmedStallDeadline() async {
        let hungGeneration = 70
        let firstLaterGeneration = 71
        let secondLaterGeneration = 72
        let transcriber = StallCaseTranscriber(
            hungGeneration: hungGeneration,
            completedText: "later transcript"
        )
        var outcomes: [DictationSessionOutcome] = []
        let delivered = expectation(description: "original stall deadline delivers queued outcomes")
        delivered.expectedFulfillmentCount = 3
        let pipeline = DictationSessionPipeline(
            transcribe: { request in
                try await transcriber.transcribe(request)
            },
            cleanup: { request in
                TranscriptCleanupResult(text: request.text, succeeded: true)
            },
            onOutcome: { outcome in
                outcomes.append(outcome)
                delivered.fulfill()
            },
            stalledGenerationTimeout: 0.4
        )
        defer {
            pipeline.cancel(generation: hungGeneration)
            pipeline.cancel(generation: firstLaterGeneration)
            pipeline.cancel(generation: secondLaterGeneration)
        }

        pipeline.begin(generation: hungGeneration, context: context)
        pipeline.release(
            generation: hungGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let headStarted = await waitForCall(generation: hungGeneration, in: transcriber)
        XCTAssertTrue(headStarted)

        pipeline.begin(generation: firstLaterGeneration, context: context)
        pipeline.release(
            generation: firstLaterGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let firstLaterCompleted = await waitForCall(
            generation: firstLaterGeneration,
            in: transcriber
        )
        XCTAssertTrue(firstLaterCompleted)
        await settleAsyncWork()

        // Releasing the hung head starts its 400 ms deadline.
        // Complete another queued result 250 ms into that same interval.
        try? await Task.sleep(nanoseconds: 250_000_000)
        pipeline.begin(generation: secondLaterGeneration, context: context)
        pipeline.release(
            generation: secondLaterGeneration,
            fullSamples: speech,
            tailSamples: speech
        )
        let secondLaterCompleted = await waitForCall(
            generation: secondLaterGeneration,
            in: transcriber
        )
        XCTAssertTrue(secondLaterCompleted)
        await settleAsyncWork()

        // The original deadline has about 150 ms left. A restarted timer
        // needs another 400 ms and cannot satisfy this 250 ms window.
        await fulfillment(of: [delivered], timeout: 0.25)
        XCTAssertEqual(outcomes, [
            .failed(
                generation: hungGeneration,
                message: "Transcription timed out after recording ended."
            ),
            .finalTranscript(generation: firstLaterGeneration, text: "later transcript"),
            .finalTranscript(generation: secondLaterGeneration, text: "later transcript")
        ])
    }

    func testNoncooperativeInferenceAloneRetainsAudioThenReloadedRetrySucceeds() async throws {
        try await verifyNoncooperativeInference(dictations: 1)
    }

    func testNoncooperativeInferenceWithRealGateFailsQueuedDictationsWithoutFollowerResult() async throws {
        try await verifyNoncooperativeInference(dictations: 2)
    }

    func testRecordingHasNoDeadlineUntilRelease() async {
        let inference = StallCaseTranscriber(hungGeneration: 101, completedText: "")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { try await inference.transcribe($0) },
            cleanup: { .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0) },
            stalledGenerationTimeout: 0.02
        )
        pipeline.begin(generation: 101, context: context)
        pipeline.processIncrementalChunk(generation: 101, samples: speech, pauseSecondsAfterChunk: 0)
        let started = await waitForCall(generation: 101, in: inference)
        XCTAssertTrue(started)
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(outcomes.isEmpty)
        pipeline.release(generation: 101, fullSamples: speech)
        for _ in 0..<100 where outcomes.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(outcomes, [.failed(generation: 101, message: "Transcription timed out after recording ended.")])
    }

    private func verifyNoncooperativeInference(dictations: Int) async throws {
        let blocked = NoncooperativeInference()
        let old = FakeEngine()
        old.inference = { await blocked.run() }
        let replacement = FakeEngine()
        replacement.inference = { syntheticResult("recovered words") }
        var loadCount = 0
        let transcriber = Transcriber(modelLoader: { _, _ in
            loadCount += 1
            return loadCount == 1 ? old : replacement
        })
        try await transcriber.load(model: "test")
        var outcomes: [DictationSessionOutcome] = []
        var pasted: [String] = []
        var history: [String] = []
        let delivery = DictationDelivery(
            transcribe: { try await transcriber.transcribe(samples: $0.samples) },
            cleanup: { .init(text: $0.text, succeeded: true) },
            inject: { text, complete in pasted.append(text); complete() },
            recordTranscript: { history.append($0) },
            onOutcome: { outcome, _ in outcomes.append(outcome) },
            onCancelled: { _ in XCTFail("A deadline must retain the failed recording") },
            onCommandCancelled: { _ in },
            onProcessingCountChange: { _ in },
            stallTimeout: 0.08, injectionInterval: 0
        )
        for _ in 0..<dictations {
            let generation = delivery.begin(.init(context: context))
            delivery.release(generation: generation, samples: speech)
        }
        for _ in 0..<200 {
            if outcomes.count == dictations, !(await transcriber.isLoaded) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(outcomes.count, dictations)
        XCTAssertTrue(outcomes.allSatisfy { if case .failed = $0 { return true }; return false })
        XCTAssertEqual(delivery.retryCount, dictations)
        XCTAssertFalse(delivery.isBusy, "Quit must unblock without the model returning")
        let oldCalls = await blocked.calls
        XCTAssertEqual(oldCalls, 1, "Queued cancelled requests must never start inference")
        XCTAssertTrue(pasted.isEmpty)
        XCTAssertTrue(history.isEmpty)

        try await transcriber.load(model: "test")
        XCTAssertEqual(loadCount, 2)
        delivery.retryFailedDictations { .init(context: self.context) }
        for _ in 0..<200 where pasted.count < dictations { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(pasted, Array(repeating: "recovered words", count: dictations))
        XCTAssertEqual(history, pasted)
        XCTAssertFalse(delivery.isBusy)
        await blocked.finish()
        await settleAsyncWork()
        XCTAssertEqual(outcomes.count, dictations * 2)
        XCTAssertEqual(history.count, dictations, "The abandoned model's late result must be ignored")
        XCTAssertEqual(delivery.retryCount, 0)
        let callsAfterLateResult = await blocked.calls
        XCTAssertEqual(callsAfterLateResult, 1)
    }

    func testKeyboardCancelLeavesRunningInferenceAndModelLoaded() async throws {
        let blocked = NoncooperativeInference()
        let engine = FakeEngine()
        engine.inference = { await blocked.run() }
        var loads = 0
        let transcriber = Transcriber(modelLoader: { _, _ in
            loads += 1
            return engine
        })
        try await transcriber.load(model: "test")
        var outcomes: [DictationSessionOutcome] = []
        let pipeline = DictationSessionPipeline(
            transcribe: { try await transcriber.transcribe(samples: $0.samples) },
            cleanup: { .init(text: $0.text, succeeded: true) },
            onOutcome: { outcomes.append($0) }
        )
        pipeline.begin(generation: 120, context: context)
        pipeline.release(generation: 120, fullSamples: speech)
        for _ in 0..<200 {
            if await blocked.calls == 1 { break }
            await Task.yield()
        }
        let callsBeforeCancel = await blocked.calls
        XCTAssertEqual(callsBeforeCancel, 1)

        pipeline.cancel(generation: 120, interruptInference: false)
        await settleAsyncWork()
        let loadedWhileBlocked = await transcriber.isLoaded
        XCTAssertTrue(loadedWhileBlocked, "Escape must not quarantine the speech model")

        await blocked.finish()
        await settleAsyncWork()
        let loadedAfterReturn = await transcriber.isLoaded
        XCTAssertTrue(loadedAfterReturn)
        XCTAssertTrue(outcomes.isEmpty, "The abandoned result must be dropped")

        engine.inference = { syntheticResult("next words") }
        pipeline.begin(generation: 121, context: context)
        pipeline.release(generation: 121, fullSamples: speech)
        for _ in 0..<200 where outcomes.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(outcomes, [.finalTranscript(generation: 121, text: "next words")])
        XCTAssertEqual(loads, 1)
    }

    func testQueuedRequestUsesReplacementAfterOrdinaryModelSwitch() async throws {
        let blocked = NoncooperativeInference()
        let old = FakeEngine()
        old.inference = { await blocked.run() }
        let replacement = FakeEngine()
        replacement.inference = { syntheticResult("new model") }
        let transcriber = Transcriber(modelLoader: { name, _ in name == "old" ? old : replacement })
        try await transcriber.load(model: "old")
        let active = Task { try await transcriber.transcribe(samples: speech) }
        for _ in 0..<200 {
            if await blocked.calls == 1 { break }
            await Task.yield()
        }
        let queued = Task { try await transcriber.transcribe(samples: speech) }
        await settleAsyncWork()
        let callsBeforeSwitch = await blocked.calls
        XCTAssertEqual(callsBeforeSwitch, 1)
        try await transcriber.load(model: "new")
        await blocked.finish()
        let activeText = try await active.value
        let queuedText = try await queued.value
        XCTAssertEqual(activeText, "late abandoned words")
        XCTAssertEqual(queuedText, "new model")
    }

    func testCancellingOldInferenceAfterModelSwitchKeepsReplacementUsable() async throws {
        let blocked = NoncooperativeInference()
        let old = FakeEngine()
        old.inference = { await blocked.run() }
        let replacement = FakeEngine()
        replacement.inference = { syntheticResult("new model") }
        let transcriber = Transcriber(modelLoader: { name, _ in name == "old" ? old : replacement })
        try await transcriber.load(model: "old")
        let active = Task { try await transcriber.transcribe(samples: speech) }
        for _ in 0..<200 {
            if await blocked.calls == 1 { break }
            await Task.yield()
        }
        try await transcriber.load(model: "new")
        active.cancel()
        await settleAsyncWork()
        let loaded = await transcriber.isLoaded
        XCTAssertTrue(loaded)
        let nextText = try await transcriber.transcribe(samples: speech)
        XCTAssertEqual(nextText, "new model")
        await blocked.finish()
        do { _ = try await active.value; XCTFail("Cancelled old model must not return text") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testRecoveryCapsQuarantinedEnginesUntilOldInferenceReturns() async throws {
        let firstBlocked = NoncooperativeInference()
        let secondBlocked = NoncooperativeInference()
        let first = FakeEngine()
        first.inference = { await firstBlocked.run() }
        let second = FakeEngine()
        second.inference = { await secondBlocked.run() }
        var loads = 0
        let transcriber = Transcriber(modelLoader: { _, _ in
            loads += 1
            return loads == 1 ? first : second
        })
        try await transcriber.load(model: "test")
        let firstTask = Task { try await transcriber.transcribe(samples: speech) }
        for _ in 0..<200 {
            if await firstBlocked.calls == 1 { break }
            await Task.yield()
        }
        firstTask.cancel()
        for _ in 0..<200 {
            if !(await transcriber.isLoaded) { break }
            await Task.yield()
        }
        try await transcriber.load(model: "test")
        let secondTask = Task { try await transcriber.transcribe(samples: speech) }
        for _ in 0..<200 {
            if await secondBlocked.calls == 1 { break }
            await Task.yield()
        }
        secondTask.cancel()
        for _ in 0..<200 {
            if !(await transcriber.isLoaded) { break }
            await Task.yield()
        }
        do {
            try await transcriber.load(model: "test")
            XCTFail("Repeated recovery must not build unbounded model engines")
        } catch Transcriber.TranscriberError.recoveryBusy {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(loads, 2)
        await firstBlocked.finish()
        _ = try? await firstTask.value
        // Once an old call returns, another explicit load is allowed.
        try await transcriber.load(model: "test")
        XCTAssertEqual(loads, 3)
        await secondBlocked.finish()
        _ = try? await secondTask.value
    }

    private var speech: [Float] {
        [Float](repeating: 0.2, count: Int(AudioRecorder.sampleRate))
    }

    private var context: DictationSessionContext {
        DictationSessionContext(
            cleanupEnabled: false,
            styleProfile: .general,
            corrections: [],
            snippets: []
        )
    }

    private func waitForCall(
        generation: Int,
        in transcriber: StallCaseTranscriber
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await transcriber.hasCall(generation: generation) { return true }
            await Task.yield()
        }
        return false
    }

    private func settleAsyncWork() async {
        for _ in 0..<100 { await Task.yield() }
    }
}

private actor StallCaseTranscriber {
    private let hungGeneration: Int
    private let completedText: String
    private var calls: Set<Int> = []
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var cancellationRequested: Set<Int> = []

    init(hungGeneration: Int, completedText: String) {
        self.hungGeneration = hungGeneration
        self.completedText = completedText
    }

    func transcribe(_ request: DictationTranscriptionRequest) async throws -> String {
        calls.insert(request.generation)
        guard request.generation == hungGeneration else { return completedText }
        let generation = request.generation
        return try await withTaskCancellationHandler {
            try await suspend(generation: generation)
        } onCancel: {
            Task { await self.cancel(generation: generation) }
        }
    }

    func hasCall(generation: Int) -> Bool {
        calls.contains(generation)
    }

    private func suspend(generation: Int) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            if cancellationRequested.remove(generation) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                pending[generation] = continuation
            }
        }
    }

    private func cancel(generation: Int) {
        if let continuation = pending.removeValue(forKey: generation) {
            continuation.resume(throwing: CancellationError())
        } else {
            cancellationRequested.insert(generation)
        }
    }
}

private final class FakeEngine: SpeechEngine, @unchecked Sendable {
    var inference: (() async throws -> EngineTranscription)?

    func transcribe(samples: [Float], lowEnergy: Bool) async throws -> EngineTranscription {
        try await inference?() ?? syntheticResult("")
    }

    func setVocabulary(_ terms: String) async {}
}

private actor NoncooperativeInference {
    private(set) var calls = 0
    private var pending: CheckedContinuation<EngineTranscription, Never>?

    func run() async -> EngineTranscription {
        calls += 1
        return await withCheckedContinuation { pending = $0 }
    }

    func finish() {
        pending?.resume(returning: syntheticResult("late abandoned words"))
        pending = nil
    }
}

private func syntheticResult(_ text: String) -> EngineTranscription {
    EngineTranscription(segments: [.init(text: text, start: 0, end: 1)], rawText: text,
                        decodingFallbacks: 0, resultCount: 1)
}
