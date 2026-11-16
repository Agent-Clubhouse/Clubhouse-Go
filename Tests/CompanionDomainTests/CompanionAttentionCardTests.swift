import Testing
@testable import CompanionDomain

struct CompanionAttentionCardTests {
    private func item(_ kind: CompanionAttentionItem.Kind) -> CompanionAttentionItem {
        .init(agent: .init(id: .init(hostID: "mac", projectID: "project", agentID: "agent"), name: "Agent", subtitle: "", status: .approval),
              hostName: "Studio Mac", projectName: "Clubhouse", kind: kind)
    }

    @Test func approvalUsesActionTitleAndSeparateToolMetadata() {
        let card = item(.approval(.init(id: "request", toolName: "mcp__desktop__Bash", summary: "Build the app", title: "Run xcodebuild")))
        #expect(card.cardHeadline == "Run xcodebuild")
        #expect(card.cardToolName == "Bash")
        #expect(card.cardSupportingText == nil)
        #expect(card.detail == "Needs permission to use Bash", "Other callers retain the existing reason text")
    }

    @Test func missingActionUsesSummaryOrAnHonestReviewFallback() {
        let summary = item(.approval(.init(id: "summary", toolName: "Write", summary: "Edit README.md")))
        #expect(summary.cardHeadline == "Edit README.md")
        let missing = item(.approval(.init(id: "missing", toolName: "Bash", summary: "Review the requested action")))
        #expect(missing.cardHeadline == "Review permission request")
        #expect(missing.cardToolName == "Bash")
        #expect(item(.unreviewed).cardHeadline == "Review permission request")
    }

    @Test func questionLeadsWithItsPromptWithoutRepeatingIt() {
        let question = CompanionQuestion(id: "question", prompts: [.init(id: "choice", text: "Which target should I build?", options: [], allowsMultiple: false, allowsFreeText: true)])
        let card = item(.question(question))
        #expect(card.cardHeadline == "Which target should I build?")
        #expect(card.cardSupportingText == nil && card.cardToolName == nil)
        #expect(item(.question(.init(id: "empty", prompts: []))).cardHeadline == "Answer in chat")
    }
}
