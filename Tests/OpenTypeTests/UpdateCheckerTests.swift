import XCTest
@testable import OpenType

/// Stage-1 (TDD red) coverage for §B of
/// `docs/superpowers/specs/2026-08-15-product-batch-plan.md` — update checking
/// without Sparkle.
///
/// Why it exists (`docs/reviews/2026-08-15-product-review.md` §4): 1.0.0 ships
/// through a one-shot `curl … | zsh` installer, so today every bug in 1.0.0
/// stays on every installed machine forever. This feature does **not** update
/// anything — it only learns that a newer release exists and tells the user, who
/// re-runs the (idempotent) install command themselves.
///
/// Every test below asserts the DESIRED behavior and is expected to FAIL TO
/// COMPILE until Stage 3 creates `Sources/OpenType/UpdateChecker.swift`. That is
/// the correct red for a Swift feature whose types do not exist yet: nothing is
/// stubbed into this file, and no production file is created here.
///
/// # Production API this file pins
///
/// ```swift
/// func compareVersions(_ a: String, _ b: String) -> ComparisonResult
///
/// enum UpdateCheckOutcome: Equatable {
///     case upToDate
///     case updateAvailable(version: String, url: String)
///     case unknown
///     static func from(local: String, latest: String, url: String) -> UpdateCheckOutcome
/// }
///
/// enum UpdatePromptPolicy {
///     static func shouldAnnounce(_ outcome: UpdateCheckOutcome, lastSeenVersion: String?) -> Bool
/// }
///
/// actor UpdateChecker {
///     init(localVersion: String, fetch: @escaping @Sendable (URL) async throws -> (Data, Int))
///     func check() async -> UpdateCheckOutcome   // non-throwing on purpose
/// }
/// ```
///
/// Three decisions this file makes on Stage 3's behalf, deliberately:
///
/// 1. **The network call is injected as a closure returning `(Data, statusCode)`**,
///    not a `URLSession`/`URLResponse` pair. No test may touch the network, and
///    a bare status code keeps the seam free of `URLResponse`'s Sendable
///    awkwardness while still letting a test drive the 404/500 branches.
/// 2. **`check()` cannot throw.** The spec is explicit that failure is
///    completely silent (`失败完全静默（.unknown），不弹任何东西`), so the
///    absence of `throws` in the signature is itself the assertion — a network
///    blip must not be expressible as something a caller has to handle.
/// 3. **`.updateAvailable` carries the *display* version, `v`-prefix stripped.**
///    GitHub tags are `v1.1.0`; the UI copy is 「有新版本 1.1.0」. Normalising at
///    the boundary means no call site has to remember to strip it, and it makes
///    `lastSeenUpdateVersion` round-trip cleanly through `shouldAnnounce`.
///
/// One consequence worth stating up front, because it rules out the shortest
/// implementation: **`UpdateCheckOutcome.from` cannot be `switch
/// compareVersions(local, latest)`.** `compareVersions` is total — it answers
/// for every pair of strings, and the tests only require that its answer for
/// nonsense be antisymmetric, not what that answer is. `from`, by contrast, must
/// return `.unknown` for an unparseable input rather than any ordering. So the
/// two need a shared "is this a version at all?" parse, and `from` has to
/// consult it before it compares.
///
/// Left deliberately unspecified (Stage 3's call, no test constrains it):
///
/// - What a release payload with a valid `tag_name` but a missing `html_url`
///   should do — falling back to the repo's releases page and returning
///   `.unknown` are both defensible, and pinning it here would be inventing
///   product policy.
/// - Which direction `compareVersions` orders two unparseable strings, or an
///   unparseable string against a real version. Only antisymmetry is required.
/// - Whether `lastSeenVersion` arrives as `nil` or `""` when nothing has been
///   seen. Both are covered as "announce", so either storage shape works.
final class UpdateCheckerTests: XCTestCase {

    // MARK: - Helpers

