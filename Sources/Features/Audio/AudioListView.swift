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
    @State private var didSetInitialScrollPosition = false
    @State private var didSetInitialScrollPositionAfterLoad = false
    /// Альбом, открытый по кнопке «К альбому» из плеера (программный push, см. .background ниже).
    @State private var routeAlbum: Album?

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    List {
                        OVKSearchStrip(text: $searchText, prompt: "Поиск треков и альбомов", floatsOverPage: true)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)

                        if isSearching {
                            OVKSegmentedControl(
                                options: [
                                    (.tracks, "Треки"),
                                    (.albums, "Альбомы")
                                ],
                                selection: $scope,
                                floatsOverPage: true
                            )
                            .id("music-content-start")
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)
                            searchRows
                        } else {
                            OVKSegmentedControl(
                                options: [
                                    (.online, "Моя музыка"),
                                    (.downloads, "Загрузки"),
                                    (.playlists, "Плейлисты")
                                ],
                                selection: $tab,
                                floatsOverPage: true
                            )
                            .id("music-content-start")
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)
                            libraryRows
                        }

                        Color.clear
                            .frame(height: scrollFillerHeight(in: geometry.size.height))
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)
                    }
                    .environment(\.defaultMinListRowHeight, 0)
                    .listStyle(.plain)
                    .overlay { contentStateOverlay }
                    .refreshable { await refreshContent() }
                    .onAppear {
                        guard !didSetInitialScrollPosition else { return }
                        didSetInitialScrollPosition = true
                        DispatchQueue.main.async {
                            proxy.scrollTo("music-content-start", anchor: .top)
                        }
                    }
                    .onChange(of: model.isLoading) { isLoading in
                        guard !isLoading,
                              !didSetInitialScrollPositionAfterLoad,
                              searchText.isEmpty else { return }
                        didSetInitialScrollPositionAfterLoad = true
                        DispatchQueue.main.async {
                            proxy.scrollTo("music-content-start", anchor: .top)
                        }
                    }
                    .onChange(of: model.tracks.count) { _ in
                        guard !didSetInitialScrollPositionAfterLoad,
                              searchText.isEmpty else { return }
                        didSetInitialScrollPositionAfterLoad = true
                        DispatchQueue.main.async {
                            proxy.scrollTo("music-content-start", anchor: .top)
                        }
                    }
                }
            }
            .navigationTitle("Музыка")
            .navigationBarTitleDisplayMode(.inline) // единый стиль навбара со всеми вкладками
            .pushesGlobalLinks(tab: 3) // ссылки из музыки пушатся в стек этой вкладки
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background)
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
            .task(id: tab) {
                guard tab == .playlists else { return }
                await playlists.loadIfNeeded(settings: settings)
            }
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

    // MARK: - Содержимое единственного списка

    @ViewBuilder
    private var libraryRows: some View {
        switch tab {
        case .online:
            ForEach(model.tracks) { track in
                AudioRow(track: track)
                    .contentShape(Rectangle())
                    .onTapGesture { tapTrack(track, in: model.tracks.filter { $0.isPlayable }, autoDownload: true, source: "Моя музыка") }
            }
        case .downloads:
            ForEach(downloads.downloaded) { track in
                AudioRow(track: track, showAddToLibrary: false)
                    .contentShape(Rectangle())
                    .onTapGesture { tapTrack(track, in: downloads.downloaded, source: "Загрузки") }
            }
            .onMove { downloads.move(from: $0, to: $1) }
            .onDelete { offsets in
                offsets.map { downloads.downloaded[$0] }.forEach { downloads.remove($0) }
            }
        case .playlists:
            ForEach(playlists.albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumRow(album: album)
                }
            }
        }
    }

    @ViewBuilder
    private var searchRows: some View {
        switch scope {
        case .tracks:
            ForEach(search.tracks) { track in
                AudioRow(track: track, showAddedBadge: true)
                    .contentShape(Rectangle())
                    .onTapGesture { tapTrack(track, in: search.tracks.filter { $0.isPlayable }, source: "Поиск") }
            }
        case .albums:
            ForEach(search.albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumRow(album: album)
                }
            }
        }
    }

    @ViewBuilder
    private var contentStateOverlay: some View {
        if isSearching {
            searchStateOverlay
        } else {
            libraryStateOverlay
        }
    }

    @ViewBuilder
    private var libraryStateOverlay: some View {
        switch tab {
        case .online:
            if model.isLoading && model.tracks.isEmpty {
                ProgressView()
            } else if let error = model.errorMessage, model.tracks.isEmpty {
                retryState(error) { await model.load(settings: settings) }
            } else if model.tracks.isEmpty {
                Text("Нет аудиозаписей").foregroundColor(OVK.Palette.textSecondary)
            }
        case .downloads:
            if downloads.downloaded.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle").font(.largeTitle)
                    Text("Нет скачанных треков")
                    Text("Нажмите ↓ у трека во вкладке «Моя музыка», чтобы слушать офлайн")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(OVK.Palette.textSecondary)
                .padding()
            }
        case .playlists:
            if playlists.isLoading && playlists.albums.isEmpty {
                ProgressView()
            } else if let error = playlists.errorMessage, playlists.albums.isEmpty {
                retryState(error) { await playlists.load(settings: settings) }
            } else if playlists.albums.isEmpty {
                Text("Нет плейлистов").foregroundColor(OVK.Palette.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var searchStateOverlay: some View {
        let resultsAreEmpty = scope == .tracks ? search.tracks.isEmpty : search.albums.isEmpty
        let error = scope == .tracks ? search.trackErrorMessage : search.albumErrorMessage
        if search.isLoading && resultsAreEmpty {
            ProgressView()
        } else if let error, resultsAreEmpty {
            retryState(error) {
                await search.run(query: searchText.trimmingCharacters(in: .whitespaces), settings: settings)
            }
        } else if resultsAreEmpty {
            Text(search.tooShort
                 ? "Введите не менее \(SearchViewModel.minQueryLength) символов"
                 : "Ничего не найдено")
                .foregroundColor(OVK.Palette.textSecondary)
                .multilineTextAlignment(.center)
                .padding()
        }
    }

    private func retryState(_ message: String, action: @escaping () async -> Void) -> some View {
        VStack(spacing: 12) {
            Text(message)
                .foregroundColor(OVK.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Повторить") { Task { await action() } }
        }
        .padding()
    }

    private func refreshContent() async {
        if isSearching {
            await search.run(query: searchText.trimmingCharacters(in: .whitespaces), settings: settings)
        } else if tab == .playlists {
            await playlists.load(settings: settings)
        } else if tab == .online {
            await model.load(settings: settings)
        }
    }

    private func scrollFillerHeight(in listHeight: CGFloat) -> CGFloat {
        // ponytail: rows are at least the 44-pt tap target; measure actual content
        // only if a future compact row becomes shorter and breaks initial hiding.
        let rowCount: Int
        if isSearching {
            rowCount = scope == .tracks ? search.tracks.count : search.albums.count
        } else {
            switch tab {
            case .online: rowCount = model.tracks.count
            case .downloads: rowCount = downloads.downloaded.count
            case .playlists: rowCount = playlists.albums.count
            }
        }
        return max(0, listHeight - OVK.Metrics.minimumTapSize * CGFloat(rowCount + 1))
    }

    // MARK: - Воспроизведение

    /// `autoDownload` — true только для вкладки «Моя музыка»: там прослушанное
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
