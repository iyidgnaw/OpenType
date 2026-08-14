import Carbon
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for "mode switching is broken".
///
/// The chord's contract is "hold the recording modifier, then tap Shift or
/// Tab". Three defects make it dead in practice:
///
///  1. `AppModel.cycleMode()` opens with
///     `guard state != .listening, !isBusy, !isStartingRecording else { return }`.
///     For the default `.leftOption` preset, holding left Option is *what
///     starts a recording* (`optionLongPressThreshold = 0.30`), so by the time
///     the user taps Tab the state is already `.listening` and the call
///     returns immediately. The only window in which it works is the <300ms
///     before the long-press threshold fires — unhittable.
///  2. The Tab gate is hardcoded to left Option
///     (`GlobalHotKey.handleEventTap`: `heldModeSwitchKeyCodes.contains(Int64(kVK_Option))`),
///     as is the Shift chord (`handleModeSwitchFlagsChanged`). A user on the
///     `fn` or double-tap presets would have to hold left Option — which is
///     not their recording key — so the chord is dead for them entirely.
///  3. The UI hint (`MenuBarPopoverView.swift`) promises "按住时点 Shift 或
///     Tab 切换模式" for every preset, including the Space-chord presets that
///     have no modifier-only event tap and therefore no Tab handling at all.
///  4. `handleModeSwitchTabKeyDown` calls `cancelPendingLongPresses()` and sets
///     `modifierChordWasUsed = true`, both of which abort the hold-to-talk long
///     press. So the gesture is not merely dead — it is *nondeterministic*: tap
///     Tab within 300ms and the mode switches and no recording starts; tap it
///     later and defect 1 rejects the switch while the recording proceeds. Same
///     gesture, two outcomes, decided by reaction time. (`USER_GUIDE.md:74-82`
///     documents this as the intended contract; it needs updating too.)
///
/// The refined rule makes the gesture uniform by letting the hold length — not
/// reaction time — decide: **Tab cycles the mode and cancels nothing.** Release
/// before the 300ms threshold and hold-to-talk simply never armed (mode
/// switched, no recording); keep holding and speak and the recording proceeds,
/// processed as the *new* mode.
///
/// The owner-approved fix: **Tab only** (the Shift chord is removed), gated on
/// the user's *configured* recording modifier, permitted during `.listening`,
/// and — critically — **retargeting the in-flight recording** rather than only
/// the next-recording default. Retargeting mid-flight is an established
/// capability, not a new concept: `VoiceModeRouter` already reassigns
/// `activeMode` after transcription (`AppModel.swift:2290`).
///
/// `AppModel` is not instantiable in tests (its `init` has side effects), so —
/// following this repo's established pattern (`OutputDeliveryPolicy`,
/// `OnboardingPolicy`, `CorrectionWindow`, `OverlayHideBehavior`,
/// `GlobalHotKey.keyAction`) — these tests pin pure seams:
///
/// ```swift
/// enum ModeCyclePolicy {
///     static func allows(
///         state: ProcessingState,
///         isBusy: Bool,
///         isStartingRecording: Bool
///     ) -> Bool
///
///     static func cycle(
///         selectedMode: InputMode,
///         activeMode: InputMode?,
///         state: ProcessingState
///     ) -> ModeCycleOutcome
/// }
///
/// struct ModeCycleOutcome: Equatable {
///     let selectedMode: InputMode
///     let activeMode: InputMode?
/// }
///
/// extension GlobalHotKey {
///     static func shouldCycleModeOnTab(
///         heldModifierKeyCodes: Set<Int64>,
///         preset: HotKeyPreset?
///     ) -> Bool
///
///     static func modeSwitchTabEffects(isAutorepeat: Bool) -> ModeSwitchTabEffects
///
///     static func releaseGesture(
///         longPressDidArm: Bool,
///         modeSwitchDidCycle: Bool,
///         chordWasUsed: Bool
///     ) -> ModifierReleaseGesture
/// }
///
/// struct ModeSwitchTabEffects: Equatable {
///     let cyclesMode: Bool
///     let swallowsKeystroke: Bool
///     let cancelsPendingLongPress: Bool
///     let marksChordUsed: Bool
///     let resetsModifierTapSequence: Bool
///     let suppressesModifierReleaseGesture: Bool
/// }
///
/// enum ModifierReleaseGesture: Equatable {
///     case finishHeldRecording
///     case tap
///     case consumed
/// }
///
/// extension HotKeyPreset {
///     var modeSwitchHint: String? { get }
/// }
/// ```
///
/// They are RED until Stage 3 adds those symbols (and routes `cycleMode()`,
/// `handleEventTap`'s Tab branch, and the popover hint through them). They
/// currently fail to COMPILE because none of the symbols exist — that is the
/// intended red.
final class ModeSwitchChordTests: XCTestCase {

