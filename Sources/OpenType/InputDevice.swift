import AVFoundation
import AppKit
import Combine
import Foundation

/// 麦克风设备可见 (§K of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md`).
///
/// `AudioRecorder` records from whatever the system says the default input is —
/// it never names a device, which is the right behaviour and the reason the user
/// cannot tell what it picked. The failure that follows
/// (`docs/reviews/2026-08-15-product-review.md` §9): a meeting ends, the AirPods
/// come out, the default silently moves to the built-in microphone, the next
/// dictation is markedly worse, and the only explanation available to the user is
/// 「这产品变差了」.
///
/// So Settings names the device. **只显示，不做选择器**: picking an input is what
/// System Settings is for, and an app-side selection would be a second source of
/// truth for something the system already owns — the row would go on claiming a
/// device the recorder is not using the moment the two drift. What this buys is
/// diagnosis, not control, and diagnosis is what was missing.
///
/// The split is the one the rest of the repo uses for anything that has to touch
/// a framework a test cannot instantiate (`LaunchAtLoginPolicy`,
/// `OutputDeliveryPolicy`, `OnboardingPolicy`): the framework call collapses to a
/// value, the decision is a pure function over it, and the observed object owns
/// only the wiring.

// MARK: - What the system reports

/// The two things the row's text depends on, read together.
///
/// Permission is in here because it is the difference between two states that
/// look identical from AVFoundation's side — no device, and no permission to see
/// one — and rendering them the same way would send a user hunting for a
/// hardware fault they do not have.
struct InputDeviceSnapshot: Equatable {
    /// `AVCaptureDevice.default(for: .audio)?.localizedName`, i.e. the name the
    /// system uses for the current default input, in the user's language.
    var localizedName: String?
    var permission: PermissionStatus

    /// The live reading. The only thing here that touches AVFoundation, and the
    /// only thing not covered by `InputDeviceNameTests` — its answer depends on
    /// what is plugged into the machine and on that machine's TCC state, so
    /// there is nothing a test could assert about it that would still be true
    /// somewhere else.
    static func system() -> InputDeviceSnapshot {
        InputDeviceSnapshot(
            localizedName: AVCaptureDevice.default(for: .audio)?.localizedName,
            permission: .microphone
        )
    }
}

extension PermissionStatus {
    /// The microphone's TCC state.
    ///
    /// One implementation for the recorder and for the Settings row: they are
    /// asking the same question, and a row that disagreed with the thing that
    /// actually records would be worse than no row.
    static var microphone: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .granted
        case .notDetermined:
            return .notDetermined
        default:
            return .denied
        }
    }
}

// MARK: - The decision

/// What the 输入设备 row says.
///
/// Three cases rather than a `String?`, because the two empty ones are not the
/// same absence. `device?.localizedName ?? ""` — the obvious implementation —
/// renders both as a blank line, in a row whose whole job is telling the user
/// something.
enum InputDeviceName: Equatable {

    /// The system named a device. That name is the answer, verbatim.
    case named(String)

    /// Nothing to record from: nothing plugged in, or every input disabled in
    /// System Settings.
    case noDevice

    /// We have no microphone access, so we cannot say. Distinct from `.noDevice`
    /// because the fix is a permission rather than a cable.
    case permissionNotGranted

    /// The rule, in one place.
    ///
    /// **A readable name outranks a missing permission.** macOS commonly reports
    /// the default input's name before the app has been granted microphone
    /// access, and when it does, that name is what the user came for — replacing
    /// it with a permission notice the 权限 group is already showing two cards
    /// down would make the row strictly less useful than the blank line it
    /// replaces. Permission is consulted only to explain an *absence*.
    static func resolve(from snapshot: InputDeviceSnapshot) -> InputDeviceName {
        let name = snapshot.localizedName?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !name.isEmpty {
            return .named(name)
        }
        return snapshot.permission == .granted ? .noDevice : .permissionNotGranted
    }

    /// The row's mono line. Never empty in any state — see
    /// `testEveryStateSaysSomething`.
    var displayText: String {
        switch self {
        case .named(let name):
            // Verbatim: this is the string System Settings › 声音 shows, and the
            // row is only useful for diagnosis if the two match exactly.
            return name
        case .noDevice:
            return OpenTypeL10n.text("没有可用的输入设备", english: "No input device available")
        case .permissionNotGranted:
            return OpenTypeL10n.text("未授权，无法读取", english: "Not readable without microphone access")
        }
    }
}

// MARK: - Staying current

/// What the Settings row observes.
///
/// The scenario §K exists for is a *change*, so a value resolved once at launch
/// would be worse than none: it would go on naming the AirPods that left,
/// actively misleading the one user who came looking for this. Hence a
/// re-read on every signal that the answer may have moved, and no stored
/// reasoning — `refresh()` overwrites from the system rather than merging with
/// what it had.
///
/// Three notifications, no timer. Connect and disconnect are the device changes
/// themselves and cover the AirPods case directly. Activation covers the other
/// half: switching the default input in System Settings › 声音 changes no
/// device, so nothing is posted, but the user has to leave our app to do it and
/// come back — and coming back is a signal, whereas polling is a timer that runs
/// forever to catch a change that happens twice a year.
@MainActor
final class InputDeviceMonitor: ObservableObject {

    /// The current default input, as of the last read.
    @Published private(set) var device: InputDeviceName

    private let read: () -> InputDeviceSnapshot
    private var cancellables: Set<AnyCancellable> = []

    init(read: @escaping () -> InputDeviceSnapshot = { .system() }) {
        self.read = read
        device = .resolve(from: read())
        observeDeviceChanges()
    }

    /// Re-read the system.
    func refresh() {
        device = .resolve(from: read())
    }

    private func observeDeviceChanges() {
        for name in [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
            NSApplication.didBecomeActiveNotification
        ] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in
                    // Hopped rather than delivered on the main queue: the two
                    // AVFoundation notifications are posted from AVFoundation's
                    // own thread, and `refresh()` touches a `@Published` the UI
                    // is bound to.
                    Task { @MainActor in self?.refresh() }
                }
                .store(in: &cancellables)
        }
    }
}
