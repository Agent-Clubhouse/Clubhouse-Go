import SwiftUI

struct CompanionQuestionCard: View {
    let question: CompanionQuestion
    var canRespond: Bool
    var respond: ([String: CompanionAnswer]) -> Void
    @State private var selections: [String: Set<String>] = [:]
    @State private var text: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(title, systemImage: "questionmark.bubble.fill").font(.headline).foregroundStyle(.orange)
            ForEach(question.prompts) { prompt in
                VStack(alignment: .leading, spacing: 10) {
                    Text(prompt.text).font(.subheadline.weight(.semibold))
                    ForEach(prompt.options) { option in
                        Button {
                            var selected = selections[prompt.id] ?? []
                            if prompt.allowsMultiple {
                                if selected.contains(option.id) { selected.remove(option.id) } else { selected.insert(option.id) }
                            } else { selected = [option.id] }
                            selections[prompt.id] = selected
                            text[prompt.id] = ""
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selections[prompt.id]?.contains(option.id) == true ? "checkmark.circle.fill" : "circle")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.label)
                                    if let detail = option.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 0)
                            }.padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selections[prompt.id]?.contains(option.id) == true ? .isSelected : [])
                    }
                    if prompt.allowsFreeText {
                        TextField("Your answer", text: Binding(get: { text[prompt.id] ?? "" }, set: { text[prompt.id] = $0; selections[prompt.id] = [] }), axis: .vertical)
                            .textFieldStyle(.roundedBorder).lineLimit(2...6)
                            .accessibilityLabel("Answer: \(prompt.text)")
                    }
                }
                .disabled(question.resolution != .pending || !canRespond)
            }
            if question.resolution == .pending {
                Button("Send answers", systemImage: "arrow.up") { respond(answers) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRespond || !CompanionStore.validAnswers(answers, for: question))
            } else if question.resolution == .submitting { ProgressView("Sending answers…") }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.orange.opacity(0.45)))
    }
    private var answers: [String: CompanionAnswer] {
        Dictionary(uniqueKeysWithValues: question.prompts.map { prompt in
            let freeText = text[prompt.id] ?? ""
            if !freeText.isEmpty { return (prompt.id, .text(freeText)) }
            let choices = prompt.options.filter { selections[prompt.id]?.contains($0.id) == true }.map(\.id)
            return (prompt.id, prompt.allowsMultiple ? .choices(choices) : .text(choices.first ?? ""))
        })
    }
    private var title: String {
        switch question.resolution {
        case .pending: "The agent has a question"
        case .submitting: "Sending your answer"
        case .answered: "Answered"
        case .uncertain: "Answer delivery unknown — refresh to check"
        }
    }
}
