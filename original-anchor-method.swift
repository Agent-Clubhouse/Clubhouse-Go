    func testRealListScrollAnchorRestoresAfterDispatchWithoutResettingScope() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        try await fixture.mount()
        let anchor = try XCTUnwrap(fixture.anchor)
        let list = try XCTUnwrap(fixture.list(in: fixture.window))
        XCTAssertGreaterThan(list.contentSize.height, list.bounds.height * 2)
        list.setContentOffset(CGPoint(x: 0, y: 900), animated: false)
        try await fixture.wait { anchor.bookmark?.id != nil && anchor.bookmark?.id != .summary && anchor.bookmark?.id != .desktops }
        let saved = try XCTUnwrap(anchor.bookmark)
        let frame = try XCTUnwrap(anchor.testFrames[saved.id])
        XCTAssertTrue(frame.intersects(anchor.testViewport), "The saved anchor is a real visible List row")
        fixture.select(.dispatcher)
        try await fixture.wait { fixture.store.selection == fixture.dispatcher }
        fixture.select(.home)
        try await fixture.wait { !anchor.testRestoring && anchor.testFrames[saved.id]?.intersects(anchor.testViewport) == true }
        XCTAssertEqual(fixture.issuedAnchors.last, saved.id, "Restore must target the saved row")
        fixture.assertAlignment(saved)
        fixture.push(.agent(fixture.hosts[2].projects[0].agents[1].id))
        try await fixture.wait { fixture.isFrozen }
        fixture.assertPushCost()
        fixture.pop()
        try await fixture.wait { !fixture.isFrozen && !anchor.testRestoring && anchor.testFrames[saved.id]?.intersects(anchor.testViewport) == true }
        XCTAssertEqual(fixture.issuedAnchors.last, saved.id, "Restore must target the saved row")
        fixture.assertAlignment(saved)
        XCTAssertTrue(fixture.anchor === anchor, "The Home state owner survives the hidden subtree")
        XCTAssertGreaterThan(try XCTUnwrap(fixture.list(in: fixture.window)).contentOffset.y, 0, "Return cannot silently reset to the top")
        fixture.capture("Home restores an explicit row anchor")
    }