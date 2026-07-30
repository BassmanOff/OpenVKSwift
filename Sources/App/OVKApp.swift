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

        // Оригинальный VK использовал один непрозрачный синий бар во всех состояниях
        // прокрутки. Одинаковые appearance не дают iOS 15 менять его у края списка.
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(OVK.Palette.primary)
        nav.shadowColor = .clear
        nav.titleTextAttributes = [
            .foregroundColor: UIColor.white,
            .font: UIFont.preferredFont(forTextStyle: .headline)
        ]
        nav.largeTitleTextAttributes = [
            .foregroundColor: UIColor.white
        ]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
        UINavigationBar.appearance().compactAppearance = nav
        UINavigationBar.appearance().tintColor = .white
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .font(OVK.Typography.body)
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
