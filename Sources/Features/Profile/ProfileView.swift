import SwiftUI

/// Профиль в стиле ВКонтакте 2.0 (2013–2014): плоские белые блоки на сером фоне.
/// Список (List) — чтобы pull-to-refresh работал и на iOS 15.
struct ProfileView: View {
    /// nil → собственный профиль (корень вкладки); иначе — чужой (пушится из списка друзей).
    var userID: Int? = nil

    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = ProfileViewModel()
    @StateObject private var wall = WallViewModel()

    private enum CounterRoute: Hashable { case friends, photos, audios, videos, groups }
    @State private var route: CounterRoute?
    @State private var showCompose = false
    @State private var showSettings = false
    @State private var showAvatar = false

    private var isOwn: Bool { userID == nil }
    /// Что передать в users.get (0 = текущий пользователь).
    private var requestID: Int { userID ?? 0 }
    /// Конкретный id пользователя (для стены/счётчиков). Берём из загруженного профиля —
    /// он надёжнее settings.userID (который мог потеряться при переустановке).
    private var ownerID: Int { model.user?.id ?? userID ?? settings.userID ?? 0 }

    var body: some View {
        if isOwn {
            NavigationView { profileBody }
                .navigationViewStyle(.stack)
        } else {
            profileBody
        }
    }

    private var profileBody: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle(isOwn ? "Профиль" : (model.user?.fullName ?? "Профиль"))
            .navigationBarTitleDisplayMode(.inline) // large-title в кастомном таб-баре скачет — фиксируем inline
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        // Написать на стену (свою или чужую).
                        Button { showCompose = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        if isOwn {
                            Menu {
                                Button {
                                    showSettings = true
                                } label: {
                                    Label("Настройки", systemImage: "gearshape")
                                }
                                Button(role: .destructive) {
                                    settings.signOut()
                                } label: {
                                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showCompose) {
                NewPostView(ownerID: ownerID) {
                    Task { await wall.reload(ownerID: ownerID, settings: settings) }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .task {
                await model.loadIfNeeded(userID: requestID, settings: settings)
                if isOwn, let id = model.user?.id { settings.rememberUserID(id) }
                await wall.loadIfNeeded(ownerID: ownerID, settings: settings)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let user = model.user {
            List {
                card { header(user) }
                if let counters = user.counters {
                    card { countersBar(counters) }
                }
                if let info = infoCard(user) {
                    card { info }
                }

                // Стена
                sectionLabel("Записи")
                if wall.posts.isEmpty && !wall.isLoading {
                    card {
                        Text("Записей пока нет")
                            .foregroundColor(OVK.Palette.textSecondary)
                            .padding()
                    }
                } else {
                    ForEach(wall.posts) { post in
                        card {
                            PostRow(post: post, authors: wall.authors) { p in
                                Task { await wall.delete(p, settings: settings) }
                            }
                        }
                            .onAppear {
                                if post.id == wall.posts.last?.id {
                                    Task { await wall.loadMore(ownerID: ownerID, settings: settings) }
                                }
                            }
                    }
                    if wall.isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)
                    }
                }
            }
            .listStyle(.plain)
            .background(
                NavigationLink(
                    isActive: Binding(get: { route != nil }, set: { if !$0 { route = nil } })
                ) {
                    routeDestination
                } label: { EmptyView() }
                .hidden()
            )
            .refreshable {
                await model.load(userID: requestID, settings: settings)
                await wall.reload(ownerID: ownerID, settings: settings)
            }
        } else if model.isLoading {
            ProgressView()
        } else if let error = model.errorMessage {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Повторить") { Task { await model.load(userID: requestID, settings: settings) } }
            }
            .padding()
        } else {
            Color.clear
        }
    }

    /// Обёртка-«карточка»: белый блок во всю ширину + серый зазор снизу (плоский VK-стиль).
    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVK.Palette.card)
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
    }

    // MARK: - Шапка

