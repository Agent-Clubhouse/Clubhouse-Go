    /// Uncredited native List characterisation; alphabetically after the strict anchor method.
    /// Standard anchors are measured, never used to change the fractional assertions.
    func testZZDiagnosticNativeListStandardAnchors() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let anchor = try XCTUnwrap(fixture.anchor)
        let list = try XCTUnwrap(fixture.list(in: fixture.window))
        try await fixture.waitForVisibleWorkToSettle()
        list.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        try await fixture.wait { anchor.bookmark != nil && anchor.bookmark?.id != .summary && anchor.bookmark?.id != .desktops }
        let saved = try XCTUnwrap(anchor.bookmark)
        let request = try XCTUnwrap(CompanionHomeBuildProbe.diagnosticScrollTo)
        @MainActor func settled() async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 3
            var previous = "", stableSince = ProcessInfo.processInfo.systemUptime
            while ProcessInfo.processInfo.systemUptime < deadline {
                try await fixture.turn()
                let now = ProcessInfo.processInfo.systemUptime
                let sample = "\(String(describing: anchor.testFrames[saved.id]))|\(anchor.testViewport)|\(list.contentOffset)|\(list.adjustedContentInset)"
                if sample != previous { previous = sample; stableSince = now }
                else if now - stableSince >= 0.25, anchor.testFrames[saved.id] != nil { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Native anchor probe geometry did not settle")
            throw NSError(domain: "HomeAnchorProbeReadiness", code: 1)
        }
        @MainActor func rect(_ value: CGRect) -> [String: CGFloat] {
            ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
        }
        var samples: [[String: Any]] = []
        for (name, alignment) in [("top", UnitPoint.top), ("bottom", UnitPoint.bottom)] {
            request(saved.id, alignment)
            try await settled()
            let frame = try XCTUnwrap(anchor.testFrames[saved.id])
            let viewport = anchor.testViewport
            let expected = viewport.minY + alignment.y * (viewport.height - frame.height)
            samples.append(["mode": name, "id": String(describing: saved.id),
                "row": rect(frame), "viewport": rect(viewport), "expectedY": expected,
                "error": frame.minY - expected, "actualOffset": list.contentOffset.y,
                "adjustedInsets": String(describing: list.adjustedContentInset)])
            fixture.capture("Native List diagnostic \(name) anchor")
        }
        let data = try JSONSerialization.data(withJSONObject: ["uncredited": true, "samples": samples], options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Home native standard-anchor characterisation JSON"; attachment.lifetime = .keepAlways
        add(attachment)
    }

