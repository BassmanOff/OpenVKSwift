import SwiftUI

/// Профиль в стиле ВКонтакте 2.0 (2013–2014): плоские белые блоки на сером фоне.
/// Список (List) — чтобы pull-to-refresh работал и на iOS 15.
struct ProfileView: View {
    /// nil → собственный профиль (корень вкладки); иначе — чужой (пушится из списка друзей).
    var userID: Int? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @StateObject private var model = ProfileViewModel()
    @StateObject private var wall = WallViewModel(ownerID: 0)

    private enum CounterRoute: Hashable { case friends, photos, audios, videos, groups }
    @State private var route: CounterRoute?
    @State private var showCompose = false
    @State private var showSettings = false
    @State private var showEditProfile = false
    @State private var openChatPeerID: Int?
    /// Точка на шестерёнке — есть новый тег на GitHub (см. UpdateChecker). Проверяется тут,
    /// а не только при заходе в «Настройки», чтобы бейдж был виден СРАЗУ, без захода внутрь.
    @State private var updateAvailable = false
    @State private var showAllInfo = false
    /// Смена фото профиля: «...» в просмотрщике аватарки → выбор источника → пикер.
    @State private var showAvatarSourceDialog = false
    @State private var showCameraPicker = false
    @State private var showLibraryPicker = false
    @State private var avatarUploadError: String?

    private var isOwn: Bool { userID == nil }
    /// Что передать в users.get (0 = текущий пользователь).
    private var requestID: Int { userID ?? 0 }
    /// Конкретный id пользователя (для стены/счётчиков). Берём из загруженного профиля —
    /// он надёжнее settings.userID (который мог потеряться при переустановке).
    private var ownerID: Int { model.user?.id ?? userID ?? settings.userID ?? 0 }
    /// Трек, который сейчас слушает владелец профиля — всегда с сервера (users.get →
    /// status_audio), а не из локального плеера: музыка может играть на другом устройстве.
    private var currentTrack: Audio? { model.user?.statusAudio }

    var body: some View {
        if isOwn {
            NavigationView { profileBody.pushesGlobalLinks(tab: 4) }
                .navigationViewStyle(.stack)
        } else {
            profileBody.handlesOVKLinks()
        }
    }

