import SwiftUI

/// Аудиозаписи пользователя/сообщества: переключатель Треки / Альбомы.
/// (У сообществ в аудио бывают не только треки, но и альбомы — как в поиске.)
struct UserAudiosView: View {
    var ownerID: Int = 0
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @StateObject private var model = AudioViewModel()

    private enum Scope: Hashable { case tracks, albums }
    @State private var scope: Scope = .tracks

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $scope) {
                Text("Треки").tag(Scope.tracks)
                Text("Альбомы").tag(Scope.albums)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch scope {
            case .tracks: tracksContent
            case .albums: albumsContent
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Аудиозаписи")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.tracks.isEmpty { await model.load(ownerID: ownerID, settings: settings) }
        }
        .task(id: scope) {
            if scope == .albums { await model.loadAlbums(ownerID: ownerID, settings: settings) }
        }
    }

    @ViewBuilder
    private var tracksContent: some View {
        if model.isLoading && model.tracks.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.tracks.isEmpty {
            ErrorRetry(message: error) { Task { await model.load(ownerID: ownerID, settings: settings) } }
        } else if model.tracks.isEmpty {
            Text("Нет аудиозаписей")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.tracks) { track in
                AudioRow(track: track)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard track.isPlayable else { return }
                        if player.current?.id == track.id {
                            player.togglePlayPause()
                        } else {
                            player.play(track, in: model.tracks.filter { $0.isPlayable })
                        }
                    }
            }
            .listStyle(.plain)
            .refreshable { await model.load(ownerID: ownerID, settings: settings) }
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        if model.albumsLoading && model.albums.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.albums.isEmpty {
            Text("Нет альбомов")
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(model.albums) { album in
                NavigationLink {
                    AlbumDetailView(album: album)
                } label: {
                    AlbumRow(album: album)
                }
            }
            .listStyle(.plain)
            .refreshable { await model.loadAlbums(ownerID: ownerID, settings: settings, force: true) }
        }
    }
}
