import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for the Agent progress panel's Swift half
/// (spec: docs/superpowers/specs/2026-08-13-agent-progress-panel-design.md §2,
/// "Swift side").
///
/// Contract picks made by this test file (stage 3 implements them exactly);
/// precedents: `AskPanelState` for the state struct, `OverlayHideBehavior` /
/// `OverlayController.hideBehavior(for:)` for pure static functions on an
/// AppKit-adjacent controller.
///
/// - `AgentProgressPanelState` (Models.swift), `Equatable`, memberwise
///   construction with `runId: String`, `task: String`,
///   `steps: [AgentProgressStep]`, `phase: Phase`, `result: String?`.
///   `Phase` is a nested `Equatable` enum with exactly the spec's three
///   cases: `.running`, `.succeeded`, `.failed`.
/// - `AgentProgressStep` (Models.swift), `Equatable`, with `kind: Kind`
///   (nested `Equatable` enum: `.thinking`, `.toolCall`, `.toolResult`,
///   `.error`) and `detail: String`.
/// - `SidecarAgentProgressEvent` (Models.swift): the wire shape of one entry
///   from `GET /agent/progress/:runId` — `type: String`, `detail: String`,
///   memberwise-constructible (the client will decode JSON into it).
/// - Step mapping is the pure static function
///   `AgentProgressPanelState.steps(fromProgressEvents: [SidecarAgentProgressEvent]) -> [AgentProgressStep]`:
///   "thinking"/"tool_call"/"tool_result"/"error" map to the matching kinds
///   with details preserved, "done" events are NOT shown as steps (the
///   `result` field covers them), unknown type strings are dropped, and
///   relative order is preserved.
/// - Panel geometry was the pure static function
///   `AgentProgressPanelController.panelOrigin(visibleFrame:panelSize:)`
///   (top-right of `visibleFrame`, 16pt margin). **Retired**: the HUD-morph
///   spec supersedes this spec's presentation layer, and the geometry seam is
///   now `VoiceSurfacePanelLayout.frame(for:visibleFrame:)` in
///   `VoiceSurfaceTests` — see the note where those two tests used to live.
/// - The polling decision is the pure static function
///   `AgentProgressPanelState.shouldContinuePolling(for: Phase) -> Bool`:
///   `.running` → true, `.succeeded`/`.failed` → false.
///
/// These tests are RED until stage 3 adds the types above: none of the new
/// symbols exist yet, so this file fails to COMPILE — which makes the whole
/// test target red. That is the intended red state; every compile error must
/// reference only the new symbols named here.
@MainActor
final class AgentProgressPanelTests: XCTestCase {

    // MARK: - AgentProgressPanelState: construction, fields, equality

    func testStateConstructionCarriesAllFields() {
        let step = AgentProgressStep(kind: .toolCall, detail: "Calling search__lookup(...)")
        let state = AgentProgressPanelState(
            runId: "run-abc",
            task: "帮我总结这份文档",
            steps: [step],
            phase: .running,
            result: nil
        )

        XCTAssertEqual(state.runId, "run-abc")
        XCTAssertEqual(state.task, "帮我总结这份文档")
        XCTAssertEqual(state.steps, [step])
        XCTAssertEqual(state.phase, .running)
        XCTAssertNil(state.result)
    }

    func testStateEqualityForIdenticalValues() {
        func make() -> AgentProgressPanelState {
            AgentProgressPanelState(
                runId: "run-1",
                task: "task",
                steps: [AgentProgressStep(kind: .thinking, detail: "Thinking...")],
                phase: .succeeded,
                result: "final answer"
            )
        }
        XCTAssertEqual(make(), make())
    }

    func testStateInequalityWhenPhaseDiffers() {
        let running = AgentProgressPanelState(
            runId: "run-1", task: "task", steps: [], phase: .running, result: nil
        )
        let failed = AgentProgressPanelState(
            runId: "run-1", task: "task", steps: [], phase: .failed, result: nil
        )
        XCTAssertNotEqual(running, failed)
    }

    func testStateInequalityWhenStepsDiffer() {
        let empty = AgentProgressPanelState(
            runId: "run-1", task: "task", steps: [], phase: .running, result: nil
        )
        let withStep = AgentProgressPanelState(
            runId: "run-1",
            task: "task",
            steps: [AgentProgressStep(kind: .toolResult, detail: "sunny, 75F")],
            phase: .running,
            result: nil
        )
        XCTAssertNotEqual(empty, withStep)
    }

