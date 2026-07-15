import SwiftUI
import UIKit

/// Шторка «Поделиться записью»: на свою стену / стену сообщества (если админ),
/// ссылкой другу или себе в ЛС, либо через системный шаринг (иконка в углу).
struct RepostSheet: View {
    let post: Post
    /// (сообщение для тоста, увеличить ли счётчик репостов на карточке).
    var onDone: (String, Bool) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @StateObject private var friendsVM = FriendsTabViewModel()
    @StateObject private var conversationsVM = ConversationsViewModel()
    @StateObject private var groupsVM = GroupsViewModel()
    @StateObject private var repostVM = RepostViewModel()
    @State private var searchText = ""
    @State private var showShareSheet = false
    @State private var showGroupPicker = false
    @State private var isBusy = false
    @State private var selectedPeerIDs: Set<Int> = []
    @State private var infoToast: String?

    private var shareURL: URL {
        URL(string: "\(settings.instance.webURL.absoluteString)/wall\(post.ownerID)_\(post.postID)") ?? settings.instance.webURL
    }

    private var recentConversations: [Conversation] {
        guard searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        // Диалог с самим собой не показываем в списке — это «Избранное» (закреплено сверху).
        return conversationsVM.conversations.filter { $0.peerID != settings.userID }.prefix(8).map { $0 }
    }

