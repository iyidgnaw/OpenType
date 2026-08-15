import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §J of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 按应用规则.
///
/// The product problem, from `docs/reviews/2026-08-15-product-review.md` §8:
/// `bundleIdentifier` is already captured all the way through the pipeline
/// (`ContextBridge` → `CapturedContext` → `OutputDeliveryPolicy.shouldInsert`'s
/// "the frontmost app changed since capture, downgrade to clipboard" guard) but
/// it is only ever consulted for *safety downgrades*, never for behaviour. The
/// data structure is already there; what is missing is a table.
///
/// The two entries that motivate the table:
///
/// - **Terminals do not receive an auto-insert.** Pasting a multi-line
///   dictation into Terminal/iTerm can execute it the moment the newline lands.
///   That is a reachable destructive path in the shipping configuration, and it
///   is *less* supervised than the agent's `opentype__bash`, which at least
///   passes through `classifyCommandRisk` first.
/// - **The best `TranscribeVariant` varies by destination.** It is one global
///   setting today; 微信/备忘录 want `tidy`, a code editor wants `direct`.
///
/// **Not a rules engine** (spec, and review §14): a built-in table with no
/// per-row user editing in this batch. So these tests pin the table's contents
/// and the two decisions that read it — nothing about persistence or UI.
///
/// ## Pinned decision — where the rule composes
///
/// The spec is explicit that the rule takes effect at `shouldInsert`, **不新开
/// 一条交付路径**: one delivery decision, not a second path that a future call
/// site could forget. So the API this file pins is an *overload* of the
/// existing seam,
/// `OutputDeliveryPolicy.shouldInsert(capturedBundleId:frontmostBundleId:perAppRulesEnabled:)`,
/// which Stage 3 can declare as `extension OutputDeliveryPolicy` inside the new
/// `Sources/OpenType/AppRules.swift` — the table and its composition stay in one
/// pure module and `Models.swift` needs no edit. The overload must **not** give
/// `perAppRulesEnabled` a default value; a defaulted third parameter alongside
/// the existing two-parameter function is how the current call sites become
/// ambiguous.
///
/// The existing two-argument form stays as it is, and its two other callers keep
/// calling it: `CorrectionWindow.intent` and `AliasUndo.decide`
/// (`LearningLoop.swift`). That narrowing is deliberate but it is not vacuous —
/// `AppModel.armCorrectionWindow` runs whether or not the insert actually
/// landed, so a terminal dictation this table downgraded to clipboard-only still
/// arms a correction window, and a follow-up correction would write into the
/// terminal through the very same `ContextBridge.insert` (clipboard + ⌘V).
/// Closing that means threading `perAppRulesEnabled` into those two call sites
/// too. It is written down here rather than pinned by a test because both live
/// in another item's files this batch, and because §J's own scope is the
/// delivery decision.
///
/// The master switch lives *inside* that function rather than at the call site,
/// so "rules off" cannot be half-honoured by one caller and not another.
///
/// ## Pinned decision — a per-app variant never overrides an explicit choice
///
/// The one genuine design question in §J: does a rule's `transcribeVariant`
/// beat the user's `TranscribeVariant` setting, or only the factory default?
/// **Only the factory default.** Someone who went into Settings and deliberately
/// chose Review did so because they want to see every transcript before it
/// lands; silently delivering straight into 备忘录 because a built-in table
/// prefers `tidy` there would be exactly the surprise they set that switch to
/// prevent, and they would have no way to tell it happened — the text is simply
/// already in the field.
///
/// This is deliberately asymmetric with `autoInsert`, where the terminal rule
/// *does* beat a global `automaticallyInsert = true`, and the asymmetry is the
/// rule: a per-app rule may **restrict** delivery on safety grounds (strictly
/// less happens than the user asked for, and the result is still on the
/// clipboard), but may never **substitute** one behaviour for another that the
/// user explicitly picked. `testExplicitDirectAlsoWinsOverAPerAppTidy` is what
/// keeps this from degrading into "overrides anything that isn't the default
/// value" — "explicit" means the user chose, not that the chosen value differs
/// from `.direct`.
///
/// That is why `userSelected` is `TranscribeVariant?` and not a `Bool` flag:
/// "the user has never chosen" has to be representable. It is not representable
/// today — `AppConfiguration.transcribeVariant` is non-optional and its
/// initializer collapses an absent key to `.direct` — so section G pins the
/// accessor that keeps the two apart. Without it the whole decision is
/// unreachable in the other direction: every call would pass a non-`nil`
/// `userSelected` and no per-app variant would ever apply.
///
/// These tests are RED until Stage 3 adds `Sources/OpenType/AppRules.swift`
/// with `AppRule`, `AppRules.defaults`, `AppRules.rule(for:)`,
/// `AppRules.transcribeVariant(for:userSelected:perAppRulesEnabled:)` and the
/// `shouldInsert` overload above. They currently fail to COMPILE because none of
/// those symbols exist — that is the intended red.
final class AppRulesTests: XCTestCase {

