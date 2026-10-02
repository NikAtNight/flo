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
        XCTAssertEqual(ParakeetEngine.segments(text: "  ", tokens: [Token(text: "▁a", start: 0, end: 1)], duration: 1), [])
    }

    func testNoGapKeepsOneSegment() {
        let tokens = [
            Token(text: "▁First", start: 0.0, end: 0.4),
            Token(text: ".", start: 0.4, end: 0.5),
            Token(text: "▁Second", start: 0.7, end: 1.1),
            Token(text: ".", start: 1.1, end: 1.2),
        ]
        XCTAssertEqual(
            ParakeetEngine.segments(text: "First. Second.", tokens: tokens, duration: 2),
            [EngineSegment(text: "First. Second.", start: 0, end: 1.2)]
        )
    }

    func testLongGapAfterSentenceSplits() {
        let segments = ParakeetEngine.segments(text: "First. Second.", tokens: pausedTokens(gap: 2), duration: 4)
        XCTAssertEqual(segments, [
            EngineSegment(text: "First.", start: 0, end: 0.5),
            EngineSegment(text: "Second.", start: 2.5, end: 3.0),
        ])
    }

    func testLongGapWithoutSentenceEndDoesNotSplit() {
        let tokens = [
            Token(text: "▁First", start: 0.0, end: 0.5),
            Token(text: "▁second", start: 2.5, end: 2.9),
            Token(text: ".", start: 2.9, end: 3.0),
        ]
        XCTAssertEqual(ParakeetEngine.segments(text: "First second.", tokens: tokens, duration: 4).count, 1)
    }

    func testShortGapAfterSentenceDoesNotSplit() {
        XCTAssertEqual(ParakeetEngine.segments(text: "First. Second.", tokens: pausedTokens(gap: 1), duration: 4).count, 1)
    }

    func testLeadingSpaceMarkerAlsoRebuildsText() {
        let tokens = [
            Token(text: " First", start: 0.0, end: 0.4),
            Token(text: ".", start: 0.4, end: 0.5),
            Token(text: " Second", start: 2.5, end: 2.9),
            Token(text: ".", start: 2.9, end: 3.0),
        ]
        XCTAssertEqual(ParakeetEngine.segments(text: "First. Second.", tokens: tokens, duration: 4).count, 2)
    }

    func testMismatchedReconstructionFallsBackToText() {
        XCTAssertEqual(
            ParakeetEngine.segments(text: "Something else entirely.", tokens: pausedTokens(gap: 2), duration: 4),
            [EngineSegment(text: "Something else entirely.", start: 0, end: 4)]
        )
    }

    func testSplitSegmentsJoinIntoParagraphs() {
        let segments = ParakeetEngine.segments(text: "First. Second.", tokens: pausedTokens(gap: 2), duration: 4)
        XCTAssertEqual(
            Transcriber.joinSegments(segments.map { (text: $0.text, start: $0.start, end: $0.end) }),
            "First.\n\nSecond."
        )
    }

    private func pausedTokens(gap: Double) -> [Token] {
        [
            Token(text: "▁First", start: 0.0, end: 0.4),
            Token(text: ".", start: 0.4, end: 0.5),
            Token(text: "▁Second", start: 0.5 + gap, end: 0.9 + gap),
            Token(text: ".", start: 0.9 + gap, end: 1.0 + gap),
        ]
    }
}