    private func inverted(_ result: ComparisonResult) -> ComparisonResult {
        switch result {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private func describe(_ result: ComparisonResult) -> String {
        switch result {
        case .orderedAscending: return "<"
        case .orderedDescending: return ">"
        case .orderedSame: return "=="
        }
    }

    /// Asserts an ordering **and** its antisymmetry: swapping the arguments must
    /// invert the answer. A comparator that gets one direction right and the
    /// other wrong is the failure mode that silently produces both "you're up to
    /// date" and "update available" for the same pair of versions.
    private func assertOrder(
        _ a: String,
        _ b: String,
        _ expected: ComparisonResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            compareVersions(a, b),
            expected,
            "expected \"\(a)\" \(describe(expected)) \"\(b)\"",
            file: file,
            line: line
        )
        XCTAssertEqual(
            compareVersions(b, a),
            inverted(expected),
            "compareVersions is not antisymmetric for (\"\(a)\", \"\(b)\")",
            file: file,
            line: line
        )
    }

    /// For inputs whose absolute ordering is not specified (garbage, two
    /// pre-releases of the same version): whatever the comparator decides, it
    /// must decide antisymmetrically, and it must not crash. Deliberately says
    /// nothing about *which* direction — pinning that here would invent a
    /// semantics for nonsense that no caller depends on.
    private func assertAntisymmetric(
        _ a: String,
        _ b: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            compareVersions(b, a),
            inverted(compareVersions(a, b)),
            "compareVersions is not antisymmetric for (\"\(a)\", \"\(b)\")",
            file: file,
            line: line
        )
    }

    // MARK: - compareVersions: equality and ordinary ordering

    func testIdenticalVersionsCompareEqual() {
        assertOrder("1.0.0", "1.0.0", .orderedSame)
        assertOrder("2.13.7", "2.13.7", .orderedSame)
        assertOrder("0.0.1", "0.0.1", .orderedSame)
    }

    func testOrdinaryAscendingOrdering() {
        assertOrder("1.0.0", "1.1.0", .orderedAscending)
        assertOrder("1.1.0", "2.0.0", .orderedAscending)
        assertOrder("1.0.0", "2.0.0", .orderedAscending)
        assertOrder("1.0.0", "1.0.1", .orderedAscending)
    }

    /// Major beats minor beats patch: a bigger minor never rescues a smaller
    /// major.
    func testComponentSignificanceIsMajorThenMinorThenPatch() {
        assertOrder("1.99.99", "2.0.0", .orderedAscending)
        assertOrder("1.2.99", "1.3.0", .orderedAscending)
    }

    // MARK: - compareVersions: `v` prefix (GitHub tags carry it)

    func testLeadingVPrefixIsToleratedOnEitherSide() {
        assertOrder("v1.1.0", "1.1.0", .orderedSame)
        assertOrder("v1.1.0", "v1.1.0", .orderedSame)
        assertOrder("1.0.0", "v1.1.0", .orderedAscending)
        assertOrder("v1.0.0", "1.1.0", .orderedAscending)
        assertOrder("v2.0.0", "1.9.9", .orderedDescending)
    }

    // MARK: - compareVersions: missing components

    func testMissingPatchComponentIsTreatedAsZero() {
        assertOrder("1.0", "1.0.0", .orderedSame)
        assertOrder("1", "1.0.0", .orderedSame)
        assertOrder("v1.2", "1.2.0", .orderedSame)
    }

    /// The pairing that catches "pad with zero" done wrong: `1.1` must beat
    /// `1.0.9` because the comparison stops at the first differing component.
    func testShorterVersionCanStillBeGreater() {
        assertOrder("1.1", "1.0.9", .orderedDescending)
        assertOrder("2", "1.9.9", .orderedDescending)
        assertOrder("1.0", "1.0.1", .orderedAscending)
    }

    // MARK: - compareVersions: numeric, NOT lexicographic
    //
    // The classic defect. String comparison says "1.10.0" < "1.9.0" and
    // "0.2.0" > "0.10.0"; both are wrong, and both silently stop announcing
    // updates the moment a component reaches double digits.

    /// `assertOrder` checks both directions, so each line here also pins the
    /// mirror image: `1.10.0 > 1.9.0` carries `1.9.0 < 1.10.0` with it, and
    /// `0.10.0 > 0.2.0` carries `0.2.0 < 0.10.0` — i.e. the two orderings a
    /// string comparison gets backwards are each nailed from both sides.
    func testDoubleDigitComponentsCompareNumericallyNotLexicographically() {
        assertOrder("1.10.0", "1.9.0", .orderedDescending)
        assertOrder("0.10.0", "0.2.0", .orderedDescending)
        assertOrder("1.0.10", "1.0.9", .orderedDescending)
        assertOrder("10.0.0", "9.9.9", .orderedDescending)
        assertOrder("1.100.0", "1.99.0", .orderedDescending)
    }

