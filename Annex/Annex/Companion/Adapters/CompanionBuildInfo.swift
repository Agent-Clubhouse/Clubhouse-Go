import Foundation

/// What a build says about itself, read from Info.plist. `scripts/testflight.sh` sets
/// `FRAMEBRIAR_BUILD_SHA` to the archived commit, and Info.plist carries it as `FramebriarBuildSHA`;
/// local and CI builds leave it empty. Framebriar reports send it as `buildSha`.
nonisolated enum CompanionBuildInfo {
    static let buildSHAKey = "FramebriarBuildSHA"

    /// A git commit (7–40 hex digits, lowercased), or nil when the build has none. Never fabricated:
    /// an empty, unexpanded (`$(FRAMEBRIAR_BUILD_SHA)`) or malformed value is nil, which Framebriar accepts,
    /// whereas passing it on would make Framebriar's configuration, and so feedback, fail.
    static func buildSHA(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              (7...40).contains(raw.count), raw.allSatisfy({ $0.isHexDigit }) else { return nil }
        return raw
    }
    static func buildSHA(bundle: Bundle = .main) -> String? { buildSHA(bundle.object(forInfoDictionaryKey: buildSHAKey)) }
    /// `CFBundleShortVersionString` and `CFBundleVersion`, e.g. "2.0.0" and "125".
    static func version(bundle: Bundle = .main) -> (version: String?, build: String?) {
        (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
         bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
}
