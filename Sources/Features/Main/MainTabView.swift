import SwiftUI

struct MainTabView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            FeedPlaceholderView()
                .tabItem { Label("Новости", systemImage: "newspaper") }

            AudioListView()
                .tabItem { Label("Музыка", systemImage: "music.note") }

            ProfileView()
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
        }
        .tint(OVK.Palette.primary)
        .task {
            // Пока приложение открыто — держим статус «онлайн» (окно 5 мин, пингуем чаще).
            while !Task.isCancelled {
                settings.reportOnline()
                try? await Task.sleep(nanoseconds: 240 * 1_000_000_000)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { settings.reportOnline() }
        }
    }
}

private struct FeedPlaceholderView: View {
    var body: some View {
        NavigationView {
            Text("Лента — скоро")
                .foregroundColor(OVK.Palette.textSecondary)
                .navigationTitle("Новости")
        }
    }
}
