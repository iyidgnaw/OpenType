import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §K of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 麦克风设备可见.
///
/// The product problem, from `docs/reviews/2026-08-15-product-review.md` §9: a
/// user finishes a meeting on AirPods, takes them out, the system default input
/// silently moves to the built-in microphone, and the next dictation is
/// noticeably worse. Nothing in the app says which microphone it is recording
/// from, so the only conclusion available to them is 「这产品变差了」.
///
/// The fix is a single read-only line in Settings, and the spec is explicit that
/// it is **只显示，不做选择器**: choosing an input is what System Settings is
/// for, and a second source of truth for the active device would be a bug
/// factory. So there is nothing here about selecting a device — only about what
/// that one line says.
///
/// **What is testable is the resolution, not AVFoundation.** `AVCaptureDevice`
/// answers differently depending on what is plugged into the machine running the
/// tests and on the TCC state of the test host, so — the established pattern in
/// this repo (`OutputDeliveryPolicy`, `OnboardingPolicy`, `LaunchAtLoginPolicy`,
/// `SidecarSupervisor`) — the framework call is reduced to a value
/// (`InputDeviceSnapshot`), the decision is a pure function over that value, and
/// only the decision is tested. `InputDeviceSnapshot.system()` — the four lines
/// that actually touch AVFoundation — is deliberately not exercised here.
///
/// **The three states, and why the last two are the point.** A naive
/// implementation is `device?.localizedName ?? ""`, which renders both failure
/// states as a blank line — a settings row that shows nothing at all, in a
/// feature whose entire purpose is telling the user something. So:
///
/// - a device with a name shows the name,
/// - no device at all (nothing plugged in, everything disabled) says so,
/// - and no microphone permission says *that*, because it is a different
///   situation with a different fix and 「没有输入设备」 would be a lie.
///
/// **Pinned decision — a readable name outranks a missing permission.** The two
/// inputs are not a priority list. macOS often reports the default input's
/// `localizedName` before the app has been granted microphone access, and when
/// it does, that name is the answer: it is what the user came for, and burying
/// it under a permission notice would make the row strictly less useful than the
/// blank line it replaces. Permission is consulted only to *explain an absence*.
/// `testAReadableNameSurvivesAMissingPermission` is the test that seam exists
/// for.
///
/// **Pinned decision — assert the resolved case, not the Chinese.** Section A
/// compares `InputDeviceName` values rather than display strings, because §F of
/// the same batch makes `OpenTypeL10n.text` follow the system locale and every
/// assertion against a literal 中文 string would then depend on the locale the
/// test host happens to run in. The strings themselves are pinned by property
/// instead (`testEveryStateSaysSomething`,
/// `testTheThreeStatesDoNotReadAlike`) plus the one string that is not a
/// translation at all: a device's own name, which must reach the row verbatim.
///
/// These tests are RED until Stage 3 adds `Sources/OpenType/InputDevice.swift`
/// with `InputDeviceSnapshot`, `InputDeviceName.resolve(from:)`,
/// `InputDeviceName.displayText` and `InputDeviceMonitor`. They currently fail
/// to COMPILE because none of those symbols exist — that is the intended red.
final class InputDeviceNameTests: XCTestCase {

    // MARK: - A. A device with a name

