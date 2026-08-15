import ServiceManagement
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §A of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 开机自启.
///
/// The product rule, in the spec's own words: 「**系统状态是唯一事实来源**。开关读
/// `SMAppService.mainApp.status`，不读 UserDefaults——否则用户在系统设置里关掉之后，
/// 我们的开关还显示「开」」. Two consequences shape everything below:
///
/// - **The toggle has no memory of its own.** Whatever the user last clicked is
///   not an input to the decision; the only inputs are what the system reports
///   right now and what the switch is being moved to. UserDefaults records only
///   「用户是否表达过意愿」 so onboarding asks once, and that is a different
///   question from 「现在是不是开着」.
/// - **`.requiresApproval` is its own case and must never be folded into
///   `.disabled`.** On macOS 13+ the user can disable the login item in System
///   Settings, after which `register()` neither throws nor takes effect. A UI
///   that only knows "on/off" would either show a switch that is on while the
///   app never launches, or an off switch that turns itself back off every time
///   it is clicked. Distinguishing the case is what lets the UI say 「已被系统设置
///   拦下」 and offer a jump. `testRequiresApprovalIsNeitherEnabledNorDisabled`
///   is the one this whole seam exists for.
///
/// `SMAppService` itself is not unit-testable — it registers a real login item
/// with a real launchd, and its `status` depends on where the bundle lives and
/// on System Settings. So — the established pattern in this repo
/// (`OutputDeliveryPolicy`, `OnboardingPolicy`, `CorrectionWindow`,
/// `DispatchConfirmation`, `SidecarSupervisor`) — the decision is factored into
/// pure, screen-free, framework-free functions and tested there, with the one
/// piece that genuinely has to talk to `SMAppService` hidden behind
/// `LoginItemRegistering` and faked. Nothing here touches AppKit, launchd or the
/// clock; section C is `@MainActor` only because the object it drives is the one
/// a SwiftUI view observes.
///
/// **Pinned decision — the shape of `desiredAction(current:desired:)`.** The
/// spec names the function but not its argument types. `current` is the `Bool`
/// the registrar reports (`LoginItemRegistering.isRegistered`, itself defined as
/// `status == .enabled`), not a `LaunchAtLoginStatus`: "should I call register or
/// unregister" is a question about registration, and it has exactly one answer
/// per (is, wants) pair. The richer status is what the *UI* renders —
/// `resolveStatus` is the seam for that — and keeping the two apart is what
/// stops a display concern (`.requiresApproval`, `.notSupported`) from silently
/// acquiring a side effect.
///
/// **The two pure functions are not the product surface.** Both can be right
/// while the switch is still wrong, because neither says where `current` comes
/// from: an implementation that hands `configuration.launchAtLogin` (a
/// UserDefaults-backed `Bool`) to `desiredAction` satisfies every test in
/// section A and reproduces precisely the bug §A forbids. So the toggle is a
/// third seam — `LaunchAtLoginController`, which owns the registrar and is the
/// only thing Settings calls — and section C drives *it* rather than an
/// equivalent hand-rolled beside it. A test that exercises a copy of the
/// production logic living in the test file cannot notice the production logic
/// being wired up differently.
///
/// These tests are RED until Stage 3 adds `Sources/OpenType/LaunchAtLogin.swift`
/// with `LoginItemRegistering`, `LaunchAtLoginStatus`, `LaunchAtLoginAction`,
/// `LaunchAtLoginPolicy.desiredAction(current:desired:)` /
/// `LaunchAtLoginPolicy.resolveStatus(_:)` and `LaunchAtLoginController`. They
/// currently fail to COMPILE because none of those symbols exist yet — that is
/// the intended red.
final class LaunchAtLoginPolicyTests: XCTestCase {

    // MARK: - A. `desiredAction(current:desired:)`

    func testTurningItOnWhenNotRegisteredRegisters() {
        XCTAssertEqual(
            LaunchAtLoginPolicy.desiredAction(current: false, desired: true),
            LaunchAtLoginAction.register
        )
    }

    func testTurningItOffWhenRegisteredUnregisters() {
        XCTAssertEqual(
            LaunchAtLoginPolicy.desiredAction(current: true, desired: false),
            LaunchAtLoginAction.unregister
        )
    }

