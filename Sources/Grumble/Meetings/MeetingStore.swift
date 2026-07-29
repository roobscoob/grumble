import Foundation
import GRDB

/// All structured meeting data, in one SQLite database under Application
/// Support. Schema changes ship only as new appended migrations - existing
/// migration blocks are never edited, so any older database upgrades cleanly
/// no matter how many versions were skipped.
struct Meeting: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "meetings"

    enum State: String, Codable {
        case recording, queued, transcribing, summarizing, done, failed
    }

    var id: Int64?
    var startedAt: Date
    var endedAt: Date?
    var sourceBundleId: String?
    var title: String?
    var summary: String?
    /// Session folder name under Meetings/ (not an absolute path, so the
    /// database survives container moves).
    var audioDir: String
    var state: State
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return "Meeting on \(f.string(from: startedAt))"
    }

    var durationSeconds: Int {
        guard let endedAt else { return 0 }
        return Int(endedAt.timeIntervalSince(startedAt))
    }
}

struct MeetingSpeaker: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "speakers"

    var id: Int64?
    var meetingId: Int64
    /// 'me' for the mic track, 'spk0'...'spk3' for diarized system speakers.
    var slot: String
    var displayName: String?
    /// 'auto' when named by the LLM from context clues, 'user' when renamed
    /// by hand. User names always win and are never overwritten.
    var namedBy: String?

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if slot == "me" { return "Me" }
        if let n = Int(slot.dropFirst(3)) { return "Speaker \(n + 1)" }
        return slot
    }
}

struct MeetingSegment: Codable, Identifiable, Equatable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "segments"

    var id: Int64?
    var meetingId: Int64
    var speakerId: Int64
    var startMs: Int
    var endMs: Int
    var text: String

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

final class MeetingStore {
    let dbQueue: DatabaseQueue

    init() throws {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Grumble", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("grumble.sqlite").path)
        try Self.migrator.migrate(dbQueue)
    }

