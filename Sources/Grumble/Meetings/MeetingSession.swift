import Foundation

/// One meeting recording: a timestamped folder holding two independent tracks
/// (mic = me, system = them) plus a meta.json written on stop. The tracks are
/// separate on purpose - ASR does better on clean single-source audio, and
/// two tracks give free two-party diarization before the diarizer even runs.
final class MeetingSession {
    let dir: URL
    let startedAt = Date()
    let sourceBundleID: String?

    private let mic = MicTrackRecorder()
    private let system = SystemTrackRecorder()

    var onLevel: ((Float) -> Void)? {
        get { mic.onLevel }
        set { mic.onLevel = newValue }
    }

    static func meetingsRoot() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grumble/Meetings", isDirectory: true)
    }

    private static let folderFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Create the session folder (UTC timestamp, suffixed on collision)
    /// without starting capture yet.
    init(sourceBundleID: String?) throws {
        self.sourceBundleID = sourceBundleID
        let root = Self.meetingsRoot()
        let base = Self.folderFormat.string(from: startedAt) + "Z"
        var candidate = root.appendingPathComponent(base, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(base)-\(n)", isDirectory: true)
            n += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        dir = candidate
    }

    /// Start both tracks. If the mic fails after the system tap started, the
    /// tap is torn down so a half-silent session never runs.
    func start() throws {
        try system.start(writingTo: dir.appendingPathComponent("system.caf"))
        do {
            try mic.start(writingTo: dir.appendingPathComponent("mic.caf"))
        } catch {
            system.stop()
            throw error
        }
    }

    /// Stop both tracks and write meta.json. meta.json is the durable record:
    /// the pipeline (and a DB rebuild after corruption) works from it alone.
    func stop() {
        mic.stop()
        system.stop()

        let ended = Date()
        let iso = ISO8601DateFormatter()

        // The tracks don't start on the same buffer; record how far each lags
        // the earliest so transcript timestamps share one clock.
        let micStart = mic.firstBufferAt ?? startedAt
        let systemStart = system.firstBufferAt ?? startedAt
        let earliest = min(micStart, systemStart)

        var meta: [String: Any] = [
            "started": iso.string(from: startedAt),
            "ended": iso.string(from: ended),
            "duration_seconds": Int(ended.timeIntervalSince(startedAt)),
            "files": ["mic": "mic.caf", "system": "system.caf"],
            "start_offset_ms": [
                "mic": Int(micStart.timeIntervalSince(earliest) * 1000),
                "system": Int(systemStart.timeIntervalSince(earliest) * 1000),
            ],
        ]
        if let sourceBundleID {
            meta["source_bundle_id"] = sourceBundleID
        }
        if let data = try? JSONSerialization.data(
            withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    /// Stop capture and delete everything recorded so far.
    func discard() {
        mic.stop()
        system.stop()
        try? FileManager.default.removeItem(at: dir)
    }
}

/// The parsed shape of a session folder's meta.json.
struct MeetingSessionMeta: Decodable {
    let started: Date
    let ended: Date
    let durationSeconds: Int
    let startOffsetMs: [String: Int]
    let sourceBundleId: String?

    enum CodingKeys: String, CodingKey {
        case started, ended
        case durationSeconds = "duration_seconds"
        case startOffsetMs = "start_offset_ms"
        case sourceBundleId = "source_bundle_id"
    }

    static func load(from dir: URL) -> MeetingSessionMeta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingSessionMeta.self, from: data)
    }
}
