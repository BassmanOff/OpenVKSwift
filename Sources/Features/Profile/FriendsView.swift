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
                        FriendRow(user: friend)
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
                if user.online {
                    HStack(spacing: 4) {
                        if user.onlinePlatform.hasIcon {
                            OnlinePlatformIcon(platform: user.onlinePlatform)
                        }
                        Text("онлайн")
                            .font(.caption)
                            .foregroundColor(OVK.Palette.primary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle()) // весь плитка — тап-цель, а не толькo аватар/текст
    }
}
