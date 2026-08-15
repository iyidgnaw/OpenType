import Carbon
import CoreGraphics
import Foundation

/// What a `.keyDown` should mean while the event tap is watching for a stop
/// key, factored out of `handleEventTap` so the commit-vs-cancel decision is
/// pure and unit-testable (see `HotKeyKeyActionTests`).
enum HotKeyKeyAction: Equatable {
    /// Finish the in-flight recording and keep the captured audio.
    case commit
    /// Discard the in-flight recording (Esc while armed — P1-10).
    case cancel
    /// Not armed for stop-on-any-key; leave the keystroke alone.
    case ignore
}

/// Everything one Tab keystroke does while the mode-switch chord is armed,
/// factored out of `handleModeSwitchTabKeyDown` so the "cancels nothing"
/// contract is pinned by a test rather than by reading the method.
///
/// `cancelsPendingLongPress` and `marksChordUsed` are both `false`, and that is
/// the fix: `cancelPendingLongPresses()` drops the pending token and
/// `modifierChordWasUsed = true` trips the `!self.modifierChordWasUsed` guard
/// inside the scheduled long-press closure, so either one alone aborts the
/// hold-to-talk the user is still holding for. Because `modifierChordWasUsed`
/// also did double duty as "don't let the eventual key-up fire the toggle",
/// dropping it needs the replacement `suppressesModifierReleaseGesture`, which
/// suppresses the release gesture *without* touching the long press.
struct ModeSwitchTabEffects: Equatable {
    let cyclesMode: Bool
    let swallowsKeystroke: Bool
    let cancelsPendingLongPress: Bool
    let marksChordUsed: Bool
    let resetsModifierTapSequence: Bool
    let suppressesModifierReleaseGesture: Bool
}

/// What releasing the recording modifier means, given what happened during the
/// hold.
enum ModifierReleaseGesture: Equatable {
    /// A long press armed and started a recording; this release finishes it.
    case finishHeldRecording
    /// An untouched hold: the double-tap/toggle machinery gets to see it.
    case tap
    /// The hold was spent on a chord; it must not register as a tap.
    case consumed
}

final class GlobalHotKey {
    var onPressed: (() -> Void)?
    var onReleased: (() -> Void)?
    var onToggle: (() -> Void)?
    var onStopRequested: (() -> Void)?
    var onCancelRequested: (() -> Void)?
    var onCycleMode: (() -> Void)?

    private(set) var shortcutKeys = HotKeyPreset.controlShiftSpace.keys
    private(set) var behavior: HotKeyBehavior = .holdToTalk
    private(set) var isUsingPreferred = false
    private(set) var activePreset: HotKeyPreset?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var heldModifierKeyCodes: Set<Int64> = []
    private var suppressedKeyCodes: Set<Int64> = []
    private var modifierChordWasUsed = false
    private var watchedModifierKeyCodes: Set<Int64> = []
    private var modifierNeedsDoubleTap = false
    private var optionHybridEnabled = false
    private var optionLongPressKeyCode: Int64?
    private var pendingLongPressTokens: [Int64: UUID] = [:]
    private var lastModifierTapKeyCode: Int64?
    private var isMomentaryActivation = false
    /// Set by a Tab cycle, cleared when the last recording modifier comes up.
    /// The `modifierChordWasUsed` replacement described on
    /// `ModeSwitchTabEffects`: it suppresses the release gesture without
    /// aborting the pending long press.
    private var modeSwitchDidCycle = false
    private var activeChordKeyCode: Int64?
    private var activeChordFlags: CGEventFlags = []
    private var doubleTapDetector = DoubleTapDetector(threshold: 0.45)
    private var stopOnAnyKeyEnabled = false
    private var isInstalled = false

    deinit {
        uninstall()
    }

    @discardableResult
    func install(preference: HotKeyPreset) -> Bool {
        guard !isInstalled else { return true }

        if preference.usesModifierOnlyEventTap {
            if installModifierOnlyTap(preference) {
                shortcutKeys = preference.keys
                if preference.usesOptionHybridGesture {
                    behavior = .optionHybrid
                } else {
                    behavior = preference.usesDoubleModifierTap
                        ? .doubleTapThenAnyKey
                        : .pressThenAnyKey
                }
                activePreset = preference
                isUsingPreferred = true
                isInstalled = true
                return true
            }

            // Modifier-only shortcuts require Accessibility. Keep OpenType
            // usable while the user is granting it, without claiming the
            // requested shortcut is active.
            for fallback in Self.emergencyFallbacks {
                if installChord(fallback) {
                    activePreset = fallback
                    shortcutKeys = fallback.keys
                    isUsingPreferred = false
                    return true
                }
                uninstall()
            }
            return false
        }

        guard installChord(preference) else {
            uninstall()
            return false
        }
        activePreset = preference
        shortcutKeys = preference.keys
        isUsingPreferred = true
        return true
    }

