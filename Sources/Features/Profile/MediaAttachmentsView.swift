import SwiftUI
import UIKit

/// Аудио- и видео-вложения (для постов и комментариев): аудио играется, видео открывается в плеере.
struct MediaAttachmentsView: View {
    let audios: [Audio]
    let videos: [Video]
    @EnvironmentObject private var player: AudioPlayer
    @EnvironmentObject private var downloads: AudioDownloadManager
    @EnvironmentObject private var library: LibraryManager
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedVideo: Video?

    @ViewBuilder
    var body: some View {
        if audios.isEmpty && videos.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(audios) { track in
                    // Встроенное меню строки выключено: внутри ячейки List (пост в ленте)
                    // SwiftUI вешает его на ВСЮ ячейку — long-press по любому месту поста
                    // открывал меню трека. UIKit-взаимодействие держит его в рамке строки.
                    // Тап — через Button (не onTapGesture): жест поверх UIKit-подложки
                    // давал «мёртвые зоны» над текстом названия, кнопка бьёт по всей строке.
                    Button { playTrack(track) } label: {
                        AudioRow(track: track, showsContextMenu: false)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RowScopedContextMenu { trackMenu(track) })
                }
                ForEach(videos) { video in
                    videoThumb(video)
                        .contentShape(Rectangle())
                        .onTapGesture { selectedVideo = video }
                }
            }
            .fullScreenCover(item: $selectedVideo) { video in
                VideoPlayerScreen(video: video)
            }
        }
    }

    private func videoThumb(_ video: Video) -> some View {
        ZStack {
            CachedImage(url: video.thumbURL) {
                ZStack { OVK.Palette.background; Image(systemName: "play.rectangle").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .clipped()
            .cornerRadius(6)

            Image(systemName: "play.circle.fill")
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.9))
                .shadow(radius: 3)

            VStack {
                Spacer()
                HStack {
                    Text(video.title.isEmpty ? "Видео" : video.title)
                        .font(.caption).foregroundColor(.white).lineLimit(1)
                    Spacer()
                    Text(video.durationText).font(.caption2).foregroundColor(.white)
                }
                .padding(6)
                .background(Color.black.opacity(0.45))
            }
            .cornerRadius(6)
        }
    }

    private func playTrack(_ track: Audio) {
        guard track.isPlayable else { return }
        if player.current?.id == track.id {
            player.togglePlayPause()
        } else {
            player.play(track, in: audios.filter { $0.isPlayable })
        }
    }

    /// Те же действия, что в контекст-меню AudioRow, но в виде UIMenu (для UIKit-взаимодействия).
    private func trackMenu(_ track: Audio) -> UIMenu {
        var actions: [UIAction] = []
        if track.isPlayable || downloads.isDownloaded(track) {
            actions.append(UIAction(title: "Играть следующим", image: UIImage(systemName: "play.circle")) { _ in
                Task { @MainActor in player.playNext(track) }
            })
            actions.append(UIAction(title: "В конец очереди", image: UIImage(systemName: "list.bullet")) { _ in
                Task { @MainActor in player.enqueue(track) }
            })
        }
        // Переход к альбому — только если трек к нему привязан (MainTabView откроет «Музыку»).
        if let album = track.album {
            actions.append(UIAction(title: "Перейти к альбому", image: UIImage(systemName: "music.note.list")) { _ in
                Task { @MainActor in player.pendingAlbum = album }
            })
        }
        if library.isAdded(track) {
            actions.append(UIAction(title: "Убрать из моей музыки",
                                    image: UIImage(systemName: "minus.circle"),
                                    attributes: .destructive) { _ in
                Task { @MainActor in library.toggleTrack(track, settings: settings) }
            })
        } else {
            actions.append(UIAction(title: "Добавить к себе", image: UIImage(systemName: "plus.circle")) { _ in
                Task { @MainActor in library.toggleTrack(track, settings: settings) }
            })
        }
        return UIMenu(children: actions)
    }
}

// MARK: - Контекст-меню строго в рамке строки

/// SwiftUI `.contextMenu` внутри ячейки `List` вешается на ВСЮ ячейку. Здесь взаимодействие
/// UIKit прикреплено к прозрачной подложке размером ровно со строку: long-press срабатывает
/// только над ней, а тапы/кнопки SwiftUI поверх продолжают работать (их распознаватели живут
/// на родительском hosting-view и получают касания, чей hit-test пришёлся на подложку).
private struct RowScopedContextMenu: UIViewRepresentable {
    let menu: () -> UIMenu

    func makeCoordinator() -> Coordinator { Coordinator(menu: menu) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.addInteraction(UIContextMenuInteraction(delegate: context.coordinator))
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.menu = menu
    }

    final class Coordinator: NSObject, UIContextMenuInteractionDelegate {
        var menu: () -> UIMenu

        init(menu: @escaping () -> UIMenu) { self.menu = menu }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            configurationForMenuAtLocation location: CGPoint
        ) -> UIContextMenuConfiguration? {
            let menu = self.menu
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu() }
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForHighlightingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            targetedPreview(for: interaction)
        }

        func contextMenuInteraction(
            _ interaction: UIContextMenuInteraction,
            previewForDismissingMenuWithConfiguration configuration: UIContextMenuConfiguration
        ) -> UITargetedPreview? {
            targetedPreview(for: interaction)
        }

        /// Подложка прозрачная (пиксели строки рисует SwiftUI поверх), поэтому «поднимаемое»
        /// превью — снимок участка окна под рамкой строки.
        private func targetedPreview(for interaction: UIContextMenuInteraction) -> UITargetedPreview? {
            guard let view = interaction.view, let window = view.window else { return nil }
            let frame = view.convert(view.bounds, to: window)
            guard let snapshot = window.resizableSnapshotView(
                from: frame, afterScreenUpdates: false, withCapInsets: .zero
            ) else { return nil }
            let parameters = UIPreviewParameters()
            parameters.backgroundColor = .clear
            parameters.visiblePath = UIBezierPath(roundedRect: snapshot.bounds, cornerRadius: 8)
            let target = UIPreviewTarget(container: window,
                                         center: CGPoint(x: frame.midX, y: frame.midY))
            return UITargetedPreview(view: snapshot, parameters: parameters, target: target)
        }
    }
}