    /// The five terminals §J names. Every one of them can execute a pasted
    /// line, which is the entire reason this table exists.
    private let terminalBundleIds = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
    ]

    /// The 即时通讯/笔记 apps §J names — all four, not just the two the review
    /// used as examples.
    private let tidyBundleIds = [
        "com.tencent.xinWeChat",     // 微信
        "com.apple.Notes",           // 备忘录
        "com.tinyspeck.slackmacgap", // Slack
        "notion.id",                 // Notion
    ]

    /// The code editors §J names. JetBrains ships one bundle id per IDE rather
    /// than one for the family; IntelliJ is the one pinned here, and section B's
    /// invariants are what keep its siblings honest as they are added.
    private let directBundleIds = [
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode",
        "com.jetbrains.intellij",
    ]

    /// An app the table has no opinion about — the case that must stay byte-for
    /// byte identical to today's behavior.
    private let unknownBundleId = "com.example.SomeAppWeHaveNeverHeardOf"

    // MARK: - A. The table

    func testEveryNamedTerminalSuppressesAutoInsert() {
        for bundleId in terminalBundleIds {
            guard let rule = AppRules.rule(for: bundleId) else {
                XCTFail("\(bundleId) must have a rule")
                continue
            }
            XCTAssertEqual(
                rule.bundleIdentifier,
                bundleId,
                "a rule must identify the app it was looked up for"
            )
            XCTAssertEqual(
                rule.autoInsert,
                false,
                "\(bundleId) can execute what is pasted into it, so it must not auto-insert"
            )
        }
    }

    func testTerminalRulesExpressNoVariantOpinion() {
        // The terminal entries are a safety rule, and §J lists them only under
        // 默认不自动插入. Giving them a variant as well would quietly change
        // what reaches the *clipboard* for a destination we already decided not
        // to deliver into — a second, unasked-for behaviour change riding along
        // with a safety one.
        for bundleId in terminalBundleIds {
            XCTAssertNil(
                AppRules.rule(for: bundleId)?.transcribeVariant,
                "\(bundleId)'s rule is about insertion, not about transcript style"
            )
        }
    }

    func testMessagingAndNotesAppsDefaultToTidy() {
        for bundleId in tidyBundleIds {
            XCTAssertEqual(
                AppRules.rule(for: bundleId)?.transcribeVariant,
                .tidy,
                "\(bundleId) is prose written to a person — fillers and stutters should be dropped"
            )
        }
    }

    func testCodeEditorsDefaultToDirect() {
        for bundleId in directBundleIds {
            XCTAssertEqual(
                AppRules.rule(for: bundleId)?.transcribeVariant,
                .direct,
                "\(bundleId) receives identifiers and code — tidying punctuation would corrupt them"
            )
        }
    }

    func testMessagingAndEditorRulesDoNotTouchAutoInsert() {
        // A variant rule is about *what* text is produced. Leaving `autoInsert`
        // nil is how it says it has no opinion on *whether* it is delivered, so
        // the global setting keeps deciding that for these apps.
        for bundleId in tidyBundleIds + directBundleIds {
            XCTAssertNil(
                AppRules.rule(for: bundleId)?.autoInsert,
                "\(bundleId)'s rule must leave delivery to the global setting"
            )
        }
    }

    func testUnknownBundleIdHasNoRuleAtAll() {
        // Nil, not a default-shaped `AppRule` with nil fields. "No opinion" has
        // to be distinguishable at the type level from "an opinion that happens
        // to match the default", because only the first one is guaranteed to
        // leave existing behavior untouched forever.
        XCTAssertNil(AppRules.rule(for: unknownBundleId))
    }

    func testNilBundleIdHasNoRule() {
        // No frontmost application at capture time, or one without a bundle
        // identifier (`ContextBridge.capture` reads
        // `NSWorkspace.frontmostApplication?.bundleIdentifier`), so there is no
        // identity to match. Must not crash and must not fall into any entry —
        // least of all a terminal's.
        XCTAssertNil(AppRules.rule(for: nil))
    }

    // MARK: - B. The table's invariants

    func testEveryRuleExpressesAtLeastOneOpinion() {
        for rule in AppRules.defaults {
            XCTAssertFalse(
                rule.autoInsert == nil && rule.transcribeVariant == nil,
                "\(rule.bundleIdentifier) has a row but says nothing — it should not have a row"
            )
        }
    }

    func testNoBundleIdAppearsTwice() {
        let ids = AppRules.defaults.map(\.bundleIdentifier)
        XCTAssertEqual(
            ids.count,
            Set(ids).count,
            "two rows for one app means lookup order silently decides behavior"
        )
    }

    func testNoRuleEverEnablesAutoInsert() {
        // The data-level statement of "a rule may restrict, never enable". If
        // no row can ever carry `autoInsert == true`, then no future row can
        // turn insertion on for a user who switched it off globally.
        for rule in AppRules.defaults {
            XCTAssertNotEqual(
                rule.autoInsert,
                true,
                "\(rule.bundleIdentifier) must not force auto-insert on"
            )
        }
    }

    // MARK: - C. Composition with `OutputDeliveryPolicy.shouldInsert`

    /// Mirrors how `AppModel` composes the two decisions at delivery time
    /// (`AppModel.swift`'s `deliveryStrategy == .automaticInsert` branch, which
    /// then asks `OutputDeliveryPolicy.shouldInsert` before calling
    /// `contextBridge.insert`). Stage 3's wiring job is to pass
    /// `perAppRulesEnabled` into that existing call — not to add a branch
    /// beside it.
    private func effectivelyInserts(
        mode: InputMode = .transcribe,
        automaticallyInsert: Bool,
        capturedBundleId: String?,
        frontmostBundleId: String?,
        perAppRulesEnabled: Bool
    ) -> Bool {
        let strategy = OutputDeliveryPolicy.strategy(
            for: mode,
            automaticallyInsert: automaticallyInsert
        )
        guard strategy == .automaticInsert else { return false }
        return OutputDeliveryPolicy.shouldInsert(
            capturedBundleId: capturedBundleId,
            frontmostBundleId: frontmostBundleId,
            perAppRulesEnabled: perAppRulesEnabled
        )
    }

    func testTerminalNeverAutoInsertsEvenWithTheGlobalSettingOn() {
        for bundleId in terminalBundleIds {
            XCTAssertFalse(
                effectivelyInserts(
                    automaticallyInsert: true,
                    capturedBundleId: bundleId,
                    frontmostBundleId: bundleId,
                    perAppRulesEnabled: true
                ),
                "\(bundleId) must stay clipboard-only regardless of automaticallyInsert"
            )
        }
    }

    func testTerminalRuleHoldsForEveryModeThatWouldOtherwiseInsert() {
        // `strategy(for:automaticallyInsert:)` answers `.automaticInsert` for
        // `agent` as well as `transcribe`, so this cannot be a rule that only
        // the transcribe path happens to consult.
        for mode in InputMode.allCases {
            guard OutputDeliveryPolicy.strategy(
                for: mode,
                automaticallyInsert: true
            ) == .automaticInsert else { continue }
            for bundleId in terminalBundleIds {
                XCTAssertFalse(
                    effectivelyInserts(
                        mode: mode,
                        automaticallyInsert: true,
                        capturedBundleId: bundleId,
                        frontmostBundleId: bundleId,
                        perAppRulesEnabled: true
                    ),
                    "\(mode) must not paste into \(bundleId) either"
                )
            }
        }
    }

    func testAppWithAVariantRuleStillAutoInsertsNormally() {
        // A `tidy`/`direct` row says nothing about delivery, so enabling rules
        // must not cost these apps their auto-insert.
        for bundleId in tidyBundleIds + directBundleIds {
            XCTAssertTrue(
                effectivelyInserts(
                    automaticallyInsert: true,
                    capturedBundleId: bundleId,
                    frontmostBundleId: bundleId,
                    perAppRulesEnabled: true
                ),
                "\(bundleId) has no delivery opinion, so delivery is unchanged"
            )
        }
    }

    func testUnknownAppIsUnaffectedByRules() {
        XCTAssertTrue(
            effectivelyInserts(
                automaticallyInsert: true,
                capturedBundleId: unknownBundleId,
                frontmostBundleId: unknownBundleId,
                perAppRulesEnabled: true
            )
        )
    }

    func testNilBundleIdsAreUnaffectedByRules() {
        // Accessibility gave us nothing to match on. The pre-existing contract
        // for an unknown captured id is "allow insert"; a table that no id can
        // match must not change that, and must not crash reaching for one.
        XCTAssertTrue(
            effectivelyInserts(
                automaticallyInsert: true,
                capturedBundleId: nil,
                frontmostBundleId: nil,
                perAppRulesEnabled: true
            )
        )
        XCTAssertTrue(
            effectivelyInserts(
                automaticallyInsert: true,
                capturedBundleId: nil,
                frontmostBundleId: "com.apple.Terminal",
                perAppRulesEnabled: true
            ),
            "an unknown capture must keep today's allow-insert behavior, not inherit the terminal rule"
        )
    }

    func testGlobalInsertOffStillWinsForAppsWithNoDeliveryOpinion() {
        // The rule table only ever subtracts. With the global switch off,
        // enabling rules cannot add an insert back.
        for bundleId in ["com.apple.Notes", unknownBundleId] {
            XCTAssertFalse(
                effectivelyInserts(
                    automaticallyInsert: false,
                    capturedBundleId: bundleId,
                    frontmostBundleId: bundleId,
                    perAppRulesEnabled: true
                )
            )
        }
    }

    // MARK: - D. Ordering: the safety guard is not something a rule can undo

    func testFrontmostChangedSinceCaptureStillDowngradesWithRulesOn() {
        XCTAssertFalse(
            OutputDeliveryPolicy.shouldInsert(
                capturedBundleId: "com.apple.Notes",
                frontmostBundleId: "com.tinyspeck.slackmacgap",
                perAppRulesEnabled: true
            ),
            "focus moved after capture — that decision is independent of the table"
        )
    }

    func testNoRuleCanUpgradeADeliveryTheSafetyGuardDowngraded() {
        // Every combination where the two apps differ must be false, whichever
        // side carries a rule. This is the one place the two mechanisms can be
        // composed wrongly — an implementation that looks the rule up *first*
        // and returns its `autoInsert` when it finds one would pass every test
        // above and fail here.
        let pairs: [(captured: String?, frontmost: String?)] = [
            ("com.apple.Notes", "com.apple.Terminal"),          // rule → rule
            ("com.apple.Terminal", "com.apple.Notes"),          // rule → rule, reversed
            ("com.apple.dt.Xcode", unknownBundleId),            // rule → no rule
            (unknownBundleId, "com.apple.Notes"),               // no rule → rule
            ("com.apple.Notes", nil),                           // frontmost unknown
        ]
        for pair in pairs {
            XCTAssertFalse(
                OutputDeliveryPolicy.shouldInsert(
                    capturedBundleId: pair.captured,
                    frontmostBundleId: pair.frontmost,
                    perAppRulesEnabled: true
                ),
                "\(String(describing: pair.captured)) → \(String(describing: pair.frontmost)) is a focus change"
            )
        }
    }

    func testRulesOnlyDecideOnceTheGuardHasAlreadyAgreed() {
        // Stated positively, so the ordering is pinned from both sides: the
        // only pairs a rule is ever consulted for are the ones where captured
        // and frontmost already match.
        XCTAssertTrue(
            OutputDeliveryPolicy.shouldInsert(
                capturedBundleId: "com.apple.Notes",
                frontmostBundleId: "com.apple.Notes",
                perAppRulesEnabled: true
            )
        )
        XCTAssertFalse(
            OutputDeliveryPolicy.shouldInsert(
                capturedBundleId: "com.apple.Terminal",
                frontmostBundleId: "com.apple.Terminal",
                perAppRulesEnabled: true
            )
        )
    }

    // MARK: - E. The master switch is a total bypass

    func testSwitchOffReproducesTodaysInsertDecisionForEveryBundleId() {
        // Compared against the *existing* two-argument function rather than
        // against hardcoded expectations, so this stays a statement about
        // "byte-for-byte what it does today" even if that function changes.
        var ids: [String?] = (terminalBundleIds + tidyBundleIds + directBundleIds)
            .map { $0 }
        ids.append(contentsOf: [unknownBundleId, nil])

        for captured in ids {
            for frontmost in ids {
                XCTAssertEqual(
                    OutputDeliveryPolicy.shouldInsert(
                        capturedBundleId: captured,
                        frontmostBundleId: frontmost,
                        perAppRulesEnabled: false
                    ),
                    OutputDeliveryPolicy.shouldInsert(
                        capturedBundleId: captured,
                        frontmostBundleId: frontmost
                    ),
                    "rules off must match the un-ruled decision for "
                        + "\(String(describing: captured)) → \(String(describing: frontmost))"
                )
            }
        }
    }

    func testSwitchOffStillAutoInsertsIntoEveryTerminal() {
        // The same terminals as section A, asserted through the composition, so
        // the switch is proven to be a real bypass and not one that forgot the
        // rows that matter most.
        for bundleId in terminalBundleIds {
            XCTAssertTrue(
                effectivelyInserts(
                    automaticallyInsert: true,
                    capturedBundleId: bundleId,
                    frontmostBundleId: bundleId,
                    perAppRulesEnabled: false
                ),
                "with rules off, \(bundleId) behaves exactly as it does today"
            )
        }
    }

    func testSwitchOffLeavesTheVariantAtTheUsersGlobalChoice() {
        for bundleId in terminalBundleIds + tidyBundleIds + directBundleIds
            + [unknownBundleId] {
            XCTAssertEqual(
                AppRules.transcribeVariant(
                    for: bundleId,
                    userSelected: nil,
                    perAppRulesEnabled: false
                ),
                .direct,
                "with rules off, \(bundleId) gets the same factory default it gets today"
            )
            XCTAssertEqual(
                AppRules.transcribeVariant(
                    for: bundleId,
                    userSelected: .review,
                    perAppRulesEnabled: false
                ),
                .review,
                "with rules off, \(bundleId) gets the user's global choice, unchanged"
            )
        }
    }

    // MARK: - F. Variant selection (the pinned override question)

    func testPerAppVariantAppliesWhenTheUserHasNeverChosen() {
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: "com.apple.Notes",
                userSelected: nil,
                perAppRulesEnabled: true
            ),
            .tidy
        )
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: "com.apple.dt.Xcode",
                userSelected: nil,
                perAppRulesEnabled: true
            ),
            .direct
        )
    }

    func testAnExplicitUserChoiceBeatsAPerAppVariant() {
        // The pinned decision. Someone who deliberately set Review wants to see
        // every transcript before it lands; a built-in table preferring `tidy`
        // in 备忘录 must not silently deliver behind their back.
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: "com.apple.Notes",
                userSelected: .review,
                perAppRulesEnabled: true
            ),
            .review
        )
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: "com.apple.dt.Xcode",
                userSelected: .tidy,
                perAppRulesEnabled: true
            ),
            .tidy
        )
    }

    func testExplicitDirectAlsoWinsOverAPerAppTidy() {
        // "Explicit" must mean *the user chose*, not *the value differs from
        // the factory default*. An implementation that compares against
        // `.direct` instead of checking for a choice passes the test above and
        // fails this one — and it is the likelier bug of the two, because
        // `AppConfiguration.transcribeVariant` is non-optional today.
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: "com.apple.Notes",
                userSelected: .direct,
                perAppRulesEnabled: true
            ),
            .direct,
            "the user picked Direct on purpose; 备忘录's tidy row does not outrank that"
        )
    }

    func testAppsWithNoVariantOpinionFallBackToTheGlobalValue() {
        // Terminals and unknown apps alike: no variant row means the global
        // value decides, chosen or defaulted.
        for bundleId in terminalBundleIds + [unknownBundleId] {
            XCTAssertEqual(
                AppRules.transcribeVariant(
                    for: bundleId,
                    userSelected: nil,
                    perAppRulesEnabled: true
                ),
                .direct,
                "\(bundleId) has no variant row, so the factory default stands"
            )
            XCTAssertEqual(
                AppRules.transcribeVariant(
                    for: bundleId,
                    userSelected: .review,
                    perAppRulesEnabled: true
                ),
                .review,
                "\(bundleId) has no variant row, so the user's choice stands"
            )
        }
    }

    func testNilBundleIdFallsBackToTheGlobalValue() {
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: nil,
                userSelected: nil,
                perAppRulesEnabled: true
            ),
            .direct
        )
        XCTAssertEqual(
            AppRules.transcribeVariant(
                for: nil,
                userSelected: .review,
                perAppRulesEnabled: true
            ),
            .review
        )
    }

    func testEveryVariantRowResolvesToItselfForAnUnsetUser() {
        // Property form of the two lookups above, over whatever the table ends
        // up containing: a row's variant is exactly what an unset user gets in
        // that app. Catches a row added later that the resolution forgets.
        for rule in AppRules.defaults {
            guard let variant = rule.transcribeVariant else { continue }
            XCTAssertEqual(
                AppRules.transcribeVariant(
                    for: rule.bundleIdentifier,
                    userSelected: nil,
                    perAppRulesEnabled: true
                ),
                variant,
                "\(rule.bundleIdentifier)'s row is not reaching the resolution"
            )
        }
    }

    // MARK: - G. What `AppConfiguration` must expose for section F to be reachable

    /// Section F's `userSelected:` is only worth its `Optional` if the settings
    /// layer can actually produce a `nil`. Today it cannot:
    /// `AppConfiguration.transcribeVariant` is a non-optional `TranscribeVariant`
    /// whose initializer collapses an absent key to `.direct`, so Stage 3 could
    /// wire the resolution up as
    /// `userSelected: configuration.transcribeVariant`, type-check, pass every
    /// test in section F — and ship a table whose variant half never fires,
    /// because the argument would never be `nil`. These tests are what make that
    /// wiring impossible.
    ///
    /// The accessor they require:
    ///
    /// ```swift
    /// var userSelectedTranscribeVariant: TranscribeVariant? { get }
    /// ```
    ///
    /// The persistence side already supports it — `didSet` does not fire during
    /// `init`, so the `transcribeVariant` key stays absent until the user picks
    /// something — and the existing non-optional `transcribeVariant` must keep
    /// answering exactly as it does today for its current readers
    /// (`TranscribeVariantTidyTests` pins those).

    @MainActor
    func testAFreshInstallHasMadeNoTranscribeVariantChoice() {
        let suiteName = "AppRulesTests.NoChoice.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertNil(
            configuration.userSelectedTranscribeVariant,
            "nobody has chosen anything yet — which is the only state a per-app row may fill"
        )
        XCTAssertEqual(
            configuration.transcribeVariant,
            .direct,
            "and the existing non-optional reader still answers exactly as before"
        )
    }

    @MainActor
    func testChoosingDirectCountsAsAChoiceEvenThoughItEqualsTheDefault() {
        // The persistence half of `testExplicitDirectAlsoWinsOverAPerAppTidy`.
        // Without it, "explicit" is unrepresentable for the one value where it
        // matters most, and the decision degrades into a `!= .direct` comparison
        // no matter how section F's pure function is written.
        let suiteName = "AppRulesTests.ChoseDirect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        configuration.transcribeVariant = .direct

        XCTAssertEqual(configuration.userSelectedTranscribeVariant, .direct)
        XCTAssertEqual(
            AppConfiguration(defaults: defaults).userSelectedTranscribeVariant,
            .direct,
            "and it is still a choice after a relaunch"
        )
    }

    @MainActor
    func testAChosenReviewSurvivesRelaunchAsAChoice() {
        let suiteName = "AppRulesTests.ChoseReview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppConfiguration(defaults: defaults).transcribeVariant = .review

        let relaunched = AppConfiguration(defaults: defaults)
        XCTAssertEqual(relaunched.userSelectedTranscribeVariant, .review)
        XCTAssertEqual(relaunched.transcribeVariant, .review)
    }

    @MainActor
    func testAnUnreadableStoredVariantIsNotAChoice() {
        // The same stored garbage `TranscribeVariantTidyTests` already pins for
        // the non-optional reader. There is no variant to honour here, so there
        // is no choice to respect either — both answers fall out of the one
        // `TranscribeVariant(rawValue:)` parse rather than from two rules that
        // can disagree about the same string.
        let suiteName = "AppRulesTests.GarbageVariant.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("polish", forKey: "transcribeVariant")

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertNil(configuration.userSelectedTranscribeVariant)
        XCTAssertEqual(configuration.transcribeVariant, .direct)
    }

    @MainActor
    func testPerAppRulesAreOnByDefaultAndTheOptOutPersists() {
        // §J's master switch — the argument every function above takes. On by
        // default, because the terminal row closes a reachable destructive path
        // (`ContextBridge.insert` is clipboard + ⌘V, and a dictated newline in a
        // shell is a command) and a safety default nobody finds in Settings
        // protects nobody. Turning it off is one switch away, and section E is
        // what proves that off means *nothing* changes.
        let suiteName = "AppRulesTests.MasterSwitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let configuration = AppConfiguration(defaults: defaults)
        XCTAssertTrue(configuration.perAppRulesEnabled)

        configuration.perAppRulesEnabled = false
        XCTAssertFalse(
            AppConfiguration(defaults: defaults).perAppRulesEnabled,
            "an opt-out that does not survive a relaunch is not an opt-out"
        )
    }
}
