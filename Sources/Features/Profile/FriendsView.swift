import SwiftUI

/// Список друзей в стиле VK: квадратный аватар, имя, иконка устройства если онлайн.
struct FriendsView: View {
    var userID: Int = 0
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = FriendsViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.friends.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.friends.isEmpty {
                VStack(spacing: 12) {
                    Text(error)
                        .foregroundColor(OVK.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Повторить") { Task { await model.load(userID: userID, settings: settings) } }
                }
                .padding()
            } else if model.friends.isEmpty {
                Text("Нет друзей")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.friends) { friend in
                    NavigationLink {
                        ProfileView(userID: friend.id)
                    } label: {
                        FriendRow(user: friend)
                    }
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

private struct FriendRow: View {
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
                        Text("онлайн")
                            .font(.caption)
                            .foregroundColor(OVK.Palette.primary)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}
