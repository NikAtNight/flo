import XCTest
@testable import LocalFlow

final class TranscriptionModelTests: XCTestCase {
    func testIDsAreUnique() {
        let ids = TranscriptionModel.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testDefaultIsSelectable() {
        XCTAssertTrue(TranscriptionModel.all.contains { $0.id == TranscriptionModel.defaultID })
        XCTAssertEqual(Settings.defaultWhisperModel, TranscriptionModel.defaultID)
    }

    func testEngineForParakeetID() {
        XCTAssertEqual(TranscriptionModel.engine(forID: TranscriptionModel.parakeetV3ID), .parakeet)
    }

    func testParakeetIsSelectableUnderItsOwnGroup() {
        let parakeet = TranscriptionModel.all.first { $0.id == TranscriptionModel.parakeetV3ID }
        XCTAssertEqual(parakeet?.engine, .parakeet)
        XCTAssertEqual(TranscriptionModel.groups, ["Whisper", "Parakeet"])
    }

    func testEngineForWhisperID() {
        XCTAssertEqual(TranscriptionModel.engine(forID: "openai_whisper-small.en"), .whisper)
    }

    func testUnknownIDIsTreatedAsWhisperRegistryName() {
        XCTAssertEqual(TranscriptionModel.engine(forID: "test"), .whisper)
        XCTAssertEqual(TranscriptionModel.engine(forID: "openai_whisper-medium"), .whisper)
    }

    func testSettingsListMatchesModels() {
        XCTAssertEqual(Settings.whisperModels.map(\.name), TranscriptionModel.all.map(\.id))
        XCTAssertEqual(Settings.whisperModels.map(\.label), TranscriptionModel.all.map(\.label))
    }

    func testIncrementalCadenceFollowsEngine() {
        XCTAssertEqual(IncrementalCadence.forModel(TranscriptionModel.defaultID), .whisper)
        XCTAssertEqual(IncrementalCadence.forModel(TranscriptionModel.parakeetV3ID), .parakeet)
        XCTAssertEqual(IncrementalCadence.forModel("not-a-model"), .whisper)
        XCTAssertEqual(IncrementalCadence.whisper, IncrementalCadence(startSeconds: 8, tickSeconds: 4))
        XCTAssertEqual(IncrementalCadence.parakeet, IncrementalCadence(startSeconds: 4, tickSeconds: 2))
    }
}