    func testAlreadyOnAndStillWantedIsANoOp() {
        // The case the round trip below asserts by call count. It matters
        // beyond tidiness: the toggle is re-read from the system every time the
        // Settings pane appears, so a policy that answered `.register` here
        // would re-register on every visit.
        XCTAssertEqual(
            LaunchAtLoginPolicy.desiredAction(current: true, desired: true),
            LaunchAtLoginAction.none
        )
    }

    func testAlreadyOffAndStillUnwantedIsANoOp() {
        XCTAssertEqual(
            LaunchAtLoginPolicy.desiredAction(current: false, desired: false),
            LaunchAtLoginAction.none
        )
    }

    func testTheActionTableIsExactlyDisagreementBetweenTheTwoBooleans() {
        // Stated as the whole 2x2 rather than four separate cases so a Stage-3
        // implementation cannot satisfy the named tests while getting a corner
        // wrong: the action is `.none` exactly when the system already agrees
        // with the switch, and otherwise moves it in the direction asked for.
        for current in [false, true] {
            for desired in [false, true] {
                let expected: LaunchAtLoginAction
                if current == desired {
                    expected = .none
                } else {
                    expected = desired ? .register : .unregister
                }
                XCTAssertEqual(
                    LaunchAtLoginPolicy.desiredAction(current: current, desired: desired),
                    expected,
                    "current=\(current) desired=\(desired) should give \(expected)"
                )
            }
        }
    }

    // MARK: - B. `resolveStatus(_:)`
    //
    // One assertion per `SMAppService.Status` case that exists on macOS 13
    // (`SMAppService.h` declares exactly four and the enum is imported
    // non-frozen), plus one for a value from outside that set —
    // `testAnUnknownFutureStatusIsNeverReportedAsEnabled`.

    func testEnabledResolvesToEnabled() {
        XCTAssertEqual(
            LaunchAtLoginPolicy.resolveStatus(.enabled),
            LaunchAtLoginStatus.enabled
        )
    }

    func testNotRegisteredResolvesToDisabled() {
        // The ordinary "off" state: nothing registered, nothing wrong.
        XCTAssertEqual(
            LaunchAtLoginPolicy.resolveStatus(.notRegistered),
            LaunchAtLoginStatus.disabled
        )
    }

    func testRequiresApprovalResolvesToRequiresApproval() {
        // The whole reason this seam is an enum and not a Bool.
        XCTAssertEqual(
            LaunchAtLoginPolicy.resolveStatus(.requiresApproval),
            LaunchAtLoginStatus.requiresApproval
        )
    }

    func testNotFoundResolvesToNotSupported() {
        // `.notFound` is what a bundle that launchd cannot register at all
        // reports — a debug build run straight out of `.build/`, an app in a
        // location the system will not accept. It is not "the user turned it
        // off", so it must not read as `.disabled`: there is nothing to toggle
        // and the UI should say so instead of offering a switch that will
        // never take.
        XCTAssertEqual(
            LaunchAtLoginPolicy.resolveStatus(.notFound),
            LaunchAtLoginStatus.notSupported
        )
    }

    func testRequiresApprovalIsNeitherEnabledNorDisabled() {
        // The case the spec singles out, asserted as the two things it must not
        // collapse into rather than only as the thing it is — because both
        // wrong answers are individually plausible implementations. Reporting
        // it as `.enabled` gives the user a switch that is on while the app
        // does not launch; reporting it as `.disabled` gives them a switch they
        // can click forever with no effect and no explanation.
        let approval = LaunchAtLoginPolicy.resolveStatus(.requiresApproval)

        XCTAssertNotEqual(approval, LaunchAtLoginStatus.enabled)
        XCTAssertNotEqual(approval, LaunchAtLoginStatus.disabled)
        XCTAssertNotEqual(approval, LaunchAtLoginPolicy.resolveStatus(.enabled))
        XCTAssertNotEqual(approval, LaunchAtLoginPolicy.resolveStatus(.notRegistered))
    }

