import SwiftUI

@main
struct OVKApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var player = AudioPlayer()
    @StateObject private var downloads = AudioDownloadManager()
    @StateObject private var library = LibraryManager()
    @StateObject private var likes = LikesManager()

    init() {
        // Дисковый+памятный кэш для всех запросов (обложки, JSON-ответы, тексты).
        URLCache.shared = URLCache(
            memoryCapacity: 50 * 1024 * 1024,    // 50 МБ
            diskCapacity: 200 * 1024 * 1024      // 200 МБ
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(settings)
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(library)
                .environmentObject(likes)
                .preferredColorScheme(.light) // дизайн старого VK — всегда светлая тема
        }
    }
}
