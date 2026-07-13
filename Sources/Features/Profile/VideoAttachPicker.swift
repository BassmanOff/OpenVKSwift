import SwiftUI

/// Выбор видео для вложения к посту/комментарию: свои видео + поиск. Прикрепление —
/// по ссылке (owner_id+video_id), как аудио: загрузки нового видео в VKAPI нет вообще
/// (Video.php — только get/search, upload — HTML-форма на sessionAuth, недоступна отсюда).
struct VideoAttachPicker: View {
    var onPick: (Video) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = VideosViewModel()
    @State private var searchResults: [Video] = []
    @State private var isSearching = false
    @State private var searchText = ""

    private var showingSearch: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationView {
            Group {
                if showingSearch {
                    list(searchResults, empty: "Ничего не найдено", loading: isSearching)
                } else {
                    list(library.videos, empty: "Нет видеозаписей", loading: library.isLoading)
                }
            }
            .navigationTitle("Прикрепить видео")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Поиск видео")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        // video.get(owner_id: 0) отвечает "Not implemented" — нужен реальный id, не 0-конвенция как у аудио/фото.
        .task { if let uid = settings.userID { await library.loadIfNeeded(ownerID: uid, settings: settings) } }
        .task(id: searchText) {
            let q = searchText.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { searchResults = []; return }
            try? await Task.sleep(nanoseconds: 600_000_000) // дебаунс, как в AudioAttachPicker
            if Task.isCancelled { return }
            await runSearch(q)
        }
    }

    @ViewBuilder
    private func list(_ videos: [Video], empty: String, loading: Bool) -> some View {
        if loading && videos.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if videos.isEmpty {
            Text(empty)
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(videos) { video in
                Button { onPick(video); dismiss() } label: { row(video) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func row(_ video: Video) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: video.thumbURL) {
                ZStack { OVK.Palette.background; Image(systemName: "play.rectangle").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(width: 100, height: 60)
            .clipped()
            .cornerRadius(4)
            .overlay(alignment: .bottomTrailing) {
                Text(video.durationText)
                    .font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(Color.black.opacity(0.7))
                    .foregroundColor(.white)
                    .cornerRadius(3)
                    .padding(2)
            }
            Text(video.title).foregroundColor(OVK.Palette.textPrimary).lineLimit(3)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func runSearch(_ q: String) async {
        guard let token = settings.token else { return }
        isSearching = true
        defer { isSearching = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: ItemsResponse<Video> = try await client.call(
                "video.search", params: ["q": q, "count": "50"]
            )
            if Task.isCancelled { return }
            searchResults = res.items
        } catch {
            if Task.isCancelled { return }
            searchResults = []
        }
    }
}
