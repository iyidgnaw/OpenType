import Foundation
import ServiceManagement

/// 开机自启 (§A of `docs/superpowers/specs/2026-08-15-product-batch-plan.md`).
///
/// A hold-to-talk menubar tool the user has to remember to launch after every
/// reboot loses a slice of its users at every reboot
/// (`docs/reviews/2026-08-15-product-review.md` §5). `SMAppService.mainApp`
/// registers the app itself, not a helper bundle: `LSUIElement` is already
/// true, so there is nothing to flash in the Dock at login and nothing extra
/// to ship or sign.
///
/// **系统状态是唯一事实来源.** The registration is the state; we keep no copy
/// of it. The user can turn our login item off in System Settings › General ›
/// 登录项 at any moment, and a switch backed by UserDefaults would go on
/// reading 「开」 forever afterwards — the precise bug §A forbids. So the
/// controller below re-reads the registrar on every question it is asked, and
/// `AppConfiguration.launchAtLogin` records only what the user last *chose*,
/// which is a different question and never reaches the switch.
///
/// The split into three types is the one the rest of this repo uses for
/// anything that has to touch a framework it cannot instantiate in a test
/// (`OutputDeliveryPolicy`, `OnboardingPolicy`, `CorrectionWindow`,
/// `SidecarSupervisor`): the decision is a pure function, the framework call is
/// a protocol with one production conformer, and the object the UI observes
/// owns nothing but the wiring between them.

// MARK: - What the system reports

/// The four situations a login item can be in, as the UI has to distinguish
/// them.
///
/// `.requiresApproval` is a case of its own and must never be folded into
/// `.disabled`. On macOS 13+ the user can disable our login item in System
/// Settings, after which `register()` neither throws nor takes effect — so a
/// two-state switch would either sit on while the app never launches, or sit
/// off and turn itself back off every time it is pressed. Neither can be
/// explained to the user; the separate case is what lets the row say 「已被系统
/// 设置拦下」 and offer the jump.
///
/// `.notSupported` is `.notFound`: a bundle launchd will not register at all —
/// a debug build run straight out of `.build/`, an app somewhere the system
/// declines. It is not 「用户关掉了」, so it gets prose instead of a switch that
/// could never take.
enum LaunchAtLoginStatus {
    case enabled
    case disabled
    case requiresApproval
    case notSupported
}

/// What moving the switch to a given position implies for the registrar.
///
/// `.none` is a real answer, not an absence of one: the Settings pane re-reads
/// the system every time it appears, and `SMAppService.register()` on an
/// already-registered main app is neither free nor obviously idempotent in the
/// presence of `.requiresApproval`.
enum LaunchAtLoginAction {
    case register
    case unregister
    case none
}

/// The one thing that genuinely has to talk to `SMAppService`.
///
/// `status` is the stored fact and `isRegistered` is a reading of it, not a
/// second fact that could disagree — hence the default implementation below,
/// which is the definition rather than a convenience.
///
/// Not `@MainActor`: none of `SMAppService`'s three calls needs the main actor,
/// and isolating the protocol would force the isolation onto every future
/// conformer including the tests' in-memory one.
protocol LoginItemRegistering {
    var status: LaunchAtLoginStatus { get }
    var isRegistered: Bool { get }
    func register() throws
    func unregister() throws
}

extension LoginItemRegistering {
    var isRegistered: Bool { status == .enabled }
}

// MARK: - The decisions

/// The two pure functions the toggle is built out of.
enum LaunchAtLoginPolicy {

    /// Whether moving the switch to `desired` means calling the registrar, and
    /// in which direction.
    ///
    /// `current` is the `Bool` the registrar reports right now, never a
    /// remembered one — "should I register or unregister" is a question about
    /// registration and has exactly one answer per (is, wants) pair. The richer
    /// `LaunchAtLoginStatus` is what the *UI* renders; keeping the two apart is
    /// what stops a display concern (`.requiresApproval`, `.notSupported`) from
    /// quietly acquiring a side effect.
    static func desiredAction(current: Bool, desired: Bool) -> LaunchAtLoginAction {
        guard current != desired else { return .none }
        return desired ? .register : .unregister
    }

    /// `SMAppService.Status` as this app distinguishes it.
    ///
    /// The `@unknown default` is load-bearing twice over. `SMAppService.Status`
    /// is a non-frozen imported enum, so a switch over only today's four cases
    /// compiles and then traps on a value from a later SDK; and the one answer
    /// that arm may never give is `.enabled` — a state we cannot interpret must
    /// not be drawn as a switch that is on.
    static func resolveStatus(_ status: SMAppService.Status) -> LaunchAtLoginStatus {
        switch status {
        case .enabled:
            return .enabled
        case .notRegistered:
            return .disabled
        case .requiresApproval:
            return .requiresApproval
        case .notFound:
            return .notSupported
        @unknown default:
            return .notSupported
        }
    }
}

// MARK: - The production registrar

/// `SMAppService.mainApp`, behind the protocol.
///
/// Deliberately thin: everything here is one call through, so there is nothing
/// in it that could be right in a test and wrong in the app. The mapping it
/// does own — `SMAppService.Status` → `LaunchAtLoginStatus` — is
/// `LaunchAtLoginPolicy.resolveStatus`'s, not its own.
struct SMAppServiceLoginItem: LoginItemRegistering {
    private let service: SMAppService

    init(service: SMAppService = .mainApp) {
        self.service = service
    }

    var status: LaunchAtLoginStatus {
        LaunchAtLoginPolicy.resolveStatus(service.status)
    }

    func register() throws {
        try service.register()
    }

    func unregister() throws {
        try service.unregister()
    }
}

// MARK: - The toggle

/// What the Settings row observes and the only thing it calls.
///
/// Both pure functions above can be correct while the switch is still wrong,
/// because neither says where `current` comes from: handing them
/// `configuration.launchAtLogin` would satisfy every one of their tests and
/// reproduce exactly the bug §A forbids. This is where that is decided, and it
/// decides it one way — every query goes to the registrar.
///
/// `status` is stored rather than computed only so SwiftUI has something to
/// observe. It is never *reasoned* from: `apply(desired:)` asks the registrar
/// afresh, `refresh()` overwrites it from the registrar, and the Settings pane
/// calls `refresh()` each time it appears, so a change made in System Settings
/// while our window was closed is picked up the moment the row is on screen
/// again.
@MainActor
final class LaunchAtLoginController: ObservableObject {

    /// What the system says right now, as of the last read.
    @Published private(set) var status: LaunchAtLoginStatus

    private let item: LoginItemRegistering

    init(item: LoginItemRegistering) {
        self.item = item
        status = item.status
    }

    /// The switch's position. `.requiresApproval` is deliberately not 「开」.
    var isEnabled: Bool { status == .enabled }

    /// Re-read the system.
    func refresh() {
        status = item.status
    }

    /// Move the registration to `desired`, if it is not already there.
    ///
    /// Throws whatever the registrar threw, unchanged: a `register()` that
    /// launchd refused has to reach the caller, or the row goes on saying
    /// nothing while claiming it is on. The state is re-read either way — after
    /// a failure the switch reads 「关」 and the next press is a real retry
    /// rather than a no-op, which is what re-reading (instead of remembering an
    /// intent) buys.
    @discardableResult
    func apply(desired: Bool) throws -> LaunchAtLoginAction {
        let action = LaunchAtLoginPolicy.desiredAction(
            current: item.isRegistered,
            desired: desired
        )
        defer { refresh() }

        switch action {
        case .register:
            try item.register()
        case .unregister:
            try item.unregister()
        case .none:
            break
        }
        return action
    }
}
