import SwiftUI

struct RootView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager

    var body: some View {
        Group {
            if settings.isLoggedIn {
                MainTabView()
            } else {
                LoginView()
            }
        }
        .onAppear { player.attach(downloads: downloads) }
        .onChange(of: settings.isLoggedIn) { loggedIn in
            // При выходе из аккаунта останавливаем воспроизведение.
            if !loggedIn { player.stop() }
        }
    }
}