    // MARK: - A. The cycle-permission seam

    /// THE BUG. `.listening` is exactly the state the user is in when they tap
    /// Tab, and today's guard refuses it.
    func testCyclingIsAllowedWhileListening() {
        XCTAssertTrue(
            ModeCyclePolicy.allows(
                state: .listening,
                isBusy: false,
                isStartingRecording: false
            )
        )
    }

    func testCyclingIsAllowedWhenIdle() {
        XCTAssertTrue(
            ModeCyclePolicy.allows(
                state: .idle,
                isBusy: false,
                isStartingRecording: false
            )
        )
    }

    /// The mid-pipeline states: the mode this run is processed as has already
    /// been committed, so cycling must not be able to move it.
    func testCyclingIsRefusedMidPipeline() {
        for state: ProcessingState in [.transcribing, .transforming, .inserting] {
            XCTAssertFalse(
                ModeCyclePolicy.allows(
                    state: state,
                    isBusy: false,
                    isStartingRecording: false
                ),
                "\(state) is mid-pipeline; the mode is already committed"
            )
        }
    }

    func testCyclingIsRefusedWhileBusyRegardlessOfState() {
        for state in Self.representativeStates {
            XCTAssertFalse(
                ModeCyclePolicy.allows(
                    state: state,
                    isBusy: true,
                    isStartingRecording: false
                ),
                "isBusy must refuse cycling in \(state)"
            )
        }
    }

    func testCyclingIsRefusedWhileStartingRecordingRegardlessOfState() {
        for state in Self.representativeStates {
            XCTAssertFalse(
                ModeCyclePolicy.allows(
                    state: state,
                    isBusy: false,
                    isStartingRecording: true
                ),
                "isStartingRecording must refuse cycling in \(state)"
            )
        }
    }

    /// The post-run surface states are not mid-pipeline — nothing is in
    /// flight, so the user may cycle for the next recording.
    func testCyclingIsAllowedInPostRunStates() {
        let states: [ProcessingState] = [
            .modeChanged,
            .success,
            .copied,
            .dispatched("task"),
            .cancelled("stopped"),
            .failure("boom")
        ]
        for state in states {
            XCTAssertTrue(
                ModeCyclePolicy.allows(
                    state: state,
                    isBusy: false,
                    isStartingRecording: false
                ),
                "\(state) has nothing in flight; cycling should be allowed"
            )
        }
    }

    private static let representativeStates: [ProcessingState] = [
        .idle,
        .modeChanged,
        .listening,
        .transcribing,
        .transforming,
        .inserting,
        .success,
        .copied,
        .dispatched("task"),
        .cancelled("stopped"),
        .failure("boom")
    ]

    // MARK: - B. The Tab gate follows the configured recording modifier

    func testTabCyclesWhileTheLeftOptionPresetsModifierIsHeld() {
        XCTAssertTrue(
            GlobalHotKey.shouldCycleModeOnTab(
                heldModifierKeyCodes: [Int64(kVK_Option)],
                preset: .leftOption
            )
        )
    }

