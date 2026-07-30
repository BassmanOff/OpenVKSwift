import SwiftUI

/// Список друзей в стиле VK: квадратный аватар, имя, иконка устройства если онлайн.
struct FriendsView: View {
    var userID: Int = 0
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = FriendsViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.friends.isEmpty {
                FriendsStateView(message: "Загрузка друзей…", isLoading: true)
                    .frame(maxHeight: .infinity)
            } else if let error = model.errorMessage, model.friends.isEmpty {
                FriendsStateView(message: error) {
                    Task { await model.load(userID: userID, settings: settings) }
                }
                .frame(maxHeight: .infinity)
            } else if model.friends.isEmpty {
                FriendsStateView(message: "Нет друзей")
                    .frame(maxHeight: .infinity)
            } else {
                List(model.friends) { friend in
                    NavigationLink {
                        ProfileView(userID: friend.id)
                    } label: {
                        FriendRow(user: friend, isMutual: model.mutualFriendIDs.contains(friend.id))
                    }
                    .ovkPlainListRow()
                }
                .listStyle(.plain)
                .refreshable { await model.load(userID: userID, settings: settings) }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Друзья")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(userID: userID, settings: settings) }
    }
}

/// Полный список подписчиков профиля. Метод users.getFollowers возвращает сразу
/// объекты User, поэтому повторно резолвить имена и аватары не требуется.
struct FollowersView: View {
    let userID: Int
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = FollowersViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.users.isEmpty {
                FriendsStateView(message: "Загрузка подписчиков…", isLoading: true)
            } else if let error = model.errorMessage, model.users.isEmpty {
                FriendsStateView(message: error) { Task { await model.reload(userID: userID, settings: settings) } }
            } else if model.users.isEmpty {
                FriendsStateView(message: "Нет подписчиков")
            } else {
                List(model.users) { user in
                    NavigationLink { ProfileView(userID: user.id) } label: { FriendRow(user: user) }
                        .ovkPlainListRow()
                        .onAppear {
                            if user.id == model.users.last?.id {
                                Task { await model.loadMore(userID: userID, settings: settings) }
                            }
                        }
                }
                .listStyle(.plain)
                .refreshable { await model.reload(userID: userID, settings: settings) }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Подписчики")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(userID: userID, settings: settings) }
    }
}

@MainActor
final class FollowersViewModel: ObservableObject {
    @Published private(set) var users: [User] = []
    @Published private(set) var isLoading = false
    @Published private(set) var canLoadMore = true
    @Published var errorMessage: String?
    private var didLoad = false
    private var offset = 0
    private let pageSize = 100

    func loadIfNeeded(userID: Int, settings: AppSettings) async {
        guard !didLoad else { return }
        await reload(userID: userID, settings: settings)
    }

    func reload(userID: Int, settings: AppSettings) async {
        offset = 0
        users = []
        canLoadMore = true
        await loadPage(userID: userID, settings: settings)
        didLoad = true
    }

    func loadMore(userID: Int, settings: AppSettings) async {
        guard canLoadMore, !isLoading else { return }
        await loadPage(userID: userID, settings: settings)
    }

    private func loadPage(userID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let response: ItemsResponse<User> = try await client.call(
                "users.getFollowers",
                params: [
                    "user_id": String(userID),
                    "fields": "photo_100,photo_50,online,last_seen,screen_name",
                    "offset": String(offset),
                    "count": String(pageSize)
                ]
            )
            let existing = Set(users.map(\.id))
            let fresh = response.items.filter { !existing.contains($0.id) }
            users += fresh
            offset += response.items.count
            canLoadMore = offset < response.count && !fresh.isEmpty
        } catch {
            if !error.isCancellation { errorMessage = error.localizedDescription }
        }
    }
}

/// Единое спокойное состояние для вкладки друзей и списков друзей в профиле.
struct FriendsStateView: View {
    let message: String
    var isLoading = false
    var retry: (() -> Void)? = nil

    var body: some View {
        OVKListStateView(message: message, isLoading: isLoading, retry: retry)
    }
}

struct FriendRow: View {
    let user: User
    var isMutual = false

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: user.avatarURL) {
                ZStack {
                    OVK.Palette.background
                    Image(systemName: "person.crop.square")
                        .foregroundColor(OVK.Palette.textSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipped()
            .cornerRadius(OVK.Metrics.compactCornerRadius)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.fullName)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .lineLimit(1)
                if isMutual || user.online {
                    HStack(spacing: 4) {
                        if isMutual {
                            Text("Общие")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(OVK.Palette.primary)
                                .clipShape(Capsule())
                        }
                        if user.online {
                            if user.onlinePlatform.hasIcon {
                                OnlinePlatformIcon(platform: user.onlinePlatform)
                            }
                            Text("онлайн")
                                .font(.caption)
                                .foregroundColor(OVK.Palette.primary)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle()) // весь плитка — тап-цель, а не толькo аватар/текст
    }
}
