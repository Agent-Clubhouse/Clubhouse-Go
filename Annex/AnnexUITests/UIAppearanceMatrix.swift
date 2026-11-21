import XCTest

/// Every push runs one representative of each theme-only appearance variant. The scheduled appearance lane
/// (`.github/workflows/ui-appearance-nightly.yml`) sets `CLUBHOUSE_UI_APPEARANCE_MATRIX=full` to run them all.
/// Use this only where the variants assert the same theme-independent layout and differ only in their screenshots.
/// Contrast, color and theme-specific checks always run.
extension ReliableUITestCase {
    var runsFullAppearanceMatrix: Bool {
        ProcessInfo.processInfo.environment["CLUBHOUSE_UI_APPEARANCE_MATRIX"] == "full"
    }

    /// The representative entries on every push; all entries in the scheduled appearance lane.
    func appearanceMatrix<Entry>(_ entries: [Entry], everyPush keep: (Entry) -> Bool) -> [Entry] {
        runsFullAppearanceMatrix ? entries : entries.filter(keep)
    }

    /// For a separate method that repeats another method's layout contract in another theme.
    func requireFullAppearanceMatrix(_ variant: String) throws {
        try XCTSkipUnless(runsFullAppearanceMatrix,
                          "\(variant) repeats a layout covered on every push; it runs in the scheduled appearance lane")
    }
}
