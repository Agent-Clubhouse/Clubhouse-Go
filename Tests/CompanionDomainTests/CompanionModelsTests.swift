import Foundation
import ImageIO
import UniformTypeIdentifiers
import Testing
@testable import CompanionDomain

/// Implements only what every desktop answers, so every optional command falls back to the protocol's defaults:
/// what an older desktop looks like to the store.
@MainActor private final class BareCompanionService: CompanionService {
    func events() -> AsyncStream<CompanionEvent> { AsyncStream { $0.finish() } }
    func history(for target: CompanionTarget) async throws -> CompanionHistory { .init(items: []) }
    func send(_ request: CompanionSendRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func cancel(_ target: CompanionTarget, clientCommandID: String) async throws {}
    func respond(to approvalID: String, optionID: String, target: CompanionTarget, clientCommandID: String) async throws {}
    func spawn(_ request: CompanionSpawnRequest) async throws -> CompanionCommandReceipt { .init(clientCommandID: request.clientCommandID) }
    func reconnect(hostID: String) async {}
}

@Suite @MainActor struct CompanionServiceDefaultsTests {
    private let target = CompanionTarget(hostID: "host", projectID: "project", agentID: "agent")
    private var project: CompanionProjectTarget { .init(hostID: "host", projectID: "project") }

    private func unavailable(_ body: () async throws -> Void) async -> String? {
        do { try await body(); return nil } catch CompanionServiceError.unavailable(let message) { return message } catch { return "unexpected \(error)" }
    }