    func testTabDoesNotCycleWithNothingHeld() {
        XCTAssertFalse(
            GlobalHotKey.shouldCycleModeOnTab(
                heldModifierKeyCodes: [],
                preset: .leftOption
            )
        )
    }

    /// THE GENERALITY BUG: an `fn` user holds fn, never left Option.
    func testTabCyclesWhileFnIsHeldOnTheFnPreset() {
        XCTAssertTrue(
            GlobalHotKey.shouldCycleModeOnTab(
                heldModifierKeyCodes: [Int64(kVK_Function)],
                preset: .fnKey
            )
        )
    }

    /// The other half of the same bug: left Option is not the fn user's
    /// recording key, so holding it must not arm the chord.
    func testTabDoesNotCycleWhileLeftOptionIsHeldOnTheFnPreset() {
        XCTAssertFalse(
            GlobalHotKey.shouldCycleModeOnTab(
                heldModifierKeyCodes: [Int64(kVK_Option)],
                preset: .fnKey
            )
        )
    }

    func testTabCyclesWhileTheDoubleTapPresetsOwnModifierIsHeld() {
        let cases: [(HotKeyPreset, Int64)] = [
            (.doubleControl, Int64(kVK_Control)),
            (.doubleControl, Int64(kVK_RightControl)),
            (.doubleOption, Int64(kVK_Option)),
            (.doubleOption, Int64(kVK_RightOption)),
            (.doubleShift, Int64(kVK_Shift)),
            (.doubleShift, Int64(kVK_RightShift))
        ]
        for (preset, keyCode) in cases {
            XCTAssertTrue(
                GlobalHotKey.shouldCycleModeOnTab(
                    heldModifierKeyCodes: [keyCode],
                    preset: preset
                ),
                "\(preset) must arm the chord while its own modifier \(keyCode) is held"
            )
        }
    }

    func testTabDoesNotCycleWhileAForeignModifierIsHeldOnADoubleTapPreset() {
        XCTAssertFalse(
            GlobalHotKey.shouldCycleModeOnTab(
                heldModifierKeyCodes: [Int64(kVK_Option)],
                preset: .doubleControl
            )
        )
    }

    /// The Space-chord presets install a Carbon hot key, not the modifier-only
    /// event tap, so no Tab handling exists for them at all — the gate must
    /// never claim otherwise, whatever happens to be held.
    func testTabNeverCyclesForPresetsWithoutTheModifierOnlyTap() {
        let held: Set<Int64> = [
            Int64(kVK_Option),
            Int64(kVK_Control),
            Int64(kVK_Shift),
            Int64(kVK_Function)
        ]
        for preset in HotKeyPreset.allCases where !preset.usesModifierOnlyEventTap {
            XCTAssertFalse(
                GlobalHotKey.shouldCycleModeOnTab(
                    heldModifierKeyCodes: held,
                    preset: preset
                ),
                "\(preset) has no modifier-only event tap; Tab cannot cycle"
            )
        }
    }

    func testTabDoesNotCycleWithoutAnActivePreset() {
        XCTAssertFalse(
            GlobalHotKey.shouldCycleModeOnTab(
                heldModifierKeyCodes: [Int64(kVK_Option)],
                preset: nil
            )
        )
    }

    /// The Shift chord is gone: Shift on its own is just Shift. (`.doubleShift`
    /// is excluded because there Shift *is* the recording modifier, so holding
    /// it legitimately arms the Tab chord — tested above.)
    func testShiftHeldAloneNeverArmsTheChord() {
        let shiftOnly: Set<Int64> = [Int64(kVK_Shift), Int64(kVK_RightShift)]
        for preset in HotKeyPreset.allCases where preset != .doubleShift {
            XCTAssertFalse(
                GlobalHotKey.shouldCycleModeOnTab(
                    heldModifierKeyCodes: shiftOnly,
                    preset: preset
                ),
                "Shift is not \(preset)'s recording modifier; it must not arm the chord"
            )
        }
    }

