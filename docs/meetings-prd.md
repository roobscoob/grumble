# PRD: Grumble Meetings

Automatic meeting recording, diarized transcripts, and local summaries.

## Overview

Grumble today is a push-to-talk dictation app. This feature adds a second mode:
Grumble detects when a meeting starts (Zoom, Google Meet, Teams, and similar),
records both the microphone and system audio entirely on-device, produces a
speaker-tagged transcript, generates a title and summary with a local LLM, and
presents everything in a simple browser UI opened from the menu bar.

Everything runs locally. No audio, transcript, or summary ever leaves the Mac.
The only network traffic is one-time model downloads from HuggingFace, matching
how ASR models are fetched today.

## Goals

- Zero-effort capture: meetings are recorded without the user remembering to
  press anything.
- Trustworthy transcripts: per-speaker attribution, not a wall of text.
- Useful recall: titles, summaries, and search make old meetings findable.
- Full user control: obvious recording indicator, one-click stop/discard,
  per-app opt-out, and easy deletion.

## Non-goals (v1)

- Live captions or a live transcript view during the meeting.
- Cloud sync, sharing, or export to third-party services.
- Calendar integration for scheduling-based detection.
- Windows/iOS anything.

## Architecture summary

Two audio tracks are the backbone, the same trick quill uses: the mic track is
inherently "me" and the system-audio track is everyone else. That gives
two-party diarization for free. On top of that, the system track is run through
FluidAudio's Sortformer streaming diarizer to split "them" into individual
remote speakers. Sortformer is the pick because it is the only backend that is
both streaming and near-SOTA accurate (~11% DER on DIHARD-III in real time);
the offline pyannote pipeline is more configurable but not streaming, and
LS-EEND trails it on accuracy.

Pipeline per meeting:

```
detect meeting start
  └─ record mic.caf + system.caf (+ start-offset bookkeeping)
       ├─ live: Sortformer streaming diarization on the system track
       └─ live: level metering for the recording indicator
meeting ends (mic released or manual stop)
  └─ post-process queue (serial, resumable, filesystem-is-the-queue like quill)
       1. batch ASR on each track (Parakeet TDT, offline mode, best accuracy)
       2. merge: mic segments → "Me"; system segments × diarizer timeline
          → Speaker 1..N; interleave by timestamp
       3. local LLM: title + summary + speaker-name inference
       4. write transcript + metadata to SQLite; keep raw audio on disk
```

