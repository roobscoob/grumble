import Foundation

/// What post-processing is doing right now, published for the UI.
///
/// Processing a long meeting runs for minutes across several stages, and a
/// bare "Transcribing" badge gives no way to tell steady progress from a
/// wedged job - so the pipeline reports the stage it is in, how far through
/// it is, and when it entered it.
struct MeetingProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// Tracks are transcribed one after another (mic, then system).
        case transcribing(track: Int, of: Int)
        case diarizing
        case summarizing
    }

    /// Session folder of the meeting being processed.
    var audioDir: String
    var stage: Stage
    var stageStartedAt: Date
    /// Length of the recording, for the throughput-based estimate.
    var audioSeconds: Double

    var label: String {
        switch stage {
        case .transcribing(let track, let total):
            return total > 1 ? "Transcribing audio (track \(track) of \(total))" : "Transcribing audio"
        case .diarizing:
            return "Identifying speakers"
        case .summarizing:
            return "Summarizing"
        }
    }

    /// Determinate fraction where the stage has a real count behind it.
    /// Transcription reports one only once throughput is known, and never
    /// claims completion, so the bar cannot sit full while work continues.
    var fraction: Double? {
        switch stage {
        case .transcribing(let track, let total):
            guard let rate = MeetingThroughput.realtimeFactor, audioSeconds > 0 else { return nil }
            let perTrack = 1.0 / Double(total)
            let elapsed = Date().timeIntervalSince(stageStartedAt)
            let withinTrack = min(elapsed / (audioSeconds / rate), 0.99)
            return (Double(track - 1) + withinTrack) * perTrack
        case .diarizing, .summarizing:
            return nil
        }
    }

    /// Rough seconds remaining, or nil when there is nothing to base it on.
    var estimatedSecondsRemaining: Double? {
        guard let fraction, fraction > 0.02 else { return nil }
        let elapsed = Date().timeIntervalSince(stageStartedAt)
        guard elapsed > 3 else { return nil }
        switch stage {
        case .transcribing(let track, let total):
            guard let rate = MeetingThroughput.realtimeFactor, audioSeconds > 0 else { return nil }
            let perTrack = audioSeconds / rate
            let remainingTracks = Double(total - track) * perTrack
            return max(perTrack - elapsed, 0) + remainingTracks
        case .diarizing, .summarizing:
            return nil
        }
    }

    /// A stage running far past its estimate is worth flagging rather than
    /// letting the user wonder whether anything is happening.
    var isStalled: Bool {
        let elapsed = Date().timeIntervalSince(stageStartedAt)
        switch stage {
        case .transcribing:
            guard let rate = MeetingThroughput.realtimeFactor, audioSeconds > 0 else {
                return elapsed > 1800
            }
            return elapsed > (audioSeconds / rate) * 4 + 120
        case .diarizing, .summarizing:
            return elapsed > 1800
        }
    }
}

/// Append-only trace of pipeline stages, for diagnosing a run that stalls on
/// a user's machine. NSLog is not reliably retrievable from a sandboxed GUI
/// app after the fact; a file under the container always is.
enum MeetingTrace {
    private static let url = MeetingSession.meetingsRoot()
        .deletingLastPathComponent()
        .appendingPathComponent("pipeline.log")

    static func write(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "[\(stamp)] \(message)\n".data(using: .utf8) else { return }
        let fm = FileManager.default
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
}

/// Learned transcription throughput: seconds of audio per second of wall
/// clock, smoothed across runs. The first meeting on a given Mac has nothing
/// to estimate from and simply shows an indeterminate bar; later ones inherit
/// what the earlier runs measured.
enum MeetingThroughput {
    private static let key = "meetingAsrRealtimeFactor"

    static var realtimeFactor: Double? {
        let value = UserDefaults.standard.double(forKey: key)
        return value > 0 ? value : nil
    }

    /// Fold one completed track into the estimate. Short tracks are ignored -
    /// model load dominates them and would skew the rate badly.
    static func record(audioSeconds: Double, elapsed: Double) {
        guard audioSeconds > 60, elapsed > 1 else { return }
        let sample = audioSeconds / elapsed
        let blended = realtimeFactor.map { $0 * 0.7 + sample * 0.3 } ?? sample
        UserDefaults.standard.set(blended, forKey: key)
    }
}

/// Bridges the pipeline actor's progress to SwiftUI. Progress is deliberately
/// not persisted: it describes a run in flight, and a run that dies leaves the
/// meeting's state in the database as the durable record.
@MainActor
final class MeetingProgressCenter: ObservableObject {
    static let shared = MeetingProgressCenter()

    @Published private(set) var current: MeetingProgress?

    func update(_ progress: MeetingProgress?) {
        current = progress
    }

    /// Progress for a specific meeting, so a row only shows its own.
    func progress(for meeting: Meeting) -> MeetingProgress? {
        guard let current, current.audioDir == meeting.audioDir else { return nil }
        return current
    }
}
