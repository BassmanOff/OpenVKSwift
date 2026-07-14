import SwiftUI

@main
struct OVKApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var settings = AppSettings()
    @StateObject private var player = AudioPlayer()
    @StateObject private var downloads = AudioDownloadManager()
    @StateObject private var library = LibraryManager()
    @StateObject private var likes = LikesManager()
    @StateObject private var longPoll = LongPollService()
    @StateObject private var photoHero = PhotoHeroCoordinator()
    @StateObject private var keepAlive = KeepAliveService()
    @StateObject private var drafts = PostDraftManager()

    init() {
        // Дисковый+памятный кэш для всех запросов (обложки, JSON-ответы, тексты).
        // Память скромная: декодированные картинки живут в ImageCache, а держать
        // ещё и сжатые байты в RAM незачем — с диска они читаются быстро.
        URLCache.shared = URLCache(
            memoryCapacity: 16 * 1024 * 1024,    // 16 МБ
            diskCapacity: 200 * 1024 * 1024      // 200 МБ
        )

        // Один и тот же облик навбара во всех состояниях скролла.
        // Иначе на iOS 15 переход scrollEdge↔standard анимирует прозрачность/высоту,
        // и кнопки с заголовком «прыгают» (Профиль, Музыка, Новости).
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = .systemBackground
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(library)
                .environmentObject(likes)
                .environmentObject(longPoll)
                .environmentObject(photoHero)
                .environmentObject(keepAlive)
                .environmentObject(drafts)
                .preferredColorScheme(.light) // дизайн старого VK — всегда светлая тема
        }
    }
}
