import SwiftUI
import UniformTypeIdentifiers

struct VKPlayerQueuePage: View {
    @EnvironmentObject private var player: AudioPlayer
    @State private var dragging: Audio?
    @State private var showUnavailableAlert = false

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Далее")
                    .font(.title2.weight(.bold))
                // Источник очереди (альбом / «Моя музыка» / «Поиск») — синий подзаголовок.
                if let source = player.queueSource {
                    Text(source)
                        .font(.subheadline)
                        .foregroundColor(OVK.Palette.primary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 10)
            if player.queue.isEmpty {
                Text("Очередь пуста")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(player.queue) { track in
                            VKPlayerQueueRow(track: track, isCurrent: track.id == player.current?.id)
                                .id(track.id)
                                // Ряды прозрачны, чтобы работало матовое стекло плеера
                                // (иначе страница очереди — глухой белый лист поверх блюра).
                                .listRowBackground(ClearListBackground())
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let index = player.queue.firstIndex(where: { $0.id == track.id }) {
                                        player.play(at: index)
                                    }
                                }
                                .onDrag {
                                    dragging = track
                                    return NSItemProvider(object: track.id as NSString)
                                }
                                .onDrop(of: [.text], delegate: VKPlayerQueueDropDelegate(item: track, dragging: $dragging, player: player))
                        }
                        .onDelete { player.removeFromQueue(at: $0) }
                    }
                    .listStyle(.plain)
                    .onAppear { scrollToCurrent(proxy, animated: false) }
                    .onChange(of: player.current?.id) { _ in scrollToCurrent(proxy, animated: true) }
                }
            }
        }
        .onReceive(player.$unavailableTrack) { track in
            showUnavailableAlert = track != nil
        }
        .unavailableAudioAlert(isPresented: $showUnavailableAlert) {
            player.clearUnavailableTrack()
        }
    }

    private func scrollToCurrent(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = player.current?.id else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (animated ? 0 : 0.1)) {
            if animated { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            else { proxy.scrollTo(id, anchor: .center) }
        }
    }
}

private struct VKPlayerQueueRow: View {
    let track: Audio
    let isCurrent: Bool
    @EnvironmentObject private var player: AudioPlayer

    private var available: Bool { player.isAvailable(track) }

    var body: some View {
        HStack(spacing: 12) {
            CachedImage(url: track.coverURL) {
                ZStack {
                    OVK.Palette.background
                    Image(systemName: available ? "music.note" : "nosign")
                        .foregroundColor(OVK.Palette.textSecondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipped()
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .foregroundColor(available ? (isCurrent ? OVK.Palette.primary : OVK.Palette.textPrimary) : OVK.Palette.textSecondary)
                    .lineLimit(1)
                Text(available ? track.artist : "Недоступно")
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            // Референс: только рукоятка перестановки справа, БЕЗ длительности.
            Image(systemName: "line.3.horizontal")
                .foregroundColor(OVK.Palette.textSecondary.opacity(0.7))
        }
        .padding(.vertical, 4)
        .opacity(available ? 1 : 0.58)
    }
}

/// Прозрачный фон ряда, который заодно гасит фон САМОГО списка: на iOS 15 List (UITableView),
/// на iOS 16+ (UICollectionView) красят непрозрачный systemBackground — сквозь него не видно
/// матовое стекло плеера. Глобальный UITableView.appearance() не трогаем — задело бы все списки.
private struct ClearListBackground: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        DispatchQueue.main.async {
            var ancestor = view.superview
            while let current = ancestor, !(current is UIScrollView) {
                ancestor = current.superview
            }
            ancestor?.backgroundColor = .clear
        }
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct VKPlayerQueueDropDelegate: DropDelegate {
    let item: Audio
    @Binding var dragging: Audio?
    let player: AudioPlayer

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != item.id else { return }
        let queue = player.queue
        guard let from = queue.firstIndex(where: { $0.id == dragging.id }),
              let to = queue.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation {
            player.moveInQueue(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
