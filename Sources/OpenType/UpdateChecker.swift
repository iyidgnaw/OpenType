import Foundation

/// 更新检查 (§B of `docs/superpowers/specs/2026-08-15-product-batch-plan.md`).
///
/// 1.0.0 ships through a one-shot `curl … | zsh` installer
/// (`docs/reviews/2026-08-15-product-review.md` §4), which means every bug in
/// 1.0.0 stays on every installed machine until its owner happens to re-run
/// that command. Nothing here changes that mechanism — **this file updates
/// nothing**. It learns that a newer release exists and hands the user the
/// install command, which is idempotent; they run it themselves.
///
/// No Sparkle, deliberately: an auto-updater is a signing, hosting and
/// appcast-feed commitment, and the thing that is actually missing is the one
/// sentence 「你这个版本旧了」.
///
/// The shape follows what the rest of this repo does with anything that has to
/// touch a framework a test cannot drive (`OutputDeliveryPolicy`,
/// `LaunchAtLogin`, `SidecarSupervisor`): the decisions are pure functions, the
/// one I/O call is an injected closure, and no test in the suite goes near the
/// network.

// MARK: - Version comparison

/// Orders two version strings **numerically**.
///
/// Total by construction: every pair of strings gets an answer, and the answer
/// is antisymmetric — swapping the arguments inverts it. That matters more than
/// it looks: a comparator that gets one direction right and the other wrong
/// produces both 「已是最新」 and 「有新版本」 for the same pair, depending on
/// which way round the caller happened to ask.
///
/// What it tolerates, because GitHub tags really do carry all of it: a leading
/// `v`, a missing minor or patch (`1.0` is `1.0.0`), and a `-prerelease`
/// suffix, which sorts *before* the release it leads up to (semver 11.4).
/// Components are compared as integers, never as text — string ordering says
/// `1.10.0 < 1.9.0`, which would silently stop announcing updates the day a
/// component reaches double digits.
///
/// Nonsense (`""`, `"latest"`, `"1.-.3"`) is ordered rather than rejected here:
/// two unparseable strings fall back to a literal string comparison, and an
/// unparseable string sorts below a real version. That keeps this function
/// total; the judgement 「无法解析，就什么都别说」 belongs to
/// `UpdateCheckOutcome.from`, which is the only place a wrong answer could
/// reach the user.
func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
    let normalizedA = SemanticVersion.normalize(a)
    let normalizedB = SemanticVersion.normalize(b)
    switch (SemanticVersion(normalizedA), SemanticVersion(normalizedB)) {
    case let (left?, right?):
        return left.compare(right)
    // Two nonsense strings are ordered literally, which is what makes the
    // comparator deterministic and equal on identical input; one nonsense
    // string sorts below a real version.
    case (nil, nil):
        return normalizedA.compare(normalizedB)
    case (nil, _):
        return .orderedAscending
    case (_, nil):
        return .orderedDescending
    }
}

/// A parsed `MAJOR[.MINOR[.PATCH]][-prerelease]`.
///
/// Not public API and not a general semver implementation: it exists so
/// `compareVersions` and `UpdateCheckOutcome.from` share one answer to 「这到底
/// 是不是一个版本号」. `from` has to consult that answer *before* it compares —
/// `compareVersions` is total and will happily order `"latest"` against our own
/// version, and turning that ordering into `.updateAvailable` is exactly the
/// wrong prompt.
struct SemanticVersion {
    let major: Int
    let minor: Int
    let patch: Int
    /// The dot-separated identifiers after the `-`, empty for a release.
    let preRelease: [String]