    /// Leading zeros are still just numbers.
    func testLeadingZerosInComponentsAreNumeric() {
        assertOrder("1.01.0", "1.1.0", .orderedSame)
        assertOrder("1.007.0", "1.7.0", .orderedSame)
    }

    // MARK: - compareVersions: pre-release suffixes

    /// Semver's rule, and the one that matters here: a pre-release sorts BEFORE
    /// the release it leads up to. Getting this backwards would tell someone
    /// running 1.1.0 that 1.1.0-beta is an upgrade.
    func testPreReleaseSortsBeforeItsRelease() {
        assertOrder("1.1.0-beta", "1.1.0", .orderedAscending)
        assertOrder("1.1.0-alpha", "1.1.0", .orderedAscending)
        assertOrder("2.0.0-rc.1", "2.0.0", .orderedAscending)
        assertOrder("v1.1.0-beta", "v1.1.0", .orderedAscending)
    }

    /// A pre-release of a *higher* version still beats the lower release.
    func testPreReleaseOfHigherVersionStillOutranksLowerRelease() {
        assertOrder("1.1.0-beta", "1.0.0", .orderedDescending)
        assertOrder("2.0.0-alpha", "1.9.9", .orderedDescending)
    }

    /// Two pre-releases of the same version: the brief requires only that the
    /// ordering be deterministic (semver's lexicographic identifier comparison
    /// satisfies this, and so does treating every pre-release as equal rank).
    func testTwoPreReleasesOfTheSameVersionAreOrderedDeterministically() {
        assertAntisymmetric("1.1.0-alpha", "1.1.0-beta")
        assertAntisymmetric("2.0.0-rc.1", "2.0.0-rc.2")
    }

    func testIdenticalPreReleasesCompareEqual() {
        assertOrder("1.1.0-beta", "1.1.0-beta", .orderedSame)
        assertOrder("v1.1.0-beta.2", "1.1.0-beta.2", .orderedSame)
    }

    // MARK: - compareVersions: garbage never crashes

    /// The comparator is fed whatever a GitHub tag happens to say, so it has to
    /// survive nonsense. It must not trap, and it must stay self-consistent;
    /// what it must never do is *claim an update*, which is asserted at the
    /// `UpdateCheckOutcome.from` layer below.
    func testGarbageInputDoesNotCrashAndStaysConsistent() {
        assertAntisymmetric("", "1.0.0")
        assertAntisymmetric("abc", "1.0.0")
        assertAntisymmetric("1.-.3", "1.0.0")
        assertAntisymmetric("", "")
        assertAntisymmetric("abc", "def")
        assertAntisymmetric("...", "1.0.0")
        assertAntisymmetric("v", "1.0.0")
        assertAntisymmetric("1.0.0", "🚀")
    }

    func testIdenticalGarbageStringsCompareEqual() {
        XCTAssertEqual(compareVersions("", ""), .orderedSame)
        XCTAssertEqual(compareVersions("abc", "abc"), .orderedSame)
        XCTAssertEqual(compareVersions("1.-.3", "1.-.3"), .orderedSame)
    }

    // MARK: - UpdateCheckOutcome.from

    private static let releaseURL = "https://github.com/iyidgnaw/OpenType/releases/tag/v1.1.0"

    func testFromReportsUpdateAvailableWhenLatestIsNewer() {
        let outcome = UpdateCheckOutcome.from(
            local: "1.0.0",
            latest: "1.1.0",
            url: Self.releaseURL
        )
        XCTAssertEqual(
            outcome,
            .updateAvailable(version: "1.1.0", url: Self.releaseURL)
        )
    }

    /// GitHub tags carry the `v`; the announced version must not, because it
    /// goes straight into 「有新版本 \(version)」 and into `lastSeenUpdateVersion`.
    func testFromStripsTheTagPrefixFromTheAnnouncedVersion() {
        let outcome = UpdateCheckOutcome.from(
            local: "1.0.0",
            latest: "v1.1.0",
            url: Self.releaseURL
        )
        XCTAssertEqual(
            outcome,
            .updateAvailable(version: "1.1.0", url: Self.releaseURL),
            "the announced version must be the display form, without the tag's `v`"
        )
    }