    func testANamedDeviceResolvesToThatName() {
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "MacBook Pro 麦克风", permission: .granted)
            ),
            InputDeviceName.named("MacBook Pro 麦克风")
        )
    }

    func testTheDeviceNameReachesTheRowVerbatim() {
        // The one display string that is not a translation: whatever the system
        // calls the device is what the user sees in System Settings › 声音, and
        // the row is only useful for diagnosis if the two match character for
        // character. No prefix, no 「当前：」, no truncation of our own.
        let name = "AirPods Pro"

        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: name, permission: .granted)
            ).displayText,
            name
        )
    }

    func testSurroundingWhitespaceIsTrimmedFromTheName() {
        // Not cosmetic: the trim is what makes 「a name we cannot use」 and
        // 「no name at all」 one case below rather than two, so a device that
        // reports `"  "` cannot slip through as a `.named` row that draws
        // blank.
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "  Studio Display 麦克风\n", permission: .granted)
            ),
            InputDeviceName.named("Studio Display 麦克风")
        )
    }

    // MARK: - B. No device at all

    func testNoDeviceWithPermissionGrantedSaysThereIsNoDevice() {
        // Nothing plugged in, or every input disabled in System Settings. We
        // have permission, so the absence is the machine's, not ours, and the
        // row has to say the true thing rather than nothing.
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: nil, permission: .granted)
            ),
            InputDeviceName.noDevice
        )
    }

    func testABlankNameWithPermissionGrantedIsTreatedAsNoDevice() {
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "   ", permission: .granted)
            ),
            InputDeviceName.noDevice
        )
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "", permission: .granted)
            ),
            InputDeviceName.noDevice
        )
    }

    // MARK: - C. No permission

    func testNothingReadableAndNoPermissionBlamesThePermission() {
        // `.denied` — the user said no, or an MDM profile did. AVFoundation
        // hands back nothing useful, and 「没有可用的输入设备」 here would be a
        // lie about the machine that sends the user looking for a hardware
        // fault. The cause is ours and the fix is a permission, so that is what
        // the row says.
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: nil, permission: .denied)
            ),
            InputDeviceName.permissionNotGranted
        )
    }

    func testNotDeterminedIsTreatedTheSameAsDenied() {
        // 「还没问过」 and 「问过被拒」 differ in what the *permissions* group
        // offers (授权 vs 打开设置) and not at all in what this row can read.
        // One message for both; the group two cards down owns the button.
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: nil, permission: .notDetermined)
            ),
            InputDeviceName.permissionNotGranted
        )
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "  ", permission: .notDetermined)
            ),
            InputDeviceName.permissionNotGranted
        )
    }

    func testAReadableNameSurvivesAMissingPermission() {
        // The pinned decision above, as the mistake it forbids. macOS commonly
        // reports the default input's name before microphone access has been
        // granted; an implementation that checks permission first would replace
        // a perfectly good answer with a notice the permissions group is
        // already showing right below.
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "AirPods Pro", permission: .denied)
            ),
            InputDeviceName.named("AirPods Pro")
        )
        XCTAssertEqual(
            InputDeviceName.resolve(
                from: InputDeviceSnapshot(localizedName: "AirPods Pro", permission: .notDetermined)
            ),
            InputDeviceName.named("AirPods Pro")
        )
    }

    // MARK: - D. Whatever the state, the row is never blank

    func testEveryStateSaysSomething() {
        // The failure mode this whole item exists to prevent, asserted directly:
        // a settings row that renders as an empty line teaches the user nothing
        // and looks like a bug. Every state owes them a sentence.
        let states: [(InputDeviceName, String)] = [
            (.named("MacBook Pro 麦克风"), ".named"),
            (.noDevice, ".noDevice"),
            (.permissionNotGranted, ".permissionNotGranted")
        ]

        for (state, label) in states {
            XCTAssertFalse(
                state.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(label) must render as something the user can read, not a blank row"
            )
        }
    }

    func testTheThreeStatesDoNotReadAlike() {
        // 「没有设备」 and 「没有权限」 have different fixes — buy a microphone
        // versus grant an app — so a row that renders them identically has
        // spent a line and answered nothing.
        let texts = [
            InputDeviceName.named("MacBook Pro 麦克风").displayText,
            InputDeviceName.noDevice.displayText,
            InputDeviceName.permissionNotGranted.displayText
        ]

        XCTAssertEqual(Set(texts).count, texts.count, "each state needs its own wording")
    }

    // MARK: - E. Staying current
    //
    // The scenario in the review is a *change*: the AirPods leave and the
    // default input moves. A row resolved once at launch would go on naming the
    // AirPods forever, which is worse than showing nothing — it would actively
    // mislead the user diagnosing exactly this. The notifications that trigger
    // the re-read are AVFoundation's and are not testable here; what is testable
    // is that the monitor re-reads the system instead of caching its first
    // answer, which is the half an implementation can get wrong on its own.

    @MainActor
    func testTheMonitorPublishesWhatTheSystemReportsAtInit() {
        let monitor = InputDeviceMonitor(
            read: { InputDeviceSnapshot(localizedName: "AirPods Pro", permission: .granted) }
        )

        XCTAssertEqual(monitor.device, InputDeviceName.named("AirPods Pro"))
    }

    @MainActor
    func testRefreshReadsTheSystemAgainRatherThanRepeatingItsFirstAnswer() {
        var current = InputDeviceSnapshot(localizedName: "AirPods Pro", permission: .granted)
        let monitor = InputDeviceMonitor(read: { current })
        XCTAssertEqual(monitor.device, InputDeviceName.named("AirPods Pro"))

        // The AirPods go back in their case.
        current = InputDeviceSnapshot(localizedName: "MacBook Pro 麦克风", permission: .granted)
        monitor.refresh()

        XCTAssertEqual(
            monitor.device,
            InputDeviceName.named("MacBook Pro 麦克风"),
            "the row must follow the system default, not the device that was there at launch"
        )
    }

    @MainActor
    func testTheMonitorFollowsTheSystemAllTheWayToNoDevice() {
        // The same rule at the edge: unplugging the last input is a change like
        // any other, and an implementation that only ever overwrites a non-empty
        // name would keep the old one on screen here.
        var current = InputDeviceSnapshot(localizedName: "USB Audio CODEC", permission: .granted)
        let monitor = InputDeviceMonitor(read: { current })

        current = InputDeviceSnapshot(localizedName: nil, permission: .granted)
        monitor.refresh()

        XCTAssertEqual(monitor.device, InputDeviceName.noDevice)
    }
}
