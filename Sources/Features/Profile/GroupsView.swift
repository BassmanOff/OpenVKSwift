import SwiftUI

@MainActor
final class GroupsViewModel: ObservableObject {
    @Published private(set) var groups: [Community] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var loaded = false

    func loadIfNeeded(userID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await load(userID: userID, settings: settings)
    }

    func load(userID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: ItemsResponse<Community> = try await client.call(
                "groups.get",
                params: ["user_id": String(userID), "extended": "1", "fields": "photo_100,photo_50", "count": "1000"]
            )
            groups = res.items
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct GroupsView: View {
    var userID: Int = 0
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = GroupsViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.groups.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.groups.isEmpty {
                ErrorRetry(message: error) { Task { await model.load(userID: userID, settings: settings) } }
            } else if model.groups.isEmpty {
                Text("Нет сообществ")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.groups) { group in
                    HStack(spacing: 12) {
                        CachedImage(url: group.avatarURL) {
                            ZStack { OVK.Palette.background; Image(systemName: "person.3").foregroundColor(OVK.Palette.textSecondary) }
                        }
                        .frame(width: 44, height: 44)
                        .clipped()
                        .cornerRadius(4)
                        Text(group.name)
                            .foregroundColor(OVK.Palette.textPrimary)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
                .refreshable { await model.load(userID: userID, settings: settings) }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Сообщества")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(userID: userID, settings: settings) }
    }
}

/// Небольшая вьюха «ошибка + повторить» для переиспользования.
struct ErrorRetry: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundColor(OVK.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Повторить", action: retry)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
