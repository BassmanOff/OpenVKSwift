import SwiftUI

/// Состояние текста трека — ObservableObject, а не init-параметр: hosting-root страницы
/// не заменяется, а @ObservedObject доставляет в него новые данные. Грузит контейнер VKPlayerView.
@MainActor
final class LyricsStore: ObservableObject {
    @Published var lyrics: Lyrics?
    @Published var loading = false
}

/// Чистое отображение: текст грузит контейнер VKPlayerView при каждой смене трека,
/// чтобы сетевая работа не зависела от видимости страницы.
/// Трек читаем из player (своя подписка), НЕ из init-параметра — см. LyricsStore выше.
struct VKPlayerLyricsPage: View {
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var store: LyricsStore
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        if let track = player.current {
            lyricBody(for: track)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.xmark")
                    .font(.system(size: 40))
                Text("Выберите трек, чтобы увидеть текст")
            }
            .foregroundColor(OVK.Palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func lyricBody(for track: Audio) -> some View {
        VStack(spacing: 0) {
            // Крупная шапка страницы текста, как в референсе: жирное название + синий артист.
            VStack(spacing: 4) {
                Text(track.title).font(.title2.weight(.bold)).lineLimit(1)
                Text(track.artist).font(.subheadline).foregroundColor(OVK.Palette.primary).lineLimit(1)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)
            if store.loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let lyrics = store.lyrics, !lyrics.isEmpty {
                lyrics.synced ? AnyView(syncedList(lyrics)) : AnyView(plainList(lyrics))
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "text.badge.xmark").font(.system(size: 40))
                    Text("Текст не найден")
                }
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func syncedList(_ lyrics: Lyrics) -> some View {
        let current = currentIndex(lyrics, time: clock.currentTime)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3)
                            .foregroundColor(color(active: index == current, passed: current.map { index < $0 } ?? false))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { if let time = line.time { player.seek(to: time) } }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 220)
                .animation(.easeInOut(duration: 0.25), value: current)
            }
            .onChange(of: current) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
    }

    private func plainList(_ lyrics: Lyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Без синхронизации")
                    .font(.caption)
                    .foregroundColor(OVK.Palette.textSecondary)
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(28)
        }
    }

    private func currentIndex(_ lyrics: Lyrics, time: Double) -> Int? {
        var index: Int?
        for (offset, line) in lyrics.lines.enumerated() {
            if let lineTime = line.time, lineTime <= time + 0.25 { index = offset } else { break }
        }
        return index
    }

    private func color(active: Bool, passed: Bool) -> Color {
        active ? OVK.Palette.textPrimary : OVK.Palette.textSecondary.opacity(passed ? 0.45 : 0.6)
    }
}
