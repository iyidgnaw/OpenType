import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for P1-19: the first-run onboarding wizard traps
/// a transcribe-only user.
///
/// Today the decision lives inline in `AppModel.needsProviderOnboarding`
/// (`Sources/OpenType/AppModel.swift:104`) as `providerConfigStatus.map { !$0.ready }`,
/// where the sidecar computes `ready = llmConfigured && whisperConfigured`
/// (`sidecar/src/provider/routes.ts:93`). Because `ready` requires BOTH, a user
/// who only wants local transcription (`transcribe` mode makes no LLM call at
/// all) is forced to configure an LLM provider just to get past the wizard and
/// into the app -- `RootView` (`Views.swift:62-95`) replaces every tab and hides
/// the tab bar until `needsProviderOnboarding` is false.
///
/// The fix extracts the gating decision into a pure, testable seam,
/// `OnboardingPolicy.needsProviderOnboarding(...)`, and changes the truth table
/// so that speech recognition being ready (or the user explicitly choosing the
/// "just local transcription, skip AI setup" path) is enough to enter the app.
/// LLM configuration is deferred: `ask`/`agent` prompt for it later, when a mode
/// that actually needs an LLM is used.
///
/// Desired truth table (`needs == !(localTranscriptionOnlyAcknowledged || whisperConfigured)`):
///
///   whisper | llm | ack  | needsOnboarding
///   --------+-----+------+----------------
///     false | false| false| true   <- brand-new install, must set something up
///     false | false| true | false  <- user chose "local only, skip AI"
///     false | true | false| true   <- LLM alone can't record; still needs ASR
///     false | true | true | false  <- ack wins over everything
///     true  | false| false| false  <- TRANSCRIBE-ONLY READY (the P1-19 fix)
///     true  | false| true | false
///     true  | true | false| false  <- fully configured
///     true  | true | true | false
///
/// Every test asserts the DESIRED behavior and is expected to FAIL to compile
/// (`OnboardingPolicy` does not exist yet) until Stage 3 introduces the seam and
/// rewires `AppModel.needsProviderOnboarding` to call it.
final class OnboardingPolicyTests: XCTestCase {

    // MARK: - The P1-19 fix: transcribe-only user is not trapped

    /// The core regression: speech recognition is configured but no LLM is.
    /// A transcribe-only user must be able to reach the app without being
    /// forced through LLM setup.
    func testWhisperReadyWithoutLLMDoesNotRequireOnboarding() {
        let needs = OnboardingPolicy.needsProviderOnboarding(
            whisperConfigured: true,
            llmConfigured: false,
            localTranscriptionOnlyAcknowledged: false
        )
        XCTAssertFalse(
            needs,
            "A transcribe-only user (whisper ready, no LLM) must not be trapped in the wizard"
        )
    }

    // MARK: - Acknowledged local-only path wins regardless of LLM

    func testAcknowledgedLocalOnlyWithNothingConfiguredSkipsOnboarding() {
        let needs = OnboardingPolicy.needsProviderOnboarding(
            whisperConfigured: false,
            llmConfigured: false,
            localTranscriptionOnlyAcknowledged: true
        )
        XCTAssertFalse(
            needs,
            "Choosing 'just local transcription, skip AI setup' must let the user into the app"
        )
    }

    func testAcknowledgedLocalOnlyWithLLMConfiguredSkipsOnboarding() {
        let needs = OnboardingPolicy.needsProviderOnboarding(
            whisperConfigured: false,
            llmConfigured: true,
            localTranscriptionOnlyAcknowledged: true
        )
        XCTAssertFalse(needs, "Acknowledgment overrides LLM state entirely")
    }

    // MARK: - Fully configured / whisper-ready => no onboarding

    func testFullyConfiguredSkipsOnboarding() {
        let needs = OnboardingPolicy.needsProviderOnboarding(
            whisperConfigured: true,
            llmConfigured: true,
            localTranscriptionOnlyAcknowledged: false
        )
        XCTAssertFalse(needs, "Both providers configured: nothing to onboard")
    }

    // MARK: - Nothing set up and not acknowledged => onboarding required

    func testNothingConfiguredAndNotAcknowledgedRequiresOnboarding() {
        let needs = OnboardingPolicy.needsProviderOnboarding(
            whisperConfigured: false,
            llmConfigured: false,
            localTranscriptionOnlyAcknowledged: false
        )
        XCTAssertTrue(
            needs,
            "Brand-new install with nothing set up must enter the wizard"
        )
    }

    /// An LLM configured on its own is NOT enough to enter the app: every mode
    /// (including transcribe/ask/agent) needs speech recognition, so the wizard
    /// still shows until whisper is ready or the local-only path is acknowledged.
    func testLLMConfiguredButNoWhisperAndNotAcknowledgedStillRequiresOnboarding() {
        let needs = OnboardingPolicy.needsProviderOnboarding(
            whisperConfigured: false,
            llmConfigured: true,
            localTranscriptionOnlyAcknowledged: false
        )
        XCTAssertTrue(
            needs,
            "LLM alone can't capture speech; ASR must still be set up (or local-only acknowledged)"
        )
    }

    // MARK: - Exhaustive truth table

    /// Locks in the full decision across all 8 input combinations so a Stage-3
    /// implementation can't accidentally satisfy the named cases while getting a
    /// corner wrong. The rule is exactly: onboarding is required iff neither the
    /// local-only path was acknowledged nor whisper is configured.
    func testExhaustiveTruthTable() {
        for whisper in [false, true] {
            for llm in [false, true] {
                for ack in [false, true] {
                    let expected = !(ack || whisper)
                    let actual = OnboardingPolicy.needsProviderOnboarding(
                        whisperConfigured: whisper,
                        llmConfigured: llm,
                        localTranscriptionOnlyAcknowledged: ack
                    )
                    XCTAssertEqual(
                        actual,
                        expected,
                        "whisper=\(whisper) llm=\(llm) ack=\(ack) should give needs=\(expected)"
                    )
                }
            }
        }
    }
}
