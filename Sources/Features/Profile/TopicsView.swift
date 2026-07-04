import SwiftUI

@MainActor
final class TopicsViewModel: ObservableObject {
    @Published private(set) var topics: [Topic] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    /// Догадка о virtual_id темы = её ранг в списке, отсортированном по DB id (см. обход бага API).
    @Published private(set) var vidGuess: [Int: Int] = [:]
    private var loaded = false

    func loadIfNeeded(groupID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await load(groupID: groupID, settings: settings)
    }

    func load(groupID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: ItemsResponse<Topic> = try await client.call(
                "board.getTopics",
                params: ["group_id": String(groupID), "count": "100"]
            )
            topics = res.items
            let sorted = res.items.map(\.topicID).sorted()
            vidGuess = Dictionary(uniqueKeysWithValues: sorted.enumerated().map { ($1, $0 + 1) })
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TopicsView: View {
    let groupID: Int
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = TopicsViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.topics.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.topics.isEmpty {
                ErrorRetry(message: error) { Task { await model.load(groupID: groupID, settings: settings) } }
            } else if model.topics.isEmpty {
                Text("Нет обсуждений")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.topics) { topic in
                    NavigationLink {
                        TopicView(
                            groupID: groupID,
                            topicDBID: topic.topicID,
                            virtualIDGuess: model.vidGuess[topic.topicID] ?? topic.topicID,
                            title: topic.title
                        )
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: topic.isClosed ? "lock.fill" : "bubble.left.and.bubble.right")
                                .foregroundColor(OVK.Palette.textSecondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(topic.title)
                                    .foregroundColor(OVK.Palette.textPrimary)
                                    .lineLimit(2)
                                Text("\(topic.comments) сообщений")
                                    .font(.caption)
                                    .foregroundColor(OVK.Palette.textSecondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.load(groupID: groupID, settings: settings) }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Обсуждения")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(groupID: groupID, settings: settings) }
    }
}