    // MARK: - E. Tapping Tab cycles the mode and cancels nothing

    /// The whole effect list of one Tab keystroke while the chord is armed.
    ///
    /// `cancelsPendingLongPress` and `marksChordUsed` are BOTH false, and that
    /// is the fix: `cancelPendingLongPresses()` drops the pending token, and
    /// `modifierChordWasUsed = true` trips the `!self.modifierChordWasUsed`
    /// guard inside the long-press closure `handleModifierPressed` schedules —
    /// so either one alone is enough to abort the hold-to-talk arming the user
    /// is still holding for. Dropping only the first would leave the gesture
    /// just as broken.
    ///
    /// Because `modifierChordWasUsed` also does double duty as "don't let the
    /// eventual key-up fire the toggle", removing it needs a REPLACEMENT flag
    /// that suppresses the release gesture without touching the long press —
    /// that is `suppressesModifierReleaseGesture`, whose meaning is pinned by
    /// section F below.
    func testTappingTabCyclesTheModeWithoutCancellingTheRecording() {
        let effects = GlobalHotKey.modeSwitchTabEffects(isAutorepeat: false)
        XCTAssertTrue(effects.cyclesMode)
        XCTAssertFalse(
            effects.cancelsPendingLongPress,
            "tapping Tab changes the mode; it must not abort the hold the user is still in"
        )
        XCTAssertFalse(
            effects.marksChordUsed,
            "modifierChordWasUsed also blocks the pending long press — Tab must not set it"
        )
        XCTAssertTrue(
            effects.suppressesModifierReleaseGesture,
            "the key-up after a cycle must not register as a toggle/double-tap"
        )
        XCTAssertTrue(
            effects.resetsModifierTapSequence,
            "the double-tap sequence must still be cleared — see the next test"
        )
    }

    /// The one thing today's `handleModeSwitchTabKeyDown` does that must
    /// SURVIVE the fix. `resetModifierTapSequence()` clears the
    /// `DoubleTapDetector`'s stored tap; unlike `cancelPendingLongPresses()` it
    /// cannot abort the hold the user is in (the pending long-press closure
    /// never consults the tap detector, and resets the sequence itself when it
    /// fires), so there is no reason to drop it — and a concrete reason to keep
    /// it. On a double-tap preset:
    ///
    ///  1. tap the recording modifier once — `registerModifierTap` stores it;
    ///  2. within the 450ms window, hold it again, tap Tab, release. Section F
    ///     makes that release `.consumed`, so it never reaches
    ///     `registerModifierTap` and never clears the stored tap;
    ///  3. tap the modifier once more, still inside step 1's window
    ///     (`testDoubleTapDetectorTriggersWithinThreshold` pins that a 0.4s gap
    ///     fires): the detector sees a double tap and **starts a recording the
    ///     user never asked for**.
    ///
    /// Resetting at Tab time is what closes that, so the effect list has to
    /// demand it explicitly rather than let it be tidied away alongside the two
    /// flags that genuinely have to go.
    func testTabStillClearsTheDoubleTapSequence() {
        XCTAssertTrue(
            GlobalHotKey.modeSwitchTabEffects(isAutorepeat: false)
                .resetsModifierTapSequence,
            "a stale tap surviving the chord can fire a double-tap on the next tap"
        )
    }

    /// Keep the one thing today's code gets right: Tab is always swallowed, so
    /// a stray tab-navigation never reaches the focused app.
    func testTabIsAlwaysSwallowed() {
        XCTAssertTrue(
            GlobalHotKey.modeSwitchTabEffects(isAutorepeat: false).swallowsKeystroke
        )
        XCTAssertTrue(
            GlobalHotKey.modeSwitchTabEffects(isAutorepeat: true).swallowsKeystroke,
            "held-Tab autorepeats must not leak into the focused app either"
        )
    }

