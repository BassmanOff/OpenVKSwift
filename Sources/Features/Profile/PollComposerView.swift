import SwiftUI

/// Черновик голосования, собираемый в композере поста. Само голосование создаётся на
/// сервере (polls.create) только при публикации поста — не в момент заполнения формы,
/// иначе отмена поста оставляла бы висящий поll без единого прикрепления.
struct PollDraft {
    var question = ""
    var answers: [String] = ["", ""]
    var isAnonymous = false
    var isMultiple = false
    var disableUnvote = false

    var trimmedAnswers: [String] {
        answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    var isValid: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && trimmedAnswers.count >= 2
    }
}

/// Форма создания голосования для нового поста. polls.max-opts (quirks.yml) = 10 вариантов.
struct PollComposerView: View {
    var onDone: (PollDraft) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PollDraft

    static let maxOptions = 10

    init(initial: PollDraft?, onDone: @escaping (PollDraft) -> Void) {
        self.onDone = onDone
        _draft = State(initialValue: initial ?? PollDraft())
    }

    var body: some View {
        NavigationView {
            Form {
                Section("Вопрос") {
                    TextField("О чём голосуем?", text: $draft.question)
                }
                Section("Варианты ответа") {
                    ForEach(draft.answers.indices, id: \.self) { i in
                        HStack {
                            TextField("Вариант \(i + 1)", text: $draft.answers[i])
                            if draft.answers.count > 2 {
                                Button { draft.answers.remove(at: i) } label: {
                                    Image(systemName: "minus.circle.fill").foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if draft.answers.count < Self.maxOptions {
                        Button("Добавить вариант") { draft.answers.append("") }
                    }
                }
                Section {
                    Toggle("Анонимное голосование", isOn: $draft.isAnonymous)
                    Toggle("Несколько вариантов ответа", isOn: $draft.isMultiple)
                    Toggle("Запретить отмену голоса", isOn: $draft.disableUnvote)
                }
            }
            .navigationTitle("Голосование")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { onDone(draft); dismiss() }
                        .disabled(!draft.isValid)
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
