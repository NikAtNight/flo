import XCTest
@testable import LocalFlow

final class ParakeetEngineTests: XCTestCase {
    private typealias Token = ParakeetEngine.Token

    func testShortClipPadsWithTrailingSilence() {
        let samples = [Float](repeating: 0.5, count: 8_000)
        let padded = ParakeetEngine.padded(samples)
        XCTAssertEqual(padded.count, 24_000)
        XCTAssertEqual(Array(padded.prefix(8_000)), samples)
        XCTAssertTrue(padded.dropFirst(8_000).allSatisfy { $0 == 0 })
    }

    func testClipsAtOrAboveMinimumAreUnchanged() {
        let exact = [Float](repeating: 0.1, count: 24_000)
        let long = [Float](repeating: 0.1, count: 48_000)
        XCTAssertEqual(ParakeetEngine.padded(exact), exact)
        XCTAssertEqual(ParakeetEngine.padded(long), long)
    }

    func testEmptyInputPadsToMinimum() {
        XCTAssertEqual(ParakeetEngine.padded([]), [Float](repeating: 0, count: 24_000))
    }

    func testMissingTokensGiveOneSegment() {
        XCTAssertEqual(
            ParakeetEngine.segments(text: " Hello there. ", tokens: nil, duration: 2),
            [EngineSegment(text: "Hello there.", start: 0, end: 2)]
        )
        XCTAssertEqual(
            ParakeetEngine.segments(text: "Hello there.", tokens: [], duration: 2),
            [EngineSegment(text: "Hello there.", start: 0, end: 2)]
        )
    }

    func testEmptyTextGivesNoSegments() {
        XCTAssertEqual(ParakeetEngine.segments(text: "  ", tokens: [Token(text: " a", start: 0, end: 1)], duration: 1), [])
    }

    func testNoGapKeepsOneSegment() {
        let tokens = [
            Token(text: " First", start: 0.0, end: 0.4),
            Token(text: ".", start: 0.4, end: 0.5),
            Token(text: " Second", start: 0.5, end: 0.9),
            Token(text: ".", start: 0.9, end: 1.0),
        ]
        XCTAssertEqual(
            ParakeetEngine.segments(text: "First. Second.", tokens: tokens, duration: 2),
            [EngineSegment(text: "First. Second.", start: 0, end: 0.9)]
        )
    }

    func testLongPauseAfterSentenceSplitsAtEstimatedSpeechBounds() {
        // A 1.3 s word gap is about a 2 s real pause.
        let segments = ParakeetEngine.segments(text: "First. Second.", tokens: pausedTokens(gap: 1.3), duration: 4)
        XCTAssertEqual(segments.map(\.text), ["First.", "Second."])
        XCTAssertEqual(segments[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].end, 0.4, accuracy: 0.001)
        XCTAssertEqual(segments[1].start, 2.4, accuracy: 0.001)
        XCTAssertEqual(segments[1].end, 2.1, accuracy: 0.001)
    }

    func testLongGapWithoutSentenceEndDoesNotSplit() {
        let tokens = [
            Token(text: " First", start: 0.0, end: 0.4),
            Token(text: " second", start: 1.7, end: 2.1),
            Token(text: ".", start: 2.1, end: 2.2),
        ]
        XCTAssertEqual(ParakeetEngine.segments(text: "First second.", tokens: tokens, duration: 4).count, 1)
    }

    func testShortPauseAfterSentenceDoesNotSplit() {
        // A 0.8 s word gap is about a 1.5 s real pause.
        XCTAssertEqual(ParakeetEngine.segments(text: "First. Second.", tokens: pausedTokens(gap: 0.8), duration: 4).count, 1)
    }

    func testSentencePieceMarkerAlsoRebuildsText() {
        let tokens = pausedTokens(gap: 1.3).map {
            Token(text: $0.text.replacingOccurrences(of: " ", with: "▁"), start: $0.start, end: $0.end)
        }
        XCTAssertEqual(ParakeetEngine.segments(text: "First. Second.", tokens: tokens, duration: 4).count, 2)
    }

    func testMismatchedReconstructionFallsBackToText() {
        XCTAssertEqual(
            ParakeetEngine.segments(text: "Something else entirely.", tokens: pausedTokens(gap: 1.3), duration: 4),
            [EngineSegment(text: "Something else entirely.", start: 0, end: 4)]
        )
    }

    func testSplitSegmentsJoinIntoParagraphs() {
        let segments = ParakeetEngine.segments(text: "First. Second.", tokens: pausedTokens(gap: 1.3), duration: 4)
        XCTAssertEqual(
            Transcriber.joinSegments(segments.map { (text: $0.text, start: $0.start, end: $0.end) }),
            "First.\n\nSecond."
        )
    }

    /// Shaped like real FluidAudio output: the period after "First" is
    /// emitted at the end of the pause, right before the next word.
    private func pausedTokens(gap: Double) -> [Token] {
        [
            Token(text: " First", start: 0.0, end: 0.4),
            Token(text: ".", start: 0.2 + gap, end: 0.4 + gap),
            Token(text: " Second", start: 0.4 + gap, end: 0.8 + gap),
            Token(text: ".", start: 0.8 + gap, end: 0.9 + gap),
        ]
    }
}
