# Narrow test-spy delta only — unrun

Prior SOURCE/UX/authority/P2/native prebuild PASS397d4e8b is retained. Before receiving that verdict, author tightened ONE test helper: count every non-preview POST as a mutation, including unexpected generic agent.update/stop/fallback, rather than filtering only providerChange/Start. This broadens rejection, changes no product/UI/flow/adapter/transport/fixture sample/policy/docs, no test member, wait, count or filter. Exact delta below. Current 5a2986eba356d3c18471dacfdfaf52629dab45e8, manifest 7e080323bd13254797918fb82340feecd4fffdb2d3899c4780becf07a2b193cf/fullDiff 445340e1b590909d21b32a9c913bd6051ec61f2426c6ed6676e90f93f15567a2;40/58 map unchanged. All168Swift inventory/35pins re-pinned; sole changed input is this test file. Same core/auditor/outer/FIFO/guards/jobs2/900/afterFIFO and no actual execution yet. Request narrow exact-hash delta verdict before P2; no need repeat approved general source review.

```diff
diff --git a/Tests/CompanionDomainTests/CompanionProviderV2TransportTests.swift b/Tests/CompanionDomainTests/CompanionProviderV2TransportTests.swift
index 9483d69ae..ccbed9729 100644
--- a/Tests/CompanionDomainTests/CompanionProviderV2TransportTests.swift
+++ b/Tests/CompanionDomainTests/CompanionProviderV2TransportTests.swift
@@ -70,7 +70,8 @@ private actor ProviderV2IO: AnnexIO {
         return .init(status: body["status"] == .string("completed") ? 200 : 409, data: try JSONEncoder().encode(body))
     }
     func openWebSocket(_ request: URLRequest) throws -> any AnnexWebSocket { throw AnnexTransportError.disconnected }
-    func mutations() -> [AnnexJSON] { posts.filter { ["agent.providerChange", "agent.start"].contains($0["type"]?.string ?? "") } }
+    /// Every non-preview POST counts, including an unexpected generic update/stop/fallback.
+    func mutations() -> [AnnexJSON] { posts.filter { $0["type"] != .string("agent.providerPreview") } }
 }
 
 private actor ProviderV2Transport: AnnexTransporting {
```

Native-r5 re-pins source/this test hash and new P2 predecessor only; all app/hosted/UI build inputs and five native method bodies are byte-identical397→current. Separate fresh native A remains required after actual P2 originals; no old head was run or claimed. Native classifier/modes/counts/guards remain unchanged; ninth pure cross-packet test reads actual r5 configuration. Parent retains landing and runtime acceptance.