    func reinstall(preference: HotKeyPreset) -> Bool {
        uninstall()
        return install(preference: preference)
    }

    func setRecordingActive(_ active: Bool) {
        switch behavior {
        case .holdToTalk:
            stopOnAnyKeyEnabled = false
        case .optionHybrid:
            stopOnAnyKeyEnabled = active && !isMomentaryActivation
        default:
            stopOnAnyKeyEnabled = active
        }
        if !active {
            suppressedKeyCodes = []
            isMomentaryActivation = false
        }
    }

    private func installModifierOnlyTap(_ preset: HotKeyPreset) -> Bool {
        watchedModifierKeyCodes = Self.modifierKeyCodes(for: preset)
        modifierNeedsDoubleTap = preset.usesDoubleModifierTap
        optionHybridEnabled = preset.usesOptionHybridGesture
        guard !watchedModifierKeyCodes.isEmpty else { return false }

        let callback: CGEventTapCallBack = { _, type, event, userData in
            guard let userData else {
                return Unmanaged.passUnretained(event)
            }
            let instance = Unmanaged<GlobalHotKey>
                .fromOpaque(userData)
                .takeUnretainedValue()
            return instance.handleEventTap(type: type, event: event)
        }

        return installEventTap(
            mask: (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue),
            callback: callback
        )
    }

