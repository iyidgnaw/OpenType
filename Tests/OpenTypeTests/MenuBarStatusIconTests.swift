import AppKit
import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §L of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — 菜单栏模板图标.
///
/// The finding (`docs/reviews/2026-08-15-product-review.md` §12): the status
/// item is a coloured rounded square whose **fill colour is the only thing that
/// says what the app is doing**, with a mode glyph knocked out of it in white.
/// Three separate problems in one line of code — it breaks the HIG rule that a
/// menu bar extra is a template image, it is one flat shape to a colour-blind
/// user, and a non-template image is drawn as-is over a menu bar that may be
/// light, dark, or translucent over an arbitrary wallpaper.
///
/// The fix is not "pick better colours". It is that **the shape has to carry the
/// state**, because a template image is drawn as a mask: hue does not survive
/// the trip to the menu bar at all. So the thing under test is a pure mapping
///
///     (ProcessingState, InputMode) -> SF Symbol name
///
/// and the property that matters is *injectivity over the states a user has to
/// be able to tell apart*. Colour is checked too, but only to pin that it is now
/// decoration: exactly one state may carry a tint, and it is the one the HIG
/// sanctions (actively recording).
///
/// ## Pinned decision — at rest the icon shows the mode, once busy it shows the state
///
/// The icon has one glyph and two questions to answer. Before the review it
/// answered both at once by spending shape on the mode and colour on the state,
/// which is precisely the thing being removed. It cannot answer both now, so it
/// answers whichever one is live: `.idle`/`.modeChanged` show `mode.symbol` —
/// the same glyph as that mode's card in the popover, which is the existing
/// product decision that the menu bar says which mode the next press will use —
/// and every state where something is actually happening overrides it. This is
/// what `testTheModeIsInvisibleOnceSomethingIsHappening` fixes in place, and it
/// is also what makes `.listening` unable to reuse `mic.fill`: transcribe's mode
/// glyph is already a microphone, so a listening microphone would be
/// indistinguishable from an idle one in the mode people record in most.
///
/// ## Pinned decision — which states are *required* to be distinguishable
///
/// Not all eleven. `transcribing`/`transforming`/`inserting` are three names for
/// "OpenType is working on it" and share one shape on purpose: they last a few
/// hundred milliseconds each, an 18pt mask cannot hold three legible variants of
/// "busy", and a user has no action that depends on which one is current.
/// `success`/`copied` group for the same reason. `idle`/`modeChanged` group
/// because `modeChanged` *is* an announcement of the mode, which is what idle
/// already draws. Every other pair must differ, and
/// `testNoTwoDistinguishableStatesShareAShape` is the assertion that says so —
/// the grouped members are listed there by one representative each, so widening
/// a group later means editing that list rather than quietly weakening it.
///
/// ## Pinned decision — a new `ProcessingState` case must not fall through
///
/// The spec asks that "a new state without an icon is a failure rather than a
/// silent fallback". A test cannot enumerate a state that does not exist yet, so
/// the real guard is a `switch` with **no `default:`** in the implementation —
/// adding a case to `ProcessingState` then fails to build, which is stronger and
/// earlier than a red test. The suite below covers the other half: that every
/// case which exists today has an entry, and that the entry is a real symbol.
final class MenuBarStatusIconTests: XCTestCase {

    /// Every state the icon can be asked to draw, paired with a name for the
    /// failure message. `ProcessingState` carries associated values on three
    /// cases so it cannot be `CaseIterable`; this list is the manual stand-in
    /// and is what the "no case is missing" checks iterate.
    private let allStates: [(name: String, state: ProcessingState)] = [
        ("idle", .idle),
        ("modeChanged", .modeChanged),
        ("listening", .listening),
        ("transcribing", .transcribing),
        ("transforming", .transforming),
        ("inserting", .inserting),
        ("success", .success),
        ("copied", .copied),
        ("dispatched", .dispatched("交给 Agent 了")),
        ("cancelled", .cancelled("未执行")),
        ("failure", .failure("出错了"))
    ]

    // MARK: - The mapping, one assertion per state