    /// One physical press, one cycle: OS autorepeat must not spin the mode.
    func testAutorepeatChangesOnlyWhetherTheModeCycles() {
        let first = GlobalHotKey.modeSwitchTabEffects(isAutorepeat: false)
        let repeated = GlobalHotKey.modeSwitchTabEffects(isAutorepeat: true)
        XCTAssertFalse(repeated.cyclesMode, "autorepeat must not cycle again")
        XCTAssertEqual(repeated.swallowsKeystroke, first.swallowsKeystroke)
        XCTAssertEqual(
            repeated.cancelsPendingLongPress,
            first.cancelsPendingLongPress
        )
        XCTAssertEqual(repeated.marksChordUsed, first.marksChordUsed)
        XCTAssertEqual(
            repeated.resetsModifierTapSequence,
            first.resetsModifierTapSequence
        )
        XCTAssertEqual(
            repeated.suppressesModifierReleaseGesture,
            first.suppressesModifierReleaseGesture
        )
    }

    // MARK: - F. The release after a cycle must not misfire

    /// "Hold hotkey → tap Tab → keep holding and speak": the long press armed
    /// despite the cycle, so releasing finishes that recording exactly as it
    /// would have without the Tab.
    func testReleaseAfterCyclingFinishesARecordingThatArmed() {
        XCTAssertEqual(
            GlobalHotKey.releaseGesture(
                longPressDidArm: true,
                modeSwitchDidCycle: true,
                chordWasUsed: false
            ),
            .finishHeldRecording
        )
    }

    /// "Hold hotkey → tap Tab → release before the threshold": the mode is
    /// switched and nothing else happens. Registering this as a tap would arm
    /// the double-tap detector (or, on a double-tap preset, immediately start a
    /// hands-free recording) — the regression the flag exists to prevent.
    func testReleaseAfterCyclingWithoutArmingIsConsumed() {
        for chordWasUsed in [false, true] {
            XCTAssertEqual(
                GlobalHotKey.releaseGesture(
                    longPressDidArm: false,
                    modeSwitchDidCycle: true,
                    chordWasUsed: chordWasUsed
                ),
                .consumed,
                "a cycled hold must never register as a tap gesture"
            )
        }
    }

    /// Today's behavior, preserved: a hold used for some other chord is
    /// consumed, and an untouched hold is an ordinary tap gesture.
    func testReleaseWithoutACycleKeepsTodaysBehavior() {
        XCTAssertEqual(
            GlobalHotKey.releaseGesture(
                longPressDidArm: true,
                modeSwitchDidCycle: false,
                chordWasUsed: false
            ),
            .finishHeldRecording
        )
        XCTAssertEqual(
            GlobalHotKey.releaseGesture(
                longPressDidArm: false,
                modeSwitchDidCycle: false,
                chordWasUsed: true
            ),
            .consumed
        )
        XCTAssertEqual(
            GlobalHotKey.releaseGesture(
                longPressDidArm: false,
                modeSwitchDidCycle: false,
                chordWasUsed: false
            ),
            .tap
        )
    }

    /// An armed long press always wins: whatever else happened during the hold,
    /// a recording that started must be finished by its own release.
    func testAnArmedLongPressAlwaysFinishesOnRelease() {
        for modeSwitchDidCycle in [false, true] {
            for chordWasUsed in [false, true] {
                XCTAssertEqual(
                    GlobalHotKey.releaseGesture(
                        longPressDidArm: true,
                        modeSwitchDidCycle: modeSwitchDidCycle,
                        chordWasUsed: chordWasUsed
                    ),
                    .finishHeldRecording
                )
            }
        }
    }

    // MARK: - C. Cycling while listening retargets the in-flight recording

    /// THE POINT OF THE FIX: it is not enough to move the next-recording
    /// default; the recording that is *currently* being captured must be
    /// processed as the new mode.
    func testCyclingWhileListeningRetargetsTheInFlightRecording() {
        let outcome = ModeCyclePolicy.cycle(
            selectedMode: .transcribe,
            activeMode: .transcribe,
            state: .listening
        )
        XCTAssertEqual(
            outcome.activeMode,
            .ask,
            "the in-flight recording must be retargeted, not just the default"
        )
        XCTAssertEqual(outcome.selectedMode, .ask)
    }