    func testPhaseHasThreeDistinctCases() {
        let phases: [AgentProgressPanelState.Phase] = [.running, .succeeded, .failed]
        XCTAssertNotEqual(phases[0], phases[1])
        XCTAssertNotEqual(phases[1], phases[2])
        XCTAssertNotEqual(phases[0], phases[2])
    }

    func testStepCarriesKindAndDetail() {
        let step = AgentProgressStep(kind: .error, detail: "Error calling tool x: boom")
        XCTAssertEqual(step.kind, .error)
        XCTAssertEqual(step.detail, "Error calling tool x: boom")
    }

    // MARK: - Step mapping from sidecar progress events

    func testMappingConvertsKnownTypesInOrderPreservingDetails() {
        let events = [
            SidecarAgentProgressEvent(type: "thinking", detail: "Thinking (step 1/10)..."),
            SidecarAgentProgressEvent(type: "tool_call", detail: "Calling search__lookup({\"q\":\"x\"})"),
            SidecarAgentProgressEvent(type: "tool_result", detail: "sunny, 75F"),
            SidecarAgentProgressEvent(type: "error", detail: "Error calling tool x: boom"),
        ]

        let steps = AgentProgressPanelState.steps(fromProgressEvents: events)

        XCTAssertEqual(steps, [
            AgentProgressStep(kind: .thinking, detail: "Thinking (step 1/10)..."),
            AgentProgressStep(kind: .toolCall, detail: "Calling search__lookup({\"q\":\"x\"})"),
            AgentProgressStep(kind: .toolResult, detail: "sunny, 75F"),
            AgentProgressStep(kind: .error, detail: "Error calling tool x: boom"),
        ])
    }

    func testMappingDropsDoneEvents() {
        let events = [
            SidecarAgentProgressEvent(type: "thinking", detail: "Thinking (step 1/10)..."),
            SidecarAgentProgressEvent(type: "done", detail: "the final answer"),
        ]

        let steps = AgentProgressPanelState.steps(fromProgressEvents: events)

        XCTAssertEqual(steps, [AgentProgressStep(kind: .thinking, detail: "Thinking (step 1/10)...")])
    }

    func testMappingDropsUnknownTypesButKeepsSurroundingOrder() {
        let events = [
            SidecarAgentProgressEvent(type: "tool_call", detail: "Calling a()"),
            SidecarAgentProgressEvent(type: "telemetry", detail: "not a real step type"),
            SidecarAgentProgressEvent(type: "tool_result", detail: "ok"),
        ]

        let steps = AgentProgressPanelState.steps(fromProgressEvents: events)

        XCTAssertEqual(steps, [
            AgentProgressStep(kind: .toolCall, detail: "Calling a()"),
            AgentProgressStep(kind: .toolResult, detail: "ok"),
        ])
    }

    func testMappingEmptyInputYieldsEmptySteps() {
        XCTAssertEqual(AgentProgressPanelState.steps(fromProgressEvents: []), [])
    }

    // MARK: - Panel geometry
    //
    // The two `AgentProgressPanelController.panelOrigin` tests that lived here
    // (top-right of `visibleFrame` with a 16pt margin) were retired together
    // with the top-right window itself: the HUD-morph spec
    // (docs/superpowers/specs/2026-08-13-hud-morph-result-surface-design.md §2)
    // supersedes this spec's *presentation* layer, folding the Agent progress
    // feed into the one bottom-center voice surface. `panelOrigin` no longer
    // exists; the replacement geometry coverage is
    // `VoiceSurfaceTests`' "Frame math: bottom-anchored growth" section
    // (`VoiceSurfacePanelLayout.frame(for:visibleFrame:)`). Everything else in
    // this file — the state model, the step mapping, the polling decision — is
    // transport/state infrastructure the new spec explicitly retains and reuses.

    // MARK: - Polling decision (pure static)

    func testPollingContinuesWhileRunning() {
        XCTAssertTrue(AgentProgressPanelState.shouldContinuePolling(for: .running))
    }

    func testPollingStopsWhenSucceeded() {
        XCTAssertFalse(AgentProgressPanelState.shouldContinuePolling(for: .succeeded))
    }

    func testPollingStopsWhenFailed() {
        XCTAssertFalse(AgentProgressPanelState.shouldContinuePolling(for: .failed))
    }
}
