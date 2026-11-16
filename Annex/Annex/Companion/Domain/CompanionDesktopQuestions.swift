import Foundation

/// One live-chat presentation for pending questions whose complete prompts this phone cannot read.
/// The original requests remain in the conversation and decision queue for authoritative review.
struct CompanionDesktopQuestions: Sendable, Equatable {
    let questions: [CompanionQuestion]

    init?(items: [CompanionTimelineItem]) {
        let questions = items.compactMap { item -> CompanionQuestion? in
            guard case .question(let question) = item, question.resolution == .pending,
                  !question.canAnswerOnPhone else { return nil }
            return question
        }
        guard !questions.isEmpty else { return nil }
        self.questions = questions
    }

    var id: String { CompanionTimelineItem.question(questions[0]).id }
    var title: String { "\(questions.count) \(questions.count == 1 ? "question" : "questions") this phone can't answer" }
    func message(hostName: String?) -> String {
        let destination = hostName.flatMap { $0.isEmpty ? nil : $0 } ?? "your desktop"
        return "Answer \(questions.count == 1 ? "it" : "them") in Clubhouse on \(destination)."
    }
    func contains(entryID: String) -> Bool {
        questions.contains { CompanionTimelineItem.question($0).id == entryID }
    }
}