    private var filteredFriends: [User] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let base = q.isEmpty ? friendsVM.friends : friendsVM.localMatches(q)
        let recentIDs = Set(recentConversations.map(\.peerID))
        return base.filter { !recentIDs.contains($0.id) && $0.id != settings.userID }
    }

    var body: some View {
        NavigationView {
            // ScrollView + LazyVStack, а не List: шит открыт поверх ленты/стены, у которых
            // List — под .refreshable. Любой вложенный List подхватывает чужой RefreshAction
            // из environment и сам ставит pull-to-refresh, даже без своего .refreshable —
            // свайп вниз запускал refresh экрана позади вместо закрытия шита. ScrollView так
            // не делает. Заодно нет и верхнего отступа insetGrouped-стиля List.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if searchText.trimmingCharacters(in: .whitespaces).isEmpty, let uid = settings.userID {
                        favoriteRow(id: uid)
                        Divider().padding(.leading, 16)
                    }
                    ForEach(recentConversations) { conv in
                        personRow(id: conv.peerID,
                                  name: conversationsVM.authors[conv.peerID]?.name ?? "Диалог",
                                  avatar: conversationsVM.authors[conv.peerID]?.avatar)
                        Divider().padding(.leading, 16)
                    }
                    ForEach(filteredFriends) { user in
                        personRow(id: user.id, name: user.fullName, avatar: user.avatarURL)
                        Divider().padding(.leading, 16)
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск друзей")
            .navigationTitle("Поделиться записью")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showShareSheet = true } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .confirmationDialog("Выберите сообщество", isPresented: $showGroupPicker, titleVisibility: .visible) {
                ForEach(groupsVM.adminGroups) { group in
                    Button(group.name) { Task { await repost(groupID: group.groupID) } }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareActivityView(activityItems: [shareURL])
            }
            .toast($repostVM.errorMessage)
            .toast($infoToast)
            .task { await loadAll() }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
        .navigationViewStyle(.stack)
        // Половина экрана, как в Instagram. presentationDetents — iOS 16+, а таргет проекта
        // 15.0, поэтому цепляемся к UISheetPresentationController напрямую (доступен с iOS 15).
        .background(HalfSheetConfigurator())
    }

    /// Строка получателя (друг/недавний диалог) — тап переключает выбор, отправка идёт
    /// одной кнопкой «Отправить» по всем отмеченным сразу (как в оригинальном VK-клиенте).
    private func personRow(id: Int, name: String, avatar: URL?) -> some View {
        selectableRow(id: id, name: name) {
            CachedImage(url: avatar) {
                ZStack { OVK.Palette.background; Image(systemName: "person.crop.square").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(width: 36, height: 36)
            .clipped()
            .cornerRadius(4)
        }
    }

    private func favoriteRow(id: Int) -> some View {
        selectableRow(id: id, name: "Избранное") {
            ZStack {
                Circle().fill(OVK.Palette.link)
                Image(systemName: "bookmark.fill").foregroundColor(.white).font(.system(size: 14))
            }
            .frame(width: 36, height: 36)
        }
    }

    private func selectableRow<Avatar: View>(id: Int, name: String, @ViewBuilder avatar: () -> Avatar) -> some View {
        let isSelected = selectedPeerIDs.contains(id)
        return Button {
            if isSelected { selectedPeerIDs.remove(id) } else { selectedPeerIDs.insert(id) }
        } label: {
            HStack(spacing: 10) {
                avatar()
                Text(name)
                    .font(.subheadline)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .lineLimit(1)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? OVK.Palette.link : OVK.Palette.separator)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Нижняя панель, приклеена к низу шита: кнопка «Отправить» (если что-то отмечено),
    /// ниже — ряд овальных кнопок действий (репост на стену, копирование ссылки).
    /// Овалы — чтобы экономить высоту (как в оригинальном VK-клиенте).
    private var bottomBar: some View {
        VStack(spacing: 8) {
            Divider()
            if !selectedPeerIDs.isEmpty {
                Button {
                    Task { await sendToSelected() }
                } label: {
                    Text("Отправить (\(selectedPeerIDs.count))")
                        .font(.subheadline).fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(OVK.Palette.link)
                        .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    pill(icon: "arrowshape.turn.up.right", label: "На своей странице") {
                        Task { await repost(groupID: nil) }
                    }
                    if !groupsVM.adminGroups.isEmpty {
                        pill(icon: "person.3", label: "На стене сообщества") {
                            if groupsVM.adminGroups.count == 1 {
                                Task { await repost(groupID: groupsVM.adminGroups[0].groupID) }
                            } else {
                                showGroupPicker = true
                            }
                        }
                    }
                    pill(icon: "link", label: "Скопировать ссылку") { copyLink() }
                }
                .padding(.horizontal)
            }
            .padding(.bottom, 6)
        }
        .background(OVK.Palette.background)
    }

    private func pill(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15))
                Text(label).font(.caption).lineLimit(1)
            }
            .foregroundColor(OVK.Palette.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(OVK.Palette.separator.opacity(0.3))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func copyLink() {
        UIPasteboard.general.string = shareURL.absoluteString
        infoToast = "Ссылка скопирована"
    }

    /// Друзья/диалоги/группы раньше грузились последовательно (друзья → диалоги → группы),
    /// а groups.get внутри сам шёл в 2 запроса — «На стене сообщества» появлялась с задержкой
    /// в сумму всех round-trip'ов. Грузим параллельно.
    private func loadAll() async {
        async let friendsTask: Void = friendsVM.load(settings: settings)
        async let conversationsTask: Void = conversationsVM.load(settings: settings)
        async let groupsTask: Void = loadGroupsIfPossible()
        _ = await (friendsTask, conversationsTask, groupsTask)
    }

    private func loadGroupsIfPossible() async {
        guard let uid = settings.userID else { return }
        await groupsVM.loadIfNeeded(userID: uid, settings: settings)
    }

    private func repost(groupID: Int?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        guard await repostVM.repostToWall(post: post, groupID: groupID, settings: settings) else { return }
        onDone(groupID == nil ? "Опубликовано на своей стене" : "Опубликовано на стене сообщества", true)
        dismiss()
    }

    private func sendToSelected() async {
        guard !isBusy, !selectedPeerIDs.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }
        var sent = 0
        for peerID in selectedPeerIDs {
            if await repostVM.sendLink(post: post, peerID: peerID, settings: settings) { sent += 1 }
        }
        guard sent > 0 else { return }
        onDone("Отправлено: \(sent)", false)
        dismiss()
    }
}

/// Обёртка над системным шарингом (UIActivityViewController) — своей SwiftUI-обёртки
/// в проекте ещё не было (только сырой UIKit-вызов в PhotoHero).
private struct ShareActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Невидимый мостик к UISheetPresentationController: открывает шит на ~3/4 экрана (как VK)
/// и включает ручку сверху. Свайп вниз просто закрывает — pull-to-refresh в шите нет
/// (List без .refreshable). Кастомная доля высоты — iOS 16+; на iOS 15 фолбэк на .large().
private struct HalfSheetConfigurator: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let sheet = uiViewController.parent?.sheetPresentationController else { return }
            if #available(iOS 16.0, *) {
                sheet.detents = [.custom(identifier: .init("threeQuarters")) { ctx in
                    0.75 * ctx.maximumDetentValue
                }]
            } else {
                sheet.detents = [.large()]
            }
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
    }
}
