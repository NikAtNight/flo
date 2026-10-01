import Foundation

/// Appends every finished dictation to a daily Markdown file under
/// ~/Library/Application Support/LocalFlow/History.
///
/// Application Support rather than ~/Documents on purpose: Documents is
/// iCloud-synced on most Macs (the Whisper model cache had to be moved out
/// of it for the same reason), and dictation transcripts must not leave the
/// machine. Nothing is pruned automatically. Plain text is tiny and the
/// history is the user's record.
enum DictationHistory {
    static let folder: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(AppIdentity.current.historyDirectory, isDirectory: true)

    static let writer = DictationHistoryWriter(folder: folder)

    /// Records one dictation. Fire-and-forget; failures are logged, never
    /// surfaced. Losing a history line must not disturb a good dictation.
    static func record(_ text: String, at date: Date = Date()) {
        guard Settings.saveHistory else { return }
        writer.record(text, at: date)
    }

    /// `## 14:32:07` followed by the dictation, verbatim. Text is never
    /// escaped: this is a record of what was written, and fidelity beats
    /// Markdown purity for the rare dictation that starts with "#".
    static func entry(for text: String, at date: Date) -> String {
        "## \(timeFormatter.string(from: date))\n\n\(text)\n\n"
    }

    static func fileName(for date: Date) -> String {
        "\(dayFormatter.string(from: date)).md"
    }

    /// Deletes every stored transcript without waiting on disk on the caller.
    static func deleteAll(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        writer.deleteAll(completion: completion)
    }

    fileprivate static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

/// Owns disk operations for one history folder. Writes and deletion share a
/// serial queue so deleting history also removes entries still waiting to write.
final class DictationHistoryWriter {
    private let folder: URL
    private let queue: DispatchQueue

    init(
        folder: URL,
        queue: DispatchQueue = DispatchQueue(label: "app.talix.localflow.history", qos: .utility)
    ) {
        self.folder = folder
        self.queue = queue
    }

    func record(_ text: String, at date: Date = Date()) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            self.append(DictationHistory.entry(for: trimmed, at: date), toFileFor: date)
        }
    }

    /// Completion runs on the main queue after all earlier records are removed.
    /// Records submitted after this call may create a new history folder.
    func deleteAll(completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async {
            let result: Result<Void, Error>
            do {
                try FileManager.default.removeItem(at: self.folder)
                result = .success(())
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                result = .success(())
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func append(_ entry: String, toFileFor date: Date) {
        let fm = FileManager.default
        let file = folder.appendingPathComponent(DictationHistory.fileName(for: date))
        do {
            if !fm.fileExists(atPath: folder.path) {
                // Owner-only: a dictation log is as private as the dictations.
                try fm.createDirectory(
                    at: folder,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            guard fm.fileExists(atPath: file.path) else {
                let header = "# Dictations \(DictationHistory.dayFormatter.string(from: date))\n\n"
                try (header + entry).write(to: file, atomically: true, encoding: .utf8)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return
            }
            // Append without reading the whole day back into memory.
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(entry.utf8))
        } catch {
            DiagLog.log("could not write dictation history: %@", error.localizedDescription)
        }
    }
}
