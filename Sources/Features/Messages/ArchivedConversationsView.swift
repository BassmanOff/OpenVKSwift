import SwiftUI

/// Архив диалогов — «отложенные» (архивация чисто локальная, см. ConversationsViewModel).
struct ArchivedConversationsView: View {
    @ObservedObject var model: ConversationsViewModel
    /// Открытый диалог (программная навигация — тот же приём, что в ConversationsView).
    @State private var openPeerID: Int?

    var body: some View {
        Group {
            if model.archivedConversations.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "archivebox")
                        .font(.system(size: 40))
                        .foregroundColor(OVK.Palette.textSecondary)
                    Text("Архив пуст")
                        .foregroundColor(OVK.Palette.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.archivedConversations) { convo in
                        Button {
                            openChat(peer: convo.peerID)
                        } label: {
                            ConversationRow(
                                convo: convo,
                                author: model.authors[convo.peerID],
                                isUnread: model.hasUnread(convo),
                                unreadCount: model.localUnread[convo.peerID] ?? 0
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                model.toggleArchive(convo.peerID)
                            } label: {
                                Label("Из архива", systemImage: "tray.and.arrow.up")
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Архив")
        .navigationBarTitleDisplayMode(.inline)
        .background(
            NavigationLink(
                isActive: Binding(
                    get: { openPeerID != nil },
                    set: { active in
                        if !active, let peer = openPeerID {
                            model.markSeen(peer: peer)
                            model.activePeerID = nil
                            openPeerID = nil
                        }
                    }
                )
            ) {
                if let peerID = openPeerID {
                    ChatView(peerID: peerID,
                             title: model.authors[peerID]?.name ?? "Диалог",
                             avatarURL: model.authors[peerID]?.avatar)
                }
            } label: { EmptyView() }
            .hidden()
        )
    }

    private func openChat(peer: Int) {
        model.markSeen(peer: peer)
        model.activePeerID = peer
        openPeerID = peer
    }
}
