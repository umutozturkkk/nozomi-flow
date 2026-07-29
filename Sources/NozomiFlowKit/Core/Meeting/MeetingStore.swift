import Foundation
import Observation

/// A recorded meeting on disk.
struct MeetingRecord: Identifiable, Equatable {
    let id: String
    let title: String
    let date: Date
    let duration: TimeInterval
    let url: URL

    var durationText: String { MeetingTranscript.timestamp(duration) }
}

/// Meetings as markdown files, one per recording.
///
/// Markdown rather than a database on purpose: the notes outlive this app, open in
/// anything, and sync wherever the user already syncs files. The store only lists
/// and writes; rendering is the UI's problem.
@MainActor
@Observable
final class MeetingStore {
    private(set) var meetings: [MeetingRecord] = []

    @ObservationIgnored private let directory: URL

    /// - Parameter directory: where meeting markdown lives. Tests inject a temp path.
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        reload()
    }

    /// Sits beside the dictation history, under the same Application Support folder
    /// the app has always used. See PersonalDictionaryStore for why that folder still
    /// carries the old name.
    private static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("Meetings", isDirectory: true)
    }

    /// Working directory for a recording in progress: raw chunks land here and are
    /// removed once the meeting is written out.
    func workingDirectory(for id: String) -> URL {
        directory.appendingPathComponent("in-progress", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
    }

    // MARK: - Writing

    /// Writes one meeting and returns its record. The transcript is always included
    /// even when the summary is missing, since a meeting with no notes is still worth
    /// having and a failed summary must not discard the recording.
    @discardableResult
    func save(
        id: String,
        startedAt: Date,
        duration: TimeInterval,
        transcript: String,
        summary: String?
    ) -> MeetingRecord? {
        let title = Self.title(for: startedAt)
        var body = "# \(title)\n\n"
        body += "_\(Self.longDateFormatter.string(from: startedAt)) · \(MeetingTranscript.timestamp(duration))_\n\n"
        if let summary, !summary.isEmpty {
            body += summary + "\n\n"
        } else {
            body += "## Summary\n\nNot generated for this meeting.\n\n"
        }
        body += "## Transcript\n\n"
        body += transcript.isEmpty ? "_Nothing was transcribed._\n" : transcript + "\n"

        let url = directory.appendingPathComponent("\(id).md")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Log.app.error("could not write meeting notes: \(error.localizedDescription)")
            return nil
        }

        let record = MeetingRecord(id: id, title: title, date: startedAt, duration: duration, url: url)
        reload()
        return record
    }

    /// Removes the raw chunk directory once its meeting is safely written. Audio is
    /// far larger than the notes and has no value after transcription.
    func discardWorkingFiles(for id: String) {
        try? FileManager.default.removeItem(at: workingDirectory(for: id))
    }

    func delete(_ record: MeetingRecord) {
        try? FileManager.default.removeItem(at: record.url)
        reload()
    }

    // MARK: - Reading

    func reload() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        meetings = contents
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                let date = Self.date(fromID: url.deletingPathExtension().lastPathComponent)
                    ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    ?? Date()
                return MeetingRecord(
                    id: url.deletingPathExtension().lastPathComponent,
                    title: Self.title(for: date),
                    date: date,
                    duration: 0,
                    url: url
                )
            }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Identifiers

    /// Sortable, filename-safe, and parseable back into a date so a listing does not
    /// depend on filesystem timestamps that copying would destroy.
    static func makeID(for date: Date) -> String {
        idFormatter.string(from: date)
    }

    static func date(fromID id: String) -> Date? {
        idFormatter.date(from: id)
    }

    static func title(for date: Date) -> String {
        "Meeting on \(mediumDateFormatter.string(from: date))"
    }

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    private static let mediumDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let longDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter
    }()
}
