import XCTest
import UIKit
@testable import ClubhouseGo

/// Observation after an outcome is already failed. Never lays out, refocuses, activates or retries a control.
@MainActor enum CompanionRecoveryFailureEvidence {
    static func capture(window: UIWindow, scene: CompanionRecoveryFixtureScene, reason: String,
                        prerequisite: [String: String]) {
        let connection = scene.store.host(for: scene.target)?.connection ?? .offline
        let conversation = scene.store.conversation(for: scene.target)
        let status = CompanionRecoveryStatus(connection: connection, isLoading: conversation.isLoading,
                                             requiresResync: conversation.requiresResync, error: conversation.error)
        var ledger: [String: Any] = [
            "reason": reason, "prerequisiteAtFailure": prerequisite,
            "target": "\(scene.target.hostID)/\(scene.target.agentID)", "selected": scene.isActive,
            "connection": String(describing: connection), "phase": String(describing: status.phase),
            "title": status.title, "visible": status.isVisible, "retry": String(describing: status.retryAction),
            "loading": conversation.isLoading, "resync": conversation.requiresResync,
            "error": conversation.error ?? "<nil>", "items": conversation.items.count,
            "pendingHistory": scene.service.pendingHistoryCount, "tearingDown": scene.service.isTearingDown,
            "historyModes": Dictionary(uniqueKeysWithValues: CompanionRecoveryFixtureService.targets.map {
                ("\($0.hostID)/\($0.agentID)", String(describing: scene.service.modes[$0] ?? .success))
            }),
            "historyCalls": Dictionary(uniqueKeysWithValues: CompanionRecoveryFixtureService.targets.map {
                ("\($0.hostID)/\($0.agentID)", scene.service.historyCalls[$0] ?? 0)
            }), "reconnectCalls": scene.service.reconnectCalls,
            "window": windowInfo(window),
            "sceneWindows": Array((window.windowScene?.windows ?? []).prefix(8)).map(windowInfo),
            "sceneWindowsTruncated": (window.windowScene?.windows.count ?? 0) > 8,
            "scope": "Synthetic fixture only; post-failure scan may materialize AX but never resumes the failed test"
        ]

        // No layoutIfNeeded or screen-update wait: preserve the window as it was observed when the failure was frozen.
        let bounds = window.bounds
        let scale = window.screen.scale
        if bounds.width > 0, bounds.height > 0, bounds.width * bounds.height * scale * scale <= 12_000_000 {
            var drew = false
            let format = UIGraphicsImageRendererFormat()
            format.scale = scale
            let image = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                drew = window.drawHierarchy(in: bounds, afterScreenUpdates: false)
            }
            ledger["windowDrawSucceeded"] = drew
            if let png = image.pngData() {
                attach(png, type: "public.png", name: "Recovery first failure — original synthetic window")
            } else { ledger["snapshotSkipped"] = "PNG encoding failed" }
        } else { ledger["snapshotSkipped"] = "Invalid bounds or 12-million-pixel cap" }