    private func installStopKeyTap() -> Bool {
        let callback: CGEventTapCallBack = { _, type, event, userData in
            guard let userData else {
                return Unmanaged.passUnretained(event)
            }
            let instance = Unmanaged<GlobalHotKey>
                .fromOpaque(userData)
                .takeUnretainedValue()
            return instance.handleEventTap(type: type, event: event)
        }

        return installEventTap(
            mask: (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
                | (CGEventMask(1) << CGEventType.keyDown.rawValue)
                | (CGEventMask(1) << CGEventType.keyUp.rawValue),
            callback: callback
        )
    }

    private func installEventTap(
        mask: CGEventMask,
        callback: @escaping CGEventTapCallBack
    ) -> Bool {
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func handleEventTap(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

        if type == .keyUp, suppressedKeyCodes.contains(keyCode) {
            suppressedKeyCodes.remove(keyCode)
            return nil
        }

        if type == .keyDown {
            // Ahead of the stop-on-any-key branch on purpose: while the
            // recording modifier is down, Tab means "switch mode", never
            // "commit this recording".
            if keyCode == Int64(kVK_Tab),
               Self.shouldCycleModeOnTab(
                   heldModifierKeyCodes: heldModifierKeyCodes,
                   preset: activePreset
               ) {
                return handleModeSwitchTabKeyDown(event)
            }
            if isActiveChordEvent(keyCode: keyCode, flags: event.flags) {
                return Unmanaged.passUnretained(event)
            }
            switch Self.keyAction(
                keyCode: keyCode,
                stopOnAnyKeyEnabled: stopOnAnyKeyEnabled
            ) {
            case .commit:
                stopOnAnyKeyEnabled = false
                suppressedKeyCodes.insert(keyCode)
                DispatchQueue.main.async { [weak self] in
                    self?.onStopRequested?()
                }
                return nil
            case .cancel:
                stopOnAnyKeyEnabled = false
                suppressedKeyCodes.insert(keyCode)
                DispatchQueue.main.async { [weak self] in
                    self?.onCancelRequested?()
                }
                return nil
            case .ignore:
                break
            }
            if !heldModifierKeyCodes.isEmpty {
                modifierChordWasUsed = true
                resetModifierTapSequence()
                cancelPendingLongPresses()
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        guard watchedModifierKeyCodes.contains(keyCode) else {
            return Unmanaged.passUnretained(event)
        }

        // fn doubles as the OS's own modifier (media keys, emoji picker,
        // input-source switching), so its flagsChanged stream can skip past a
        // temporarily disabled tap and leave a toggle-based held-set
        // desynced. Read the flag itself instead of inferring press/release.
        if keyCode == Int64(kVK_Function) {
            let isDown = event.flags.contains(.maskSecondaryFn)
            if isDown, !heldModifierKeyCodes.contains(keyCode) {
                handleModifierPressed(keyCode)
            } else if !isDown, heldModifierKeyCodes.contains(keyCode) {
                handleModifierReleased(keyCode)
            }
            return Unmanaged.passUnretained(event)
        }

        if heldModifierKeyCodes.contains(keyCode) {
            handleModifierReleased(keyCode)
        } else {
            handleModifierPressed(keyCode)
        }
        return Unmanaged.passUnretained(event)
    }

    private func handleModifierPressed(_ keyCode: Int64) {
        if heldModifierKeyCodes.isEmpty {
            // Nothing was held, so no chord can be in progress: a fresh press
            // starts from a clean slate. (The Tab chord is the only one left,
            // and it requires a held recording modifier by construction.)
            modifierChordWasUsed = false
            modeSwitchDidCycle = false
        } else {
            modifierChordWasUsed = true
            resetModifierTapSequence()
            cancelPendingLongPresses()
        }
        heldModifierKeyCodes.insert(keyCode)

        guard optionHybridEnabled,
              !modifierChordWasUsed,
              !stopOnAnyKeyEnabled else { return }

        let token = UUID()
        pendingLongPressTokens[keyCode] = token
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.optionLongPressThreshold
        ) { [weak self] in
            guard let self,
                  self.pendingLongPressTokens[keyCode] == token,
                  self.heldModifierKeyCodes.contains(keyCode),
                  !self.modifierChordWasUsed else { return }
            self.pendingLongPressTokens[keyCode] = nil
            self.optionLongPressKeyCode = keyCode
            self.isMomentaryActivation = true
            self.resetModifierTapSequence()
            self.onPressed?()
        }
    }

    private func handleModifierReleased(_ keyCode: Int64) {
        heldModifierKeyCodes.remove(keyCode)
        pendingLongPressTokens[keyCode] = nil

        switch Self.releaseGesture(
            longPressDidArm: optionHybridEnabled
                && optionLongPressKeyCode == keyCode,
            modeSwitchDidCycle: modeSwitchDidCycle,
            chordWasUsed: modifierChordWasUsed
        ) {
        case .finishHeldRecording:
            optionLongPressKeyCode = nil
            DispatchQueue.main.async { [weak self] in
                self?.onReleased?()
            }
        case .tap:
            let now = Date.timeIntervalSinceReferenceDate
            let shouldToggle: Bool
            if optionHybridEnabled || modifierNeedsDoubleTap {
                shouldToggle = registerModifierTap(
                    keyCode: keyCode,
                    at: now
                )
            } else {
                shouldToggle = true
            }

            if shouldToggle {
                isMomentaryActivation = false
                DispatchQueue.main.async { [weak self] in
                    self?.onToggle?()
                }
            }
        case .consumed:
            break
        }

        if heldModifierKeyCodes.isEmpty {
            modifierChordWasUsed = false
            modeSwitchDidCycle = false
        }
    }

    private func registerModifierTap(
        keyCode: Int64,
        at time: TimeInterval
    ) -> Bool {
        if lastModifierTapKeyCode != keyCode {
            doubleTapDetector.reset()
        }
        let triggered = doubleTapDetector.registerTap(at: time)
        lastModifierTapKeyCode = triggered ? nil : keyCode
        return triggered
    }

    private func resetModifierTapSequence() {
        doubleTapDetector.reset()
        lastModifierTapKeyCode = nil
    }

    private func cancelPendingLongPresses() {
        pendingLongPressTokens = [:]
    }

    /// Tab while the user's *configured* recording modifier is held: cycles the
    /// mode. Tab is a regular key, not a modifier, so it comes through as
    /// `.keyDown` (with OS auto-repeat if held) — this always swallows the
    /// event (never lets Tab reach the focused app while the hotkey is down,
    /// since a stray tab-navigation in the background app while the user means
    /// to switch modes would be a worse outcome than a consumed keystroke) but
    /// only fires `onCycleMode` once per physical press, skipping repeats.
    ///
    /// It cancels nothing, so hold length — not reaction time — decides what
    /// the gesture does: release before the long-press threshold and the mode
    /// simply switched, keep holding and the recording proceeds and is
    /// processed as the *new* mode. See `ModeSwitchTabEffects`.
    private func handleModeSwitchTabKeyDown(
        _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let effects = Self.modeSwitchTabEffects(
            isAutorepeat: event.getIntegerValueField(
                .keyboardEventAutorepeat
            ) != 0
        )

        if effects.swallowsKeystroke {
            suppressedKeyCodes.insert(Int64(kVK_Tab))
        }
        if effects.cancelsPendingLongPress {
            cancelPendingLongPresses()
        }
        if effects.marksChordUsed {
            modifierChordWasUsed = true
        }
        if effects.resetsModifierTapSequence {
            resetModifierTapSequence()
        }
        if effects.suppressesModifierReleaseGesture {
            modeSwitchDidCycle = true
        }
        if effects.cyclesMode {
            DispatchQueue.main.async { [weak self] in
                self?.onCycleMode?()
            }
        }
        return effects.swallowsKeystroke ? nil : Unmanaged.passUnretained(event)
    }

    /// Whether a Tab keystroke should cycle the mode: only while one of the
    /// keys the *active preset* records with is held. Gating on left Option
    /// regardless of preset (the old behavior) left the gesture dead for every
    /// `fn` and double-tap user, since left Option is not their recording key.
    ///
    /// The Space-chord presets register a Carbon hot key rather than the
    /// modifier-only event tap, so no Tab handling exists for them at all —
    /// `usesModifierOnlyEventTap` is what says so.
    static func shouldCycleModeOnTab(
        heldModifierKeyCodes: Set<Int64>,
        preset: HotKeyPreset?
    ) -> Bool {
        guard let preset, preset.usesModifierOnlyEventTap else { return false }
        return !heldModifierKeyCodes.isDisjoint(with: modifierKeyCodes(for: preset))
    }

    /// See `ModeSwitchTabEffects` for why "cancels nothing" is the fix.
    /// Autorepeat changes only whether the mode cycles: one physical press,
    /// one cycle — but a held Tab must not leak into the focused app either.
    static func modeSwitchTabEffects(isAutorepeat: Bool) -> ModeSwitchTabEffects {
        ModeSwitchTabEffects(
            cyclesMode: !isAutorepeat,
            swallowsKeystroke: true,
            cancelsPendingLongPress: false,
            marksChordUsed: false,
            // The `DoubleTapDetector`'s stored tap still has to go: unlike the
            // pending long press it cannot be aborted by clearing it (the
            // scheduled closure never consults it), and leaving it means a
            // tap-then-chord-then-tap sequence inside the 450ms window fires a
            // double tap and starts a recording the user never asked for.
            resetsModifierTapSequence: true,
            suppressesModifierReleaseGesture: true
        )
    }

    /// What the recording modifier coming back up means. An armed long press
    /// always wins — a recording that started must be finished by its own
    /// release, whatever else happened during the hold. Otherwise a hold spent
    /// on a chord is consumed rather than registered as a tap: letting it
    /// through would arm the double-tap detector (or, on a double-tap preset,
    /// immediately start a hands-free recording) off a gesture the user made to
    /// switch modes.
    static func releaseGesture(
        longPressDidArm: Bool,
        modeSwitchDidCycle: Bool,
        chordWasUsed: Bool
    ) -> ModifierReleaseGesture {
        if longPressDidArm { return .finishHeldRecording }
        if modeSwitchDidCycle || chordWasUsed { return .consumed }
        return .tap
    }

    private func isActiveChordEvent(
        keyCode: Int64,
        flags: CGEventFlags
    ) -> Bool {
        guard let activeChordKeyCode, keyCode == activeChordKeyCode else {
            return false
        }
        return flags.intersection(activeChordFlags) == activeChordFlags
    }

    private func installChord(_ preset: HotKeyPreset) -> Bool {
        guard let chord = Self.chord(for: preset) else { return false }
        activeChordKeyCode = Int64(chord.keyCode)
        activeChordFlags = chord.cgFlags

        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            )
        ]

        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return noErr }
            let instance = Unmanaged<GlobalHotKey>
                .fromOpaque(userData)
                .takeUnretainedValue()
            let kind = GetEventKind(event)

            DispatchQueue.main.async {
                if kind == UInt32(kEventHotKeyPressed) {
                    if instance.behavior == .holdToTalk {
                        instance.onPressed?()
                    } else {
                        instance.onToggle?()
                    }
                } else if kind == UInt32(kEventHotKeyReleased),
                          instance.behavior == .holdToTalk {
                    instance.onReleased?()
                }
            }
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(
            signature: fourCharacterCode("OTYP"),
            id: 1
        )
        let status = RegisterEventHotKey(
            chord.keyCode,
            chord.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else { return false }

        // Carbon works without Accessibility. The event tap upgrades the
        // interaction from hold-to-talk to press once / any key to stop.
        behavior = installStopKeyTap() ? .pressThenAnyKey : .holdToTalk
        isInstalled = true
        return true
    }

    func uninstall() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        hotKeyRef = nil
        eventHandlerRef = nil
        eventTap = nil
        runLoopSource = nil
        heldModifierKeyCodes = []
        suppressedKeyCodes = []
        watchedModifierKeyCodes = []
        modifierNeedsDoubleTap = false
        optionHybridEnabled = false
        optionLongPressKeyCode = nil
        pendingLongPressTokens = [:]
        lastModifierTapKeyCode = nil
        isMomentaryActivation = false
        modeSwitchDidCycle = false
        modifierChordWasUsed = false
        activeChordKeyCode = nil
        activeChordFlags = []
        stopOnAnyKeyEnabled = false
        doubleTapDetector.reset()
        behavior = .holdToTalk
        isInstalled = false
        isUsingPreferred = false
        activePreset = nil
    }

