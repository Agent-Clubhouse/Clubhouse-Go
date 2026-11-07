import XCTest

/// Reads only after the original Retry frame is captured below 44; never normalizes or rescues it.
@MainActor enum RecoverySizeFailureEvidence {
    static func record(_ app: XCUIApplication, retry: XCUIElement, frame: CGRect) {
        guard frame.width < 44 || frame.height < 44 else { return }
        let started = ProcessInfo.processInfo.systemUptime
        var fields = ["originalButtonFrame=\(frame)", "startUptime=\(started)"]
        XCTContext.runActivity(named: "Retry original strict-size reading — frame=\(frame), uptime=\(started)") { _ in }
        func surface(_ name: String, _ query: XCUIElementQuery) {
            let count = query.count
            fields.append("\(name).count=\(count)")
            guard count == 1 else { fields.append("\(name).frame=unavailable"); return }
            let element = query.element(boundBy: 0)
            guard element.exists else { fields.append("\(name).frame=disappeared"); return }
            fields.append("\(name).frame=\(element.frame), type=\(element.elementType.rawValue), label=\(element.label)")
        }
        surface("Button descendant StaticText", retry.staticTexts)
        surface("containing ScrollView", app.scrollViews.containing(.button, identifier: "companion-recovery-detail-retry"))
        surface("matching presentation NavigationBar", app.navigationBars.matching(identifier: "Connection and recovery"))
        surface("matching Done", app.navigationBars.matching(identifier: "Connection and recovery").buttons.matching(identifier: "Done"))
        surface("containing Window", app.windows.containing(.button, identifier: "companion-recovery-detail-retry"))
        fields.append("appFrame=\(app.frame), endUptime=\(ProcessInfo.processInfo.systemUptime)")
        // These are sequential native exports, not the SwiftUI label allocation or an atomic transaction.
        XCTContext.runActivity(named: "Retry strict-size failure boundaries — " + fields.joined(separator: "; ")) { _ in }
    }
}