    func testEveryStatusMapsToADistinctState() {
        // No two system states may share a resolved state. Asserted as an
        // injectivity property so that any future fold — not just the
        // `.requiresApproval` one named above — shows up here.
        let cases: [(SMAppService.Status, String)] = [
            (.enabled, ".enabled"),
            (.notRegistered, ".notRegistered"),
            (.requiresApproval, ".requiresApproval"),
            (.notFound, ".notFound")
        ]

        for (outerIndex, outer) in cases.enumerated() {
            for inner in cases[(outerIndex + 1)...] {
                XCTAssertNotEqual(
                    LaunchAtLoginPolicy.resolveStatus(outer.0),
                    LaunchAtLoginPolicy.resolveStatus(inner.0),
                    "\(outer.1) and \(inner.1) are different situations and must not resolve alike"
                )
            }
        }
    }

    func testAnUnknownFutureStatusIsNeverReportedAsEnabled() {
        // `SMAppService.Status` is a non-frozen imported enum: a switch over
        // only the four known cases compiles (with a warning) and then *traps*
        // when handed a value from a later SDK. So `resolveStatus` must carry an
        // `@unknown default`, and the one thing that arm may never answer is
        // `.enabled` — a state we cannot interpret must not be rendered as a
        // switch that is on. `.notSupported` is the intended landing place.
        //
        // `init(rawValue:)` on an imported C enum accepts values outside the
        // declared set, which is what makes this reachable from a test at all.
        guard let future = SMAppService.Status(rawValue: 9_999) else {
            XCTFail("expected an out-of-range SMAppService.Status to be constructible")
            return
        }

        XCTAssertNotEqual(
            LaunchAtLoginPolicy.resolveStatus(future),
            LaunchAtLoginStatus.enabled,
            "an unrecognised system status must never read as 「开」"
        )
    }
}

// MARK: - C. The toggle itself, through a fake registrar

/// An in-memory `LoginItemRegistering` that records what it was asked to do.
///
/// It records the call *before* deciding whether to throw, so a failed attempt
/// is still visible as an attempt — the difference between "register was never
/// called" and "register was called and blew up" is exactly what
/// `testAFailingRegisterLeavesTheObservedStateUnchanged` turns on.
///
/// `status` is the stored fact and `isRegistered` is read off it, mirroring the
/// production `SMAppServiceLoginItem`: there is one thing the system reports,
/// and "is it registered" is a reading of that rather than a second fact that
/// could disagree with it. Tests assign to `status` directly to stand in for the
/// user changing the switch in System Settings › General › Login Items while the
/// app is running.
private final class FakeLoginItem: LoginItemRegistering {

    enum Call: Equatable {
        case register
        case unregister
    }

    /// Both the counts and the order the assertions below need.
    private(set) var calls: [Call] = []

    /// What the system reports right now — the only state anything downstream
    /// is allowed to consult.
    var status: LaunchAtLoginStatus

    /// What `status` becomes after a `register()` that does not throw. Defaults
    /// to `.enabled`; a test sets it to `.requiresApproval` to reproduce the
    /// macOS 13 case where launchd accepts the call and the login item still
    /// never runs, because System Settings has it blocked.
    var statusAfterRegister: LaunchAtLoginStatus = .enabled

    /// Set to make the next `register()`/`unregister()` fail the way
    /// `SMAppService.register()` does when launchd refuses.
    var registerError: Error?
    var unregisterError: Error?

    init(isRegistered: Bool = false) {
        status = isRegistered ? .enabled : .disabled
    }

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    /// Stands in for `SMAppService.mainApp.status == .enabled`.
    var isRegistered: Bool { status == .enabled }

    var registerCallCount: Int { calls.filter { $0 == .register }.count }
    var unregisterCallCount: Int { calls.filter { $0 == .unregister }.count }

    func register() throws {
        calls.append(.register)
        if let registerError { throw registerError }
        status = statusAfterRegister
    }

    func unregister() throws {
        calls.append(.unregister)
        if let unregisterError { throw unregisterError }
        status = .disabled
    }
}

private struct LoginItemFailure: Error, Equatable {
    let message: String
}