    /// Pure decision behind `handleEventTap`'s stop-on-any-key branch. When
    /// armed (`stopOnAnyKeyEnabled`), Esc discards the recording (P1-10) while
    /// any other key commits it (today's stop-on-any-key behavior); when not
    /// armed, keystrokes are left alone — Esc included, so the tap never steals
    /// Esc outside an active recording.
    static func keyAction(
        keyCode: Int64,
        stopOnAnyKeyEnabled: Bool
    ) -> HotKeyKeyAction {
        guard stopOnAnyKeyEnabled else { return .ignore }
        return keyCode == Int64(kVK_Escape) ? .cancel : .commit
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }

    private static let emergencyFallbacks: [HotKeyPreset] = [
        .controlShiftSpace,
        .controlOptionSpace,
        .optionSpace
    ]

    private static let optionLongPressThreshold: TimeInterval = 0.30

    /// The keys a preset records with — the same set the modifier-only event
    /// tap watches and the mode-switch chord is gated on.
    static func modifierKeyCodes(for preset: HotKeyPreset) -> Set<Int64> {
        switch preset {
        case .leftOption:
            return [Int64(kVK_Option)]
        case .fnKey:
            return [Int64(kVK_Function)]
        case .doubleControl:
            return [Int64(kVK_Control), Int64(kVK_RightControl)]
        case .doubleOption:
            return [Int64(kVK_Option), Int64(kVK_RightOption)]
        case .doubleShift:
            return [Int64(kVK_Shift), Int64(kVK_RightShift)]
        default:
            return []
        }
    }

    private static func chord(
        for preset: HotKeyPreset
    ) -> (
        keyCode: UInt32,
        carbonModifiers: UInt32,
        cgFlags: CGEventFlags
    )? {
        switch preset {
        case .controlShiftSpace:
            return (
                UInt32(kVK_Space),
                UInt32(controlKey | shiftKey),
                [.maskControl, .maskShift]
            )
        case .optionSpace:
            return (
                UInt32(kVK_Space),
                UInt32(optionKey),
                [.maskAlternate]
            )
        case .controlSpace:
            return (
                UInt32(kVK_Space),
                UInt32(controlKey),
                [.maskControl]
            )
        case .controlOptionSpace:
            return (
                UInt32(kVK_Space),
                UInt32(controlKey | optionKey),
                [.maskControl, .maskAlternate]
            )
        default:
            return nil
        }
    }
}

struct DoubleTapDetector {
    let threshold: TimeInterval
    private(set) var lastTap: TimeInterval?

    mutating func registerTap(at time: TimeInterval) -> Bool {
        if let lastTap, time - lastTap <= threshold {
            self.lastTap = nil
            return true
        }
        lastTap = time
        return false
    }

    mutating func reset() {
        lastTap = nil
    }
}
