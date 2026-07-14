import SwiftUI

/// Закреплённые диалоги — обычные строки того же `List` (просто первые), скроллятся со всеми.
///
/// Перестановка — НАТИВНЫЙ edit mode (вариант «А», после двух тупиков):
/// кастомные drag-жесты дрались с contextMenu за long-press, а UIKit drag-сессия
/// (.onDrag/.onDrop) в List на iOS 15 сломана в обе стороны (drop глотается ячейками,
/// lift поднимает всю ячейку). Пункт меню «Изменить порядок» включает edit mode:
/// у закреплённых появляются хендлы (.onMove), «Готово» в тулбаре выключает.
///
/// Меню — обычный SwiftUI .contextMenu, тот же стиль, что у всех диалогов
/// (строки снова отдельные ячейки, конфликт «меню на всю ячейку» не при чём).
struct PinnedConversationsSection: View {
    @ObservedObject var model: ConversationsViewModel
    let onOpen: (Int) -> Void
    /// «Изменить порядок» в меню — родитель (ConversationsView) включает edit mode списка.
    let onStartReorder: () -> Void

    var body: some View {
        ForEach(model.pinnedConversations) { convo in
            Button {
                onOpen(convo.peerID)
            } label: {
                ConversationRow(
                    convo: convo,
                    author: model.authors[convo.peerID],
                    isUnread: model.hasUnread(convo),
                    unreadCount: model.localUnread[convo.peerID] ?? 0,
                    showsPinIcon: true
                )
            }
            .buttonStyle(.plain)
            .contextMenu {
                Button {
                    model.togglePin(convo.peerID)
                } label: {
                    Label("Открепить", systemImage: "pin.slash")
                }
                Button {
                    model.toggleArchive(convo.peerID)
                } label: {
                    Label("В архив", systemImage: "archivebox")
                }
                // Переставлять есть смысл только когда закреплённых больше одного.
                if model.pinnedConversations.count > 1 {
                    Button {
                        onStartReorder()
                    } label: {
                        Label("Изменить порядок", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
        }
        .onMove { from, to in
            model.movePinned(fromOffsets: from, toOffset: to)
        }
    }
}
