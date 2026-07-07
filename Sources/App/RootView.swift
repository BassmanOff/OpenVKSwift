import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var longPoll: LongPollService

    var body: some View {
        Group {
            if settings.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        // Просмотрщик фото живёт в отдельном окне поверх всего приложения —
        // включая sheet'ы (страницы, открытые по ссылке). Здесь только монтируем его.
        .background(PhotoHeroWindowMount())
        .onAppear {
            player.attach(downloads: downloads)
            player.attach(settings: settings)
            library.attach(downloads: downloads)
            player.downloadOnPlay = settings.autoDownloadMyTracks
        }
        .onChange(of: settings.autoDownloadMyTracks) { enabled in
            player.downloadOnPlay = enabled
        }
        .onChange(of: settings.isLoggedIn) { loggedIn in
            // При выходе из аккаунта останавливаем воспроизведение и LongPoll,
            // и стираем кэши личных сообщений.
            if !loggedIn {
                player.stop()
                longPoll.stop()
                ConversationsViewModel.clearCache()
                ChatViewModel.clearAllCaches()
                // Кэши ленты и профилей — тоже личные данные.
                NewsfeedViewModel.clearCache()
                ProfileViewModel.clearCache()
                WallViewModel.clearCache()
            }
        }
    }
}
