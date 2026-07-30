import SwiftUI
import MapKit
import CoreLocation
import UIKit

/// Профиль в стиле ВКонтакте 2.0 (2013–2014): плоские белые блоки на сером фоне.
/// Список (List) — чтобы pull-to-refresh работал и на iOS 15.
struct ProfileView: View {
    /// nil → собственный профиль в корне вкладки; иначе — явно открытый профиль, в том числе свой.
    var userID: Int? = nil

    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @StateObject private var model = ProfileViewModel()
    @StateObject private var wall = WallViewModel(ownerID: 0)
    @StateObject private var profilePhotos = ProfilePhotosPreviewModel()

    private enum CounterRoute: Hashable { case friends, followers, photos, audios, videos, groups }
    private enum WallScope: Hashable { case all, owner }
    @State private var route: CounterRoute?
    @State private var wallScope: WallScope = .all
    @State private var showAccounts = false
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
    @State private var showBlockConfirmation = false
    @State private var showProfileShare = false
    @State private var actionToast: String?

    private var isOwn: Bool {
        ProfileIdentity.isOwn(requestedUserID: userID, currentUserID: settings.userID)
    }
    private var isRootProfile: Bool { userID == nil }
    /// Что передать в users.get (0 = текущий пользователь).
    private var requestID: Int { userID ?? 0 }
    /// Конкретный id пользователя (для стены/счётчиков). Берём из загруженного профиля —
    /// он надёжнее settings.userID (который мог потеряться при переустановке).
    private var ownerID: Int { model.user?.id ?? userID ?? settings.userID ?? 0 }
    /// Трек, который сейчас слушает владелец профиля — всегда с сервера (users.get →
    /// status_audio), а не из локального плеера: музыка может играть на другом устройстве.
    private var currentTrack: Audio? { model.user?.statusAudio }

    var body: some View {
        if isRootProfile {
            NavigationView { profileBody.pushesGlobalLinks(tab: 4) }
                .navigationViewStyle(.stack)
        } else {
            profileBody.handlesOVKLinks()
        }
    }

