import Foundation
import Testing
@testable import ClubhouseTransport

@Suite struct HelperRoutingTransportTests {
    @Test func optionalScopeUsesEscapedQueryParametersAndBareReadHasNoQuery() async throws {
        let page = try AnnexContract.json("helper-routing.json")
        let io = AnnexContractIO(try ["bare", "project", "agent", "project"].map { try AnnexContract.response(page[$0]?["response"]) })
        let transport = try await annexContractTransport(io)
        _ = try await transport.read(.helperRouting())
        _ = try await transport.read(.helperRouting(projectID: "a b+c&d"))
        _ = try await transport.read(.helperRouting(agentID: "helper/id"))
        _ = try await transport.read(.helperRouting(projectID: "p", agentID: "a"))
        let urls = await io.requests.compactMap(\.url?.absoluteString)
        #expect(urls == ["https://127.0.0.1:7432/api/v1/mobile/helper-routing", "https://127.0.0.1:7432/api/v1/mobile/helper-routing?projectId=a%20b%2Bc%26d", "https://127.0.0.1:7432/api/v1/mobile/helper-routing?agentId=helper/id", "https://127.0.0.1:7432/api/v1/mobile/helper-routing?projectId=p&agentId=a"])
    }
    @Test func completeNoMappingAndStaleReceiptsRemainDefinitiveAt409() async throws {
        for file in ["commands/helper.approve.json", "commands/helperRouting.update.json"] {
            for item in try AnnexContract.cases(file) where ["no_valid_mapping", "helper_routing_stale"].contains(item["name"]?.string ?? "") {
                let caps = try AnnexContract.json("capabilities.json")["response"]
                let io = AnnexContractIO([try AnnexContract.response(caps), try AnnexContract.response(item["response"])])
                let transport = try await annexContractTransport(io)
                _ = try await transport.read(.capabilities)
                let request = try #require(item["request"])
                let kind: AnnexCommand.Kind = file.contains("approve") ? .helperApprove(requestID: try #require(request["requestId"]?.string)) : .updateHelperRouting(try request.decode(AnnexHelperRoutingUpdate.self))
                let command = AnnexCommand(commandID: try #require(request["commandId"]?.string), epoch: try #require(request["epoch"]?.string), kind: kind)
                let receipt = try await transport.execute(command)
                #expect(receipt.status == .rejected && receipt.error?.message == item["response"]?["body"]?["error"]?["message"]?.string)
                #expect(try await transport.execute(command) == receipt)
                #expect(await io.requests.count == 2, "Even an explicit same-id replay is local; there is no new start")
                if receipt.error?.code == "helper_routing_stale" { #expect(receipt.settings != nil && receipt.revision == item["response"]?["body"]?["revision"]?.string) }
            }
        }
    }
}