    /// Append-only. Never edit an existing migration; add a new one.
    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "meetings") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull()
                t.column("endedAt", .datetime)
                t.column("sourceBundleId", .text)
                t.column("title", .text)
                t.column("summary", .text)
                t.column("audioDir", .text).notNull().unique()
                t.column("state", .text).notNull()
                t.column("errorMessage", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "speakers") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.column("slot", .text).notNull()
                t.column("displayName", .text)
                t.column("namedBy", .text)
                t.uniqueKey(["meetingId", "slot"])
            }
            try db.create(table: "segments") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("meeting", onDelete: .cascade).notNull()
                t.belongsTo("speaker", onDelete: .cascade).notNull()
                t.column("startMs", .integer).notNull()
                t.column("endMs", .integer).notNull()
                t.column("text", .text).notNull()
            }
            try db.create(index: "segments_by_meeting", on: "segments", columns: ["meetingId", "startMs"])

            // Full-text search over transcript text, kept in sync with the
            // segments table by GRDB-generated triggers.
            try db.create(virtualTable: "segments_fts", using: FTS5()) { t in
                t.synchronize(withTable: "segments")
                t.column("text")
            }
        }

        return migrator
    }

    // MARK: - Writes

    @discardableResult
    func createMeeting(audioDir: String, startedAt: Date, sourceBundleId: String?) throws -> Meeting {
        try dbQueue.write { db in
            let now = Date()
            var meeting = Meeting(
                startedAt: startedAt,
                sourceBundleId: sourceBundleId,
                audioDir: audioDir,
                state: .recording,
                createdAt: now,
                updatedAt: now
            )
            try meeting.insert(db)
            return meeting
        }
    }

    func update(_ meeting: Meeting) throws {
        var meeting = meeting
        meeting.updatedAt = Date()
        try dbQueue.write { db in try meeting.update(db) }
    }

    func setState(audioDir: String, _ state: Meeting.State, error: String? = nil) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE meetings SET state = ?, errorMessage = ?, updatedAt = ?
                    WHERE audioDir = ?
                    """,
                arguments: [state.rawValue, error, Date(), audioDir]
            )
        }
    }

    /// Replace any prior transcript for the meeting (a re-run after a crash
    /// must not duplicate segments), preserving user-assigned speaker names
    /// by slot.
    func replaceTranscript(
        meetingId: Int64,
        speakers: [MeetingSpeaker],
        segments: [(slot: String, startMs: Int, endMs: Int, text: String)]
    ) throws {
        try dbQueue.write { db in
            let preserved = try MeetingSpeaker
                .filter(Column("meetingId") == meetingId)
                .filter(Column("namedBy") == "user")
                .fetchAll(db)
            let preservedNames = Dictionary(
                uniqueKeysWithValues: preserved.map { ($0.slot, $0.displayName) })

            try MeetingSegment.filter(Column("meetingId") == meetingId).deleteAll(db)
            try MeetingSpeaker.filter(Column("meetingId") == meetingId).deleteAll(db)

            var idBySlot: [String: Int64] = [:]
            for var speaker in speakers {
                if let name = preservedNames[speaker.slot] {
                    speaker.displayName = name
                    speaker.namedBy = "user"
                }
                try speaker.insert(db)
                idBySlot[speaker.slot] = speaker.id
            }
            for segment in segments {
                guard let speakerId = idBySlot[segment.slot] else { continue }
                var record = MeetingSegment(
                    meetingId: meetingId,
                    speakerId: speakerId,
                    startMs: segment.startMs,
                    endMs: segment.endMs,
                    text: segment.text
                )
                try record.insert(db)
            }
        }
    }

    /// Apply an LLM-proposed name. Callers must skip user-named speakers.
    func setAutoName(speakerId: Int64, name: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE speakers SET displayName = ?, namedBy = 'auto' WHERE id = ?",
                arguments: [name, speakerId]
            )
        }
    }

    func renameSpeaker(id: Int64, to name: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE speakers SET displayName = ?, namedBy = 'user' WHERE id = ?",
                arguments: [name.isEmpty ? nil : name, id]
            )
        }
    }

    func deleteMeeting(_ meeting: Meeting) throws {
        _ = try dbQueue.write { db in try meeting.delete(db) }
        let dir = MeetingSession.meetingsRoot().appendingPathComponent(meeting.audioDir)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Reads

    func meeting(audioDir: String) throws -> Meeting? {
        try dbQueue.read { db in
            try Meeting.filter(Column("audioDir") == audioDir).fetchOne(db)
        }
    }

    func meeting(id: Int64) throws -> Meeting? {
        try dbQueue.read { db in try Meeting.fetchOne(db, key: id) }
    }

    func speakers(meetingId: Int64) throws -> [MeetingSpeaker] {
        try dbQueue.read { db in
            try MeetingSpeaker.filter(Column("meetingId") == meetingId)
                .order(Column("slot")).fetchAll(db)
        }
    }

    func segments(meetingId: Int64) throws -> [MeetingSegment] {
        try dbQueue.read { db in
            try MeetingSegment.filter(Column("meetingId") == meetingId)
                .order(Column("startMs")).fetchAll(db)
        }
    }

    /// Newest first; a non-empty query matches titles and summaries by
    /// substring and transcript text by FTS.
    func meetings(matching query: String) throws -> [Meeting] {
        try dbQueue.read { db in
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else {
                return try Meeting.order(Column("startedAt").desc).fetchAll(db)
            }
            guard let pattern = FTS5Pattern(matchingAllPrefixesIn: trimmed) else {
                return try Meeting.order(Column("startedAt").desc).fetchAll(db)
            }
            return try Meeting.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT m.* FROM meetings m
                    LEFT JOIN segments s ON s.meetingId = m.id
                    LEFT JOIN segments_fts f ON f.rowid = s.id AND segments_fts MATCH ?
                    WHERE f.rowid IS NOT NULL
                       OR m.title LIKE ? OR m.summary LIKE ?
                    ORDER BY m.startedAt DESC
                    """,
                arguments: [pattern, "%\(trimmed)%", "%\(trimmed)%"]
            )
        }
    }

    /// Export one meeting as readable markdown.
    func markdown(for meeting: Meeting) throws -> String {
        guard let meetingId = meeting.id else { return "" }
        let speakers = try speakers(meetingId: meetingId)
        let segments = try segments(meetingId: meetingId)
        let labelById = Dictionary(uniqueKeysWithValues: speakers.compactMap { s in
            s.id.map { ($0, s.label) }
        })

        var out = "# \(meeting.displayTitle)\n\n"
        let f = DateFormatter()
        f.dateStyle = .full
        f.timeStyle = .short
        out += "\(f.string(from: meeting.startedAt))\n\n"
        if let summary = meeting.summary, !summary.isEmpty {
            out += "## Summary\n\n\(summary)\n\n"
        }
        out += "## Transcript\n\n"
        for segment in segments {
            let stamp = String(
                format: "%d:%02d", segment.startMs / 60000, (segment.startMs / 1000) % 60)
            let label = labelById[segment.speakerId] ?? "Speaker"
            out += "**\(label)** (\(stamp)): \(segment.text)\n\n"
        }
        return out
    }
}
