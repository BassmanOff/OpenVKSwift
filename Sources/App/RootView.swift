import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var longPoll: LongPollService

    var body: some View {
        ZStack {
            Group {
                if settings.isLoggedIn {
                    MainTabView()
                } else {
                    LoginView()
                }
            }
            // Просмотрщик фото «вылетает» из миниатюры — оверлей поверх всего (включая таб-бар).
            PhotoHeroOverlay()
        }
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
            }
        }
    }
}
