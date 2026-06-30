import SwiftUI

/// Аудиозаписи пользователя (переиспользует AudioViewModel + AudioRow).
struct UserAudiosView: View {
    var ownerID: Int = 0
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @StateObject private var model = AudioViewModel()

    var body: some View {
        Group {
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
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Аудиозаписи")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.tracks.isEmpty { await model.load(ownerID: ownerID, settings: settings) }
        }
    }
}
