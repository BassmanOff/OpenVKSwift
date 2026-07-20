import SwiftUI

/// Перехват ссылок OpenVK: внутренние открываются в приложении ПУШЕМ в ОКРУЖАЮЩИЙ
/// NavigationView (как в VK — новая страница выезжает справа, свайп-назад работает,
/// таб-бар остаётся). Самодостаточный (свой `LinkRouter` + фоновый `NavigationLink`).
///
/// Где применяется:
/// • на каждый МОДАЛЬНЫЙ корень с кликабельным контентом (sheet — SwiftUI не проносит
///   `openURL` через границу модалки; пуш идёт в NavigationView самой модалки);
/// • РЕКУРСИВНО на экран, открытый по ссылке (`GlobalLinkPush` навешивает его на
///   `LinkDestinationView`) — чтобы ссылки в цепочке пушились дальше в тот же стек.
/// Глобальный перехват в ОСНОВНЫХ вкладках — НЕ через этот модификатор, а через общий
/// роутер + `.pushesGlobalLinks(tab:)` (см. `MainTabView`), т.к. пушить надо в стек
/// КОНКРЕТНОЙ активной вкладки, а её NavigationView лежит НИЖЕ глобального override.
private struct OVKLinkHandler: ViewModifier {
    @StateObject private var router = LinkRouter()
    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { router.open($0) ? .handled : .systemAction })
            .background(
                NavigationLink(
                    isActive: Binding(
                        get: { router.destination != nil },
                        set: { if !$0 { router.destination = nil } }
                    )
                ) {
                    if let dest = router.destination {
                        LinkDestinationView(destination: dest).handlesOVKLinks()
                    }
                } label: { EmptyView() }
                .hidden()
            )
    }
}

/// Пушит назначение глобального роутера в стек КОНКРЕТНОЙ вкладки. Навешивается ВНУТРИ
/// NavigationView каждой вкладки. Пушит, только если ссылку тапнули на ЭТОЙ вкладке
/// (`targetTab` зафиксирован в момент тапа) — переключение вкладок не роняет открытый экран.
private struct GlobalLinkPush: ViewModifier {
    let tab: Int
    @EnvironmentObject private var router: LinkRouter
    func body(content: Content) -> some View {
        content
            .background(
                NavigationLink(
                    isActive: Binding(
                        get: { router.targetTab == tab && router.destination != nil },
                        set: { active in
                            if !active, router.targetTab == tab { router.destination = nil; router.targetTab = nil }
                        }
                    )
                ) {
                    if let dest = router.destination {
                        LinkDestinationView(destination: dest).handlesOVKLinks() // рекурсия внутри
                    }
                } label: { EmptyView() }
                .hidden()
            )
            // Повторный тап по активной вкладке → pop-to-root её стека (см. MainTabView.tabButton).
            .background(NavigationPopper(trigger: router.resetTrigger[tab, default: 0]))
    }
}

/// Программный pop-to-root для NavigationView (iOS 15 не даёт этого штатно, а смена .id()
/// пересоздаёт весь раздел = видимая перезагрузка). Пустой VC живёт в стеке вкладки; при
/// инкременте `trigger` он зовёт popToRootViewController(animated:) — ощущается как свайп-назад.
private struct NavigationPopper: UIViewControllerRepresentable {
    let trigger: Int

    func makeUIViewController(context: Context) -> UIViewController {
        context.coordinator.lastTrigger = trigger
        return UIViewController()
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        // На след. runloop: к этому моменту стек смонтирован и nav-контроллер доступен.
        DispatchQueue.main.async { vc.navigationController?.popToRootViewController(animated: true) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastTrigger = 0 }
}

extension View {
    /// Открытие ссылок OpenVK ПУШЕМ в окружающий NavigationView. На модальных корнях
    /// и рекурсивно на открытом по ссылке экране (НЕ на основных вкладках).
    func handlesOVKLinks() -> some View { modifier(OVKLinkHandler()) }

