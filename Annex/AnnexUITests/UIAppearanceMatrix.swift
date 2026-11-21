import XCTest

/// Every push runs one representative of each theme-only appearance variant. The scheduled appearance lane
/// (`.github/workflows/ui-appearance-nightly.yml`) sets `CLUBHOUSE_UI_APPEARANCE_MATRIX=full` to run them all.
/// Use this only where the variants assert the same theme-independent layout and differ only in their screenshots.
/// Contrast, color and theme-specific checks always run.
///
/// Each use prints one `APPEARANCE_MATRIX` line naming the test, the mode, every variant and the variants it runs.
/// `scripts/ci/appearance_matrix.py verify` requires those lines in the nightly log, so a missing switch, a skipped
/// variant or a shortened loop fails that lane instead of passing quietly.
extension ReliableUITestCase {
    var runsFullAppearanceMatrix: Bool {
        ProcessInfo.processInfo.environment["CLUBHOUSE_UI_APPEARANCE_MATRIX"] == "full"
    }

    /// The representative entries on every push; all entries in the scheduled appearance lane.
    func appearanceMatrix<Entry>(_ entries: [Entry], name: (Entry) -> String, everyPush keep: (Entry) -> Bool) -> [Entry] {
        let running = runsFullAppearanceMatrix ? entries : entries.filter(keep)
        reportAppearanceMatrix(variants: entries.map(name), running: running.map(name))
        return running
    }

    /// For a separate method that repeats another method's layout contract in another theme.
    func requireFullAppearanceMatrix(_ variant: String) throws {
        reportAppearanceMatrix(variants: [variant], running: runsFullAppearanceMatrix ? [variant] : [])
        try XCTSkipUnless(runsFullAppearanceMatrix,
                          "\(variant) repeats a layout covered on every push; it runs in the scheduled appearance lane")
    }

    private func reportAppearanceMatrix(variants: [String], running: [String]) {
        print("APPEARANCE_MATRIX test=\(name) mode=\(runsFullAppearanceMatrix ? "full" : "push") "
              + "variants=\(variants.joined(separator: "|")) ran=\(running.joined(separator: "|"))")
    }
}
