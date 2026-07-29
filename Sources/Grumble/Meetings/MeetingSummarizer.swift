import Foundation

/// A proposed real name for a diarized speaker slot, inferred from context
/// clues in the transcript. Only confident proposals are applied, and never
/// over a user-assigned name.
struct SpeakerNameProposal {
    let name: String
    let confident: Bool
}

struct MeetingSummary {
    let title: String
    let summary: String
    /// Keyed by speaker slot ('me', 'spk0', ...).
    let speakerNames: [String: SpeakerNameProposal]
}

/// A local model that turns a finished transcript into a title, a summary,
/// and speaker-name proposals. Implemented by the opt-in Qwen summarizer;
/// absent until the user installs it.
protocol MeetingSummarizer: Sendable {
    func summarize(transcript: String, speakerLabels: [String]) async throws -> MeetingSummary
}
