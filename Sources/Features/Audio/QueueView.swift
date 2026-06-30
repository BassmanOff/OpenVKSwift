import SwiftUI
import UniformTypeIdentifiers

/// Экран текущей очереди: тап — перейти к треку, зажать и тянуть — переставить, свайп — убрать.
/// Без «режима редактирования»: перетаскивание по long-press через onDrag/onDrop.
struct QueueView: View {
    @EnvironmentObject private var player: AudioPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var dragging: Audio?

    var body: some View {
        NavigationView {
            Group {
                if player.queue.isEmpty {
                    Text("Очередь пуста")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        List {
                            ForEach(player.queue) { track in
                                QueueRow(track: track, isCurrent: track.id == player.current?.id)
                                    .id(track.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        if let i = player.queue.firstIndex(where: { $0.id == track.id }) {
                                            player.play(at: i)
                                        }
                                    }
                                    .onDrag {
                                        dragging = track
                                        return NSItemProvider(object: track.id as NSString)
                                    }
                                    .onDrop(
                                        of: [.text],
                                        delegate: QueueDropDelegate(item: track, dragging: $dragging, player: player)
                                    )
                            }
                            .onDelete { player.removeFromQueue(at: $0) }
                        }
                        .listStyle(.plain)
                        .onAppear { scrollToCurrent(proxy, animated: false) }
                        .onChange(of: player.current?.id) { _ in scrollToCurrent(proxy, animated: true) }
                    }
                }
            }
            .navigationTitle("Очередь")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = player.current?.id else { return }
        // небольшая задержка, чтобы список успел разложиться перед прокруткой
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0 : 0.1)) {
            if animated {
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }
}

/// Живая перестановка треков во время перетаскивания.
private struct QueueDropDelegate: DropDelegate {
    let item: Audio
    @Binding var dragging: Audio?
    let player: AudioPlayer

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        Task { @MainActor in
            let q = player.queue
            guard let from = q.firstIndex(where: { $0.id == dragging.id }),
                  let to = q.firstIndex(where: { $0.id == item.id }) else { return }
            withAnimation {
                player.moveInQueue(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private struct QueueRow: View {
    let track: Audio
    let isCurrent: Bool
    @EnvironmentObject private var player: AudioPlayer

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isCurrent ? (player.isPlaying ? "speaker.wave.2.fill" : "speaker.fill") : "music.note")
                .foregroundColor(isCurrent ? OVK.Palette.primary : OVK.Palette.textSecondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundColor(isCurrent ? OVK.Palette.primary : OVK.Palette.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.durationText)
                .font(.caption)
                .foregroundColor(OVK.Palette.textSecondary)
        }
        .padding(.vertical, 2)
    }
}