    @Test func olderDesktopsRefuseEveryOptionalCommandAsUnavailable() async {
        let service = BareCompanionService()
        let image = CompanionImageAttachment(bytes: .init(Data([1])), mimeType: "image/png", width: 1, height: 1)
        let helper = CompanionHelperRequest(id: "h", hostID: "host", projectID: "project", kind: .start, requesterID: "agent",
                                            requesterName: "Agent", helperName: "Helper", summary: "Start a helper")
        let file = CompanionChangedFile(path: "a.swift", code: "M", staged: false)
        var messages: [String?] = []
        messages.append(await unavailable { _ = try await service.upload(image, target: target) })
        messages.append(await unavailable { try await service.wake(target, resume: true, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.content(.image("ref"), target: target) })
        messages.append(await unavailable { _ = try await service.removeQueued("m", target: target, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.sessions(for: target) })
        messages.append(await unavailable { _ = try service.archive(for: target, sessionID: "s") })
        messages.append(await unavailable { try await service.answer("q", answers: [:], target: target, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.createOptions(for: project) })
        messages.append(await unavailable {
            _ = try await service.create(.init(project: project, name: "a", color: "indigo", clientCommandID: "c"))
        })
        messages.append(await unavailable { _ = try await service.settings(for: target) })
        messages.append(await unavailable { _ = try await service.updateSettings(.init(name: "b"), target: target, clientCommandID: "c") })
        messages.append(await unavailable { try await service.setModel("m", effort: nil, target: target, clientCommandID: "c") })
        messages.append(await unavailable { try await service.setLevel(.plan, target: target, clientCommandID: "c") })
        messages.append(await unavailable { try await service.answerHelperRequest(helper, approve: true, force: false, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.changes(for: project) })
        messages.append(await unavailable { _ = try await service.diff(of: file, in: project) })
        messages.append(await unavailable { _ = try await service.setProject(project, pinned: true, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.setProject(project, inactive: true, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.dismissFinishedQuick(target, clientCommandID: "c") })
        messages.append(await unavailable { _ = try await service.clearFinishedQuick(project, clientCommandID: "c") })
        messages.append(await unavailable { _ = try service.terminal(.project(project)) })
        #expect(messages.count == 21)
        for message in messages {
            #expect(message?.isEmpty == false && message?.hasPrefix("unexpected") == false, "Got \(String(describing: message))")
        }
        #expect(messages.last == CompanionTerminalAvailability.updateDesktop)
    }

    @Test func storeSurfacesTheDefaultsForArchivesTerminalsAndOptions() async {
        let store = CompanionStore(service: BareCompanionService())
        store.apply(.hosts([.init(id: "host", name: "Desk", endpoint: "desk.local", connection: .connected, projects: [
            .init(id: "project", name: "Project", agents: [.init(id: target, name: "Agent", subtitle: "", status: .idle)])
        ])]))
        await #expect(throws: CompanionServiceError.self) { try await store.sessions(for: target) }
        #expect(throws: CompanionServiceError.self) { try store.archive(for: target, sessionID: "s") }
        #expect(throws: CompanionServiceError.self) { try store.makeTerminal(.project(project)) }
        #expect(store.terminalAvailability(.project(project)) == .hidden, "No terminal support advertised")
        await #expect(throws: CompanionServiceError.self) { try await store.createOptions(for: project) }
    }
}

@Suite struct CompanionModelValueTests {
    @Test func targetsAreTheirOwnIdentity() {
        let target = CompanionTarget(hostID: "h", projectID: "p", agentID: "a")
        let project = CompanionProjectTarget(hostID: "h", projectID: "p")
        #expect(target.id == target)
        #expect(project.id == project)
    }

    @Test func wakeChoicesHaveIdentityAndIcons() {
        #expect(CompanionWakeChoice.resume.id == .resume)
        #expect(CompanionWakeChoice.newSession.systemImage == "plus")
        #expect(CompanionWakeChoice.resume.systemImage == "sun.max")
        #expect(CompanionWakeChoice.wake.systemImage == "sun.max")
    }

    @Test func imageBytesCompareByIdentityNotContents() {
        let one = CompanionImageBytes(Data([1, 2]))
        let same = CompanionImageBytes(Data([1, 2]))
        #expect(one == one)
        #expect(one != same)
        #expect(Set([one, one, same]).count == 2)
    }

    @Test func deliveryLabelsDescribeEachState() {
        typealias Delivery = CompanionMessage.Delivery
        #expect(Delivery.confirmed.label == nil)
        #expect(Delivery.sending.label == "Sending…")
        #expect(Delivery.accepted.label == "Accepted by desktop")
        #expect(Delivery.failed("x").label == "Not sent")
        #expect(Delivery.uncertain("x").label == "Delivery unknown")
        #expect(Delivery.uploading(completed: 0, total: 1).label == "Uploading image…")
        #expect(Delivery.uploading(completed: 1, total: 3).label == "Uploading image 2 of 3…")
        #expect(Delivery.uploading(completed: 3, total: 3).label == "Uploading image 3 of 3…", "Never counts past the total")
    }

    @Test func statusSymbolsAndTextTones() throws {
        let symbols = [CompanionAgentStatus.idle, .working, .approval, .waiting, .completed, .failed, .sleeping, .stopped, .starting].map(\.symbol)
        #expect(Set(symbols).count == symbols.count, "Each status has its own symbol")
        #expect(CompanionAgentStatus.sleeping.symbol == "moon.zzz")
        let theme = try #require(CompanionDesktopTheme.transported([
            "base": "#1e1e2e", "mantle": "#181825", "crust": "#11111b", "text": "#cdd6f4", "subtext0": "#a6adc8",
            "surface0": "#313244", "surface1": "#45475a", "accent": "#89b4fa", "warning": "#f9e2af", "error": "#f38ba8",
            "success": "#a6e3a1", "info": "#89dceb"]))
        let palette = CompanionPalette(theme: theme, dark: true)
        #expect(CompanionStatusDot.needsYou.textColor(in: palette) == palette.warning)
        #expect(CompanionStatusDot.error.textColor(in: palette) == palette.error)
        for dot in [CompanionStatusDot.working, .done, .sleeping, .starting] {
            #expect(dot.textColor(in: palette) == palette.secondaryLabel)
        }
    }
}

@Suite struct CompanionImageProcessorFailureTests {
    private func noisyPNG(side: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let pixels = try #require(context.data?.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * side))
        var seed: UInt32 = 11
        for index in 0..<(context.bytesPerRow * side) { seed = seed &* 1_664_525 &+ 1_013_904_223; pixels[index] = UInt8(truncatingIfNeeded: seed >> 24) }
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test func imageThatNeverFitsTheLimitIsTooLarge() throws {
        let png = try noisyPNG(side: 160)
        for types in [["image/png", "image/jpeg"], ["image/png"], ["image/jpeg"]] {
            let limits = CompanionAttachmentLimits(imageTypes: types, maxImageBytes: 64, maxCount: 1)
            #expect(throws: CompanionImageProcessor.Failure.tooLarge) { try CompanionImageProcessor.process(png, limits: limits) }
        }
    }

    @Test func emptyDataIsUnreadable() {
        let limits = CompanionAttachmentLimits(imageTypes: ["image/png"], maxImageBytes: 1_000, maxCount: 1)
        #expect(throws: CompanionImageProcessor.Failure.unreadable) { try CompanionImageProcessor.process(Data(), limits: limits) }
    }

    @Test func failuresExplainThemselves() {
        let failures: [CompanionImageProcessor.Failure] = [.unreadable, .tooLarge, .unsupported]
        let descriptions = failures.compactMap(\.errorDescription)
        #expect(descriptions.count == 3)
        #expect(Set(descriptions).count == 3)
        #expect(CompanionImageProcessor.Failure.tooLarge.localizedDescription.contains("too large"))
    }
}

@Suite struct CompanionMarkdownEdgeTests {
    private func paragraph(_ text: String) -> String? {
        guard case .paragraph(let value)? = CompanionMarkdown.parse(text).blocks.first else { return nil }
        return String(value.characters)
    }

    @Test func imagesShowTheirAltTextOrSource() {
        #expect(paragraph("See ![a diagram](https://example.com/d.png) here") == "See a diagram here")
        #expect(paragraph("See ![](https://example.com/d.png) here") == "See https://example.com/d.png here")
    }

    @Test func tableColumnCountFollowsItsAlignments() {
        guard case .table(let table)? = CompanionMarkdown.parse("| a | b | c |\n|:-|:-:|-:|\n| 1 | 2 | 3 |").blocks.first else {
            Issue.record("Expected a table"); return
        }
        #expect(table.columnCount == 3)
        #expect(table.alignments == [.leading, .center, .trailing])
    }

    @Test func documentIsMemoisedPerTextAndStreamingState() {
        let text = "# Title\n\nbody \(UUID().uuidString)"
        #expect(CompanionMarkdown.document(text) == CompanionMarkdown.document(text))
        #expect(CompanionMarkdown.document(text, streaming: true).blocks.count >= 1)
    }
}
