import SwiftUI

/// Виджет голосования внутри поста: до голоса — варианты для выбора (одиночный тап
/// для single-choice, чекбоксы + кнопка для multiple), после — результаты с барами.
/// После vote/unvote перезапрашиваем poll целиком (polls.getById) вместо ручного
/// пересчёта процентов на клиенте — надёжнее и не расходится с сервером.
struct PollCardView: View {
    @EnvironmentObject private var settings: AppSettings
    @State var poll: Poll
    @State private var selected: Set<Int> = []
    @State private var isVoting = false

    private var showsResults: Bool { poll.hasVoted || poll.closed || !poll.canVote }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "chart.bar.fill").foregroundColor(OVK.Palette.primary)
                Text(poll.question).font(.subheadline).fontWeight(.semibold)
            }

            if showsResults {
                ForEach(poll.answers) { answer in
                    resultRow(answer)
                }
            } else if poll.multiple {
                ForEach(poll.answers) { answer in
                    Button { toggle(answer.id) } label: { choiceRow(answer, checked: selected.contains(answer.id)) }
                        .buttonStyle(.plain)
                }
                Button { Task { await vote(Array(selected)) } } label: {
                    Text("Проголосовать")
                        .font(.subheadline).fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(OVK.Palette.primary)
                        .foregroundColor(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(selected.isEmpty || isVoting)
                .opacity(selected.isEmpty ? 0.5 : 1)
            } else {
                ForEach(poll.answers) { answer in
                    Button { Task { await vote([answer.id]) } } label: { choiceRow(answer, checked: false) }
                        .buttonStyle(.plain)
                        .disabled(isVoting)
                }
            }

            HStack(spacing: 4) {
                Text(votesText(poll.votes))
                if poll.closed {
                    Text("· Голосование завершено")
                } else if poll.hasVoted {
                    // Не гейтим по disable_unvote: в ленте сервер отдаёт его инвертированным.
                    // Если голосование неотзывное — deleteVote вернёт ошибку, просто no-op.
                    Text("·")
                    Button("Отменить голос") { Task { await unvote() } }
                        .disabled(isVoting)
                }
            }
            .font(.caption)
            .foregroundColor(OVK.Palette.textSecondary)
        }
        .padding()
        .background(OVK.Palette.background)
        .cornerRadius(8)
    }

    private func choiceRow(_ answer: Poll.Answer, checked: Bool) -> some View {
        HStack {
            Image(systemName: poll.multiple ? (checked ? "checkmark.square.fill" : "square") : "circle")
                .foregroundColor(checked ? OVK.Palette.primary : OVK.Palette.textSecondary)
            Text(answer.text).foregroundColor(OVK.Palette.textPrimary)
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func resultRow(_ answer: Poll.Answer) -> some View {
        let mine = poll.answerIDs.contains(answer.id)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(answer.text)
                    .foregroundColor(mine ? OVK.Palette.primary : OVK.Palette.textPrimary)
                    .fontWeight(mine ? .semibold : .regular)
                Spacer()
                Text("\(Int(answer.rate.rounded()))%")
                    .font(.caption)
                    .foregroundColor(OVK.Palette.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(OVK.Palette.card)
                    Capsule()
                        .fill(mine ? OVK.Palette.primary : OVK.Palette.textSecondary.opacity(0.5))
                        .frame(width: geo.size.width * CGFloat(answer.rate / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func vote(_ answerIDs: [Int]) async {
        guard !isVoting, !answerIDs.isEmpty, let token = settings.token else { return }
        isVoting = true
        defer { isVoting = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        let ok: Int? = try? await client.call(
            "polls.addVote",
            params: ["poll_id": String(poll.id), "answer_ids": answerIDs.map(String.init).joined(separator: ",")]
        )
        guard ok == 1 else { return }
        await refresh(client: client)
    }

    private func unvote() async {
        guard !isVoting, let token = settings.token else { return }
        isVoting = true
        defer { isVoting = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        _ = try? await client.execute("polls.deleteVote", params: ["poll_id": String(poll.id)])
        await refresh(client: client)
    }

    private func refresh(client: OVKClient) async {
        if let fresh: Poll = try? await client.call("polls.getById", params: ["poll_id": String(poll.id)]) {
            poll = fresh
            selected = []
        }
    }

    private func votesText(_ count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        if mod100 >= 11 && mod100 <= 14 { return "\(count) голосов" }
        switch mod10 {
        case 1: return "\(count) голос"
        case 2, 3, 4: return "\(count) голоса"
        default: return "\(count) голосов"
        }
    }
}
