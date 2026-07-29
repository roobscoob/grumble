import AVFoundation
import FluidAudio
import Foundation

/// Post-meeting processing: a serial queue of session folders. For each one,
/// both tracks are transcribed with the offline Parakeet TDT model, the
/// system track is diarized with Sortformer, mic segments become "me" while
/// system segments are assigned to diarized speaker slots, and the merged
/// transcript lands in the database.
///
/// The filesystem is the queue: `resumePending()` rescans session folders at
/// launch, so a crash or quit mid-processing just retries on the next run.
/// Models are loaded lazily when there is work and released when the queue
/// drains, so Grumble never idles holding the batch models.
actor MeetingPipeline {
    private let store: MeetingStore
    private var queue: [String] = []
    private var draining = false

    private var asrManager: AsrManager?
    private var diarizer: SortformerDiarizer?

    /// Set by the app so finished transcripts get a title and summary; absent
    /// until the summarization model is installed (it is opt-in).
    var summarizer: MeetingSummarizer?

    /// Fired on every meeting state change so the menu can reflect progress.
    var onActivity: (@Sendable () -> Void)?

    init(store: MeetingStore) {
        self.store = store
    }

    func setSummarizer(_ summarizer: MeetingSummarizer?) {
        self.summarizer = summarizer
    }

    func setOnActivity(_ handler: @escaping @Sendable () -> Void) {
        onActivity = handler
    }

    var isProcessing: Bool { draining }

    func enqueue(audioDir: String) {
        guard !queue.contains(audioDir) else { return }
        queue.append(audioDir)
        drainIfIdle()
    }

    /// Scan for sessions that finished recording (meta.json exists) but never
    /// completed processing, oldest first. Folder names sort chronologically.
    func resumePending() {
        let root = MeetingSession.meetingsRoot()
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
        else { return }

        let fm = FileManager.default
        let pending =
            entries
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
            .map(\.lastPathComponent)
            .filter { dir in
                let state = (try? store.meeting(audioDir: dir))??.state
                return state != .done && state != .failed
            }
            .sorted()
        for dir in pending { enqueue(audioDir: dir) }
    }

    /// Re-run summarization only (used when the LLM is installed after
    /// meetings were already transcribed).
    func summarize(meetingId: Int64) async {
        guard let summarizer, let meeting = try? store.meeting(id: meetingId) else { return }
        try? store.setState(audioDir: meeting.audioDir, .summarizing)
        onActivity?()
        await runSummarizer(summarizer, meeting: meeting)
        try? store.setState(audioDir: meeting.audioDir, .done)
        onActivity?()
    }

    private func drainIfIdle() {
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while let dir = queue.first {
            queue.removeFirst()
            do {
                try await process(audioDir: dir)
            } catch {
                NSLog("Grumble: meeting processing failed for \(dir): \(error)")
                try? store.setState(
                    audioDir: dir, .failed, error: error.localizedDescription)
            }
            onActivity?()
        }
        releaseModels()
        draining = false
        onActivity?()
    }

    private func process(audioDir: String) async throws {
        let dir = MeetingSession.meetingsRoot().appendingPathComponent(audioDir)
        guard let meta = MeetingSessionMeta.load(from: dir) else {
            throw NSError(
                domain: "Grumble", code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Session has no readable meta.json."])
        }

        // The DB row normally exists from recording start; recreate it from
        // meta.json when the database was reset or the row was lost.
        var meeting: Meeting
        if let existing = try store.meeting(audioDir: audioDir) {
            meeting = existing
        } else {
            meeting = try store.createMeeting(
                audioDir: audioDir, startedAt: meta.started, sourceBundleId: meta.sourceBundleId)
        }
        meeting.endedAt = meta.ended
        meeting.state = .transcribing
        try store.update(meeting)
        onActivity?()

        let manager = try await loadAsr()

        let micOffsetMs = meta.startOffsetMs["mic"] ?? 0
        let systemOffsetMs = meta.startOffsetMs["system"] ?? 0
        let micSegments = try await transcribeTrack(
            dir.appendingPathComponent("mic.caf"), with: manager)
        let systemSegments = try await transcribeTrack(
            dir.appendingPathComponent("system.caf"), with: manager)

        // Diarize the system track. Failure degrades to a single remote
        // speaker rather than losing the meeting.
        var speakerSpans: [(slot: String, start: Double, end: Double)] = []
        if !systemSegments.isEmpty {
            do {
                let diarizer = try await loadDiarizer()
                let timeline = try diarizer.processComplete(
                    audioFileURL: dir.appendingPathComponent("system.caf"))
                for (index, speaker) in timeline.speakers.sorted(by: { $0.key < $1.key }) {
                    for segment in speaker.finalizedSegments {
                        speakerSpans.append(
                            (
                                slot: "spk\(index)",
                                start: Double(segment.startTime),
                                end: Double(segment.endTime)
                            ))
                    }
                }
            } catch {
                NSLog("Grumble: diarization failed, using a single remote speaker: \(error)")
            }
        }

        var merged: [(slot: String, startMs: Int, endMs: Int, text: String)] = []
        for segment in micSegments {
            merged.append(
                (
                    slot: "me",
                    startMs: micOffsetMs + Int(segment.start * 1000),
                    endMs: micOffsetMs + Int(segment.end * 1000),
                    text: segment.text
                ))
        }
        for segment in systemSegments {
            let slot = Self.dominantSlot(
                for: segment, among: speakerSpans) ?? "spk0"
            merged.append(
                (
                    slot: slot,
                    startMs: systemOffsetMs + Int(segment.start * 1000),
                    endMs: systemOffsetMs + Int(segment.end * 1000),
                    text: segment.text
                ))
        }
        merged.sort { $0.startMs < $1.startMs }

        guard let meetingId = meeting.id else { return }
        var speakers: [MeetingSpeaker] = []
        for slot in Set(merged.map(\.slot)).sorted() {
            speakers.append(MeetingSpeaker(meetingId: meetingId, slot: slot))
        }
        try store.replaceTranscript(meetingId: meetingId, speakers: speakers, segments: merged)

        if let summarizer {
            try store.setState(audioDir: audioDir, .summarizing)
            onActivity?()
            await runSummarizer(summarizer, meeting: meeting)
        }
        try store.setState(audioDir: audioDir, .done)

        if MeetingAudioRetention.current == .afterTranscription {
            for file in ["mic.caf", "system.caf"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
            }
        }
    }

    private func runSummarizer(_ summarizer: MeetingSummarizer, meeting: Meeting) async {
        guard let meetingId = meeting.id else { return }
        do {
            guard
                let transcript = try? store.markdown(for: meeting),
                !transcript.isEmpty
            else { return }
            let speakers = try store.speakers(meetingId: meetingId)
            let result = try await summarizer.summarize(
                transcript: transcript,
                speakerLabels: speakers.map(\.label)
            )
            var updated = try store.meeting(id: meetingId) ?? meeting
            // Manual edits win: only fill fields the user hasn't touched.
            if updated.title == nil || updated.title?.isEmpty == true {
                updated.title = result.title
            }
            updated.summary = result.summary
            try store.update(updated)

            for speaker in speakers {
                guard speaker.namedBy != "user", let speakerId = speaker.id else { continue }
                if let proposal = result.speakerNames[speaker.slot], proposal.confident {
                    try store.setAutoName(speakerId: speakerId, name: proposal.name)
                }
            }
        } catch {
            // Summarization is best-effort; the transcript is already saved.
            NSLog("Grumble: summarization failed: \(error)")
        }
    }

    // MARK: - Engines

    private func loadAsr() async throws -> AsrManager {
        if let asrManager { return asrManager }
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager()
        try await manager.loadModels(models)
        asrManager = manager
        return manager
    }

    private func loadDiarizer() async throws -> SortformerDiarizer {
        if let diarizer { return diarizer }
        let models = try await SortformerModels.loadFromHuggingFace(config: .default)
        let newDiarizer = SortformerDiarizer(config: .default)
        newDiarizer.initialize(models: models)
        diarizer = newDiarizer
        return newDiarizer
    }

    private func releaseModels() {
        if let asrManager {
            let manager = asrManager
            Task { await manager.cleanup() }
        }
        asrManager = nil
        diarizer?.cleanup()
        diarizer = nil
    }

    // MARK: - Merge helpers

    struct TrackSegment {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private func transcribeTrack(_ url: URL, with manager: AsrManager) async throws
        -> [TrackSegment]
    {
        // A track with no frames (recorder died before its first buffer)
        // raises an uncatchable ObjC exception deep in the resampler; probe
        // readability up front and treat the track as empty instead.
        do {
            let probe = try AVAudioFile(forReading: url)
            guard probe.length > 0 else { return [] }
        } catch {
            return []
        }

        var state = try TdtDecoderState()
        let result = try await manager.transcribe(url, decoderState: &state)

        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [TrackSegment(start: 0, end: result.duration, text: text)]
        }
        return Self.segments(from: words)
    }

    /// Group word timings into readable segments: break on sentence-ending
    /// punctuation (Parakeet v2 emits punctuation), a silence gap, or a hard
    /// length cap so a run-on speaker still wraps.
    private static func segments(from words: [WordTiming]) -> [TrackSegment] {
        var out: [TrackSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(
                TrackSegment(
                    start: first.startTime,
                    end: last.endTime,
                    text: current.map(\.word).joined(separator: " ")
                ))
            current = []
        }

        for word in words {
            if let last = current.last, word.startTime - last.endTime > 1.0 {
                flush()
            }
            current.append(word)
            let endsSentence =
                word.word.hasSuffix(".") || word.word.hasSuffix("?") || word.word.hasSuffix("!")
            if endsSentence || current.count >= 60 {
                flush()
            }
        }
        flush()
        return out
    }

    /// The diarized speaker whose speech overlaps this ASR segment the most.
    private static func dominantSlot(
        for segment: TrackSegment,
        among spans: [(slot: String, start: Double, end: Double)]
    ) -> String? {
        var overlapBySlot: [String: Double] = [:]
        for span in spans {
            let overlap = min(segment.end, span.end) - max(segment.start, span.start)
            if overlap > 0 {
                overlapBySlot[span.slot, default: 0] += overlap
            }
        }
        return overlapBySlot.max(by: { $0.value < $1.value })?.key
    }
}
