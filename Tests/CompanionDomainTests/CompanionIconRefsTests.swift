import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import ClubhouseTransport
@testable import CompanionDomain

@Suite struct CompanionIconRefsTests {
    @Test func annexSnapshotRefsSurviveTruncationButCompleteMapsChangeAndRemoveIcons() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let initial = AnnexEnvelope(type: "snapshot", payload: try #require(ContractFixtures.json("snapshot-icon-refs.json")["value"]))
        var catalog = await CompanionIconCatalog().applyingSnapshot(initial, usesReferences: true, host: "host", store: store)
        #expect(catalog.agents.count == 2 && catalog.projects.count == 1)
        let before = catalog
        let agent = try #require(catalog.agents["durable_chat"])
        let route = try ContractFixtures.json("icon-route.json")
        let base64 = try #require(route["imageBase64"]?.string)
        let data = try #require(Data(base64Encoded: base64))
        await store.setFetcher(for: "host") { _, _ in .init(status: 200, contentType: "image/png", data: data, version: agent.version) }
        #expect(await store.image(for: agent, points: 32) != nil)

        guard case .object(var payload)? = try ContractFixtures.json("snapshot-truncated.json")["value"],
              case .object(var marker)? = payload["snapshotTruncated"] else { Issue.record("Missing truncation"); return }
        for omitted in [["canvasState", "appCanvasState"], ["agentIcons", "projectIcons"], ["iconRefs"]] {
            marker["omitted"] = .array(omitted.map(AnnexJSON.string))
            payload["snapshotTruncated"] = .object(marker)
            payload["agentIcons"] = .object([:]); payload["projectIcons"] = .object([:])
            // A declared omission is unknown even if an empty placeholder is sent.
            payload["iconRefs"] = omitted == ["iconRefs"] ? .object(["agents": .object([:]), "projects": .object([:])]) : nil
            let snapshot = AnnexEnvelope(type: "snapshot", payload: .object(payload))
            catalog = await catalog.applyingSnapshot(snapshot, usesReferences: true, host: "host", store: store)
            #expect(catalog == before)
            #expect(await store.image(for: agent, points: 32) != nil)
            #expect((CompanionIconCatalog.omissionNotice(snapshot, usesReferences: true) != nil) == (omitted == ["iconRefs"]))
        }
        let changed = try ContractFixtures.json("snapshot-icon-refs-changed.json")
        #expect(changed["before"]?["version"]?.string == agent.version)
        let replacement = AnnexEnvelope(type: "snapshot", payload: .object([
            "iconRefs": .object(["agents": .object(["durable_chat": try #require(changed["changed"])]), "projects": .object([:])])
        ]))
        catalog = await catalog.applyingSnapshot(replacement, usesReferences: true, host: "host", store: store)
        #expect(catalog.agents["durable_chat"]?.version == changed["changed"]?["version"]?.string)
        #expect(catalog.agents["durable_dispatcher"] == nil && catalog.projects.isEmpty)
        #expect(await store.image(for: agent, points: 32) == nil, "A complete replacement retires the old association")
        let removed = AnnexEnvelope(type: "snapshot", payload: .object([
            "iconRefs": .object(["agents": .object([:]), "projects": .object([:])])
        ]))
        catalog = await catalog.applyingSnapshot(removed, usesReferences: true, host: "host", store: store)
        #expect(catalog.references.isEmpty && changed["removed"] == .null)
        #expect(CompanionIconCatalog.omissionNotice(removed, usesReferences: true) == nil)
    }

    static func fixture(_ name: String) throws -> AnnexJSON {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/IconRefs")
        return try JSONDecoder().decode(AnnexJSON.self, from: Data(contentsOf: root.appendingPathComponent(name)))
    }
    @Test func pinnedSnapshotCasesDistinguishUnknownReplacementAndRemoval() throws {
        let f = try Self.fixture("icon-refs-cases.json")
        for c in f["snapshots"].arrayValue {
            var catalog = CompanionIconCatalog()
            catalog.applyReferences(f["stored"], host: "host")
            catalog.applyReferences(c["iconRefs"], host: "host")
            switch c["name"]?.string {
            case "complete": #expect(catalog.agents.count == 2 && catalog.projects.count == 1)
            case "one removed", "one sub-map missing": #expect(catalog.agents.count == 1 && catalog.projects.count == 1)
            case "all removed", "partial entry": #expect(catalog.agents.isEmpty && catalog.projects.isEmpty)
            default: #expect(catalog.agents.count == 2 && catalog.projects.count == 1)
            }
        }
    }
    @Test func realFourFormatFixturesValidateBytesHashTypeAndDimensions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CompanionIconStore(directory: directory)
        for image in try Self.fixture("icon-images.json")["images"].arrayValue {
            let metadata = try #require(CompanionIconMetadata(image)), data = try #require(Data(base64Encoded: image["base64"]!.string!))
            let key = CompanionIconReference(host: "host", kind: .agent, id: metadata.type, version: image["version"]!.string!, metadata: metadata)
            await store.setReferences([key], for: "host")
            await store.setFetcher(for: "host") { _, _ in .init(status: 200, contentType: metadata.type, data: data, version: key.version) }
            #expect(await store.image(for: key, points: 32) != nil)
            #expect(await store.image(for: key, points: 32) != nil)
        }
    }
    @Test func malformedMetadataCannotCreateAReference() throws {
        let f = try Self.fixture("icon-images.json")["images"].arrayValue[0]
        for (field, value) in [("version", AnnexJSON.string(String(repeating: "A", count: 64))), ("type", .string("image/svg+xml")), ("bytes", .integer(73729)), ("width", .integer(257)), ("height", .integer(0))] {
            guard case .object(var data) = f else { return }; data[field] = value
            #expect(CompanionIconMetadata(.object(data)) == nil)
        }
    }
}

private actor IconReplies {
    var response: CompanionIconStore.Response
    var calls = 0
    var gate: CheckedContinuation<Void, Never>?
    var held = false
    init(_ response: CompanionIconStore.Response) { self.response = response }
    func set(_ value: CompanionIconStore.Response, held: Bool = false) { response = value; self.held = held }
    func fetch() async -> CompanionIconStore.Response { calls += 1; if held { await withCheckedContinuation { gate = $0 } }; return response }
    func release() { held = false; gate?.resume(); gate = nil }
}

extension CompanionIconRefsTests {
    @Test func remoteMismatchValidationAndVersionLongFencesSurviveSnapshotAndPressure() async throws {
        let image = try Self.fixture("icon-images.json")["images"].arrayValue[0]
        let metadata = try #require(CompanionIconMetadata(image)), data = Data(base64Encoded: image["base64"]!.string!)!, version = image["version"]!.string!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        let missing = CompanionIconReference(host: "host", kind: .agent, id: "missing", version: version, metadata: metadata)
        let stale = CompanionIconReference(host: "host", kind: .agent, id: "stale", version: String(repeating: "0", count: 64), metadata: metadata)
        let pressure = (0..<1030).map { CompanionIconReference(host: "host", kind: .agent, id: "pressure\($0)", version: version, metadata: metadata) }
        let all = Set(pressure + [missing, stale])
        await store.setReferences(all, for: "host")
        let replies = IconReplies(.init(status: 404, contentType: "application/json", data: Data()))
        await store.setFetcher(for: "host") { _, _ in await replies.fetch() }
        #expect(await store.image(for: missing, points: 32) == nil)
        await replies.set(.init(status: 200, contentType: metadata.type, data: data, version: version))
        #expect(await store.image(for: stale, points: 32) == nil)
        await replies.set(.init(status: 500, contentType: "", data: Data()))
        for key in pressure { _ = await store.image(for: key, points: 32) }
        let before = await replies.calls
        await store.setReferences(all, for: "host")
        #expect(await store.image(for: missing, points: 32) == nil)
        #expect(await store.image(for: stale, points: 32) == nil)
        #expect(await replies.calls == before)
        // A genuinely new version can use the already validated stale bytes without downloading.
        var current = stale; current = .init(host: current.host, kind: current.kind, id: current.id, version: version, metadata: metadata)
        await store.setReferences([current], for: "host")
        #expect(await store.image(for: current, points: 32) != nil)
        #expect(await replies.calls == before)
        for (index, response) in [
            CompanionIconStore.Response(status: 200, contentType: "image/jpeg", data: data, version: version),
            .init(status: 200, contentType: "image/png", data: data + Data([0]), version: version),
            .init(status: 200, contentType: "image/png", data: data, version: String(repeating: "1", count: 64)),
            .init(status: 304, contentType: "image/png", data: Data(), version: version)
        ].enumerated() {
            let key = CompanionIconReference(host: "host", kind: .agent, id: "bad\(index)", version: version, metadata: metadata)
            await store.setReferences([key], for: "host"); await replies.set(response)
            #expect(await store.image(for: key, points: 32) == nil)
        }
    }

    @Test func associationRemovalCancelsInflightAndCannotResurrectOnDisk() async throws {
        let image = try Self.fixture("icon-images.json")["images"].arrayValue[0], metadata = try #require(CompanionIconMetadata(image))
        let key = CompanionIconReference(host: "host", kind: .agent, id: "a", version: image["version"]!.string!, metadata: metadata)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root), replies = IconReplies(.init(status: 200, contentType: metadata.type, data: Data(base64Encoded: image["base64"]!.string!)!, version: key.version))
        await store.setReferences([key], for: "host"); await replies.set(await replies.response, held: true)
        await store.setFetcher(for: "host") { _, _ in await replies.fetch() }
        let task = Task { await store.image(for: key, points: 32) }
        for _ in 0..<1000 { if await replies.gate != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        await store.setReferences([], for: "host"); await replies.release()
        #expect(await task.value == nil)
        #expect(await store.image(for: key, points: 32) == nil)
        #expect(!FileManager.default.fileExists(atPath: await store.fileURL(for: key).path))
    }

    @MainActor @Test func negotiatedServiceKeepsUnknownRefsAndDispatcherAcrossRESTButHonorsRemoval() async throws {
        let image = try Self.fixture("icon-images.json")["images"].arrayValue[0]
        let h = try await LiveServiceHarness.start { t in
            await t.setCapability("iconRefs", .object(["version": .integer(1)]))
            await t.setFeature("dispatcher", .object(["version": .integer(1), "enabled": .bool(true), "flagOn": .bool(true), "projectId": .string("__dispatcher__")]))
        }
        defer { h.stop() }
        let dispatcher: AnnexJSON = .object(["enabled": .bool(true), "flagOn": .bool(true), "agent": .object(["id": .string("dispatcher"), "name": .string("Dispatcher")])])
        await h.transport.emit(h.snapshotEvent(["dispatcher": dispatcher, "iconRefs": .object(["agents": .object(["agent": image, "dispatcher": image]), "projects": .object(["project": image])]), "agentIcons": .object([:]), "projectIcons": .object([:])]))
        try await h.waitUntil { h.host?.projects.first?.agents.first?.icon != nil && h.host?.dispatcher?.liveAgent?.icon != nil }
        let before = h.host?.projects.first?.agents.first?.icon
        guard case .object(var truncation)? = try ContractFixtures.json("snapshot-truncated.json")["value"]?["snapshotTruncated"] else {
            Issue.record("Missing truncation"); return
        }
        truncation["omitted"] = .array([.string("iconRefs")])
        await h.transport.emit(h.snapshotEvent(["agentIcons": .object([:]), "projectIcons": .object([:]), "snapshotTruncated": .object(truncation)]))
        try await h.refreshCatalog()
        #expect(h.host?.projects.first?.agents.first?.icon == before)
        #expect(h.host?.dispatcher?.liveAgent?.icon != nil)
        #expect(h.host?.snapshotTruncationNotice != nil)
        await h.transport.emit(h.snapshotEvent(["iconRefs": .object(["agents": .object([:]), "projects": .object([:])])]))
        try await h.waitUntil { h.host?.projects.first?.agents.first?.icon == nil && h.host?.dispatcher?.liveAgent?.icon == nil }
        #expect(h.host?.snapshotTruncationNotice == nil)
        #expect(h.host?.connection == .connected)
    }
}

extension CompanionIconRefsTests {
    @Test func exactRemoteByteAndPixelLimitsAndMetadataMismatch() async throws {
        let image = try Self.fixture("icon-images.json")["images"].arrayValue[0]
        var data = Data(base64Encoded: image["base64"]!.string!)!
        data.append(Data(repeating: 0, count: 73728 - data.count))
        guard case .object(var fields) = image else { return }
        fields["version"] = .string(CompanionIconReference.digest(data)); fields["bytes"] = .integer(Int64(data.count))
        let metadata = try #require(CompanionIconMetadata(.object(fields)))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        var key = CompanionIconReference(host: "host", kind: .project, id: "exact", version: fields["version"]!.string!, metadata: metadata)
        await store.setReferences([key], for: "host")
        let payload = data, version = key.version
        await store.setFetcher(for: "host") { _, _ in .init(status: 200, contentType: "image/png", data: payload, version: version) }
        #expect(await store.image(for: key, points: 32) != nil)
        fields["width"] = .integer(2)
        key.metadata = try #require(CompanionIconMetadata(.object(fields)))
        await store.setReferences([key], for: "host")
        #expect(await store.image(for: key, points: 32) == nil)
        fields["width"] = .integer(256); fields["height"] = .integer(256)
        #expect(CompanionIconMetadata(.object(fields)) != nil)
        fields["width"] = .integer(257)
        #expect(CompanionIconMetadata(.object(fields)) == nil)
    }
}

extension CompanionIconRefsTests {
    @Test func temporaryUnavailableBacksOffWithoutBecomingVersionLongMissing() async throws {
        let row = try Self.fixture("icon-images.json")["images"].arrayValue[0], metadata = try #require(CompanionIconMetadata(row))
        let key = CompanionIconReference(host: "host", kind: .agent, id: "temporary", version: row["version"]!.string!, metadata: metadata)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = AnnexManualClock(), store = CompanionIconStore(directory: root, now: clock.clock.now)
        let replies = IconReplies(.init(status: 503, contentType: "application/json", data: Data()))
        await store.setReferences([key], for: "host"); await store.setFetcher(for: "host") { _, _ in await replies.fetch() }
        #expect(await store.image(for: key, points: 32) == nil)
        #expect(await store.image(for: key, points: 32) == nil); #expect(await replies.calls == 1)
        clock.advance(by: .seconds(31))
        await replies.set(.init(status: 200, contentType: metadata.type, data: Data(base64Encoded: row["base64"]!.string!)!, version: key.version))
        #expect(await store.image(for: key, points: 32) != nil); #expect(await replies.calls == 2)
    }
}

extension CompanionIconRefsTests {
    @Test func realRouteFixtureAndConditional304UseOnlyValidatedKeptBytes() async throws {
        let route = try Self.fixture("icon-route.json"), cases = try Self.fixture("icon-refs-cases.json")
        let row = try #require(cases["stored"]?["agents"]?["a1"]), metadata = try #require(CompanionIconMetadata(row))
        let key = CompanionIconReference(host: "route", kind: .agent, id: "a1", version: row["version"]!.string!, metadata: metadata)
        let body = try #require(Data(base64Encoded: route["imageBase64"]!.string!))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        await store.setReferences([key], for: "route")
        let replies = IconReplies(.init(status: 304, contentType: "", data: Data(), version: key.version))
        await replies.set(await replies.response, held: true)
        await store.setFetcher(for: "route") { _, _ in await replies.fetch() }
        let task = Task { await store.image(for: key, points: 32) }
        for _ in 0..<1000 { if await replies.gate != nil { break }; try await Task.sleep(for: .milliseconds(1)) }
        #expect(await store.insert(body, for: key))
        await replies.release()
        #expect(await task.value != nil)
        #expect(await store.image(for: key, points: 32) != nil); #expect(await replies.calls == 1)
        #expect(CompanionIconMetadata.version(etag: route["current"]?["response"]?["headers"]?["etag"]?.string) == key.version)
        #expect(CompanionIconMetadata.version(etag: "W/\"" + key.version + "\"") == nil)
    }
}

extension CompanionIconRefsTests {
    @Test func rotatedJPEGValidatesRawDimensionsAndProducesUprightAvatarPixels() async throws {
        let canvas = try #require(CGContext(data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 800,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); canvas.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        canvas.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); canvas.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        let bytes = NSMutableData(), sourceImage = try #require(canvas.makeImage())
        let destination = try #require(CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, sourceImage, [kCGImagePropertyOrientation: 6, kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let data = bytes as Data, source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 200)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 100)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        let version = CompanionIconReference.digest(data)
        let metadata = try #require(CompanionIconMetadata(.object(["version": .string(version), "type": .string("image/jpeg"), "bytes": .integer(Int64(data.count)), "width": .integer(200), "height": .integer(100)])))
        let key = CompanionIconReference(host: "rotated", kind: .agent, id: "jpeg", version: version, metadata: metadata)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CompanionIconStore(directory: root)
        await store.setReferences([key], for: "rotated")
        await store.setFetcher(for: "rotated") { _, _ in .init(status: 200, contentType: "image/jpeg", data: data, version: version) }
        let output = try #require(await store.image(for: key, points: 32))
        #expect(output.cgImage.width == 48); #expect(output.cgImage.height == 96)
        let sample = try #require(CGContext(data: nil, width: 1, height: 2, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(output.cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 2))
        let pixels = try #require(sample.data).assumingMemoryBound(to: UInt8.self)
        #expect(pixels[0] > 200 && pixels[2] < 50)
        #expect(pixels[4] < 50 && pixels[6] > 200)
        print("EXIF_JPEG raw=200x100 orientation=6 accepted=true uprightAvatar=48x96 top=red bottom=blue")
    }
}
