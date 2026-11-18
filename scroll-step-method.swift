    /// Uncredited diagnostic: real List offsets, no Store traffic or new body-time State reads.
    /// Programmatic movement is not a claim about native finger-gesture invalidation.
    func testDiagnosticHomeScrollStepsReportExpensiveWork() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        @MainActor func findList(in view: UIView) -> UICollectionView? {
            (view as? UICollectionView) ?? view.subviews.lazy.compactMap { findList(in: $0) }.first
        }
        let list = try XCTUnwrap(findList(in: fixture.window))
        XCTAssertGreaterThan(list.contentSize.height, list.bounds.height * 2)
        XCTAssertGreaterThan(fixture.counts[.layout, default: 0], 0)
        try await fixture.waitForVisibleWorkToSettle()
        // Warm the native large-title collapse before measuring; main adjusts the first
        // raw offset by 52pt as its top inset changes. Every measured offset stays exact.
        list.setContentOffset(CGPoint(x: 0, y: 200), animated: false)
        try await fixture.waitForVisibleWorkToSettle()
        let warmup: [String: Any] = ["requestedOffset": 200, "actualOffset": list.contentOffset.y,
            "adjustedInsets": String(describing: list.adjustedContentInset)]
        @MainActor func counts() -> [String: Int] {
            Dictionary(fixture.counts.map { (String(describing: $0.key), $0.value) }, uniquingKeysWith: { _, last in last })
        }
        let measuredTopInset = list.adjustedContentInset.top
        let offsets = (0..<8).map { CGFloat(300 + $0 * 160) }
        var samples: [[String: Any]] = []
        for (step, offset) in (offsets + Array(offsets.reversed())).enumerated() {
            let before = counts()
            let oldOffset = list.contentOffset.y
            list.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
            try await fixture.waitForVisibleWorkToSettle()
            XCTAssertEqual(list.contentOffset.y, offset, accuracy: 1, "The measured scroll step actually moved the real List")
            let after = counts()
            let keys = Set(before.keys).union(after.keys)
            let delta = Dictionary(keys.map { ($0, after[$0, default: 0] - before[$0, default: 0]) }, uniquingKeysWith: { _, last in last })
            samples.append(["step": step, "oldOffset": oldOffset, "requestedOffset": offset,
                "actualOffset": list.contentOffset.y, "before": before, "after": after, "delta": delta,
                "listBounds": String(describing: list.bounds),
                "adjustedInsets": String(describing: list.adjustedContentInset)])
        }
        XCTAssertEqual(list.adjustedContentInset.top, measuredTopInset, "Native title bar must remain collapsed throughout the measured steps")
        let report: [String: Any] = ["uncredited": true, "warmup": warmup, "samples": samples,
            "notes": "Real hosted List programmatic offsets, not finger gestures. Lazy row realisation is distinguished from owner/content/layout/header reconstruction. No Store traffic, counter allowance or new body-time State reads."]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Home step-scroll redraw measurement JSON"; attachment.lifetime = .keepAlways
        add(attachment)
        fixture.capture("Home after measured step-scroll diagnostic")
    }

