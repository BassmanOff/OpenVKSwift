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

    private var isOwn: Bool { userID == nil }
    /// Что передать в users.get (0 = текущий пользователь).
    private var requestID: Int { userID ?? 0 }
    /// Конкретный id пользователя (для стены/счётчиков).
    private var ownerID: Int { userID ?? settings.userID ?? 0 }

    var body: some View {
        if isOwn {
            NavigationView { profileBody }
        } else {
            profileBody
        }
    }

    private var profileBody: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle(isOwn ? "Профиль" : (model.user?.fullName ?? "Профиль"))
            .navigationBarTitleDisplayMode(isOwn ? .automatic : .inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if isOwn {
                        Menu {
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
            .task {
                await model.loadIfNeeded(userID: requestID, settings: settings)
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
                        card { PostRow(post: post, authors: wall.authors) }
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

                if user.online {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(OVK.Palette.card, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(user.fullName)
                    .font(.title3).fontWeight(.semibold)
                    .foregroundColor(OVK.Palette.textPrimary)
                HStack(spacing: 4) {
                    // Это наш iOS-клиент, поэтому свой профиль онлайн — всегда «с iPhone».
                    if user.online {
                        OnlinePlatformIcon(platform: .iphone)
                    }
                    Text(user.online ? "онлайн" : "не в сети")
                        .font(.caption)
                        .foregroundColor(user.online ? OVK.Palette.primary : OVK.Palette.textSecondary)
                }
                if let status = user.status, !status.isEmpty {
                    Text(status)
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
                        Text(row.1)
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