Recording and post-processing are decoupled so a crash, quit, or model download
failure never loses audio. On launch, any session folder with audio but no
transcript is re-queued (quill's `resumePending` pattern).

## Feature requirements

### 1. Meeting detection and auto-record

Detection is based on "who is using the microphone", via the CoreAudio process
list API (macOS 14.4+): observe `kAudioHardwarePropertyProcessObjectList`,
watch each process's `kAudioProcessPropertyIsRunningInput`, and resolve its
`kAudioProcessPropertyBundleID`.

- Known meeting apps (initial set, config-extensible):
  - `us.zoom.xos` (Zoom)
  - `com.microsoft.teams2` / `com.microsoft.teams` (Teams)
  - `com.cisco.webexmeetingsapp` (Webex)
  - `com.tinyspeck.slackmacgap` (Slack huddles)
  - `com.hnc.Discord` (Discord)
  - `com.apple.FaceTime` (FaceTime)
- Browsers (`com.google.Chrome`, `com.apple.Safari`, `org.mozilla.firefox`,
  Arc, Edge, Brave) capturing the mic imply a web meeting (Google Meet has no
  native app). Browser detection is a heuristic and defaults to **ask**, not
  auto-record, since a mic-using tab could be anything.
- Debounce: mic in use for 3 s continuously before triggering; meeting
  considered over when the app releases the mic for 15 s, or on manual stop.
- Per-app policy in settings: Auto-record / Ask first / Never. "Ask" posts a
  notification with Record / Ignore actions.
- When recording starts automatically, post a notification and switch the menu
  bar icon to a distinct recording tint. Recording must never be invisible.
- Guard: if Grumble's own dictation is active, dictation wins; meeting capture
  of the mic uses a second AVAudioEngine tap and must not fight the dictation
  path.

### 2. Manual control from the menu bar

- "Record Meeting" menu item toggles recording regardless of detection.
- While recording: elapsed time in the menu, Stop and Discard items.
- Discard deletes the session folder immediately and skips post-processing.

### 3. Capture and storage

- Mic: existing `AudioCapture` (AVAudioEngine tap) pattern, written to
  `mic.caf`.
- System audio: CoreAudio process tap (`CATapDescription` /
  `AudioHardwareCreateProcessTap` + aggregate device, macOS 14.4+), written to
  `system.caf`. This needs the "System Audio Recording Only" TCC grant
  (`NSAudioCaptureUsageDescription`), which is a new row in the Setup window.
  CAF on purpose: append-safe on crash, no finalization step.
- Layout under `~/Library/Application Support/Grumble/` (the sandboxed App
  Store build maps this into its container automatically):

  ```
  Meetings/
    2026-07-28T14-03-22Z/        # UTC start time, sorts chronologically
      mic.caf
      system.caf
      meta.json                  # offsets, source app, device info
    grumble.sqlite               # all structured data (see Data model)
  ```

- Raw audio is kept after transcription (playback in the UI). Settings offer
  retention: keep forever / keep N days / delete audio after transcription.
- Requires raising the deployment target from 14.0 to 14.4 (or gating the
  feature on 14.4+ at runtime). Recommendation: bump the target; 14.4 is over
  two years old.

### 4. Diarization

- Backend: **SortformerDiarizer** (streaming, ~11% DER DIHARD-III). It runs
  in the post-processing queue over the recorded system track rather than
  live during the meeting: the model is much faster than real time, so
  post-processing stays short without holding inference state open for the
  whole meeting. Feeding it live remains an option if post-meeting latency
  ever matters.
- Sortformer has 4 fixed speaker slots. Combined with the dedicated mic track
  this supports "Me" + up to 4 distinct remote speakers, which covers the large
  majority of calls. More than 4 remote speakers degrade gracefully (merged
  into nearest slot). Documented limitation, revisit if it bites.
- Model download/caching follows the existing ASR pattern
  (`FluidInference/diar-streaming-sortformer-coreml` via the ModelRegistry).

### 5. Transcription

- Post-meeting batch ASR per track with Parakeet TDT 0.6B (offline mode, the
  most accurate configuration; not the streaming Unified variant used for
  dictation). Reuses FluidAudio `AsrManager`, serial queue, one session at a
  time.
- Merge step: shift each track's segments by its start offset, tag mic
  segments "Me", intersect system segments with the Sortformer timeline to
  assign Speaker 1..N, and interleave by timestamp into the final transcript.
- Transcript stored in SQLite (canonical) with timed segments; a markdown
  export is generated on demand, not stored.

### 6. Title, summary, and speaker naming (local LLM)

- Model: Qwen3-4B Instruct, 4-bit, via MLX Swift (consistent with the Smart
  Compose work; same weights can be shared if both features ship). Downloaded
  on first use like other models, with progress in the Setup window.
- After transcription completes, one structured-output run produces:
  - `title`: short, specific ("Q3 pricing sync with Dana"), not generic.
  - `summary`: a few sentences plus key decisions / action items when present.
  - `speaker_names`: proposed mapping from Speaker 1..N to real names based on
    context clues (introductions, "thanks, Sarah", vocatives), each with a
    confidence. Only high-confidence names are auto-applied, and they render
    with a subtle "auto-named" affordance so the user can correct them.
- Every speaker label is manually editable in the UI regardless. Manual edits
  always win and are never overwritten by re-processing.
- Stretch (post-v1): voice fingerprinting across meetings using FluidAudio's
  `EmbeddingExtractor`; store per-speaker embeddings so a named speaker in one
  meeting is recognized in the next.

### 7. Meetings UI

A single SwiftUI window opened from the menu bar ("Meetings…").

- List pane: meetings newest-first showing title, date, duration, source app,
  and participant names. Search box over titles, summaries, and transcript
  text (SQLite FTS5). Processing states shown inline (Recording…,
  Transcribing…, Summarizing…, Failed with retry).
- Detail pane: title (editable), summary, participants with rename affordance,
  and the speaker-tagged transcript with timestamps. Clicking a segment plays
  the raw audio from that point. Actions: copy transcript, export markdown,
  delete meeting (removes DB rows and audio).
- No dock icon change; Grumble stays a menu bar app (LSUIElement), the window
  is a floating panel like Setup/About.

### 8. Data model (SQLite + GRDB)

Structured data lives in one SQLite database managed with **GRDB.swift**,
using its `DatabaseMigrator` for schema migrations. GRDB is actively
maintained, SQLite-native, and its migrator is append-only by design: every
schema change is a new named migration, old migrations are never edited, and
the app runs pending migrations at launch, so any older database upgrades
cleanly no matter how many versions were skipped.

Initial schema (migration `v1`):

```sql
meetings(id, started_at, ended_at, source_bundle_id, title,
         summary, audio_dir, state,          -- recording|transcribing|summarizing|done|failed
         created_at, updated_at)
speakers(id, meeting_id → meetings, slot,    -- 'me' | 'spk1'..'spk4'
         display_name, named_by)             -- 'auto' | 'user' | NULL
segments(id, meeting_id → meetings, speaker_id → speakers,
         start_ms, end_ms, text)
segments_fts(text)                           -- FTS5, contentless, synced by triggers
```

Rules: schema changes ship only as new migrations; destructive migrations are
forbidden; `meta.json` in the session folder duplicates enough to rebuild a DB
row so the DB is recoverable from disk.

## Permissions and App Store notes

- New TCC grant: System Audio Recording (macOS 14.4+ process-tap API,
  `NSAudioCaptureUsageDescription`). Added to the Setup window with the same
  test-via-`open`, reset-via-`tccutil` dev workflow as the existing grants.
- Notifications permission for auto-record prompts.
- The Dev ID build is the primary target. For the GrumbleAppStore target,
  verify early that the process-tap API is usable inside the sandbox with our
  entitlements; if it is not, the Meetings feature is compiled out of the
  App Store build behind the existing `APPSTORE` flag until resolved.

## Performance targets

- Recording overhead: < 10% of one core (two CAF writers + Sortformer
  streaming, which is designed for real-time).
- Post-processing: faster than 0.5x meeting duration on Apple Silicon.
- A 60-minute meeting is roughly 350 MB of CAF audio; retention settings exist
  because of this.

## Milestones

1. **Capture** — manual record from the menu bar, mic + system tracks, session
   folders, TCC plumbing, deployment-target bump.
2. **Pipeline** — batch ASR, Sortformer integration, merge, GRDB schema,
   resumable post-processing queue.
3. **Detection** — CoreAudio process-list watcher, per-app policies, debounce,
   notifications.
4. **UI** — Meetings window, search, playback, delete/export.
5. **Intelligence** — Qwen3-4B title/summary, speaker-name inference, manual
   rename.
6. **Stretch** — cross-meeting voice fingerprints, live transcript view,
   calendar-aware detection.

## Resolved decisions (2026-07-29)

- **Deployment target**: bump the whole app to macOS 14.4. No runtime gating.
- **App Store**: spike first. Before Milestone 1 completes, build a minimal
  sandboxed test of `AudioHardwareCreateProcessTap` with the GrumbleAppStore
  entitlements; the result decides whether Meetings ships in both targets or
  Dev ID only (compiled out behind `APPSTORE`).
  **Spike result (2026-07-29): the sandboxed build creates process taps
  successfully** (`Grumble --probe-system-audio` under the GrumbleAppStore
  entitlements). Meetings ships in both targets.
- **Echo handling**: enable Apple's voice-processing AudioUnit
  (`setVoiceProcessingEnabled`) on the mic path during meeting capture for
  automatic echo cancellation. Accepted trade-off: slightly colored mic audio.
- **LLM download**: opt-in at first use. Meetings work end-to-end without the
  LLM (transcript only); the first summary request prompts to download
  Qwen3-4B (~2.5 GB) with progress in the Setup window.
