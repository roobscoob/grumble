import Foundation

/// Storage policy for raw meeting audio. Transcripts and summaries live in
/// the database and are never subject to retention; this only governs the
/// CAF tracks (roughly 30 MB per meeting hour).
enum MeetingAudioRetention: String, CaseIterable {
    case forever
    case thirtyDays
    case sevenDays
    case afterTranscription

    static let defaultsKey = "meetingAudioRetention"

    static var current: MeetingAudioRetention {
        get {
            UserDefaults.standard.string(forKey: defaultsKey)
                .flatMap(MeetingAudioRetention.init(rawValue:)) ?? .forever
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
        }
    }

    var label: String {
        switch self {
        case .forever: return "Keep forever"
        case .thirtyDays: return "Keep for 30 days"
        case .sevenDays: return "Keep for 7 days"
        case .afterTranscription: return "Delete after transcription"
        }
    }

    var maxAge: TimeInterval? {
        switch self {
        case .forever: return nil
        case .thirtyDays: return 30 * 24 * 3600
        case .sevenDays: return 7 * 24 * 3600
        case .afterTranscription: return 0
        }
    }

    /// Remove audio tracks that have aged out for fully processed meetings.
    /// meta.json stays so the database row remains rebuildable; without the
    /// tracks the meeting simply loses playback.
    static func enforce(store: MeetingStore) {
        guard let maxAge = current.maxAge else { return }
        guard let meetings = try? store.meetings(matching: "") else { return }
        let cutoff = Date().addingTimeInterval(-maxAge)
        for meeting in meetings where meeting.state == .done && meeting.startedAt < cutoff {
            let dir = MeetingSession.meetingsRoot().appendingPathComponent(meeting.audioDir)
            for file in ["mic.caf", "system.caf"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }
}
