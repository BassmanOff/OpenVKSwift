import SwiftUI
import UIKit

struct AudioListView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var library: LibraryManager
    @StateObject private var model = AudioViewModel()
    @StateObject private var search = SearchViewModel()
    @StateObject private var playlists = PlaylistsViewModel()

    private enum Tab: Hashable { case online, downloads, playlists }
    private enum Scope: Hashable { case tracks, albums }
    @State private var tab: Tab = .online
    @State private var scope: Scope = .tracks
    @State private var searchText = ""
    /// Альбом, открытый по кнопке «К альбому» из плеера (программный push, см. .background ниже).
    @State private var routeAlbum: Album?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if isSearching {
                    searchSection
                } else {
                    librarySection
                }
            }
            .navigationTitle("Музыка")
            .navigationBarTitleDisplayMode(.inline) // единый стиль навбара со всеми вкладками
            .pushesGlobalLinks(tab: 3) // ссылки из музыки пушатся в стек этой вкладки
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background.ignoresSafeArea())
            // Программный переход к альбому играющего трека (кнопка «К альбому» в плеере).
            // Один NavigationLink(isActive:) в фоне — как в GroupView (не в строке List).
            .background(
                NavigationLink(
                    isActive: Binding(get: { routeAlbum != nil }, set: { if !$0 { routeAlbum = nil } })
                ) {
                    if let routeAlbum { AlbumDetailView(album: routeAlbum) }
                } label: { EmptyView() }
                .hidden()
            )
            .onReceive(player.$pendingAlbum) { album in
                guard let album else { return }
                tab = .playlists       // назад из альбома пользователь попадёт в «Плейлисты»
                routeAlbum = album
            }
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Поиск треков и альбомов"
            )
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if tab == .downloads && !isSearching && !downloads.downloaded.isEmpty {
                        EditButton()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await model.load(settings: settings) }
        .task(id: searchText) {
            let q = searchText.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { search.clear(); return }
            try? await Task.sleep(nanoseconds: 600_000_000) // дебаунс
            if Task.isCancelled { return }
            await search.run(query: q, settings: settings)
        }
        .alert("Трек недоступен", isPresented: Binding(
            get: { model.diagnostic != nil },
            set: { if !$0 { model.diagnostic = nil } }
        )) {
            Button("Скопировать данные") {
                UIPasteboard.general.string = model.diagnosticRaw
                model.diagnostic = nil
            }
            Button("Закрыть", role: .cancel) { model.diagnostic = nil }
        } message: {
            Text(model.diagnostic ?? "")
        }
        .toast($library.toast)
    }

    // MARK: - Библиотека (Онлайн / Загрузки)

    private var librarySection: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Онлайн").tag(Tab.online)
                Text("Загрузки").tag(Tab.downloads)
                Text("Плейлисты").tag(Tab.playlists)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch tab {
            case .online:    onlineContent
            case .downloads: downloadsContent
            case .playlists: playlistsContent
            }
        }
    }

    @ViewBuilder
    private var onlineContent: some View {
        if model.isLoading && model.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.tracks.isEmpty {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Повторить") { Task { await model.load(settings: settings) } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else if model.tracks.isEmpty {
            Text("Нет аудиозаписей")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.tracks) { track in
                AudioRow(track: track)
                    .contentShape(Rectangle())
                    .onTapGesture { tapTrack(track, in: model.tracks.filter { $0.isPlayable }, autoDownload: true, source: "Моя музыка") }
            }
            .listStyle(.plain)
            .refreshable { await model.load(settings: settings) }
        }
    }

    @ViewBuilder
    private var downloadsContent: some View {
        if downloads.downloaded.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.circle")
                    .font(.largeTitle)
                    .foregroundColor(OVK.Palette.textSecondary)
                Text("Нет скачанных треков")
                    .foregroundColor(OVK.Palette.textSecondary)
                Text("Нажмите ↓ у трека во вкладке «Онлайн», чтобы слушать офлайн")
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        } else {
            List {
                ForEach(downloads.downloaded) { track in
                    AudioRow(track: track, showAddToLibrary: false)
                        .contentShape(Rectangle())
                        .onTapGesture { tapTrack(track, in: downloads.downloaded, source: "Загрузки") }
                }
                .onMove { downloads.move(from: $0, to: $1) }
                .onDelete { offsets in
                    offsets.map { downloads.downloaded[$0] }.forEach { downloads.remove($0) }
                }
            }
            .listStyle(.plain)
        }
    }

    // MARK: - Плейлисты

    private var playlistsContent: some View {
        Group {
            if playlists.isLoading && playlists.albums.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = playlists.errorMessage, playlists.albums.isEmpty {
                VStack(spacing: 12) {
                    Text(error)
                        .foregroundColor(OVK.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Повторить") { Task { await playlists.load(settings: settings) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if playlists.albums.isEmpty {
                Text("Нет плейлистов")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(playlists.albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumRow(album: album)
                    }
                }
                .listStyle(.plain)
                .refreshable { await playlists.load(settings: settings) }
            }
        }
        .task { await playlists.loadIfNeeded(settings: settings) }
    }

    // MARK: - Поиск (Треки / Альбомы)

    private var searchSection: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scope) {
                Text("Треки").tag(Scope.tracks)
                Text("Альбомы").tag(Scope.albums)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch scope {
            case .tracks: searchTracks
            case .albums: searchAlbums
            }
        }
    }

    @ViewBuilder
    private var searchTracks: some View {
        if search.isLoading && search.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.tracks.isEmpty {
            emptySearch
        } else {
            List(search.tracks) { track in
                AudioRow(track: track, showAddedBadge: true)
                    .contentShape(Rectangle())
                    .onTapGesture { tapTrack(track, in: search.tracks.filter { $0.isPlayable }, source: "Поиск") }
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var searchAlbums: some View {
        if search.isLoading && search.albums.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if search.albums.isEmpty {
            emptySearch
        } else {
            List(search.albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumRow(album: album)
                }
            }
            .listStyle(.plain)
        }
    }

    private var emptySearch: some View {
        Text(search.tooShort
             ? "Введите не менее \(SearchViewModel.minQueryLength) символов"
             : "Ничего не найдено")
            .foregroundColor(OVK.Palette.textSecondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Воспроизведение

    /// `autoDownload` — true только для вкладки «Онлайн» (Мои треки): там прослушанное
    /// докачивается для офлайна. Поиск/Загрузки такого не делают.
    private func tapTrack(_ track: Audio, in list: [Audio], autoDownload: Bool = false, source: String? = nil) {
        if track.isPlayable || downloads.isDownloaded(track) {
            if player.current?.id == track.id {
                player.togglePlayPause()
            } else {
                player.play(track, in: list, autoDownload: autoDownload, source: source)
            }
        } else if track.isProcessing {
            // Трек был в обработке — пробуем ещё раз (аналог «Всё равно воспроизвести» на сайте).
            Task {
                if let fresh = await model.retry(track, settings: settings), fresh.isPlayable {
                    player.play(fresh, in: model.tracks.filter { $0.isPlayable }, autoDownload: autoDownload, source: source)
                } else {
                    // Сервер так и не отдал источник — объясняем честно, raw оставляем для отправки.
                    model.diagnosticRaw = await model.fetchRaw(track, settings: settings)
                    model.diagnostic = "Сервер OpenVK не обработал этот трек (ready=false) и не отдаёт " +
                        "ни mp3, ни поток — воспроизвести его в приложении нельзя."
                }
            }
        }
        // withdrawn (снят по копирайту) — не играется нигде, тап игнорируем.
    }
}

