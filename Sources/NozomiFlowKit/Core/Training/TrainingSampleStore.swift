import Foundation

/// Training samples on disk: `<id>.wav` (16 kHz mono PCM16, as uploaded) plus
/// `<id>.json`. The WAV is written first and the JSON last, via a temp file and
/// rename, so a sample only exists once both are complete; anything else is
/// debris from an interrupted write and `removeIncomplete` deletes it.
///
/// Thread-safe: saves run off the main actor while Settings reads totals.
final class TrainingSampleStore: @unchecked Sendable {

    static var defaultDirectory: URL {
        // Still "Murmur" after the rename to Nozomi Flow, like the other stores.
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Murmur/Training", isDirectory: true)
    }

    private let directory: URL
    private let lock = NSLock()
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL = TrainingSampleStore.defaultDirectory) {
        self.directory = directory
    }

    func audioURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).wav")
    }

    private func jsonURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func save(_ sample: TrainingSample, audio: [Int16]) throws {
        lock.lock(); defer { lock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = CloudTranscriptionSession.makeWAV(samples: audio, sampleRate: TrainingSample.sampleRate)
        try wav.write(to: audioURL(for: sample.id), options: .atomic)
        try writeJSONLocked(sample)
    }

    func update(_ sample: TrainingSample) throws {
        lock.lock(); defer { lock.unlock() }
        try writeJSONLocked(sample)
    }

    func loadAll() -> [TrainingSample] {
        lock.lock(); defer { lock.unlock() }
        return loadAllLocked()
    }

    func totalDurationSeconds() -> Double {
        loadAll().reduce(0) { $0 + $1.durationSeconds }
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    /// Deletes WAVs without a JSON and leftover temp files. Call once at launch.
    func removeIncomplete() {
        lock.lock(); defer { lock.unlock() }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let complete = Set(files.filter { $0.pathExtension == "json" }.map { $0.deletingPathExtension().lastPathComponent })
        for file in files {
            let isTemp = file.lastPathComponent.hasSuffix(".json.tmp")
            let isOrphanAudio = file.pathExtension == "wav" && !complete.contains(file.deletingPathExtension().lastPathComponent)
            if isTemp || isOrphanAudio {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    // MARK: - Locked helpers

    private func writeJSONLocked(_ sample: TrainingSample) throws {
        let data = try encoder.encode(sample)
        let final = jsonURL(for: sample.id)
        let temp = final.appendingPathExtension("tmp")
        try data.write(to: temp)
        if FileManager.default.fileExists(atPath: final.path) {
            _ = try FileManager.default.replaceItemAt(final, withItemAt: temp)
        } else {
            try FileManager.default.moveItem(at: temp, to: final)
        }
    }

    private func loadAllLocked() -> [TrainingSample] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(TrainingSample.self, from: Data(contentsOf: $0)) }
            .filter { FileManager.default.fileExists(atPath: audioURL(for: $0.id).path) }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