    func testIdleShowsTheActiveModeSoTheIconStillSaysWhatTheNextPressWillDo() {
        // `InputMode.symbol` rather than a literal: the menu bar glyph and the
        // popover's mode card have to stay the same shape, and hard-coding the
        // three strings here is how they drift apart.
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .idle, mode: .transcribe),
            InputMode.transcribe.symbol
        )
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .idle, mode: .ask),
            InputMode.ask.symbol
        )
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .idle, mode: .agent),
            InputMode.agent.symbol
        )
    }

    func testModeChangedShowsTheModeItChangedTo() {
        for mode in InputMode.allCases {
            XCTAssertEqual(
                MenuBarStatusIcon.symbolName(for: .modeChanged, mode: mode),
                mode.symbol,
                "a mode announcement should draw the mode it announces (\(mode))"
            )
        }
    }

    func testListeningIsAWaveformAndNeverAMicrophone() {
        for mode in InputMode.allCases {
            XCTAssertEqual(
                MenuBarStatusIcon.symbolName(for: .listening, mode: mode),
                "waveform"
            )
        }
        // The collision this exists to prevent: transcribe's mode glyph is
        // `mic.fill`, so reusing the microphone for "recording" would make the
        // busiest mode's idle and listening states the same picture.
        XCTAssertNotEqual(
            MenuBarStatusIcon.symbolName(for: .listening, mode: .transcribe),
            MenuBarStatusIcon.symbolName(for: .idle, mode: .transcribe)
        )
    }

    func testEveryProcessingStageSharesOneWorkingShape() {
        for mode in InputMode.allCases {
            for state in [ProcessingState.transcribing, .transforming, .inserting] {
                XCTAssertEqual(
                    MenuBarStatusIcon.symbolName(for: state, mode: mode),
                    "ellipsis.circle",
                    "\(state) is one of the three 'working on it' stages"
                )
            }
        }
    }

    func testDeliveredStatesAreACheckmark() {
        for state in [ProcessingState.success, .copied] {
            XCTAssertEqual(
                MenuBarStatusIcon.symbolName(for: state, mode: .transcribe),
                "checkmark"
            )
        }
    }

    func testDispatchedIsItsOwnShapeBecauseNothingHasFinishedYet() {
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .dispatched("走了"), mode: .agent),
            "paperplane.fill"
        )
    }

    func testCancelledAndFailedAreTwoDifferentAnswers() {
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .cancelled("未执行"), mode: .agent),
            "xmark"
        )
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .failure("出错了"), mode: .agent),
            "exclamationmark.triangle.fill"
        )
    }

    func testTheAssociatedMessageNeverChangesTheShape() {
        // The three message-carrying cases must map on the case, not on the
        // string, or an error's wording would move the icon.
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .failure("网络超时"), mode: .ask),
            MenuBarStatusIcon.symbolName(for: .failure(""), mode: .ask)
        )
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .cancelled("a"), mode: .ask),
            MenuBarStatusIcon.symbolName(for: .cancelled("b"), mode: .ask)
        )
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .dispatched("a"), mode: .ask),
            MenuBarStatusIcon.symbolName(for: .dispatched("b"), mode: .ask)
        )
    }

    func testTheModeIsInvisibleOnceSomethingIsHappening() {
        // Every state except the two that *are* the mode announcement resolves
        // to one shape regardless of mode. Otherwise "what is it doing" would
        // still need the user to remember which mode they were in.
        let busy: [ProcessingState] = [
            .listening, .transcribing, .transforming, .inserting,
            .success, .copied, .dispatched("x"), .cancelled("x"), .failure("x")
        ]
        for state in busy {
            let names = Set(
                InputMode.allCases.map {
                    MenuBarStatusIcon.symbolName(for: state, mode: $0)
                }
            )
            XCTAssertEqual(
                names.count,
                1,
                "\(state) draws differently per mode, so the shape no longer means one thing"
            )
        }
    }

    // MARK: - The actual product requirement: shape, not colour, separates states

    func testNoTwoDistinguishableStatesShareAShape() {
        // One representative per deliberate group (see the type doc), crossed
        // with mode for the two states that render the mode. Anything that
        // collides here is a state the user cannot read off the menu bar.
        let required: [(String, String)] = [
            ("idle · transcribe", MenuBarStatusIcon.symbolName(for: .idle, mode: .transcribe)),
            ("idle · ask", MenuBarStatusIcon.symbolName(for: .idle, mode: .ask)),
            ("idle · agent", MenuBarStatusIcon.symbolName(for: .idle, mode: .agent)),
            ("listening", MenuBarStatusIcon.symbolName(for: .listening, mode: .transcribe)),
            ("processing", MenuBarStatusIcon.symbolName(for: .transcribing, mode: .transcribe)),
            ("delivered", MenuBarStatusIcon.symbolName(for: .success, mode: .transcribe)),
            ("dispatched", MenuBarStatusIcon.symbolName(for: .dispatched("x"), mode: .agent)),
            ("cancelled", MenuBarStatusIcon.symbolName(for: .cancelled("x"), mode: .agent)),
            ("failure", MenuBarStatusIcon.symbolName(for: .failure("x"), mode: .agent))
        ]
        let names = required.map(\.1)
        XCTAssertEqual(
            Set(names).count,
            required.count,
            "two states share a glyph: \(required.map { "\($0.0)=\($0.1)" }.joined(separator: ", "))"
        )
    }

    func testTheThreeStatesTheReviewNamesAreDistinctInEveryMode() {
        // 「idle 点 / listening 波形 / processing 齿轮或进度」 — the spec's own
        // triple. It has to hold per mode, because idle is the one that varies.
        for mode in InputMode.allCases {
            let triple = [
                MenuBarStatusIcon.symbolName(for: .idle, mode: mode),
                MenuBarStatusIcon.symbolName(for: .listening, mode: mode),
                MenuBarStatusIcon.symbolName(for: .transcribing, mode: mode)
            ]
            XCTAssertEqual(Set(triple).count, 3, "idle/listening/processing collide in \(mode)")
        }
    }

    func testEverySymbolResolvesToARealSFSymbol() {
        // A typo'd symbol name is not a crash — `NSImage(systemSymbolName:)`
        // just answers nil and the menu bar shows an empty square. This is the
        // check that turns that into a test failure.
        for mode in InputMode.allCases {
            for entry in allStates {
                let name = MenuBarStatusIcon.symbolName(for: entry.state, mode: mode)
                XCTAssertNotNil(
                    NSImage(systemSymbolName: name, accessibilityDescription: nil),
                    "\(entry.name)/\(mode) maps to \"\(name)\", which is not an SF Symbol"
                )
            }
        }
    }

    // MARK: - Rendered masks

    func testTheIconIsATemplateImageInEveryState() {
        for mode in InputMode.allCases {
            for entry in allStates {
                let image = MenuBarStatusIcon.image(for: entry.state, mode: mode)
                XCTAssertTrue(
                    image.isTemplate,
                    "\(entry.name)/\(mode) is not a template image"
                )
            }
        }
    }

    func testTheIconIsDrawnAtMenuBarSize() {
        let image = MenuBarStatusIcon.image(for: .idle, mode: .transcribe)
        XCTAssertEqual(image.size, NSSize(width: 18, height: 18))
    }

    func testTheRequiredStatesRenderAsVisiblyDifferentMasksAtMenuBarSize() {
        // The one check that tests the actual claim rather than the mapping
        // that implements it: rasterise each icon at menu-bar size, throw away
        // everything but the alpha channel — which is all a template image is —
        // and confirm the masks differ. Colour is not merely unused here, it is
        // not present in the data being compared.
        let subjects: [(String, NSImage)] = [
            ("idle · transcribe", MenuBarStatusIcon.image(for: .idle, mode: .transcribe)),
            ("idle · ask", MenuBarStatusIcon.image(for: .idle, mode: .ask)),
            ("idle · agent", MenuBarStatusIcon.image(for: .idle, mode: .agent)),
            ("listening", MenuBarStatusIcon.image(for: .listening, mode: .transcribe)),
            ("processing", MenuBarStatusIcon.image(for: .transcribing, mode: .transcribe)),
            ("failure", MenuBarStatusIcon.image(for: .failure("x"), mode: .transcribe))
        ]
        let masks = subjects.map { ($0.0, alphaMask(of: $0.1)) }

        for mask in masks {
            XCTAssertTrue(
                mask.1.contains { $0 > 8 },
                "\(mask.0) rendered as an empty mask — nothing would appear in the menu bar"
            )
        }

        for i in masks.indices {
            for j in masks.indices where j > i {
                let difference = maskDifference(masks[i].1, masks[j].1)
                // 8% of the 36×36 grid is ~104 pixels. Two glyphs that differ
                // by less than that are the same picture as far as a glance at
                // the menu bar is concerned.
                XCTAssertGreaterThan(
                    difference,
                    0.08,
                    "\(masks[i].0) and \(masks[j].0) render as near-identical masks (\(difference))"
                )
            }
        }
    }

    func testTheRunningAgentBadgeChangesTheMaskWithoutChangingTheState() {
        // The badge is an additional mark, not a state: it must be visible in
        // the mask, and it must not disturb the glyph that encodes the state.
        let plain = MenuBarStatusIcon.image(for: .idle, mode: .agent)
        let badged = MenuBarStatusIcon.image(for: .idle, runningAgentCount: 2, mode: .agent)
        XCTAssertTrue(badged.isTemplate)
        XCTAssertEqual(badged.size, plain.size)
        XCTAssertGreaterThan(
            maskDifference(alphaMask(of: plain), alphaMask(of: badged)),
            0.005,
            "a running Agent task leaves no visible mark on the icon"
        )
        XCTAssertEqual(
            MenuBarStatusIcon.symbolName(for: .idle, mode: .agent),
            "wand.and.stars",
            "the badge must not be implemented by swapping the state glyph"
        )
    }

    // MARK: - Colour is now decoration, and only in the one sanctioned place

    func testOnlyActiveRecordingCarriesATint() {
        // The HIG's one exception. Everything else renders as the plain
        // template so it inverts with the menu bar and with menu highlighting.
        XCTAssertEqual(MenuBarStatusIcon.tint(for: .listening), AppAccent.nsPrimary)
        for entry in allStates where entry.name != "listening" {
            XCTAssertNil(
                MenuBarStatusIcon.tint(for: entry.state),
                "\(entry.name) still tints the menu bar icon"
            )
        }
    }

    func testTheTintIsTheAppsOneAccentRatherThanANewColour() {
        // `AppAccent` is the single accent the whole product uses (the six-way
        // theme picker was deleted); a second literal colour here would be a
        // second palette nobody else reads.
        XCTAssertEqual(MenuBarStatusIcon.tint(for: .listening), AppAccent.nsPrimary)
    }

    // MARK: - What the shape means, said in words

    func testTheAccessibilityDescriptionNamesBothTheModeAndTheState() {
        // Shape is a picture; VoiceOver and the tooltip are where the same
        // information exists as text. Both halves have to be in it, since the
        // picture now encodes whichever one is live rather than both.
        let description = MenuBarStatusIcon.accessibilityDescription(
            for: .listening,
            mode: .ask,
            runningAgentCount: 0
        )
        XCTAssertTrue(description.contains("OpenType"), description)
        XCTAssertTrue(description.contains(InputMode.ask.title), description)
        XCTAssertTrue(description.contains(ProcessingState.listening.title), description)
    }

    func testTheAccessibilityDescriptionCountsRunningAgentTasks() {
        // The badge is a dot with no numeral (18pt cannot hold a legible one in
        // a mask), so the count has to survive somewhere. This is where.
        let none = MenuBarStatusIcon.accessibilityDescription(
            for: .idle,
            mode: .agent,
            runningAgentCount: 0
        )
        XCTAssertFalse(none.contains("0"), none)

        let three = MenuBarStatusIcon.accessibilityDescription(
            for: .idle,
            mode: .agent,
            runningAgentCount: 3
        )
        XCTAssertTrue(three.contains("3"), three)
    }

    func testEveryStateAndModeProducesANonEmptyDescription() {
        for mode in InputMode.allCases {
            for entry in allStates {
                let description = MenuBarStatusIcon.accessibilityDescription(
                    for: entry.state,
                    mode: mode,
                    runningAgentCount: 0
                )
                XCTAssertFalse(
                    description.isEmpty,
                    "\(entry.name)/\(mode) has no spoken description"
                )
            }
        }
    }

    func testTheImageCarriesTheDescriptionItWasBuiltWith() {
        let image = MenuBarStatusIcon.image(for: .listening, mode: .ask)
        XCTAssertEqual(
            image.accessibilityDescription,
            MenuBarStatusIcon.accessibilityDescription(
                for: .listening,
                mode: .ask,
                runningAgentCount: 0
            )
        )
    }

    // MARK: - Helpers

    /// Rasterises `image` at the menu bar's 18pt in 2× and returns its alpha
    /// channel. A template image *is* its alpha channel — AppKit throws the
    /// colour away and re-fills the mask — so comparing anything else would be
    /// comparing something the user never sees.
    private func alphaMask(of image: NSImage, scale: Int = 2) -> [UInt8] {
        let side = 18 * scale
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side,
            pixelsHigh: side,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            XCTFail("could not build a bitmap to rasterise into")
            return []
        }
        // Declaring the rep's *point* size is what makes the context 2×. Without
        // it the bitmap is a 36-point canvas and an 18-point draw lands in one
        // quadrant of it at 1×, which is a quiet way to compare quarter-size
        // renders and call the difference small.
        representation.size = NSSize(width: 18, height: 18)
        guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
            XCTFail("could not build a drawing context")
            return []
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.set()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 18, height: 18),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        var alpha: [UInt8] = []
        alpha.reserveCapacity(side * side)
        for y in 0..<side {
            for x in 0..<side {
                alpha.append(
                    representation.colorAt(x: x, y: y).map {
                        UInt8(($0.alphaComponent * 255).rounded())
                    } ?? 0
                )
            }
        }
        return alpha
    }

    /// Fraction of pixels whose coverage differs enough to be seen. The 32/255
    /// floor ignores antialiasing along shared edges, which is noise rather
    /// than a difference in shape.
    private func maskDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return 0 }
        let differing = zip(lhs, rhs).reduce(into: 0) { total, pair in
            if abs(Int(pair.0) - Int(pair.1)) > 32 { total += 1 }
        }
        return Double(differing) / Double(lhs.count)
    }
}
