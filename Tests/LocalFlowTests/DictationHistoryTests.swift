import XCTest
@testable import LocalFlow

/// Daily-log rendering and disk operations under disposable temporary folders.
final class DictationHistoryTests: XCTestCase {
    private func date(_ iso: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: iso)!
    }

    func testFileNameIsOnePerCalendarDay() {
        XCTAssertEqual(DictationHistory.fileName(for: date("2026-08-08 09:14:22")), "2026-08-08.md")
        XCTAssertEqual(DictationHistory.fileName(for: date("2026-08-08 23:59:59")), "2026-08-08.md")
        XCTAssertEqual(DictationHistory.fileName(for: date("2026-12-31 00:00:01")), "2026-12-31.md")
    }

    func testEntryIsATimestampedMarkdownSection() {
        XCTAssertEqual(
            DictationHistory.entry(for: "Ship it.", at: date("2026-08-08 09:14:22")),
            "## 09:14:22\n\nShip it.\n\n")
    }

    func testEntryPreservesMultiLineFormattingVerbatim() {
        let dictation = "1. Review the PR.\n2. Merge it."
        XCTAssertEqual(
            DictationHistory.entry(for: dictation, at: date("2026-08-08 14:02:00")),
            "## 14:02:00\n\n1. Review the PR.\n2. Merge it.\n\n")
    }

    func testHistoryFolderStaysOutOfICloudSyncedDocuments() {
        // ~/Documents is iCloud-synced on most Macs; transcripts must not
        // leave the machine.
        let path = DictationHistory.folder.path
        XCTAssertTrue(path.contains("Application Support/LocalFlow/History"), path)
        XCTAssertFalse(path.contains("/Documents/"), path)
    }

    func testDeletionWaitsForPendingRecordsAndDoesNotResurrectHistory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("History")
        let queue = DispatchQueue(label: "DictationHistoryTests.pending")
        let writer = DictationHistoryWriter(folder: folder, queue: queue)
        queue.suspend()
        writer.record("Pending first dictation.")
        writer.record("Pending second dictation.")
        let deleted = expectation(description: "queued history deleted")

        writer.deleteAll { result in
            if case .failure(let error) = result { XCTFail("Deletion failed: \(error)") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            deleted.fulfill()
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        queue.resume()

        await fulfillment(of: [deleted], timeout: 3)
        queue.sync {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testNewRecordAfterDeletionCreatesOnlyNewHistory() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("History")
        let queue = DispatchQueue(label: "DictationHistoryTests.new-record")
        let writer = DictationHistoryWriter(folder: folder, queue: queue)
        let recordedAt = date("2026-08-08 09:14:22")
        writer.record("Old dictation.", at: recordedAt)
        let deleted = expectation(description: "old history deleted")
        writer.deleteAll { result in
            if case .failure(let error) = result { XCTFail("Deletion failed: \(error)") }
            deleted.fulfill()
        }
        await fulfillment(of: [deleted], timeout: 3)

        writer.record("New dictation.", at: recordedAt)
        queue.sync {}

        let contents = try String(contentsOf: folder.appendingPathComponent("2026-08-08.md"))
        XCTAssertEqual(contents, "# Dictations 2026-08-08\n\n## 09:14:22\n\nNew dictation.\n\n")
    }

    func testDeletingMissingHistorySucceedsRepeatedly() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("History")
        let writer = DictationHistoryWriter(folder: folder)
        for _ in 0..<2 {
            let deleted = expectation(description: "missing history is already deleted")
            writer.deleteAll { result in
                if case .failure(let error) = result { XCTFail("Deletion failed: \(error)") }
                deleted.fulfill()
            }
            await fulfillment(of: [deleted], timeout: 3)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testDeletionReportsDiskFailureAndAllowsRetry() async throws {
        let root = try temporaryDirectory()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let folder = root.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("test.md")
        try "Saved dictation.".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let writer = DictationHistoryWriter(folder: folder)
        let failed = expectation(description: "deletion fails visibly")

        writer.deleteAll { result in
            if case .success = result { XCTFail("Expected a filesystem permission failure") }
            failed.fulfill()
        }
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let retried = expectation(description: "deletion retry succeeds")
        writer.deleteAll { result in
            if case .failure(let error) = result { XCTFail("Retry failed: \(error)") }
            retried.fulfill()
        }
        await fulfillment(of: [retried], timeout: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    @MainActor
    func testSettingsModelReportsHistoryDeletionFailureWithoutBlockingTheUI() async throws {
        let root = try temporaryDirectory()
        let defaultsName = "LocalFlow.DictationHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let folder = root.appendingPathComponent("History")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let queue = DispatchQueue(label: "DictationHistoryTests.settings")
        let writer = DictationHistoryWriter(folder: folder, queue: queue)
        let application = SettingsApplication(
            defaults: defaults,
            supportedWhisperModels: ["test-model"],
            defaultWhisperModel: "test-model",
            effects: .init(
                applyHotkey: { _ in },
                reloadWhisperModel: { _ in },
                selectMicrophone: { _ in },
                applyAutomaticUpdates: { _ in }
            ),
            loginItem: .init(isEnabled: { false }, setEnabled: { _ in })
        )
        let model = SettingsModel(settingsApplication: application, historyWriter: writer)
        queue.suspend()

        model.deleteHistory()
        XCTAssertTrue(model.deletingHistory)
        XCTAssertNil(model.lastIssue)
        // A queue barrier schedules the check after the deletion callback.
        let reported = expectation(description: "settings displays deletion failure")
        queue.async {
            DispatchQueue.main.async {
                XCTAssertFalse(model.deletingHistory)
                XCTAssertEqual(model.lastIssue?.summary, "Couldn't delete dictation history")
                XCTAssertTrue(model.lastIssue?.details.contains("Try again") == true)
                reported.fulfill()
            }
        }
        queue.resume()
        await fulfillment(of: [reported], timeout: 3)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

}
