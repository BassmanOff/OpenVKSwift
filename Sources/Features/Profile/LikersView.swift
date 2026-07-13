import SwiftUI

/// Кто оценил запись/комментарий. Долгий тап по «сердечку» → этот лист.
/// Друзья идут первыми (серверного порядка «друзья вперёд» нет — сортируем на клиенте
/// по множеству id своих друзей). Список репостнувших OpenVK не отдаёт (нет метода
/// wall.getReposts), поэтому лист только для лайков.
struct LikersView: View {
    enum ItemType: String { case post, comment }
    let type: ItemType
    let ownerID: Int
    let itemID: Int
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var vm = LikersViewModel()
    /// СВОЙ роутер (не .handlesOVKLinks()): тот переопределяет \.openURL только для
    /// поддерева, в которое встроен, а `open(_:)` ниже читает `@Environment` СВОЕГО
    /// LikersView — она берётся из окружения РОДИТЕЛЯ (sheet наследует его от PostRow →
    /// глобальный роутер MainTabView), т.е. модификатор на дочернем Group её не подменял
    /// НИ на одной версии iOS. Профиль пушим напрямую через этот роутер.
    @StateObject private var router = LinkRouter()

    init(ownerID: Int, postID: Int) {
        self.type = .post
        self.ownerID = ownerID
        self.itemID = postID
    }

    init(commentOwnerID: Int, commentID: Int) {
        self.type = .comment
        self.ownerID = commentOwnerID
        self.itemID = commentID
    }

    var body: some View {
        NavigationView {
            Group {
                if vm.isLoading && vm.users.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.users.isEmpty {
                    Text(vm.errorMessage ?? "Пока никто не оценил")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // ScrollView, не List: List (UITableView) конфликтует со свайпом-закрытием
                    // sheet'а на iOS 15 — так же, как сделано в CommentsView.
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(vm.users) { user in
                                Button { open(user) } label: { row(user) }
                                    .buttonStyle(.plain)
                                Divider().padding(.leading, 64)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Оценили")
            .navigationBarTitleDisplayMode(.inline)
            // Профиль лайкнувшего — пуш ВНУТРИ этого листа (свой router.destination),
            // а не через \.openURL: sheet наследует openURL от точки презентации (PostRow),
            // то есть от ГЛОБАЛЬНОГО роутера MainTabView — тот пушит в активную вкладку,
            // и профиль открывался «за» открытым sheet'ом.
            .background(
                NavigationLink(
                    isActive: Binding(
                        get: { router.destination != nil },
                        set: { if !$0 { router.destination = nil } }
                    )
                ) {
                    if let dest = router.destination {
                        LinkDestinationView(destination: dest).handlesOVKLinks()
                    }
                } label: { EmptyView() }
                .hidden()
            )
        }
        .navigationViewStyle(.stack)
        .task { await vm.loadIfNeeded(type: type, ownerID: ownerID, itemID: itemID, settings: settings) }
    }

    private func row(_ user: User) -> some View {
        HStack(spacing: 12) {
            CachedImage(url: user.avatarURL) {
                ZStack { OVK.Palette.background; Image(systemName: "person.crop.circle").foregroundColor(OVK.Palette.textSecondary) }
            }
            .frame(width: 40, height: 40)
            .clipShape(Circle())

            Text(user.fullName).foregroundColor(OVK.Palette.textPrimary)
            if vm.isFriend(user.id) {
                Text("друг").font(.caption2).foregroundColor(OVK.Palette.primary)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func open(_ user: User) {
        guard let url = URL(string: "https://openvk.org/id\(user.id)") else { return }
        router.open(url)
    }
}

@MainActor
final class LikersViewModel: ObservableObject {
    @Published private(set) var users: [User] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    /// id друзей текущего пользователя — кэш на сессию (лист могут открывать много раз).
    private static var cachedFriendIDs: Set<Int>?
    private var friendIDs: Set<Int> = []
    /// Список привязан к жизни листа (пересоздаётся при каждом открытии) — грузим один раз,
    /// не на каждый повторный вызов .task (iOS 15 может дёргать его во время интерактивного
    /// закрытия sheet свайпом вниз — без гварда список видимо перезагружался, мешая закрытию).
    private var loaded = false

    func isFriend(_ id: Int) -> Bool { friendIDs.contains(id) }

    func loadIfNeeded(type: LikersView.ItemType, ownerID: Int, itemID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        loaded = true
        await load(type: type, ownerID: ownerID, itemID: itemID, settings: settings)
    }

    private func load(type: LikersView.ItemType, ownerID: Int, itemID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)

        friendIDs = await Self.friendIDs(client: client)
        do {
            let res: ItemsResponse<User> = try await client.call(
                "likes.getList",
                params: ["type": type.rawValue, "owner_id": String(ownerID), "item_id": String(itemID),
                         "extended": "1", "count": "100"]
            )
            // Друзья вперёд, порядок сервера сохраняем внутри групп (stable).
            users = res.items.enumerated()
                .sorted { a, b in
                    let fa = friendIDs.contains(a.element.id), fb = friendIDs.contains(b.element.id)
                    return fa == fb ? a.offset < b.offset : fa
                }
                .map(\.element)
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func friendIDs(client: OVKClient) async -> Set<Int> {
        if let cached = cachedFriendIDs { return cached }
        // user_id=0 → друзья текущего; берём только id.
        let res: ItemsResponse<User>? = try? await client.call(
            "friends.get", params: ["user_id": "0", "count": "1000"]
        )
        let ids = Set((res?.items ?? []).map(\.id))
        cachedFriendIDs = ids
        return ids
    }
}
