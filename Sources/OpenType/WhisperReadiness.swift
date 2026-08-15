import Foundation

/// How far the local speech model has got to loading, and what the app does
/// about it while it is not there yet.
///
/// Before this, the first launch was a blank screen: the installer mentions the
/// ~460 MB download in the terminal, the whisper server loaded its model before
/// opening its socket, and the app had nothing to ask. Install, grant, hold the
/// hotkey, speak, release — and nothing, for minutes. Everything here exists to
/// turn that minute into something the user can read, and — the part that
/// matters more — to make sure the words they spoke into it survive.

/// The states `GET /asr/status` reports.
///
/// `starting` is the sidecar's alone: the python child is spawned without
/// awaiting readiness, so a connection refused on its socket is the ordinary
/// first second of a launch rather than an error, and only the parent can say
/// so because the child is not there to.
enum WhisperModelState: String, Codable, CaseIterable, Equatable {
    case starting
    case downloading
    case loading
    case ready
    case failed
}

enum WhisperBackend: String, Codable, Equatable {
    case local
    case remote
}

/// One reading of `GET /asr/status`.
///
/// Everything but `state` and `backend` is optional because a remote-Whisper
/// user's entire body is `{"state":"ready","backend":"remote"}` — there is no
/// local model, no download, and nothing to wait for. Requiring any other field
/// would throw on that body and back the poller off forever against a perfectly
/// healthy configuration.
struct WhisperStatusSnapshot: Equatable, Decodable {
    let state: WhisperModelState
    let backend: WhisperBackend
    let model: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?
    let error: String?

    /// Download progress, or `nil` when it cannot honestly be drawn.
    ///
    /// An unknown or zero total degrades to no bar rather than to a bar at 0%:
    /// a progress indicator frozen at zero for a whole minute is this feature's
    /// original blank screen wearing a costume. Clamped at both ends because a
    /// count arriving from another process is not something to trust into a
    /// layout.
    var fractionComplete: Double? {
        guard
            let downloadedBytes,
            let totalBytes,
            totalBytes > 0
        else { return nil }
        return min(1.0, max(0.0, Double(downloadedBytes) / Double(totalBytes)))
    }
}

/// What one poll produced. `unreachable` covers every transport failure and
/// every body this app cannot read — an unrecognised state must land here, not
/// near `.ready`, because `.ready` is what stops the poller and takes the
/// banner down.
enum WhisperPollOutcome: Equatable {
    case status(WhisperModelState)
    case unreachable
}

enum WhisperPollDecision: Equatable {
    case poll(afterSeconds: TimeInterval)
    case stop
}

/// When to ask again, and when to stop asking.
enum WhisperStatusPolling {
    /// Fast enough that a minutes-long download looks alive; slow enough that a
    /// unix-socket round trip per tick costs nothing.
    static let interval: TimeInterval = 1.0

    /// Ceiling on the transport backoff.
    static let maxBackoff: TimeInterval = 30

    /// How many consecutive unreachable polls before giving up. Bounded for the
    /// same reason `SidecarSupervisor.restartDecision` is: an unbounded retry
    /// loop against a dead sidecar is exactly the permanent background timer
    /// this design refuses to create, under a different name.
    static let maxConsecutiveFailures: Int = 5

    /// Polling waits for a sidecar that is actually answering. Starting sooner
    /// would spend the whole failure budget on the seconds before the sidecar
    /// has opened its socket, and then stop for good.
    static func shouldStart(sidecarStatus: SidecarStatus) -> Bool {
        sidecarStatus == .ready
    }

    static func decide(
        outcome: WhisperPollOutcome,
        consecutiveFailureCount: Int
    ) -> WhisperPollDecision {
        switch outcome {
        case .status(let state):
            switch state {
            case .ready:
                // The headline rule: no resident timer for a question that was
                // answered once at launch and cannot change without a restart.
                return .stop
            case .failed:
                // Terminal until the user acts. The exits are retry and switch
                // to remote recognition, both of which they choose; polling on
                // would show a spinner that resolves to nothing and sit on top
                // of the two buttons that actually fix it.
                return .stop
            case .starting, .downloading, .loading:
                // Backoff describes the transport, not the model — a status
                // that arrived is a working transport whatever came before it,
                // so the failure count is deliberately ignored here.
                return .poll(afterSeconds: interval)
            }
        case .unreachable:
            guard consecutiveFailureCount <= maxConsecutiveFailures else { return .stop }
            // One dropped request during a sidecar restart is not a reason to
            // wait, so the first failure retries at the ordinary interval and
            // the doubling starts after it.
            let doublings = max(0, consecutiveFailureCount - 1)
            let delay = interval * pow(2, Double(doublings))
            return .poll(afterSeconds: min(delay, maxBackoff))
        }
    }
}

/// One entry in the model menu, as the sidecar reports it.
///
/// Carries no display copy: the sidecar returns data and this side names the
/// sizes, which is what keeps every user-visible string inside this app's own
/// localisation rather than arriving pre-translated over HTTP.
struct WhisperModelPreset: Decodable, Equatable, Identifiable {
    let id: String
    let approximateDownloadBytes: Int64

    /// 「约 460 MB」 — the number the choice is actually made on.
    var approximateSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: approximateDownloadBytes)
    }
}

/// `GET`/`PUT /config/whisper-model`.
struct WhisperModelConfig: Decodable, Equatable {
    let model: String
    /// `saved` / `env` / `default` — an ambient environment variable is used
    /// but never counts as a choice the user made.
    let source: String
    let configured: Bool
    let presets: [WhisperModelPreset]
    /// Present only on a `PUT`: the new model applies from the next launch.
    let restartRequired: Bool?
}

/// What the rest of the app does while the model is coming up.
enum WhisperReadinessPolicy {
    /// Always true, and asserted over every state so it stays that way.
    ///
    /// 「用户在未就绪时按了热键：录音照常进行」 is a promise, not a default: what
    /// changes while the model loads is what the overlay says, never whether the
    /// microphone opens. A version of this that returned false somewhere would
    /// throw away words the user had already spoken.
    static func allowsRecording(_ state: WhisperModelState) -> Bool {
        true
    }

    /// The 「正在准备语音模型」 banner, shown exactly while there is something to
    /// wait for. A failed load gets the failure surface instead — a preparing
    /// banner that will never finish is worse than none.
    static func showsPreparingBanner(_ state: WhisperModelState) -> Bool {
        switch state {
        case .starting, .downloading, .loading:
            return true
        case .ready, .failed:
            return false
        }
    }

    /// How long a transcription request may take, given what the model is doing.
    ///
    /// This is the load-bearing half of 「录音不能丢」. The whisper server holds a
    /// request until the model is ready, but that only preserves the recording
    /// if the caller is still there when it arrives — and `SidecarClient`'s
    /// budget is 300s for every request. A 460 MB download over a bad hotel
    /// connection outlasts that comfortably, and when the timeout fires the
    /// user's dictation is gone with nothing on screen to say why: the same
    /// failure this whole feature removes, moved five minutes later.
    ///
    /// A failed load is excluded because it answers immediately rather than
    /// blocking, so the long budget could only delay an error the user is
    /// already waiting to see.
    static func transcribeTimeoutSeconds(_ state: WhisperModelState) -> Int {
        switch state {
        case .starting, .downloading, .loading:
            return 1_800
        case .ready, .failed:
            return 300
        }
    }
}