    private func header(_ user: User) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack(alignment: .bottomTrailing) {
                // Тап по аватару — просмотр в полном размере.
                Button { showAvatar = true } label: {
                    CachedImage(url: user.avatarURL) {
                        ZStack {
                            OVK.Palette.background
                            Image(systemName: "person.crop.square")
                                .font(.system(size: 36))
                                .foregroundColor(OVK.Palette.textSecondary)
                        }
                    }
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(user.avatarURL == nil)

                if user.online {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(OVK.Palette.card, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .fullScreenCover(isPresented: $showAvatar) {
                AvatarViewer(url: user.fullAvatarURL ?? user.avatarURL)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(user.fullName)
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(OVK.Palette.textPrimary)
                HStack(spacing: 4) {
                    // Свой профиль онлайн — всегда «с iPhone» (это наш iOS-клиент).
                    // У чужих берём реальную платформу из last_seen (иконка только для мобильных, как в VK).
                    if user.online {
                        let platform: User.OnlinePlatform = isOwn ? .iphone : user.onlinePlatform
                        if platform.hasIcon {
                            OnlinePlatformIcon(platform: platform)
                        }
                    }
                    Text(user.online ? "онлайн" : "не в сети")
                        .font(.caption)
                        .foregroundColor(user.online ? OVK.Palette.primary : OVK.Palette.textSecondary)
                }
                if let status = user.status, !status.isEmpty {
                    Text(linkifiedText(status))
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    // MARK: - Счётчики

    private func countersBar(_ c: User.Counters) -> some View {
        HStack(alignment: .top, spacing: 0) {
            counterButton("друзья", c.friends ?? 0, .friends)
            counterButton("фото", c.photos ?? 0, .photos)
            counterButton("аудио", c.audios ?? 0, .audios)
            counterButton("видео", c.videos ?? 0, .videos)
            counterButton("группы", c.groups ?? 0, .groups)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
    }

    private func counterButton(_ label: String, _ value: Int, _ dest: CounterRoute) -> some View {
        Button { route = dest } label: { counterItem(label, value) }
            .buttonStyle(.plain)
    }

    @ViewBuilder
    private var routeDestination: some View {
        switch route {
        case .friends: FriendsView(userID: ownerID)
        case .photos:  PhotosView(ownerID: ownerID)
        case .audios:  UserAudiosView(ownerID: ownerID)
        case .videos:  VideosView(ownerID: ownerID)
        case .groups:  GroupsView(userID: ownerID)
        case .none:    EmptyView()
        }
    }

    /// Серый заголовок-разделитель секции (как «Записи» в VK).
    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote).fontWeight(.semibold)
            .foregroundColor(OVK.Palette.textSecondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
    }

    private func counterItem(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline)
                .foregroundColor(OVK.Palette.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundColor(OVK.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Информация

    private func infoCard(_ user: User) -> AnyView? {
        let candidates: [(String, String?)] = [
            ("Город", user.cityTitle),
            ("День рождения", user.bdate),
            ("О себе", user.about),
        ]
        let rows = candidates.compactMap { label, value -> (String, String)? in
            guard let v = value, !v.isEmpty else { return nil }
            return (label, v)
        }
        guard !rows.isEmpty else { return nil }

        return AnyView(
            VStack(alignment: .leading, spacing: 0) {
                Text("Информация")
                    .font(.footnote).fontWeight(.semibold)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.0)
                            .foregroundColor(OVK.Palette.textSecondary)
                            .frame(width: 120, alignment: .leading)
                        Text(linkifiedText(row.1))
                            .foregroundColor(OVK.Palette.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.subheadline)
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                    if index < rows.count - 1 {
                        Divider().padding(.leading)
                    }
                }
            }
            .padding(.bottom, 8)
        )
    }
}

/// Полноэкранный просмотр аватарки: чёрный фон, картинка целиком, тап/крестик — закрыть.
/// Используется в профиле и на странице сообщества.
struct AvatarViewer: View {
    let url: URL?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            CachedImage(url: url, contentMode: .fit, maxPixelSize: 2048) {
                ProgressView().tint(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(10)
                    .background(Circle().fill(Color.black.opacity(0.5)))
            }
            .padding()
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
    }
}