/// `@MainActor` because `LaunchAtLoginController` is what the Settings switch
/// observes, so it lives on the main actor the same way `AppConfiguration`
/// does — the same reason `OverlayHideBehaviorTests` and
/// `ReviewPanelSessionTests` are annotated.
@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {

    // MARK: - The switch position comes from the system, never from us

    func testInitialStatusIsReadFromTheRegistrar() {
        XCTAssertEqual(
            LaunchAtLoginController(item: FakeLoginItem(isRegistered: true)).status,
            LaunchAtLoginStatus.enabled
        )
        XCTAssertEqual(
            LaunchAtLoginController(item: FakeLoginItem(isRegistered: false)).status,
            LaunchAtLoginStatus.disabled
        )
    }

    func testStatusFollowsTheSystemAfterTheUserTurnsItOffElsewhere() throws {
        // 「系统状态是唯一事实来源」, stated as the failure it exists to prevent:
        // the user switches the login item off in System Settings and our
        // switch must stop saying 「开」. An implementation that remembers what
        // it last wrote — to UserDefaults, or to a stored property it never
        // re-reads — passes every other test in this file and fails this one.
        let item = FakeLoginItem(isRegistered: false)
        let controller = LaunchAtLoginController(item: item)
        try controller.apply(desired: true)
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.enabled)

        item.status = .disabled

        controller.refresh()

        XCTAssertEqual(
            controller.status,
            LaunchAtLoginStatus.disabled,
            "the system was changed behind our back; refresh must report the system, not our last write"
        )
    }

    func testApplyDecidesAgainstTheSystemNotAgainstItsOwnLastValue() throws {
        // The same rule on the write side. The user enabled the login item in
        // System Settings while our window was closed, then moves our switch to
        // on: the system already agrees, so nothing may be called. A controller
        // that compared `desired` against a remembered `false` would register a
        // second time here.
        let item = FakeLoginItem(isRegistered: false)
        let controller = LaunchAtLoginController(item: item)

        item.status = .enabled

        let action = try controller.apply(desired: true)

        XCTAssertEqual(action, LaunchAtLoginAction.none)
        XCTAssertEqual(item.calls, [])
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.enabled)
    }

    func testRegisteringWhileSystemSettingsBlocksItNeverReportsEnabled() throws {
        // macOS 13+: the user disabled our login item in System Settings, so
        // `register()` neither throws nor takes effect. Showing `.enabled` here
        // is exactly the 「打开着但不起作用的开关」 §A refuses to ship — and it
        // is why `.requiresApproval` has to survive all the way to the UI
        // instead of being flattened into a `Bool` at this boundary.
        let item = FakeLoginItem(status: .requiresApproval)
        item.statusAfterRegister = .requiresApproval
        let controller = LaunchAtLoginController(item: item)

        try controller.apply(desired: true)

        XCTAssertEqual(item.calls, [.register])
        XCTAssertEqual(
            controller.status,
            LaunchAtLoginStatus.requiresApproval,
            "a register() that was accepted but did not take must not read as 「开」"
        )
    }

    // MARK: - The ordinary round trip

    func testTogglingOnRegistersExactlyOnce() throws {
        let item = FakeLoginItem(isRegistered: false)
        let controller = LaunchAtLoginController(item: item)

        try controller.apply(desired: true)

        XCTAssertEqual(item.calls, [.register])
        XCTAssertTrue(item.isRegistered)
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.enabled)
    }

    func testTogglingOffUnregistersExactlyOnce() throws {
        let item = FakeLoginItem(isRegistered: true)
        let controller = LaunchAtLoginController(item: item)

        try controller.apply(desired: false)

        XCTAssertEqual(item.calls, [.unregister])
        XCTAssertFalse(item.isRegistered)
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.disabled)
    }

    func testTogglingOnWhenAlreadyRegisteredTouchesNothing() throws {
        // The redundant-call case, asserted by count. `SMAppService.register()`
        // on an already-registered main app is not free and not obviously
        // idempotent in the presence of `.requiresApproval`, and the Settings
        // pane re-reads the system state every time it appears — so "the system
        // already agrees" has to mean "do not call", not "call and hope".
        let item = FakeLoginItem(isRegistered: true)
        let controller = LaunchAtLoginController(item: item)

        let action = try controller.apply(desired: true)

        XCTAssertEqual(action, LaunchAtLoginAction.none)
        XCTAssertEqual(item.calls, [])
        XCTAssertEqual(item.registerCallCount, 0)
        XCTAssertTrue(item.isRegistered)
    }

    func testTogglingOffWhenAlreadyUnregisteredTouchesNothing() throws {
        let item = FakeLoginItem(isRegistered: false)
        let controller = LaunchAtLoginController(item: item)

        let action = try controller.apply(desired: false)

        XCTAssertEqual(action, LaunchAtLoginAction.none)
        XCTAssertEqual(item.calls, [])
        XCTAssertEqual(item.unregisterCallCount, 0)
        XCTAssertFalse(item.isRegistered)
    }

    func testAFullOnOffOnCycleIssuesThreeCallsInOrderAndNothingElse() throws {
        // The round trip as a sequence rather than as three independent facts,
        // including a redundant press at each end: only the transitions may
        // reach the registrar. One controller across all six presses, so a
        // state it kept between them would show up here.
        let item = FakeLoginItem(isRegistered: false)
        let controller = LaunchAtLoginController(item: item)

        try controller.apply(desired: false)   // already off — no-op
        try controller.apply(desired: true)    // on
        try controller.apply(desired: true)    // already on — no-op
        try controller.apply(desired: false)   // off
        try controller.apply(desired: false)   // already off — no-op
        try controller.apply(desired: true)    // on again

        XCTAssertEqual(item.calls, [.register, .unregister, .register])
        XCTAssertEqual(item.registerCallCount, 2)
        XCTAssertEqual(item.unregisterCallCount, 1)
        XCTAssertTrue(item.isRegistered)
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.enabled)
    }

    // MARK: - Failure

    func testAFailingRegisterLeavesTheObservedStateUnchangedAndSurfacesTheError() throws {
        // A thrown `register()` must not be swallowed into a switch that reads
        // "on". Three things are asserted together because a fix that gets one
        // of them without the others is still broken: the error reaches the
        // caller, the observed state still says off, and — the consequence that
        // makes the first two matter — the next press is a real retry rather
        // than a no-op. That last one is the 「系统状态是唯一事实来源」 rule
        // doing its job: because the controller re-reads the registrar instead
        // of a remembered intent, a failed attempt leaves the toggle usable
        // instead of stuck on and doing nothing.
        let item = FakeLoginItem(isRegistered: false)
        item.registerError = LoginItemFailure(message: "launchd refused")
        let controller = LaunchAtLoginController(item: item)

        XCTAssertThrowsError(try controller.apply(desired: true)) { error in
            XCTAssertEqual(
                error as? LoginItemFailure,
                LoginItemFailure(message: "launchd refused"),
                "the registrar's own error must reach the caller, not be replaced or dropped"
            )
        }

        XCTAssertFalse(item.isRegistered)
        XCTAssertEqual(item.calls, [.register], "the attempt must have been made exactly once")
        XCTAssertEqual(
            controller.status,
            LaunchAtLoginStatus.disabled,
            "a register() that threw must not leave the switch reading 「开」"
        )

        item.registerError = nil
        try controller.apply(desired: true)

        XCTAssertEqual(item.calls, [.register, .register], "the next press must be a real retry")
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.enabled)
    }

    func testAFailingUnregisterLeavesTheObservedStateUnchangedAndSurfacesTheError() throws {
        let item = FakeLoginItem(isRegistered: true)
        item.unregisterError = LoginItemFailure(message: "launchd refused")
        let controller = LaunchAtLoginController(item: item)

        XCTAssertThrowsError(try controller.apply(desired: false)) { error in
            XCTAssertEqual(
                error as? LoginItemFailure,
                LoginItemFailure(message: "launchd refused")
            )
        }

        XCTAssertTrue(item.isRegistered)
        XCTAssertEqual(item.calls, [.unregister])
        XCTAssertEqual(
            controller.status,
            LaunchAtLoginStatus.enabled,
            "an unregister() that threw must not leave the switch reading 「关」"
        )

        item.unregisterError = nil
        try controller.apply(desired: false)

        XCTAssertEqual(item.calls, [.unregister, .unregister], "the next press must be a real retry")
        XCTAssertEqual(controller.status, LaunchAtLoginStatus.disabled)
    }
}