    private var profileBody: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background)
            .navigationTitle(model.user?.firstName ?? "Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Group {
                        if isOwn {
                        Menu {
                            Button { showEditProfile = true } label: {
                                Label("Редактировать профиль", systemImage: "pencil")
                            }
                            Button { showAccounts = true } label: {
                                Label("Аккаунты", systemImage: "person.2")
                            }
                            Button { showSettings = true } label: {
                                Label("Настройки", systemImage: "gearshape")
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .overlay(alignment: .topTrailing) {
                                    if updateAvailable {
                                        Circle().fill(Color.red).frame(width: 7, height: 7).offset(x: 3, y: -2)
                                    }
                                }
                        }
                        .accessibilityLabel("Дополнительно")
                        }
                    }
                }
            }
            .alert("Ошибка", isPresented: Binding(
                get: { avatarUploadError != nil },
                set: { if !$0 { avatarUploadError = nil } }
            )) {
                Button("ОК", role: .cancel) {}
            } message: {
                Text(avatarUploadError ?? "")
            }
            .confirmationDialog("Заблокировать \(model.user?.fullName ?? "пользователя")?", isPresented: $showBlockConfirmation, titleVisibility: .visible) {
                Button("Заблокировать", role: .destructive) {
                    if let user = model.user { Task { await block(user) } }
                }
            }
            .sheet(isPresented: $showProfileShare) {
                RepostSheet(profileURL: profileURL(for: ownerID)) { message, _ in
                    actionToast = message
                }
            }
            .toast($wall.errorMessage)
            .toast($actionToast)
            // Настройки — обычный пуш в стек (не modal), чтобы переходы по ссылкам внутри
            // (разработчик и т.п.) не открывались «за» модалкой, а просто пушились дальше.
            .background(
                NavigationLink(isActive: $showAccounts) {
                    AccountsView()
                } label: { EmptyView() }
                .hidden()
            )
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
                await wall.loadIfNeeded(ownerID: ownerID, settings: settings)
                await profilePhotos.loadIfNeeded(ownerID: ownerID, settings: settings)
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
                card {
                    VStack(spacing: 0) {
                        header(user)
                        if let counters = user.counters {
                            OVKHairline()
                            countersBar(counters)
                        }
                        if !profilePhotos.photos.isEmpty {
                            OVKHairline()
                            profilePhotosSection
                        }
                        if isOwn || user.canAccessClosed {
                            OVKHairline()
                            WallPublishControls(ownerID: ownerID) {
                                Task { await wall.reload(ownerID: ownerID, settings: settings) }
                            }
                        }
                    }
                }
                if !isOwn { card { actionRow(user) } }

                card { wallScopeControl }

                if displayedPosts.isEmpty && !wall.isLoading {
                    card {
                        Text("Записей пока нет")
                            .foregroundColor(OVK.Palette.textSecondary)
                            .padding()
                    }
                } else {
                    ForEach(displayedPosts) { post in
                        PostRow(post: post, authors: wall.authors, onDelete: { p in
                            Task { await wall.delete(p, settings: settings) }
                        }, onEdited: { p in
                            Task { await wall.refreshPost(ownerID: p.ownerID, postID: p.postID, settings: settings) }
                        })
                        .ovkPostListRow()
                        .onAppear {
                            if post.id == displayedPosts.last?.id {
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

                    NavigationLink(isActive: $showAllInfo) {
                        if let user = model.user { ProfileAllInfoView(user: user) }
                    } label: { EmptyView() }
                    .hidden()

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

    private var profilePhotosSection: some View {
        VStack(spacing: 0) {
            Button { route = .photos } label: {
                HStack {
                    Text("\(profilePhotos.totalCount) фотографий")
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.textSecondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(OVK.Palette.separator)
                }
                .padding(.horizontal, OVK.Metrics.contentInset)
                .frame(minHeight: OVK.Metrics.minimumTapSize)
            }
            .buttonStyle(.plain)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(profilePhotos.photos.enumerated()), id: \.element.id) { index, photo in
                        CachedImage(url: photo.thumbURL) { OVK.Palette.background }
                            .frame(width: min(max((photo.aspectRatio ?? 1) * 100, 80), 160),
                                   height: 100)
                            .clipped()
                            .photoHeroSource(photos: profilePhotos.photos, index: index, post: nil, coordinator: photoHero)
                    }
                }
            }
        }
    }

    private var displayedPosts: [Post] {
        switch wallScope {
        case .all: return wall.posts
        case .owner: return wall.posts.filter { $0.fromID == ownerID }
        }
    }

    private var wallScopeControl: some View {
        HStack(spacing: 8) {
            wallScopeButton(title: "Все записи", scope: .all)
            wallScopeButton(title: isOwn ? "Мои записи" : "Записи пользователя", scope: .owner)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OVK.Metrics.contentInset)
        .padding(.vertical, 7)
    }

    private func wallScopeButton(title: String, scope: WallScope) -> some View {
        Button { wallScope = scope } label: {
            Text(title)
                .font(.footnote)
                .foregroundColor(wallScope == scope ? OVK.Palette.textPrimary : OVK.Palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(minHeight: 30)
                .background(wallScope == scope ? OVK.Palette.background : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(wallScope == scope ? .isSelected : [])
    }

    // MARK: - Шапка

    private func header(_ user: User) -> some View {
        VStack(alignment: .leading, spacing: 0) {
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

                    if settings.legacyAvatarIndicators, user.online {
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

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 4) {
                        Text(user.fullName)
                            .font(.system(size: 17, weight: .regular))
                            .foregroundColor(OVK.Palette.textPrimary)
                            .lineLimit(2)
                        // Пасхалка: разработчик (id21510) — иконка-гаечный ключ вместо галочки;
                        // остальные верифицированные на сервере — обычная галочка verified.
                        if user.id == 21510 {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.caption)
                                .foregroundColor(OVK.Palette.primary)
                        } else if user.verified {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundColor(OVK.Palette.primary)
                        }
                    }
                    if let activity = user.activityDisplay {
                        HStack(spacing: 4) {
                        if user.online {
                            let platform: User.OnlinePlatform = isOwn ? .iphone : user.onlinePlatform
                            if platform.hasIcon {
                                OnlinePlatformIcon(platform: platform)
                            }
                        }
                        Text(activity)
                            .font(.caption)
                            .foregroundColor(user.online ? OVK.Palette.primary : OVK.Palette.textSecondary)
                        }
                    }
                    let demographic = [user.compactAge, user.cityTitle].compactMap { $0 }.joined(separator: ", ")
                    if !demographic.isEmpty {
                        Text(demographic)
                            .font(.caption)
                            .foregroundColor(OVK.Palette.textSecondary)
                    }
                }

                Spacer(minLength: 0)

                Button { showAllInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.title3)
                        .foregroundColor(OVK.Palette.primary)
                        .frame(width: OVK.Metrics.minimumTapSize, height: OVK.Metrics.minimumTapSize)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Информация о профиле")
            }
            .padding(.horizontal, OVK.Metrics.contentInset)
            .padding(.vertical, 12)

            if let track = currentTrack {
                OVKHairline()
                Button { player.play(track, in: [track]) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "music.note").foregroundColor(OVK.Palette.primary)
                        Text("\(track.artist) — \(track.title)")
                            .font(.caption)
                            .foregroundColor(OVK.Palette.link)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Слушает \(track.artist) — \(track.title)")
                .padding(.horizontal, OVK.Metrics.contentInset)
                .padding(.vertical, 10)
            }
        }
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
        .cornerRadius(settings.legacyAvatarIndicators ? OVK.Metrics.compactCornerRadius : 40)
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
            counterButton("подписчики", c.followers ?? 0, .followers)
            counterButton("группы", c.groups ?? 0, .groups)
            counterButton("фото", c.photos ?? 0, .photos)
            counterButton("видео", c.videos ?? 0, .videos)
            counterButton("аудио", c.audios ?? 0, .audios)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
    }

    private func counterButton(_ label: String, _ value: Int, _ dest: CounterRoute) -> some View {
        Button { route = dest } label: { counterItem(label, value) }
            .buttonStyle(ProfileCounterButtonStyle())
            .accessibilityLabel("\(value) \(label)")
    }

    @ViewBuilder
    var routeDestination: some View {
        switch route {
        case .friends: FriendsView(userID: ownerID)
        case .followers: FollowersView(userID: ownerID)
        case .photos:  PhotosView(ownerID: ownerID)
        case .audios:  UserAudiosView(ownerID: ownerID)
        case .videos:  VideosView(ownerID: ownerID)
        case .groups:  GroupsView(userID: ownerID)
        case .none:    EmptyView()
        }
    }

    func counterItem(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text(compactCounter(value))
                .font(.system(size: 17, weight: .regular))
                .foregroundColor(OVK.Palette.textPrimary)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(OVK.Palette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
        }
        .frame(maxWidth: .infinity, minHeight: OVK.Metrics.minimumTapSize)
    }

    private func compactCounter(_ value: Int) -> String {
        guard value >= 1_000 else { return String(value) }
        let divisor = value >= 1_000_000 ? 1_000_000.0 : 1_000.0
        let suffix = value >= 1_000_000 ? "M" : "K"
        let scaled = Double(value) / divisor
        let text = scaled >= 10
            ? String(format: "%.0f", scaled)
            : String(format: "%.1f", scaled).replacingOccurrences(of: ".", with: ",")
        return text + suffix
    }

    // MARK: - Действия (дружба, сообщение, ещё)

    private func actionRow(_ user: User) -> some View {
        HStack(spacing: 8) {
            if friendshipIsPrimary {
                friendshipButton(primary: true)
                messageButton(user, primary: false)
            } else {
                messageButton(user, primary: true)
                friendshipButton(primary: false)
            }
            profileMenuButton(user)
        }
        .padding()
    }

    private var friendshipIsPrimary: Bool {
        model.friendStatus != 1 && model.friendStatus != 3
    }

    private func friendshipButton(primary: Bool) -> some View {
        Button {
            Task { await toggleFriend() }
        } label: {
            Text(friendButtonTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(ProfileActionButtonStyle(primary: primary))
    }

    private func messageButton(_ user: User, primary: Bool) -> some View {
        Button { openChatPeerID = user.id } label: {
            Text("Сообщение")
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(ProfileActionButtonStyle(primary: primary))
    }

    private func profileMenuButton(_ user: User) -> some View {
        Menu {
            Button(role: .destructive) { showBlockConfirmation = true } label: {
                Label("Заблокировать", systemImage: "hand.raised")
            }
            Button { copyProfileLink(for: user.id) } label: {
                Label("Копировать ссылку", systemImage: "link")
            }
            Button { showProfileShare = true } label: {
                Label("Поделиться", systemImage: "square.and.arrow.up")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(OVK.Palette.primary)
                .frame(width: OVK.Metrics.minimumTapSize, height: OVK.Metrics.minimumTapSize)
                .background(OVK.Palette.card)
                .cornerRadius(OVK.Metrics.compactCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: OVK.Metrics.compactCornerRadius)
                        .stroke(OVK.Palette.separator, lineWidth: 1 / UIScreen.main.scale)
                )
        }
        .accessibilityLabel("Дополнительные действия")
    }

    private func profileURL(for userID: Int) -> URL {
        ProfileIdentity.url(webURL: settings.instance.webURL, userID: userID)
    }

    private func copyProfileLink(for userID: Int) {
        UIPasteboard.general.url = profileURL(for: userID)
        actionToast = "Ссылка скопирована"
    }

    private func block(_ user: User) async {
        do {
            try await model.blockUser(settings: settings)
            actionToast = "Пользователь заблокирован"
        } catch {
            if !error.isCancellation { actionToast = error.localizedDescription }
        }
    }

    var friendButtonTitle: String {
        switch model.friendStatus {
        case 1:  return "Заявка отправлена"
        case 2:  return "Принять заявку"
        case 3:  return "В друзьях"
        default: return "Добавить в друзья"
        }
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
                        OVKHairline().padding(.leading, OVK.Metrics.contentInset)
                    }
                }

                // Доп. поля (музыка/фильмы/интересы/…) — отдельным листом, чтобы не раздувать
                // карточку профиля тем, что заполняет меньшинство пользователей.
                if !ProfileAllInfoView.rows(for: user).isEmpty {
                    OVKHairline().padding(.leading, OVK.Metrics.contentInset)
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

private struct ProfileCounterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

private struct ProfileActionButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(primary ? .white : OVK.Palette.primary)
            .frame(maxWidth: .infinity, minHeight: OVK.Metrics.minimumTapSize)
            .background(primary ? OVK.Palette.primary : OVK.Palette.card)
            .cornerRadius(OVK.Metrics.compactCornerRadius)
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: OVK.Metrics.compactCornerRadius)
                        .stroke(OVK.Palette.separator, lineWidth: 1 / UIScreen.main.scale)
                }
            }
            .opacity(configuration.isPressed ? 0.65 : 1)
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
        .listStyle(.plain)
        .navigationTitle("Информация")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Единая панель публикации для личных и групповых стен. Права решает родитель,
/// а все три сценария используют тот же NewPostView и его проверку wall.post.
struct WallPublishControls: View {
    let ownerID: Int
    var groupName: String? = nil
    let onPosted: () -> Void

    @State private var showCompose = false
    @State private var showPhotoPreparation = false
    @State private var showPlacePicker = false
    @State private var preparedImages: [UIImage] = []
    @State private var preparedLocation: PostLocationDraft?
    @State private var openComposerAfterPreparation = false

    var body: some View {
        HStack(spacing: 0) {
            publishButton("Запись", systemImage: "square.and.pencil") {
                preparedImages = []
                preparedLocation = nil
                showCompose = true
            }
            OVK.Palette.separator.frame(width: 1 / UIScreen.main.scale)
            publishButton("Фото", systemImage: "camera") {
                showPhotoPreparation = true
            }
            OVK.Palette.separator.frame(width: 1 / UIScreen.main.scale)
            publishButton("Место", systemImage: "mappin.and.ellipse") {
                showPlacePicker = true
            }
        }
        .frame(height: 50)
        .sheet(isPresented: $showCompose) {
            NewPostView(ownerID: ownerID, groupName: groupName,
                        initialImages: preparedImages, initialLocation: preparedLocation,
                        onPosted: onPosted)
        }
        .sheet(isPresented: $showPhotoPreparation, onDismiss: continuePreparedPost) {
            PhotoPostPreparationView { images in
                preparedImages = images
                preparedLocation = nil
                openComposerAfterPreparation = true
                showPhotoPreparation = false
            }
        }
        .sheet(isPresented: $showPlacePicker, onDismiss: continuePreparedPost) {
            PlacePickerView { location in
                preparedImages = []
                preparedLocation = location
                openComposerAfterPreparation = true
                showPlacePicker = false
            }
        }
    }

    private func publishButton(_ title: String, systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(OVK.Palette.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func continuePreparedPost() {
        guard openComposerAfterPreparation else { return }
        openComposerAfterPreparation = false
        DispatchQueue.main.async { showCompose = true }
    }
}

/// Photo-first entry point from the profile. Uploading still happens in NewPostView;
/// this screen only gathers and orders images before handing them over.
private struct PhotoPostPreparationView: View {
    let onContinue: ([UIImage]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var images: [UIImage] = []
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var didOpenInitialSource = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if images.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 38))
                            .foregroundColor(OVK.Palette.textSecondary)
                        Text("Добавьте фотографии к записи")
                            .foregroundColor(OVK.Palette.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(images.indices, id: \.self) { index in
                            HStack(spacing: 12) {
                                Image(uiImage: images[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 64, height: 64)
                                    .clipped()
                                    .cornerRadius(OVK.Metrics.compactCornerRadius)
                                Text("Фото \(index + 1)")
                                    .foregroundColor(OVK.Palette.textPrimary)
                                Spacer()
                                Button { images.remove(at: index) } label: {
                                    Image(systemName: "trash")
                                        .foregroundColor(OVK.Palette.textSecondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .onMove { images.move(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                    .environment(\.editMode, .constant(.active))
                }

                OVKHairline()
                HStack(spacing: 24) {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        Button { showCamera = true } label: {
                            Label("Камера", systemImage: "camera")
                        }
                    }
                    Button { showLibrary = true } label: {
                        Label("Медиатека", systemImage: "photo")
                    }
                    Spacer()
                    Text("\(images.count)/\(NewPostViewModel.maxAttachments)")
                        .font(.caption)
                        .foregroundColor(OVK.Palette.textSecondary)
                }
                .foregroundColor(OVK.Palette.primary)
                .padding()
                .disabled(images.count >= NewPostViewModel.maxAttachments)
            }
            .background(OVK.Palette.card.ignoresSafeArea())
            .navigationTitle("Фото для записи")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Далее") { onContinue(images) }
                        .disabled(images.isEmpty)
                }
            }
            .onAppear {
                guard !didOpenInitialSource else { return }
                didOpenInitialSource = true
                DispatchQueue.main.async {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) {
                        showCamera = true
                    } else {
                        showLibrary = true
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    if images.count < NewPostViewModel.maxAttachments { images.append(image) }
                }
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showLibrary) {
                PhotoPicker { image in
                    if images.count < NewPostViewModel.maxAttachments { images.append(image) }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private struct PlacePickerView: View {
    let onPick: (PostLocationDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlacePickerModel()

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(OVK.Palette.textSecondary)
                    TextField("Найти место", text: $model.query)
                        .submitLabel(.search)
                        .onSubmit { model.search() }
                    Button { model.search() } label: {
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.horizontal, OVK.Metrics.contentInset)
                .frame(minHeight: 50)
                .background(OVK.Palette.card)

                OVKHairline()

                Map(coordinateRegion: $model.region, showsUserLocation: true)
                    .overlay {
                        Image(systemName: "mappin")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(OVK.Palette.primary)
                            .offset(y: -17)
                            .allowsHitTesting(false)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Button { model.useCurrentLocation() } label: {
                            Image(systemName: "location.fill")
                                .frame(width: 44, height: 44)
                                .background(OVK.Palette.card)
                                .clipShape(Circle())
                                .shadow(radius: 2)
                        }
                        .accessibilityLabel("Моё местоположение")
                        .padding()
                    }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.footnote)
                        .foregroundColor(.red)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
            .navigationTitle("Место")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if model.isResolving {
                        ProgressView()
                    } else {
                        Button("Готово") {
                            model.resolveSelection(onPick)
                        }
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

private final class PlacePickerModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var query = ""
    @Published var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 55.751_244, longitude: 37.618_423),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @Published var errorMessage: String?
    @Published var isResolving = false

    private let locationManager = CLLocationManager()
    private let geocoder = CLGeocoder()
    private var activeSearch: MKLocalSearch?
    private var fallbackName: String?
    private var waitingForPermission = false

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        errorMessage = nil
        activeSearch?.cancel()
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = term
        request.region = region
        let search = MKLocalSearch(request: request)
        activeSearch = search
        search.start { [weak self] response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard let item = response?.mapItems.first else {
                    self.errorMessage = error?.localizedDescription ?? "Место не найдено"
                    return
                }
                self.fallbackName = item.name
                self.region = MKCoordinateRegion(
                    center: item.placemark.coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
            }
        }
    }

    func useCurrentLocation() {
        errorMessage = nil
        waitingForPermission = true
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.requestLocation()
        case .restricted, .denied:
            waitingForPermission = false
            errorMessage = "Разрешите доступ к геопозиции в настройках"
        @unknown default:
            waitingForPermission = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard waitingForPermission else { return }
        if manager.authorizationStatus == .authorizedAlways ||
            manager.authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        } else if manager.authorizationStatus == .denied ||
                    manager.authorizationStatus == .restricted {
            waitingForPermission = false
            errorMessage = "Разрешите доступ к геопозиции в настройках"
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        waitingForPermission = false
        guard let coordinate = locations.last?.coordinate else { return }
        fallbackName = nil
        region = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        waitingForPermission = false
        errorMessage = "Не удалось определить местоположение"
    }

    func resolveSelection(_ completion: @escaping (PostLocationDraft) -> Void) {
        isResolving = true
        errorMessage = nil
        let coordinate = region.center
        geocoder.reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude,
                                                   longitude: coordinate.longitude)) {
            [weak self] placemarks, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isResolving = false
                let placemark = placemarks?.first
                let resolvedName = placemark?.name ?? placemark?.locality
                    ?? self.fallbackName ?? self.query.trimmingCharacters(in: .whitespacesAndNewlines)
                completion(PostLocationDraft(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    name: resolvedName.isEmpty ? "Место" : resolvedName
                ))
            }
        }
    }
}