    /// Trimmed and with the tag's `v` removed — the form everything else in
    /// this file compares, stores and displays.
    ///
    /// One normalisation for all three uses is what keeps `lastSeenUpdateVersion`
    /// round-tripping: storing `v1.1.0` and later comparing `1.1.0` would
    /// re-announce the same release forever.
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first == "v" || first == "V" else { return trimmed }
        return String(trimmed.dropFirst())
    }

    /// `nil` for anything that is not a version. Deliberately strict: a missing
    /// component is fine (`1.0`), an empty or non-decimal one is not (`1.`,
    /// `1.-.3`, `latest`, `""`), and more than three components is a tag scheme
    /// this app does not use.
    init?(_ normalized: String) {
        let core: Substring
        let preRelease: [String]
        if let hyphen = normalized.firstIndex(of: "-") {
            core = normalized[normalized.startIndex..<hyphen]
            let suffix = normalized[normalized.index(after: hyphen)...]
            let identifiers = suffix.split(separator: ".", omittingEmptySubsequences: false)
            guard !suffix.isEmpty, identifiers.allSatisfy({ !$0.isEmpty }) else { return nil }
            preRelease = identifiers.map(String.init)
        } else {
            core = normalized[...]
            preRelease = []
        }

        let components = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }
        var numbers: [Int] = []
        for component in components {
            // `Int(_:)` alone would accept `+1` and `-2`, and `isNumber` alone
            // would accept `٣`, which `Int(_:)` then rejects. Both checks, so
            // "parses" and "is decimal digits" cannot disagree.
            guard !component.isEmpty,
                  component.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(component)
            else { return nil }
            numbers.append(value)
        }

        major = numbers[0]
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
        self.preRelease = preRelease
    }

    func compare(_ other: SemanticVersion) -> ComparisonResult {
        for (left, right) in [(major, other.major), (minor, other.minor), (patch, other.patch)]
        where left != right {
            return left < right ? .orderedAscending : .orderedDescending
        }
        return Self.comparePreRelease(preRelease, other.preRelease)
    }

    /// Semver 11.4, with the one rule that matters for us first: a release
    /// outranks any pre-release of the same version, so 1.1.0-beta is never
    /// offered as an upgrade to someone already running 1.1.0.
    private static func comparePreRelease(_ a: [String], _ b: [String]) -> ComparisonResult {
        if a.isEmpty, b.isEmpty { return .orderedSame }
        if a.isEmpty { return .orderedDescending }
        if b.isEmpty { return .orderedAscending }

        for (left, right) in zip(a, b) where left != right {
            switch (Int(left), Int(right)) {
            case let (l?, r?):
                if l == r { continue }  // `beta.01` and `beta.1` are one rank.
                return l < r ? .orderedAscending : .orderedDescending
            case (_?, nil):
                return .orderedAscending  // numeric identifiers rank below alphanumeric ones
            case (nil, _?):
                return .orderedDescending
            case (nil, nil):
                return left < right ? .orderedAscending : .orderedDescending
            }
        }
        if a.count == b.count { return .orderedSame }
        return a.count < b.count ? .orderedAscending : .orderedDescending
    }
}

// MARK: - The outcome

/// What one check concluded. Three cases, and the third is not a failure to
/// handle — it is the answer 「不知道」, which the UI says nothing about.
enum UpdateCheckOutcome: Equatable {
    case upToDate
    case updateAvailable(version: String, url: String)
    case unknown

    /// The whole decision, as a pure function of three strings.
    ///
    /// `latest < local` is `.upToDate`, not `.updateAvailable`: this repo's
    /// `CFBundleShortVersionString` is bumped in the commit that prepares a
    /// release, so between that commit and the pushed tag every local build is
    /// ahead of `releases/latest`. Being told to 「更新」 to an older release is
    /// an everyday case here, not a corner.
    ///
    /// Either side being unparseable is `.unknown`. We have no basis for a
    /// comparison, and silence beats a wrong claim in both directions.
    static func from(local: String, latest: String, url: String) -> UpdateCheckOutcome {
        let normalizedLatest = SemanticVersion.normalize(latest)
        guard let localVersion = SemanticVersion(SemanticVersion.normalize(local)),
              let latestVersion = SemanticVersion(normalizedLatest)
        else { return .unknown }

        guard latestVersion.compare(localVersion) == .orderedDescending else { return .upToDate }
        // The display form, `v` already stripped: it goes straight into
        // 「有新版本 \(version)」 and into `lastSeenUpdateVersion`, and no call
        // site should have to remember to strip it again.
        return .updateAvailable(version: normalizedLatest, url: url)
    }
}

/// Whether an outcome is worth putting on screen.
///
/// Being nagged on every launch about a version you already looked at is the
/// failure mode this exists to prevent, so the decision is 「比上次说过的更新
/// 才说」 — compared as versions, never as text, or a `v`-prefixed leftover
/// would re-announce forever.
enum UpdatePromptPolicy {
    static func shouldAnnounce(_ outcome: UpdateCheckOutcome, lastSeenVersion: String?) -> Bool {
        guard case .updateAvailable(let version, _) = outcome else { return false }
        // A stored value we cannot parse degrades to 「说」, not to permanent
        // silence — including `""`, which is what the preference reads back
        // before anything has ever been announced.
        guard let lastSeenVersion,
              SemanticVersion(SemanticVersion.normalize(lastSeenVersion)) != nil
        else { return true }
        return compareVersions(version, lastSeenVersion) == .orderedDescending
    }
}

// MARK: - The check