    func testFromReportsUpToDateWhenVersionsMatch() {
        XCTAssertEqual(
            UpdateCheckOutcome.from(local: "1.0.0", latest: "1.0.0", url: Self.releaseURL),
            .upToDate
        )
        XCTAssertEqual(
            UpdateCheckOutcome.from(local: "1.0.0", latest: "v1.0.0", url: Self.releaseURL),
            .upToDate
        )
        XCTAssertEqual(
            UpdateCheckOutcome.from(local: "1.0", latest: "1.0.0", url: Self.releaseURL),
            .upToDate
        )
    }

    /// A developer running a build newer than the last published release must
    /// not be nagged. This is a live case in this repo, not a hypothetical: the
    /// `CFBundleShortVersionString` in `Resources/Info.plist` gets bumped in the
    /// commit that prepares a release, so between that bump and the moment the
    /// tag is pushed every local build is ahead of `releases/latest`.
    ///
    /// Note for the wiring: the local version is `CFBundleShortVersionString`
    /// (`1.0.0`), **not** `CFBundleVersion` (`36`). Feeding the build number in
    /// here would compare `36` against `1.1.0`, land in this branch forever, and
    /// silently kill the whole feature.
    func testFromReportsUpToDateWhenLocalIsNewerThanLatest() {
        XCTAssertEqual(
            UpdateCheckOutcome.from(local: "1.2.0", latest: "1.1.0", url: Self.releaseURL),
            .upToDate,
            "a local build ahead of the latest release must never be told to 'update'"
        )
        XCTAssertEqual(
            UpdateCheckOutcome.from(local: "1.1.0", latest: "v1.1.0-beta", url: Self.releaseURL),
            .upToDate,
            "a released local build must not be downgraded to a pre-release"
        )
        XCTAssertEqual(
            UpdateCheckOutcome.from(local: "2.0.0", latest: "1.9.9", url: Self.releaseURL),
            .upToDate
        )
    }

    func testFromReportsUnknownForUnparseableLatest() {
        for latest in ["", "abc", "1.-.3", "v", "latest", "..."] {
            XCTAssertEqual(
                UpdateCheckOutcome.from(local: "1.0.0", latest: latest, url: Self.releaseURL),
                .unknown,
                "unparseable tag_name \"\(latest)\" must be .unknown, never an update prompt"
            )
        }
    }

    /// Symmetrically: if we cannot parse our *own* version we have no basis for
    /// a comparison, and silence beats a wrong claim in both directions.
    func testFromReportsUnknownForUnparseableLocal() {
        for local in ["", "abc", "1.-.3"] {
            XCTAssertEqual(
                UpdateCheckOutcome.from(local: local, latest: "1.1.0", url: Self.releaseURL),
                .unknown,
                "unparseable local version \"\(local)\" must be .unknown"
            )
        }
    }

    // MARK: - UpdateChecker.check() against an injected fetcher
    //
    // No test in this file may touch the network. Every one of them injects the
    // fetcher, and the checker is unusable without one.

    private static func releaseJSON(
        tagName: String,
        htmlURL: String = UpdateCheckerTests.releaseURL
    ) -> Data {
        Data(
            """
            {
              "url": "https://api.github.com/repos/iyidgnaw/OpenType/releases/181234567",
              "html_url": "\(htmlURL)",
              "tag_name": "\(tagName)",
              "name": "OpenType \(tagName)",
              "draft": false,
              "prerelease": false,
              "published_at": "2026-08-20T09:00:00Z",
              "body": "Release notes."
            }
            """.utf8
        )
    }

    func testCheckParsesTagNameAndHTMLURLFromAWellFormedRelease() async {
        let checker = UpdateChecker(localVersion: "1.0.0") { _ in
            (Self.releaseJSON(tagName: "v1.1.0"), 200)
        }

        let outcome = await checker.check()

        XCTAssertEqual(
            outcome,
            .updateAvailable(version: "1.1.0", url: Self.releaseURL)
        )
    }

    func testCheckReportsUpToDateWhenTheLatestReleaseIsTheRunningVersion() async {
        let checker = UpdateChecker(localVersion: "1.1.0") { _ in
            (Self.releaseJSON(tagName: "v1.1.0"), 200)
        }

        let outcome = await checker.check()

        XCTAssertEqual(outcome, .upToDate)
    }