        ledger["controllers"] = controllers(window.rootViewController)
        attachJSON(ledger, name: "Recovery first failure — model service window ledger")
        attachJSON(accessibility(window), name: "Recovery first failure — bounded public AX inventory")
        print("RECOVERY_FIRST_FAILURE_EVIDENCE phase=\(status.phase) loading=\(conversation.isLoading) resync=\(conversation.requiresResync) pending=\(scene.service.pendingHistoryCount) maximumAttachments=3 maximumEvents=1")
    }

    private static func windowInfo(_ window: UIWindow) -> [String: Any] {
        ["class": String(describing: type(of: window)), "frame": NSStringFromCGRect(window.frame),
         "bounds": NSStringFromCGRect(window.bounds), "key": window.isKeyWindow, "hidden": window.isHidden,
         "alpha": window.alpha, "level": window.windowLevel.rawValue,
         "safeArea": NSStringFromUIEdgeInsets(window.safeAreaInsets),
         "sceneActivation": window.windowScene.map { String(describing: $0.activationState) } ?? "<nil>",
         "sceneBounds": window.windowScene.map { NSStringFromCGRect($0.coordinateSpace.bounds) } ?? "<nil>",
         "root": window.rootViewController.map { String(describing: type(of: $0)) } ?? "<nil>"]
    }
    private static func controllers(_ root: UIViewController?) -> [String: Any] {
        var records: [[String: Any]] = [], visited: Set<ObjectIdentifier> = []
        var truncated = false
        func visit(_ controller: UIViewController?, depth: Int) {
            guard let controller, visited.insert(ObjectIdentifier(controller)).inserted else { return }
            guard depth <= 6, records.count < 12 else { truncated = true; return }
            records.append(["class": String(describing: type(of: controller)), "depth": depth,
                "viewLoaded": controller.isViewLoaded,
                "frame": controller.viewIfLoaded.map { NSStringFromCGRect($0.frame) } ?? "<unloaded>",
                "attachedToWindow": controller.viewIfLoaded?.window != nil,
                "presented": controller.presentedViewController.map { String(describing: type(of: $0)) } ?? "<nil>"])
            visit(controller.presentedViewController, depth: depth + 1)
            for child in controller.children.prefix(8) { visit(child, depth: depth + 1) }
            if controller.children.count > 8 { truncated = true }
        }
        visit(root, depth: 0)
        return ["records": records, "truncated": truncated, "maxControllers": 12, "maxDepth": 6]
    }
    private static func accessibility(_ root: NSObject) -> [String: Any] {
        var records: [[String: Any]] = [], visited: Set<ObjectIdentifier> = []
        var truncated = false, exhausted = false, textBytes = 0
        let targets: Set<String> = ["companion-recovery-details", "companion-recovery-retry", "companion-recovery-detail-retry"]
        var postFailureMatches: Set<String> = []
        func bounded(_ value: String?) -> String {
            let value = value ?? "<nil>"
            if value.count > 160 { truncated = true }
            return String(value.prefix(160))
        }
        func visit(_ object: NSObject, depth: Int, edge: String) {
            guard !exhausted else { return }
            guard depth <= 12 else { truncated = true; return }
            guard records.count < 256, textBytes < 65_536 else { truncated = true; exhausted = true; return }
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            let protocolID = (object as? UIAccessibilityIdentification)?.accessibilityIdentifier
            let viewID = (object as? UIView)?.accessibilityIdentifier
            let elementID = (object as? UIAccessibilityElement)?.accessibilityIdentifier
            for id in [protocolID, viewID, elementID].compactMap({ $0 }) where targets.contains(id) { postFailureMatches.insert(id) }
            let elements = object.accessibilityElements ?? []
            let count = object.accessibilityElementCount()
            let record: [String: Any] = ["class": bounded(String(describing: type(of: object))), "depth": depth, "edge": edge,
                "protocolConforms": object is UIAccessibilityIdentification, "protocolID": bounded(protocolID),
                "viewID": bounded(viewID), "elementID": bounded(elementID),
                "respondsToIdentifier": object.responds(to: NSSelectorFromString("accessibilityIdentifier")),
                "label": bounded(object.accessibilityLabel), "value": bounded(object.accessibilityValue),
                "isElement": object.isAccessibilityElement, "modal": object.accessibilityViewIsModal,
                "axFrame": NSStringFromCGRect(object.accessibilityFrame),
                "viewFrame": (object as? UIView).map { NSStringFromCGRect($0.frame) } ?? "<not UIView>",
                "viewHidden": (object as? UIView)?.isHidden ?? false,
                "declaredElements": elements.count, "containerCount": count]
            guard let data = try? JSONSerialization.data(withJSONObject: record), textBytes + data.count <= 65_536 else {
                truncated = true; exhausted = true; return
            }
            textBytes += data.count
            records.append(record)
            // This independent inventory prioritizes declared AX children; the test's existing lookup is unchanged.
            for case let child as NSObject in elements.prefix(64) { visit(child, depth: depth + 1, edge: "accessibilityElements") }
            if elements.count > 64 { truncated = true }
            if count > 0, count != NSNotFound {
                for index in 0..<min(count, 64) {
                    if let child = object.accessibilityElement(at: index) as? NSObject { visit(child, depth: depth + 1, edge: "container") }
                }
                if count > 64 { truncated = true }
            }
            if let view = object as? UIView {
                for child in view.subviews.prefix(64) { visit(child, depth: depth + 1, edge: "subview") }
                if view.subviews.count > 64 { truncated = true }
            }
        }
        visit(root, depth: 0, edge: "window")
        return ["records": records, "truncated": truncated, "maxNodes": 256, "maxDepth": 12,
                "maxChildrenPerEdge": 64, "maxRecordBytes": 65_536, "recordBytes": textBytes,
                "postFailureLeafMatches": postFailureMatches.sorted(),
                "note": "Post-failure observation only; no new activation or predicate lookup follows"]
    }
    private static func attachJSON(_ value: [String: Any], name: String) {
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), data.count <= 73_728 {
            attach(data, type: "public.json", name: name)
        } else {
            let fallback = Data("{\"truncated\":true,\"reason\":\"JSON encoding failed or exceeded 73728-byte cap\"}".utf8)
            attach(fallback, type: "public.json", name: name)
        }
    }
    private static func attach(_ data: Data, type: String, name: String) {
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
        attachment.name = name; attachment.lifetime = .keepAlways
        XCTContext.runActivity(named: name) { $0.add(attachment) }
    }
}
