import SwiftUI

/// Красивый показ текста песни: синхронизированный (подсветка активной строки, автоскролл,
/// тап по строке — перемотка) или обычный (просто прокручиваемый текст).
struct LyricsView: View {
    let track: Audio
    @ObservedObject var clock: PlaybackClock
    let onSeek: (Double) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var lyrics: Lyrics?
    @State private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: lyrics)
        }
        .background(OVK.Palette.card.ignoresSafeArea())
        .task(id: track.id) {
            loading = true
            lyrics = await LyricsService.shared.lyrics(for: track, settings: settings)
            loading = false
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(track.artist).font(.subheadline).foregroundColor(OVK.Palette.textSecondary).lineLimit(1)
                    if let src = lyrics?.source, lyrics?.isEmpty == false {
                        Text(lyrics?.synced == true ? "LRCLIB" : src)
                            .font(.caption2).fontWeight(.semibold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(OVK.Palette.primary.opacity(0.15)))
                            .foregroundColor(OVK.Palette.primary)
                    }
                }
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "chevron.down").font(.title3.weight(.semibold))
                    .foregroundColor(OVK.Palette.textSecondary)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func body(for lyrics: Lyrics?) -> some View {
        if loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let lyrics, !lyrics.isEmpty {
            if lyrics.synced {
                syncedList(lyrics)
            } else {
                plainList(lyrics)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "text.badge.xmark").font(.system(size: 40)).foregroundColor(OVK.Palette.textSecondary)
                Text("Текст не найден").foregroundColor(OVK.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Синхронизированный

    private func syncedList(_ lyrics: Lyrics) -> some View {
        let current = currentIndex(lyrics, time: clock.currentTime)
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { i, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.title3).fontWeight(i == current ? .bold : .regular)
                            .foregroundColor(color(active: i == current, passed: current != nil && i < current!))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .contentShape(Rectangle())
                            .onTapGesture { if let t = line.time { onSeek(t) } }
                    }
                }
                .padding(.horizontal, 24)
                // Отступы, чтобы первая/последняя строка могли встать по центру.
                .padding(.vertical, 220)
                .animation(.easeInOut(duration: 0.25), value: current)
            }
            .onChange(of: current) { idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(idx, anchor: .center) }
            }
            .onAppear {
                if let idx = current { proxy.scrollTo(idx, anchor: .center) }
            }
        }
    }

    // MARK: Обычный (без таймкодов)

    private func plainList(_ lyrics: Lyrics) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Без синхронизации")
                    .font(.caption).foregroundColor(OVK.Palette.textSecondary)
                    .padding(.bottom, 4)
                ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.body)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
        }
    }

    // MARK: Логика

    /// Индекс активной строки: последняя, чьё время ≤ текущему.
    private func currentIndex(_ lyrics: Lyrics, time: Double) -> Int? {
        var idx: Int?
        for (i, line) in lyrics.lines.enumerated() {
            if let t = line.time, t <= time + 0.25 { idx = i } else { break }
        }
        return idx
    }

    private func color(active: Bool, passed: Bool) -> Color {
        if active { return OVK.Palette.textPrimary }
        return OVK.Palette.textSecondary.opacity(passed ? 0.45 : 0.6)
    }
}