    /// Asserting the whole recorded array (rather than `.first`) pins two things
    /// at once: the endpoint, and that a successful `check()` makes **exactly
    /// one** request. The failure paths get their own no-retry tests below.
    func testCheckRequestsTheGitHubLatestReleaseEndpointExactlyOnce() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(localVersion: "1.0.0") { url in
            await recorder.record(url)
            return (Self.releaseJSON(tagName: "v1.1.0"), 200)
        }

        _ = await checker.check()

        let requested = await recorder.requestedURLs
        XCTAssertEqual(
            requested.map(\.absoluteString),
            ["https://api.github.com/repos/iyidgnaw/OpenType/releases/latest"]
        )
    }

    // MARK: - Every failure is silent
    //
    // `check()` is declared non-throwing, so "none of these throw" is enforced
    // by the signature rather than by an assertion: a test that awaited a
    // throwing call would not compile without `try`. What the tests below add is
    // that each failure resolves to `.unknown` — never `.upToDate` (which would
    // be a lie) and never `.updateAvailable` (which would be a wrong prompt).

    func testCheckReportsUnknownOnHTTPErrorStatus() async {
        for status in [400, 401, 403, 404, 429, 500, 502, 503] {
            let checker = UpdateChecker(localVersion: "1.0.0") { _ in
                (Data(#"{"message":"Not Found"}"#.utf8), status)
            }

            let outcome = await checker.check()

            XCTAssertEqual(
                outcome,
                .unknown,
                "HTTP \(status) must resolve to .unknown, silently"
            )
        }
    }

    /// Offline, DNS failure and a hung request all surface to the checker the
    /// same way — as something thrown out of the injected fetcher — and all
    /// three must be equally silent. One test, because there is one code path:
    /// the checker cannot and must not tell them apart.
    func testCheckReportsUnknownOnAnyThrownTransportError() async {
        let failures = [
            "The Internet connection appears to be offline.",
            "A server with the specified hostname could not be found.",
            "The request timed out.",
        ]

        for message in failures {
            let checker = UpdateChecker(localVersion: "1.0.0") { _ in
                throw StubTransportError(message: message)
            }

            let outcome = await checker.check()

            XCTAssertEqual(outcome, .unknown, "\"\(message)\" must resolve to .unknown, silently")
        }
    }

    func testCheckReportsUnknownOnMalformedJSON() async {
        let bodies = [
            Data("not json at all".utf8),
            Data(#"{"tag_name": "#.utf8),
            Data("<html><body>502 Bad Gateway</body></html>".utf8),
            Data(),
        ]

        for body in bodies {
            let checker = UpdateChecker(localVersion: "1.0.0") { _ in (body, 200) }

            let outcome = await checker.check()

            XCTAssertEqual(
                outcome,
                .unknown,
                "malformed body must resolve to .unknown, silently"
            )
        }
    }

    func testCheckReportsUnknownWhenTagNameIsMissing() async {
        let json = Data(
            """
            {
              "html_url": "\(Self.releaseURL)",
              "name": "OpenType 1.1.0",
              "draft": false
            }
            """.utf8
        )
        let checker = UpdateChecker(localVersion: "1.0.0") { _ in (json, 200) }

        let outcome = await checker.check()

        XCTAssertEqual(outcome, .unknown)
    }

    func testCheckReportsUnknownWhenTagNameIsUnparseable() async {
        let checker = UpdateChecker(localVersion: "1.0.0") { _ in
            (Self.releaseJSON(tagName: "nightly"), 200)
        }

        let outcome = await checker.check()

        XCTAssertEqual(outcome, .unknown)
    }

    // MARK: - A failing check is still one request

    /// The one that matters: a failing check must not retry in a tight loop.
    /// GitHub's unauthenticated API allows 60 requests/hour per IP, and a
    /// background checker that answers a 403 with a retry storm turns "silent
    /// failure" into a rate-limit ban.
    func testCheckDoesNotRetryAFailureWithinASingleCall() async {
        for status in [403, 404, 500] {
            let recorder = FetchRecorder()
            let checker = UpdateChecker(localVersion: "1.0.0") { url in
                await recorder.record(url)
                return (Data(#"{"message":"error"}"#.utf8), status)
            }

            _ = await checker.check()

            let count = await recorder.callCount
            XCTAssertEqual(count, 1, "HTTP \(status) must not be retried inside one check()")
        }
    }

    func testCheckDoesNotRetryAThrownTransportError() async {
        let recorder = FetchRecorder()
        let checker = UpdateChecker(localVersion: "1.0.0") { url in
            await recorder.record(url)
            throw StubTransportError(message: "offline")
        }

        _ = await checker.check()

        let count = await recorder.callCount
        XCTAssertEqual(count, 1, "a transport error must not be retried inside one check()")
    }

    // MARK: - "The same version is only announced once"
    //
    // `lastSeenUpdateVersion` in `AppConfiguration` is the persisted half; the
    // decision itself is pure and is what these tests cover (not UserDefaults).
    // Being nagged on every launch about a version you already looked at and
    // decided to skip is the failure mode this exists to prevent.

    func testAnnouncesAnUpdateNeverSeenBefore() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.1.0",
            url: Self.releaseURL
        )
        XCTAssertTrue(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: nil)
        )
    }

    func testDoesNotAnnounceTheSameVersionTwice() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.1.0",
            url: Self.releaseURL
        )
        XCTAssertFalse(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: "1.1.0"),
            "a version the user has already been shown must not be announced again"
        )
    }

    /// The stored value and the announced value must be compared as versions,
    /// not as strings — otherwise a `v`-prefixed leftover re-nags forever.
    func testLastSeenComparisonIsSemanticNotTextual() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.1.0",
            url: Self.releaseURL
        )
        XCTAssertFalse(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: "v1.1.0")
        )
        XCTAssertFalse(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: "1.1")
        )
    }

    func testAnnouncesAVersionNewerThanTheOneAlreadySkipped() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.2.0",
            url: Self.releaseURL
        )
        XCTAssertTrue(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: "1.1.0"),
            "skipping 1.1.0 must not silence 1.2.0"
        )
    }

    /// Double-digit ordering has to survive this layer too: having seen 1.9.0
    /// must not suppress 1.10.0.
    func testAnnouncesDoubleDigitVersionAfterASingleDigitOneWasSeen() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.10.0",
            url: Self.releaseURL
        )
        XCTAssertTrue(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: "1.9.0")
        )
    }

    func testDoesNotAnnounceAVersionOlderThanTheOneAlreadySeen() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.1.0",
            url: Self.releaseURL
        )
        XCTAssertFalse(
            UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: "1.2.0")
        )
    }

    func testNeverAnnouncesUpToDateOrUnknownRegardlessOfLastSeen() {
        for lastSeen: String? in [nil, "1.0.0", "1.1.0", "abc", ""] {
            XCTAssertFalse(
                UpdatePromptPolicy.shouldAnnounce(.upToDate, lastSeenVersion: lastSeen),
                "nothing to announce when up to date (lastSeen=\(lastSeen ?? "nil"))"
            )
            XCTAssertFalse(
                UpdatePromptPolicy.shouldAnnounce(.unknown, lastSeenVersion: lastSeen),
                "a failed check must stay silent (lastSeen=\(lastSeen ?? "nil"))"
            )
        }
    }

    /// A stored value we cannot parse must not be able to suppress a real
    /// update — it should degrade to "announce", not to permanent silence.
    /// `""` is the load-bearing case rather than the exotic one: it is what a
    /// `defaults.string(forKey:) ?? ""` preference reads back before anything
    /// has ever been announced, so treating it as "a version already seen"
    /// would suppress the very first prompt on a fresh install.
    func testUnparseableLastSeenDoesNotSuppressARealUpdate() {
        let outcome = UpdateCheckOutcome.updateAvailable(
            version: "1.1.0",
            url: Self.releaseURL
        )
        for lastSeen in ["", "abc", "1.-.3"] {
            XCTAssertTrue(
                UpdatePromptPolicy.shouldAnnounce(outcome, lastSeenVersion: lastSeen),
                "a corrupt lastSeenUpdateVersion (\"\(lastSeen)\") must not silence updates forever"
            )
        }
    }
}

// MARK: - Test doubles

/// Records what the injected fetcher was asked for, so a test can assert both
/// the endpoint and the call count. An actor because `check()` calls the fetcher
/// from inside `UpdateChecker`'s own isolation.
private actor FetchRecorder {
    private(set) var requestedURLs: [URL] = []

    var callCount: Int { requestedURLs.count }

    func record(_ url: URL) {
        requestedURLs.append(url)
    }
}

/// Stands in for whatever `URLSession` throws — offline, DNS failure, timeout.
/// The checker must treat all of them identically and silently.
private struct StubTransportError: Error {
    let message: String
}
