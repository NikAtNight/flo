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
}