    /// While listening, the mode being cycled is the one the recording locked
    /// in (`activeMode`) — which is what the voice surface shows
    /// (`AppModel.voiceSurfaceMode`) — not a diverged stale default.
    func testCyclingWhileListeningAdvancesFromTheInFlightMode() {
        let outcome = ModeCyclePolicy.cycle(
            selectedMode: .agent,
            activeMode: .transcribe,
            state: .listening
        )
        XCTAssertEqual(outcome.activeMode, .ask)
        XCTAssertEqual(outcome.selectedMode, .ask)
    }

    func testCyclingWhileListeningWrapsAround() {
        let outcome = ModeCyclePolicy.cycle(
            selectedMode: .agent,
            activeMode: .agent,
            state: .listening
        )
        XCTAssertEqual(outcome.activeMode, .transcribe)
        XCTAssertEqual(outcome.selectedMode, .transcribe)
    }

    /// With nothing being recorded there is nothing to retarget — cycling must
    /// not invent an active mode.
    func testCyclingWhenIdleOnlyMovesTheSelectedMode() {
        let outcome = ModeCyclePolicy.cycle(
            selectedMode: .transcribe,
            activeMode: nil,
            state: .idle
        )
        XCTAssertEqual(outcome.selectedMode, .ask)
        XCTAssertNil(
            outcome.activeMode,
            "no recording is in flight; nothing to retarget"
        )
    }

    /// A run that has already left `.listening` owns its mode: cycling sets up
    /// the next recording and leaves the finished run's mode untouched.
    func testCyclingOutsideListeningDoesNotRetarget() {
        let outcome = ModeCyclePolicy.cycle(
            selectedMode: .transcribe,
            activeMode: .agent,
            state: .success
        )
        XCTAssertEqual(outcome.selectedMode, .ask)
        XCTAssertEqual(
            outcome.activeMode,
            .agent,
            "only a listening recording is retargeted"
        )
    }

    // MARK: - D. The hint text is derived from the preset

    func testLeftOptionHintPromisesTabAndNamesItsOwnKey() throws {
        let text = try XCTUnwrap(HotKeyPreset.leftOption.modeSwitchHint)
        XCTAssertTrue(text.contains("Tab"), "hint should promise Tab: \(text)")
        XCTAssertTrue(
            text.lowercased().contains("option"),
            "hint should name the preset's own key: \(text)"
        )
        XCTAssertFalse(
            text.contains("Shift"),
            "the Shift chord is gone: \(text)"
        )
    }

    func testFnHintNamesFnRatherThanOption() throws {
        let text = try XCTUnwrap(HotKeyPreset.fnKey.modeSwitchHint)
        XCTAssertTrue(text.contains("Tab"), "hint should promise Tab: \(text)")
        XCTAssertTrue(
            text.lowercased().contains("fn"),
            "hint should name fn: \(text)"
        )
        XCTAssertFalse(
            text.lowercased().contains("option"),
            "left Option is not the fn user's key: \(text)"
        )
    }

    /// `.doubleShift` is the one preset whose recording modifier *is* Shift, so
    /// its hint names Shift as the key to HOLD — the removed chord was tapping
    /// it. (Pinned separately from the blanket no-Shift rule below.)
    func testDoubleShiftHintPromisesTabWhileHoldingShift() throws {
        let text = try XCTUnwrap(HotKeyPreset.doubleShift.modeSwitchHint)
        XCTAssertTrue(text.contains("Tab"), "hint should promise Tab: \(text)")
        XCTAssertTrue(
            text.contains("Shift"),
            "Shift is this preset's own recording key: \(text)"
        )
    }

