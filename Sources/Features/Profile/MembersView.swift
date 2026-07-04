import SwiftUI

@MainActor
final class MembersViewModel: ObservableObject {
    @Published private(set) var members: [User] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
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
            let res: ItemsResponse<User> = try await client.call(
                "groups.getMembers",
                params: ["group_id": String(groupID), "fields": "photo_100,photo_50,online,last_seen,screen_name", "count": "1000"]
            )
            members = res.items
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct MembersView: View {
    let groupID: Int
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = MembersViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.members.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.members.isEmpty {
                ErrorRetry(message: error) { Task { await model.load(groupID: groupID, settings: settings) } }
            } else if model.members.isEmpty {
                Text("Нет участников")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.members) { user in
                    NavigationLink {
                        ProfileView(userID: user.id)
                    } label: {
                        row(user)
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.load(groupID: groupID, settings: settings) }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Участники")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(groupID: groupID, settings: settings) }
    }

    private func row(_ user: User) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: user.avatarURL) {
                ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(width: 44, height: 44)
            .clipped()
            .cornerRadius(4)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.fullName)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .lineLimit(1)
                if user.online {
                    HStack(spacing: 4) {
                        if user.onlinePlatform.hasIcon {
                            OnlinePlatformIcon(platform: user.onlinePlatform)
                        }
                        Text("онлайн").font(.caption).foregroundColor(OVK.Palette.primary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
