import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var likes: LikesManager
    @EnvironmentObject private var longPoll: LongPollService
    @EnvironmentObject private var drafts: PostDraftManager

    var body: some View {
        Group {
            if settings.isLoggedIn {
                MainTabView()
                    .id(settings.sessionID)
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
        .onChange(of: settings.sessionID) { _ in
            // Экранные модели пересоздаются через .id(sessionID); дисковые кэши остаются
            // в изолированном каталоге аккаунта и снова используются при возврате.
            player.stop()
            longPoll.stop()
            likes.clear()
            LikersViewModel.clearCache()
            ObjectResolver.shared.clear()
            drafts.clear()
        }
    }
}
