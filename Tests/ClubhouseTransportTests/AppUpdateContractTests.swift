import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct AppUpdateContractTests {
    @Test func statusesAndEventsUseTheSameWholeObject() throws {
        let statuses = try AnnexContract.json("app-update-statuses.json")["values"].list
        let updates = try statuses.map { try $0.decode(AnnexAppUpdate.self) }
        #expect(Set(updates.map(\.state.rawValue)) == ["none", "available", "downloading", "ready", "unsupported"])
        #expect(updates.first { $0.state == .downloading }?.downloadProgress == 42.5)
        #expect(updates.filter(\.canRequest).allSatisfy { $0.state == .ready && $0.request?.isActive != true })
        let requests = updates.compactMap(\.request)
        #expect(Set(requests.map(\.state.rawValue)) == ["pending_approval", "waiting_for_idle", "restarting", "failed", "cancelled"])
        #expect(requests.filter(\.canCancel).map(\.state) == [.pendingApproval, .waitingForIdle])
        for frame in try AnnexContract.json("app-update-events.json")["frames"].list {
            let envelope = try frame.decode(AnnexEnvelope.self)
            #expect(envelope.type == "app_update:changed")
            let value = try #require(envelope.payload)
            let decoded = try value.decode(AnnexAppUpdate.self)
            if !updates.contains(decoded) {
                // The second request's pending state is event-only: snapshots may coalesce intermediate states.
                #expect(decoded.request?.state == .pendingApproval && decoded.request?.requestId.hasSuffix("000000000003") == true)
                #expect(decoded.currentVersion == "0.0.0-test" && decoded.availableVersion == "1.1.0")
            }
        }
        let approval = try AnnexContract.json("snapshot-app-update-approval.json")
        let update = try #require(approval["appUpdate"]).decode(AnnexAppUpdate.self)
        let review = try #require(approval["grantRequest"]?["update"]).decode(AnnexUpdateReview.self)
        #expect(update.request?.version == review.version && review.workingAgents.map(\.name) == ["planner"])
    }

    @Test func theFeatureNeedsTheCapabilityAndCommandsNotJustSnapshotData() throws {
        let body = try #require(AnnexContract.json("capabilities.json")["response"]?["body"])
        #expect(try body.decode(AnnexCapabilities.self).supportsAppUpdate)
        #expect(try body.decode(AnnexCapabilities.self).supportsAppUpdateCheck)
        guard case .object(var fields) = body else { return }
        fields["appUpdate"] = nil
        #expect(try !AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsAppUpdate)
        fields["appUpdate"] = .object(["version": .string("1")])
        #expect(try !AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsAppUpdate)
        fields["appUpdate"] = body["appUpdate"]
        if case .object(var update)? = fields["appUpdate"] {
            update["commands"] = .array([.string("app.update.request"), .string("app.update.cancel")])
            fields["appUpdate"] = .object(update)
            #expect(try AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsAppUpdate)
            #expect(try !AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsAppUpdateCheck)
        }
        fields["commands"] = .array([.string("grant.answer")])
        #expect(try !AnnexJSON.object(fields).decode(AnnexCapabilities.self).supportsAppUpdate)
    }

    @Test func everyUpdateCommandAndRefusalPassesThroughTheRealTransport() async throws {
        let caps = try #require(AnnexContract.json("capabilities.json")["response"])
        var codes: Set<String> = []
        for name in ["app.update.check", "app.update.request", "app.update.cancel", "grant.answer"] {
            for item in try AnnexContract.cases("commands/\(name).json") {
                let request = try #require(item["request"])
                let kind = try #require(AnnexContractTests.kind(from: request))
                let command = AnnexCommand(commandID: try #require(request["commandId"]?.string),
                                           epoch: try #require(request["epoch"]?.string), kind: kind)
                #expect(try JSONDecoder().decode(AnnexJSON.self, from: command.encoded()) == request)
                let io = AnnexContractIO([try AnnexContract.response(caps), try AnnexContract.response(item["response"])])
                let transport = try await annexContractTransport(io)
                _ = try await transport.read(.capabilities)
                let receipt = try await transport.execute(command)
                #expect(receipt.status.rawValue == item["response"]?["body"]?["status"]?.string)
                if let error = receipt.error {
                    codes.insert(error.code)
                    #expect(receipt.status == .rejected && !error.message.isEmpty)
                } else if name == "app.update.check" {
                    let result = try #require(receipt.result).decode(AnnexAppUpdate.self)
                    #expect([AnnexAppUpdate.State.ready, .downloading].contains(result.state))
                    #expect(result.request == nil)
                } else if name != "grant.answer" {
                    let result = try #require(receipt.result).decode(AnnexAppUpdate.Request.self)
                    #expect(result.state == (name == "app.update.request" ? .pendingApproval : .cancelled))
                }
            }
        }
        #expect(codes.isSuperset(of: ["update_unsupported", "dispatcher_unavailable", "update_not_ready", "update_request_active",
                                     "update_request_not_found", "update_restart_started", "grant_answer_failed", "grant_answer_not_offered",
                                     "grant_request_not_found", "update_approval_capacity", "update_check_running", "command_conflict"]))
    }

    @Test func checkingEventsAreSequencedWholeStatesWhileTheReceiptCanRemainPending() throws {
        let frames = try AnnexContract.json("app-update-check-events.json")["frames"].list
        var updates: [AnnexAppUpdate] = []
        for (index, frame) in frames.enumerated() {
            let event = try frame.decode(AnnexEnvelope.self)
            #expect(event.type == "app_update:changed")
            #expect(event.seq == Int64(1000 + index))
            updates.append(try #require(event.payload).decode(AnnexAppUpdate.self))
        }
        #expect(updates.map(\.state) == [.none, .available, .downloading, .downloading, .ready])
        #expect(updates.map(\.downloadProgress) == [0, 0, 0, 50, 100])
        #expect(updates.allSatisfy { $0.request == nil })
    }

    @Test func onlyAllowOnceCanCarryARestartMode() {
        for answer in [AnnexCommand.GrantAnswer.decline, .allowLasting] {
            #expect(throws: AnnexTransportError.malformedResponse) {
                try AnnexCommand(epoch: "e", kind: .answerGrant(requestID: "g", answer: answer, updateMode: .now)).encoded()
            }
        }
        #expect(throws: AnnexTransportError.malformedResponse) {
            try AnnexCommand(epoch: "e", kind: .cancelAppUpdate(requestID: "")).encoded()
        }
    }

}
