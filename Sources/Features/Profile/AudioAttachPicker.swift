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
            Group {
                if isSearching {
                    searchList
                } else {
                    libraryList
                }
            }
            .navigationTitle("Прикрепить трек")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Поиск треков")
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
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if library.tracks.isEmpty {
            Text("В «Моей музыке» пока пусто")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(library.tracks) { track in
                Button { pick(track) } label: { AudioRow(track: track, showAddToLibrary: false) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var searchList: some View {
        if search.tooShort {
            Text("Введите не менее \(SearchViewModel.minQueryLength) символов")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.isLoading && search.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.tracks.isEmpty {
            Text(search.errorMessage ?? "Ничего не найдено")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(search.tracks) { track in
                Button { pick(track) } label: { AudioRow(track: track, showAddToLibrary: false, showAddedBadge: true) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func pick(_ track: Audio) {
        onPick(track)
        dismiss()
    }
}
