import Testing
import Foundation
@testable import ClubhouseGo

// MARK: - Permission State & Timeout Tests

struct PermissionStateTests {

    // MARK: - toolInputSummary

    @Test func toolInputSummaryWithPath() {
        let perm = makePermission(toolInput: .object(["path": .string("/src/main.ts")]))
        #expect(perm.toolInputSummary == "/src/main.ts")
    }

    @Test func toolInputSummaryWithCommand() {
        let perm = makePermission(toolInput: .object(["command": .string("npm test")]))
        #expect(perm.toolInputSummary == "npm test")
    }

    @Test func toolInputSummaryWithPattern() {
        let perm = makePermission(toolInput: .object(["pattern": .string("*.swift")]))
        #expect(perm.toolInputSummary == "*.swift")
    }

    @Test func toolInputSummaryTruncatesLongCommand() {
        let longCommand = String(repeating: "x", count: 200)
        let perm = makePermission(toolInput: .object(["command": .string(longCommand)]))
        #expect(perm.toolInputSummary?.count == 120)
    }

    @Test func toolInputSummaryWithStringInput() {
        let perm = makePermission(toolInput: .string("simple input"))
        #expect(perm.toolInputSummary == "simple input")
    }

    @Test func toolInputSummaryNilWhenNoInput() {
        let perm = makePermission(toolInput: nil)
        #expect(perm.toolInputSummary == nil)
    }

    @Test func toolInputSummaryNilForArrayInput() {
        let perm = makePermission(toolInput: .array([.string("a"), .string("b")]))
        #expect(perm.toolInputSummary == nil)
    }

    @Test func toolInputSummaryNilForBoolInput() {
        let perm = makePermission(toolInput: .bool(true))
        #expect(perm.toolInputSummary == nil)
    }

    @Test func toolInputSummaryPrioritizesPath() {
        // When both path and command exist, path should win
        let perm = makePermission(toolInput: .object([
            "path": .string("/src/file.ts"),
            "command": .string("echo hello")
        ]))
        #expect(perm.toolInputSummary == "/src/file.ts")
    }

    // MARK: - isExpired

    @Test func isExpiredWhenDeadlinePassed() {
        let pastDeadline = Int(Date().timeIntervalSince1970 * 1000) - 5000
        let perm = makePermission(deadline: pastDeadline)
        #expect(perm.isExpired == true)
    }

    @Test func isNotExpiredWhenDeadlineInFuture() {
        let futureDeadline = Int(Date().timeIntervalSince1970 * 1000) + 60000
        let perm = makePermission(deadline: futureDeadline)
        #expect(perm.isExpired == false)
    }

    @Test func isNotExpiredWhenNoDeadline() {
        let perm = makePermission(deadline: nil)
        #expect(perm.isExpired == false)
    }

    // MARK: - PermissionRequest Codable

    @Test func decodePermissionRequestWithToolInput() throws {
        let json = """
        {"requestId":"req_001","agentId":"agent_001","toolName":"Bash","toolInput":{"command":"rm -rf /tmp/test"},"message":"Agent wants to run a bash command","timeout":120000,"deadline":1737000120000}
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(perm.requestId == "req_001")
        #expect(perm.agentId == "agent_001")
        #expect(perm.toolName == "Bash")
        #expect(perm.toolInputSummary == "rm -rf /tmp/test")
        #expect(perm.timeout == 120000)
        #expect(perm.deadline == 1737000120000)
    }

    @Test func decodePermissionRequestMinimal() throws {
        let json = """
        {"requestId":"req_002","agentId":"agent_001","toolName":"Read"}
        """
        let perm = try JSONDecoder().decode(PermissionRequest.self, from: Data(json.utf8))
        #expect(perm.toolInput == nil)
        #expect(perm.message == nil)
        #expect(perm.timeout == nil)
        #expect(perm.deadline == nil)
        #expect(perm.toolInputSummary == nil)
        #expect(perm.isExpired == false)
    }

    // MARK: - Permission Response Models

    @Test func encodePermissionResponseAllow() throws {
        let request = PermissionResponseRequest(requestId: "req_001", decision: "allow")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionResponseRequest.self, from: data)
        #expect(decoded.requestId == "req_001")
        #expect(decoded.decision == "allow")
    }

    @Test func encodePermissionResponseDeny() throws {
        let request = PermissionResponseRequest(requestId: "req_001", decision: "deny")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionResponseRequest.self, from: data)
        #expect(decoded.decision == "deny")
    }

    @Test func encodeStructuredPermissionApproved() throws {
        let request = StructuredPermissionRequest(requestId: "req_001", approved: true, reason: nil)
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(StructuredPermissionRequest.self, from: data)
        #expect(decoded.approved == true)
        #expect(decoded.reason == nil)
    }

    @Test func encodeStructuredPermissionDeniedWithReason() throws {
        let request = StructuredPermissionRequest(requestId: "req_001", approved: false, reason: "Too dangerous")
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(StructuredPermissionRequest.self, from: data)
        #expect(decoded.approved == false)
        #expect(decoded.reason == "Too dangerous")
    }

    // MARK: - ServerInstance permission filtering

    @Test @MainActor func serverInstanceFiltersExpiredPermissions() {
        let instance = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "localhost", mainPort: 4321, pairingPort: 4322, fingerprint: "fp")
        )

        let pastDeadline = Int(Date().timeIntervalSince1970 * 1000) - 5000
        instance.pendingPermissions["agent_001"] = PermissionRequest(
            requestId: "req_expired",
            agentId: "agent_001",
            toolName: "Bash",
            toolInput: nil,
            message: nil,
            timeout: nil,
            deadline: pastDeadline
        )

        #expect(instance.pendingPermission(for: "agent_001") == nil)
    }

    @Test @MainActor func serverInstanceReturnsValidPermission() {
        let instance = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "localhost", mainPort: 4321, pairingPort: 4322, fingerprint: "fp")
        )

        let futureDeadline = Int(Date().timeIntervalSince1970 * 1000) + 60000
        let perm = PermissionRequest(
            requestId: "req_valid",
            agentId: "agent_001",
            toolName: "Edit",
            toolInput: .object(["path": .string("/src/main.ts")]),
            message: "Edit file",
            timeout: 120000,
            deadline: futureDeadline
        )
        instance.pendingPermissions["agent_001"] = perm

        let result = instance.pendingPermission(for: "agent_001")
        #expect(result != nil)
        #expect(result?.requestId == "req_valid")
        #expect(result?.toolInputSummary == "/src/main.ts")
    }

    @Test @MainActor func serverInstanceReturnsNilForUnknownAgent() {
        let instance = ServerInstance(
            id: ServerInstanceID(value: "test"),
            protocolConfig: .v2(host: "localhost", mainPort: 4321, pairingPort: 4322, fingerprint: "fp")
        )

        #expect(instance.pendingPermission(for: "nonexistent") == nil)
    }

    // MARK: - Helpers

    private func makePermission(
        requestId: String = "req_001",
        agentId: String = "agent_001",
        toolName: String = "Bash",
        toolInput: JSONValue? = nil,
        message: String? = nil,
        timeout: Int? = nil,
        deadline: Int? = nil
    ) -> PermissionRequest {
        PermissionRequest(
            requestId: requestId,
            agentId: agentId,
            toolName: toolName,
            toolInput: toolInput,
            message: message,
            timeout: timeout,
            deadline: deadline
        )
    }
}
