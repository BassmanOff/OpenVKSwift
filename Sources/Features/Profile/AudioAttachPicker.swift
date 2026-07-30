import SwiftUI

/// Выбор трека для вложения к посту/комментарию: своя музыка + поиск (переиспользует
/// AudioViewModel/SearchViewModel — те же, что во вкладке «Музыка»). Прикрепление — по
/// ссылке (owner_id+audio_id), файл не грузится.
struct AudioAttachPicker: View {
    var onPick: (Audio) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var library = AudioViewModel()
    @StateObject private var search = SearchViewModel()
    @State private var searchText = ""

    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                OVKSearchStrip(text: $searchText, prompt: "Поиск треков")
                Group {
                    if isSearching {
                        searchList
                    } else {
                        libraryList
                    }
                }
            }
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle("Прикрепить трек")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await library.load(settings: settings) }
        .task(id: searchText) {
            let q = searchText.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { search.clear(); return }
            try? await Task.sleep(nanoseconds: 600_000_000) // дебаунс, как в AudioListView
            if Task.isCancelled { return }
            await search.run(query: q, settings: settings)
        }
    }

    @ViewBuilder
    private var libraryList: some View {
        if library.isLoading && library.tracks.isEmpty {
            OVKListStateView(message: "Загрузка треков…", isLoading: true)
        } else if library.tracks.isEmpty {
            OVKListStateView(message: "В «Моей музыке» пока пусто")
        } else {
            List(library.tracks) { track in
                Button { pick(track) } label: { AudioRow(track: track, showAddToLibrary: false) }
                    .buttonStyle(.plain)
                    .ovkPlainListRow()
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var searchList: some View {
        if search.tooShort {
            OVKListStateView(message: "Введите не менее \(SearchViewModel.minQueryLength) символов")
        } else if search.isLoading && search.tracks.isEmpty {
            OVKListStateView(message: "Поиск треков…", isLoading: true)
        } else if search.tracks.isEmpty {
            OVKListStateView(message: search.trackErrorMessage ?? "Ничего не найдено")
        } else {
            List(search.tracks) { track in
                Button { pick(track) } label: { AudioRow(track: track, showAddToLibrary: false, showAddedBadge: true) }
                    .buttonStyle(.plain)
                    .ovkPlainListRow()
            }
            .listStyle(.plain)
        }
    }

    private func pick(_ track: Audio) {
        onPick(track)
        dismiss()
    }
}