/// Asks GitHub what the latest release is. Once, silently, and never more than
/// that.
///
/// The network call is injected rather than reached for, so every test drives
/// the 404 / offline / malformed-body branches without a socket. `(Data, Int)`
/// rather than `URLSession`'s `(Data, URLResponse)` keeps the seam free of
/// `URLResponse`'s `Sendable` awkwardness; a bare status code is all the
/// decision needs.
///
/// `check()` does not throw, and that is the feature rather than a
/// simplification: a network blip must not be expressible as something a caller
/// has to handle, because the only correct handling is to say nothing.
actor UpdateChecker {

    /// The unauthenticated releases endpoint. 60 requests/hour per IP is the
    /// budget, and this feature spends two a day.
    static let latestReleaseEndpoint = URL(
        string: "https://api.github.com/repos/iyidgnaw/OpenType/releases/latest"
    )!

    /// Where to send someone when the release payload has no `html_url` of its
    /// own — the releases page always exists, so a missing field costs the
    /// announcement its precision, not the announcement itself.
    static let releasesPage = "https://github.com/iyidgnaw/OpenType/releases/latest"

    private let localVersion: String
    private let fetch: @Sendable (URL) async throws -> (Data, Int)

    init(
        localVersion: String,
        fetch: @escaping @Sendable (URL) async throws -> (Data, Int)
    ) {
        self.localVersion = localVersion
        self.fetch = fetch
    }

    /// The production checker: same logic, `URLSession` behind the seam.
    init(localVersion: String) {
        self.init(localVersion: localVersion, fetch: UpdateChecker.networkFetch)
    }

    /// One request, one answer. Every failure — HTTP status, transport error,
    /// unreadable body, missing or unparseable `tag_name` — is `.unknown`, and
    /// none of them is retried: a background checker that answers a 403 with a
    /// retry storm turns 「静默失败」 into a rate-limit ban.
    func check() async -> UpdateCheckOutcome {
        guard let (data, status) = try? await fetch(Self.latestReleaseEndpoint) else {
            return .unknown
        }
        guard (200..<300).contains(status) else { return .unknown }
        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
              let tagName = release.tag_name
        else { return .unknown }

        return .from(
            local: localVersion,
            latest: tagName,
            url: release.html_url ?? Self.releasesPage
        )
    }

    /// Only the two fields the decision uses, both optional: GitHub's payload
    /// has thirty more, and a release object missing the one field we need is a
    /// `.unknown` rather than a decode failure we would have to distinguish.
    private struct GitHubRelease: Decodable {
        let tag_name: String?
        let html_url: String?
    }

    /// `URLSession`, with the two headers GitHub's API expects. The
    /// `User-Agent` is not optional politeness — api.github.com answers 403 to a
    /// request without one, which would make every check silently `.unknown`.
    private static let networkFetch: @Sendable (URL) async throws -> (Data, Int) = { url in
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("OpenType/\(AppVersion.short)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        // A non-HTTP response cannot be a release; 0 lands in the same silent
        // branch every other unusable answer does.
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

// MARK: - This build

/// What version this copy of the app is.
///
/// `short` is `CFBundleShortVersionString` (`1.0.0`) and it is the one that may
/// ever reach `UpdateCheckOutcome.from`. `CFBundleVersion` is the build number
/// (`36`); comparing *that* against `1.1.0` would land in the
/// 「本地比线上新」 branch forever and silently kill the whole feature. `build`
/// exists to be printed beside it in 设置, nothing else.
enum AppVersion {
    static var short: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }

    /// `1.0.0 (36)`, or just the version when there is no build number — and an
    /// empty string when neither exists, which is what a debug binary run
    /// straight out of `.build/` has. An unparseable local version is already
    /// `.unknown` at the decision layer, so that build simply never announces
    /// anything.
    static var displayText: String {
        let short = Self.short
        let build = Self.build
        guard !short.isEmpty else { return "" }
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// The command §B hands the user. Idempotent: re-running it over an existing
/// install is the update.
enum UpdateInstall {
    static let command = "curl -fsSL https://opentype-site.vercel.app/install | zsh"
}

/// When the check runs. Named rather than inlined so the two numbers §B fixes
/// are readable in one place.
enum UpdateCheckSchedule {
    /// 10s after launch — late enough not to compete with the sidecar coming
    /// up and the first-run Whisper model download, early enough that someone
    /// who opens the popover to dictate one sentence already knows.
    static let initialDelay: TimeInterval = 10
    /// And once a day after that.
    static let interval: TimeInterval = 24 * 60 * 60
}