    /// No mechanism, no promise: the Space-chord presets never install the
    /// modifier-only event tap, so there is no Tab handling to advertise.
    func testSpaceChordPresetsHaveNoHint() {
        for preset: HotKeyPreset in [
            .controlShiftSpace,
            .optionSpace,
            .controlSpace,
            .controlOptionSpace
        ] {
            XCTAssertNil(
                preset.modeSwitchHint,
                "\(preset) has no Tab handling; it must not promise the chord"
            )
        }
    }

    /// The hint exists exactly where the mechanism does.
    func testHintPresenceMatchesTheModifierOnlyTap() {
        for preset in HotKeyPreset.allCases {
            XCTAssertEqual(
                preset.modeSwitchHint != nil,
                preset.usesModifierOnlyEventTap,
                "\(preset): hint presence must track usesModifierOnlyEventTap"
            )
        }
    }

    /// The Shift chord is gone from the copy too. Presets whose own recording
    /// modifier is not Shift must not mention Shift at all.
    func testNoPresetHintMentionsShiftUnlessItIsThatPresetsOwnKey() {
        for preset in HotKeyPreset.allCases where preset != .doubleShift {
            guard let hint = preset.modeSwitchHint else { continue }
            XCTAssertFalse(
                hint.contains("Shift"),
                "\(preset) must not mention Shift: \(hint)"
            )
        }
    }

    /// Every preset that has the mechanism advertises the mechanism. Without
    /// this, `.doubleControl` and `.doubleOption` — the two presets the named
    /// tests above skip — could return any non-nil, Shift-free string and pass.
    func testEveryHintPromisesTab() {
        for preset in HotKeyPreset.allCases {
            guard let hint = preset.modeSwitchHint else { continue }
            XCTAssertTrue(
                hint.contains("Tab"),
                "\(preset) has the mechanism but does not promise Tab: \(hint)"
            )
        }
    }

    /// The fn-hint test above is one instance of a general rule: a hint naming a
    /// key the user is not holding *is* the hardcoding bug, in copy form.
    /// Pinning it for every preset is what stops one preset's string from being
    /// reused for another — otherwise a `.doubleControl` user could be told to
    /// hold Option, exactly the defect this batch is fixing on the input side.
    func testEveryHintNamesItsOwnRecordingKeyAndNoOtherModifier() {
        // Lowercased spellings; any one of a preset's own spellings counts as
        // naming the key, and every spelling belonging only to *another* preset
        // must be absent.
        let names: [HotKeyPreset: [String]] = [
            .leftOption: ["option"],
            .fnKey: ["fn"],
            .doubleControl: ["ctrl", "control"],
            .doubleOption: ["option"],
            .doubleShift: ["shift"]
        ]
        for preset in HotKeyPreset.allCases {
            guard let hint = preset.modeSwitchHint?.lowercased() else { continue }
            guard let own = names[preset] else {
                XCTFail("\(preset) has a hint but no expected key spelling")
                continue
            }
            XCTAssertTrue(
                own.contains { hint.contains($0) },
                "\(preset) must name the key the user holds: \(hint)"
            )
            let foreign = Set(
                names
                    .filter { $0.key != preset }
                    .flatMap { $0.value }
                    .filter { !own.contains($0) }
            )
            for word in foreign {
                XCTAssertFalse(
                    hint.contains(word),
                    "\(preset) names '\(word)', which is not its recording key: \(hint)"
                )
            }
        }
    }

    /// …and no hint anywhere may tell the user to TAP Shift, which is the
    /// instruction the removed chord gave.
    func testNoPresetHintTellsTheUserToTapShift() {
        for preset in HotKeyPreset.allCases {
            guard let hint = preset.modeSwitchHint else { continue }
            XCTAssertFalse(
                hint.contains("点 Shift"),
                "\(preset) still tells the user to tap Shift: \(hint)"
            )
            XCTAssertFalse(
                hint.lowercased().contains("tap shift"),
                "\(preset) still tells the user to tap Shift: \(hint)"
            )
        }
    }
}