    private var profileBody: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle(isOwn ? "Профиль" : (model.user?.fullName ?? "Профиль"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button { showCompose = true } label: {
                            Image(systemName: "square.and.pencil")
                        }
                        if isOwn {
                            Menu {
                                Button { showEditProfile = true } label: {
                                    Label("Редактировать профиль", systemImage: "pencil")
                                }
                                Button { showSettings = true } label: {
                                    Label("Настройки", systemImage: "gearshape")
                                }
                                Button(role: .destructive) {
                                    settings.signOut()
                                } label: {
                                    Label("Выйти", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                            } label: {
                                Image(systemName: "gearshape")
                                    .overlay(alignment: .topTrailing) {
                                        if updateAvailable {
                                            Circle()
                                                .fill(Color.red)
                                                .frame(width: 8, height: 8)
                                                .offset(x: 4, y: -2)
                                        }
                                    }
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
            .sheet(isPresented: $showAllInfo) {
                if let user = model.user { ProfileAllInfoView(user: user) }
            }
            .alert("Ошибка", isPresented: Binding(
                get: { avatarUploadError != nil },
                set: { if !$0 { avatarUploadError = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(avatarUploadError ?? "")
            }
            // Настройки — обычный пуш в стек (не modal), чтобы переходы по ссылкам внутри
            // (разработчик и т.п.) не открывались «за» модалкой, а просто пушились дальше.
            .background(
                NavigationLink(isActive: $showSettings) {
                    SettingsView()
                } label: { EmptyView() }
                .hidden()
            )
            .background(
                NavigationLink(isActive: $showEditProfile) {
                    if let user = model.user {
                        ProfileEditView(user: user) {
                            Task { await model.load(userID: requestID, settings: settings) }
                        }
                    }
                } label: { EmptyView() }
                .hidden()
            )
            .task {
                await model.loadIfNeeded(userID: requestID, settings: settings)
                if isOwn, let id = model.user?.id { settings.rememberUserID(id) }
                await wall.loadIfNeeded(ownerID: ownerID, settings: settings)
            }
            .task {
                // Из кэша (см. UpdateChecker), если проверяли < часа назад — сети почти
                // никогда не бывает при обычном открытии вкладки «Профиль».
                guard isOwn else { return }
                let result = await UpdateChecker.check(currentVersion: UpdateChecker.currentVersion, force: false)
                updateAvailable = result.isUpdateAvailable
            }
    }

    @ViewBuilder
    var content: some View {
        if let user = model.user {
            List {
                card { header(user) }
                if let counters = user.counters { card { countersBar(counters) } }
                if let info = infoCard(user) { card { info } }
                if !isOwn { card { actionRow(user) } }

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
                ZStack {
                    NavigationLink(
                        isActive: Binding(get: { route != nil }, set: { if !$0 { route = nil } })
                    ) { routeDestination } label: { EmptyView() }.hidden()

                    NavigationLink(
                        isActive: Binding(get: { openChatPeerID != nil }, set: { if !$0 { openChatPeerID = nil } })
                    ) {
                        if let peerID = openChatPeerID {
                            ChatView(peerID: peerID,
                                     title: model.user?.fullName ?? "Диалог",
                                     avatarURL: model.user?.avatarURL)
                        }
                    } label: { EmptyView() }
                    .hidden()
                }
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

    // MARK: - Карточка

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
                // Тот же UIKit-просмотрщик, что и у обычных фото (не AvatarViewer):
                // «...» в нём даёт «Изменить фото профиля» только на своей странице (isOwn).
                Group {
                    if let url = user.fullAvatarURL ?? user.avatarURL {
                        avatarImage(user)
                            .photoHeroSource(
                                photos: [.avatar(ownerID: user.id, url: url)],
                                index: 0,
                                post: nil,
                                coordinator: photoHero,
                                onChangeAvatar: isOwn ? { showAvatarSourceDialog = true } : nil
                            )
                    } else {
                        avatarImage(user)
                    }
                }

                if user.online {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(OVK.Palette.card, lineWidth: 2))
                        .offset(x: 3, y: 3)
                }
            }
            .confirmationDialog("Изменить фото профиля", isPresented: $showAvatarSourceDialog, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Камера") { showCameraPicker = true }
                }
                Button("Медиатека") { showLibraryPicker = true }
            }
            .fullScreenCover(isPresented: $showCameraPicker) {
                CameraPicker { uploadAvatar($0) }.ignoresSafeArea()
            }
            .sheet(isPresented: $showLibraryPicker) {
                PhotoPicker { uploadAvatar($0) }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(user.fullName)
                        .font(.title3).fontWeight(.semibold)
                        .foregroundColor(OVK.Palette.textPrimary)
                    // Пасхалка: разработчик (id21510) — иконка-гаечный ключ вместо галочки;
                    // остальные верифицированные на сервере — обычная галочка verified.
                    if user.id == 21510 {
                        Image(systemName: "wrench.and.screwdriver.fill")
                            .font(.subheadline)
                            .foregroundColor(OVK.Palette.primary)
                    } else if user.verified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.subheadline)
                            .foregroundColor(OVK.Palette.primary)
                    }
                }
                if user.id == 21510 {
                    Text("OpenVK iOS Creator")
                        .font(.caption)
                        .foregroundColor(OVK.Palette.primary)
                }
                HStack(spacing: 4) {
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
                if let track = currentTrack {
                    Button { player.play(track, in: [track]) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "music.note")
                                .font(.caption)
                                .foregroundColor(OVK.Palette.primary)
                            Text("Слушает: \(track.artist) — \(track.title)")
                                .font(.subheadline)
                                .foregroundColor(OVK.Palette.textPrimary)
                                .lineLimit(1)
                        }
                        .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private func avatarImage(_ user: User) -> some View {
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

    /// Загружает выбранное/снятое фото как новый аватар и обновляет профиль с сервера.
    private func uploadAvatar(_ image: UIImage) {
        guard let token = settings.token, let data = image.jpegData(compressionQuality: 0.85) else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        Task {
            do {
                try await client.uploadOwnerPhoto(jpeg: data)
                await model.load(userID: requestID, settings: settings) // подтягиваем новый avatarURL
            } catch {
                if error.isCancellation { return }
                avatarUploadError = "Не удалось изменить фото профиля"
            }
        }
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
    var routeDestination: some View {
        switch route {
        case .friends: FriendsView(userID: ownerID)
        case .photos:  PhotosView(ownerID: ownerID)
        case .audios:  UserAudiosView(ownerID: ownerID)
        case .videos:  VideosView(ownerID: ownerID)
        case .groups:  GroupsView(userID: ownerID)
        case .none:    EmptyView()
        }
    }

    func counterItem(_ label: String, _ value: Int) -> some View {
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

    // MARK: - Действия (дружба, сообщение, ещё)

    private func actionRow(_ user: User) -> some View {
        HStack(spacing: 10) {
            Button {
                Task { await toggleFriend() }
            } label: {
                Text(friendButtonTitle)
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(friendButtonBackground)
                    .foregroundColor(friendButtonForeground)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button { openChatPeerID = user.id } label: {
                Image(systemName: "envelope")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(OVK.Palette.background)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)

            Button { } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(OVK.Palette.background)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding()
    }

    var friendButtonTitle: String {
        switch model.friendStatus {
        case 1:  return "Заявка отправлена"
        case 2:  return "Принять заявку"
        case 3:  return "В друзьях"
        default: return "Добавить в друзья"
        }
    }

    var friendButtonBackground: Color {
        model.friendStatus == 3 ? OVK.Palette.background : OVK.Palette.primary
    }

    var friendButtonForeground: Color {
        model.friendStatus == 3 ? OVK.Palette.textPrimary : .white
    }

    func toggleFriend() async {
        switch model.friendStatus {
        case 1:
            await model.removeFriend(settings: settings)
        case 2:
            await model.sendFriendRequest(settings: settings, optimisticStatus: 3)
        case 3:
            await model.removeFriend(settings: settings)
        default:
            await model.sendFriendRequest(settings: settings)
        }
    }

    // MARK: - Информация

    func infoCard(_ user: User) -> AnyView? {
        let candidates: [(String, String?)] = [
            ("Город", user.cityTitle),
            ("День рождения", user.birthdayDisplay),
            ("О себе", user.about),
        ]
        let rows = candidates.compactMap { label, value -> (String, String)? in
            guard let v = value, !v.isEmpty else { return nil }
            return (label, v)
        }
        let hasExtra = !ProfileAllInfoView.rows(for: user).isEmpty
        // Раньше карточка (и с ней кнопка «Все данные») пряталась целиком, если не было
        // города/дня рождения/о себе — даже когда есть музыка/интересы/etc. Показываем
        // карточку, если есть ЛИБО основные поля, ЛИБО доп. поля.
        guard !rows.isEmpty || hasExtra else { return nil }

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

                // Доп. поля (музыка/фильмы/интересы/…) — отдельным листом, чтобы не раздувать
                // карточку профиля тем, что заполняет меньшинство пользователей.
                if !ProfileAllInfoView.rows(for: user).isEmpty {
                    Divider().padding(.leading)
                    Button { showAllInfo = true } label: {
                        HStack {
                            Text("Все данные")
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption)
                        }
                        .foregroundColor(OVK.Palette.primary)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle()) // вся строка кликабельна, не только текст/иконка
                    }
                    .buttonStyle(.plain)
                    .font(.subheadline)
                }
            }
            .padding(.bottom, 8)
        )
    }

}

func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
    content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OVK.Palette.card)
        .padding(.bottom, 8)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(OVK.Palette.background)
}

/// «Все данные»: полный список полей users.get, включая те, что не влезли в основную
/// карточку профиля (музыка/фильмы/книги/игры/интересы/цитаты/Telegram/дата регистрации/пол).
/// Сервер отдаёт только заполненные и видимые вызывающему поля — пустые строки уже отфильтрованы.
struct ProfileAllInfoView: View {
    let user: User
    @Environment(\.dismiss) private var dismiss

    /// Единый источник строк — используется и для показа/скрытия кнопки «Все данные»
    /// в ProfileView, и для самого листа, чтобы условия не разъезжались.
    static func rows(for user: User) -> [(String, String)] {
        let sexText: String? = { switch user.sex { case 1: return "Женский"; case 2: return "Мужской"; default: return nil } }()
        let regDateText = user.regDate.map { Self.dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval($0))) }

        let candidates: [(String, String?)] = [
            ("Город", user.cityTitle),
            ("День рождения", user.birthdayDisplay),
            ("Пол", sexText),
            ("О себе", user.about),
            ("Никнейм", user.nickname),
            ("Короткий адрес", user.screenName),
            ("Telegram", user.telegram),
            ("Дата регистрации", regDateText),
            ("Интересы", user.interests),
            ("Любимая музыка", user.music),
            ("Любимые фильмы", user.movies),
            ("Любимые передачи", user.tv),
            ("Любимые книги", user.books),
            ("Любимые игры", user.games),
            ("Любимые цитаты", user.quotes),
        ]
        return candidates.compactMap { label, value in
            guard let v = value, !v.isEmpty else { return nil }
            return (label, v)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    var body: some View {
        NavigationView {
            List {
                ForEach(Array(Self.rows(for: user).enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.0)
                            .font(.caption)
                            .foregroundColor(OVK.Palette.textSecondary)
                        Text(linkifiedText(row.1))
                            .font(.subheadline)
                            .foregroundColor(OVK.Palette.textPrimary)
                    }
                    .padding(.vertical, 2)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Все данные")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}