    /// Пуш назначения ГЛОБАЛЬНОГО роутера в стек этой вкладки. Внутри NavigationView вкладки.
    func pushesGlobalLinks(tab: Int) -> some View { modifier(GlobalLinkPush(tab: tab)) }
}

/// Экран, открываемый по внутренней ссылке (плейлист / профиль / сообщество / тема).
/// Сам НЕ заворачивается в NavigationView и НЕ показывает кнопку «Закрыть» —
/// его пушит `.handlesOVKLinks()` внутри NavigationView активной вкладки,
/// поэтому ссылки внутри него продолжают пушиться в тот же стек.
struct LinkDestinationView: View {
    let destination: LinkDestination

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .profile(let userID):
            ProfileView(userID: userID)
        case .community(let groupID):
            CommunityLinkLoader(groupID: groupID)
        case .playlist(let ownerID, let id):
            PlaylistLinkLoader(ownerID: ownerID, id: id)
        case .topic(let groupID, let virtualID):
            // Из ссылки virtual_id известен точно — передаём его как guess без резолва.
            TopicView(groupID: groupID, topicDBID: nil, virtualIDGuess: virtualID, title: "Обсуждение")
        case .post(let ownerID, let postID):
            // Стена: открываем пост с комментариями (PostRow переиспользуется внутри).
            CommentsView(ownerID: ownerID, postID: postID, fallbackIDs: [], post: nil)
        case .photo(let ownerID, let photoID):
            PhotoLinkLoader(ownerID: ownerID, photoID: photoID)
        case .video(let ownerID, let videoID):
            VideoLinkLoader(ownerID: ownerID, videoID: videoID)
        case .screenName(let name):
            ScreenNameLinkLoader(name: name)
        }
    }
}

/// Резолвит короткий адрес (utils.resolveScreenName) в профиль или сообщество.
private struct ScreenNameLinkLoader: View {
    let name: String
    @EnvironmentObject private var settings: AppSettings
    @State private var resolvedUserID: Int?
    @State private var resolvedGroupID: Int?
    @State private var failed = false

    private struct Resolved: Decodable {
        let objectID: Int?
        let type: String?
        enum CodingKeys: String, CodingKey {
            case objectID = "object_id"
            case type
        }
    }

    var body: some View {
        Group {
            if let uid = resolvedUserID {
                ProfileView(userID: uid)
            } else if let gid = resolvedGroupID {
                CommunityLinkLoader(groupID: gid)
            } else if failed {
                VStack(spacing: 12) {
                    Text("Не удалось открыть «\(name)»")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Открыть в браузере") {
                        // Напрямую через UIApplication — openURL из окружения зациклил бы
                        // ссылку обратно в наш перехватчик.
                        UIApplication.shared.open(
                            settings.instance.webURL.appendingPathComponent(name)
                        )
                    }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard let token = settings.token else { failed = true; return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let r: Resolved = try await client.call(
                "utils.resolveScreenName",
                params: ["screen_name": name]
            )
            switch (r.type, r.objectID) {
            case ("user", .some(let id)):  resolvedUserID = id
            case ("group", .some(let id)): resolvedGroupID = id
            default:                       failed = true
            }
        } catch {
            failed = true
        }
    }
}

/// Загружает сообщество по id (groups.getById) и открывает его страницу.
private struct CommunityLinkLoader: View {
    let groupID: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var community: Community?
    @State private var failed = false

    var body: some View {
        Group {
            if let community {
                GroupView(community: community)
            } else if failed {
                Text("Сообщество не найдено").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let result = await ObjectResolver.shared.community(id: groupID, settings: settings) {
            community = result
        } else {
            failed = true
        }
    }
}

/// Загружает фото по owner_id+id (photos.getById) и показывает его на весь экран.
private struct PhotoLinkLoader: View {
    let ownerID: Int
    let photoID: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var photo: Photo?
    @State private var failed = false

    var body: some View {
        Group {
            if let photo {
                PhotoViewer(photo: photo)
            } else if failed {
                Text("Фото не найдено").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let result = await ObjectResolver.shared.photo(ownerID: ownerID, photoID: photoID, settings: settings) {
            photo = result
        } else {
            failed = true
        }
    }
}

/// Фото на весь экран из загруженной модели Photo (чёрный фон, тап/крестик — закрыть).
private struct PhotoViewer: View {
    let photo: Photo
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url = photo.bestURL {
                CachedImage(url: url, contentMode: .fit, maxPixelSize: 2048) {
                    ProgressView().tint(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Загружает видео по owner_id+id (video.get) и открывает плеер.
private struct VideoLinkLoader: View {
    let ownerID: Int
    let videoID: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var video: Video?
    @State private var failed = false

    var body: some View {
        Group {
            if let video {
                VideoPlayerScreen(video: video)
            } else if failed {
                Text("Видео не найдено").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let result = await ObjectResolver.shared.video(ownerID: ownerID, videoID: videoID, settings: settings) {
            video = result
        } else {
            failed = true
        }
    }
}

/// Загружает плейлист по owner_id+id (audio.getPlaylistById) и открывает его.
private struct PlaylistLinkLoader: View {
    let ownerID: Int
    let id: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var album: Album?
    @State private var failed = false

    var body: some View {
        Group {
            if let album {
                AlbumDetailView(album: album)
            } else if failed {
                Text("Плейлист не найден").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        if let result = await ObjectResolver.shared.playlist(ownerID: ownerID, id: id, settings: settings) {
            album = result
        } else {
            failed = true
        }
    }
}
