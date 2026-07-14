import SwiftUI

/// Экран «Ответы»: заявки в друзья + лента уведомлений (лайки/комменты/упоминания/…).
struct ActivityView: View {
    @ObservedObject var model: ActivityViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    /// Открытые комментарии к записи-цели уведомления.
    @State private var commentsTarget: PostRef?

    private struct PostRef: Identifiable {
        let ownerID: Int
        let postID: Int
        let fallbackIDs: [Int]
        var id: String { "\(ownerID)_\(postID)" }
        init(ownerID: Int, postID: Int, fallbackIDs: [Int] = []) {
            self.ownerID = ownerID
            self.postID = postID
            self.fallbackIDs = fallbackIDs
        }
    }

    var body: some View {
        content
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle("Ответы")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $commentsTarget) { ref in
                CommentsView(ownerID: ref.ownerID, postID: ref.postID, fallbackIDs: ref.fallbackIDs)
            }
            .task {
                await model.reload(settings: settings) // открыли — всегда свежий список
                await model.markViewed(settings: settings) // и гасим бейдж
            }
            .onAppear { model.isBellVisible = true } // видимое не баннерим
            .onDisappear {
                model.isBellVisible = false
                // Гасим и то, что пришло, ПОКА экран был открыт (иначе бейдж горит
                // на уже увиденное). markViewed идемпотентен и дёшев.
                Task { await model.markViewed(settings: settings) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.notifications.isEmpty && model.friendRequests.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.notifications.isEmpty && model.friendRequests.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "bell.slash").font(.system(size: 40)).foregroundColor(OVK.Palette.textSecondary)
                Text(model.errorMessage ?? "Пока нет уведомлений").foregroundColor(OVK.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.friendRequests.isEmpty {
                    Section("Заявки в друзья") {
                        ForEach(model.friendRequests) { user in
                            requestRow(user)
                        }
                    }
                }
                if !model.notifications.isEmpty {
                    Section("Уведомления") {
                        ForEach(model.notifications) { notif in
                            notificationRow(notif)
                                .onAppear {
                                    if notif.id == model.notifications.last?.id {
                                        Task { await model.loadMore(settings: settings) }
                                    }
                                }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await model.reload(settings: settings) }
        }
    }

    // MARK: Заявка в друзья

    private func requestRow(_ user: User) -> some View {
        HStack(spacing: 10) {
            Button { goProfile(user.id) } label: {
                CachedImage(url: user.avatarURL) {
                    ZStack { OVK.Palette.background; Image(systemName: "person.crop.circle").foregroundColor(OVK.Palette.textSecondary) }
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(user.fullName).font(.subheadline).fontWeight(.medium).lineLimit(1)
            Spacer()
            Button("Принять") { Task { await model.accept(user, settings: settings) } }
                .font(.caption).buttonStyle(.borderedProminent).tint(OVK.Palette.primary)
            Button { Task { await model.decline(user, settings: settings) } } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.bordered).tint(.gray)
        }
        .padding(.vertical, 2)
    }

    // MARK: Уведомление

    private func notificationRow(_ notif: ActivityNotification) -> some View {
        let author = notif.actorID.flatMap { model.authors[$0] }
        return HStack(alignment: .top, spacing: 10) {
            // Аватар: всегда → профиль автора действия (НЕ туда же, куда тело).
            Button {
                if let actor = notif.actorID {
                    #if DEBUG
                    print("[Notifications] avatar tap: open profile(\(actor)) type=\(notif.type ?? "nil")")
                    #endif
                    goProfile(actor)
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    CachedImage(url: author?.avatar) {
                        ZStack { OVK.Palette.background; Image(systemName: "person.crop.circle").foregroundColor(OVK.Palette.textSecondary) }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(Circle())
                    Image(systemName: notif.icon)
                        .font(.system(size: 10))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Circle().fill(iconColor(notif)))
                        .overlay(Circle().stroke(OVK.Palette.card, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            }
            .buttonStyle(.plain)

            // Тело: открывает целевой объект (запись/профиль), в зависимости от типа.
            Button { navigateBody(notif) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if let name = author?.name {
                            Text(name).fontWeight(.semibold) + Text(" \(notif.phrase)")
                        } else {
                            // Репост/назначение — сервер не отдаёт «кто», показываем без имени.
                            Text(notif.standalonePhrase)
                        }
                    }
                    .font(.subheadline)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    if let snippet = notif.snippet {
                        Text(snippet)
                            .font(.footnote)
                            .foregroundColor(OVK.Palette.textSecondary)
                            .lineLimit(2)
                    }
                    Text(Self.relativeTime(notif.date))
                        .font(.caption2)
                        .foregroundColor(OVK.Palette.textSecondary)
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private func iconColor(_ notif: ActivityNotification) -> Color {
        switch notif.type {
        case "like_post": return .red
        case "copy_post", "wall_publish": return .green
        case let t? where t.hasPrefix("mention"): return .orange
        default: return OVK.Palette.primary
        }
    }

    // MARK: Навигация

    /// Тело уведомления → целевой объект (пост, стена, профиль) через Resolver.
    private func navigateBody(_ notif: ActivityNotification) {
        #if DEBUG
        print("[Notifications] tap: \(notif.debugFields)")
        #endif
        switch NotificationNavigationResolver.resolve(notif, currentUserID: settings.userID) {
        case .wallPost(let ownerID, let postID):
            #if DEBUG
            print("[Notifications] destination: CommentsView(\(ownerID)_\(postID))")
            #endif
            // Собираем запасные ID из уведомления (на случай если parent.id — не post_id)
            var fallbacks: [Int] = []
            if let fid = notif.feedback?.id, fid != postID { fallbacks.append(fid) }
            if let pid = notif.parent?.id, pid != postID { fallbacks.append(pid) }
            // Можно добавить toID/ownerID если они похожи на post_id
            commentsTarget = PostRef(ownerID: ownerID, postID: postID, fallbackIDs: fallbacks)
        case .commentLike(let commentID, let commentAuthorID):
            #if DEBUG
            print("[Notifications] destination: COMMENT LIKE — resolving via wall.getComment(\(commentID))")
            #endif
            resolveCommentLikeAndNavigate(commentID: commentID, commentAuthorID: commentAuthorID, notif: notif)
        case .profile(let userID):
            #if DEBUG
            print("[Notifications] destination: profile(\(userID))")
            #endif
            goProfile(userID)
        case .unsupported:
            #if DEBUG
            print("[Notifications] destination: unsupported (ничего не делаем)")
            #endif
            break
        }
    }

    /// Резолвит лайк на комментарии через wall.getComment → получает post_id + owner_id → открывает CommentsView.
    private func resolveCommentLikeAndNavigate(commentID: Int, commentAuthorID: Int, notif: ActivityNotification) {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        Task {
            do {
                // wall.getComment требует owner_id (владелец стены) и comment_id.
                // В OpenVK комментарий ищется по глобальному ID, owner_id нужен для проверки прав.
                // Передаём автора комментария как owner_id (если коммент на его стене — сработает).
                // Если не сработает — попробуем текущего пользователя.
                struct CommentResponse: Decodable {
                    let items: [CommentItem]
                    struct CommentItem: Decodable {
                        let postID: Int
                        let ownerID: Int
                        enum CodingKeys: String, CodingKey {
                            case postID = "post_id"
                            case ownerID = "owner_id"
                        }
                    }
                }
                
                // Пробуем с authorID коммента
                var resp: CommentResponse? = try? await client.call(
                    "wall.getComment",
                    params: ["owner_id": String(commentAuthorID), "comment_id": String(commentID), "extended": "0"]
                )
                
                // Если не вышло — пробуем с текущим пользователем
                if resp == nil || resp?.items.isEmpty == true {
                    if let currentUserID = settings.userID {
                        resp = try? await client.call(
                            "wall.getComment",
                            params: ["owner_id": String(currentUserID), "comment_id": String(commentID), "extended": "0"]
                        )
                    }
                }
                
                if let item = resp?.items.first {
                    let postID = item.postID
                    let ownerID = item.ownerID
                    #if DEBUG
                    print("[Notifications] wall.getComment: postID=\(postID) ownerID=\(ownerID)")
                    #endif
                    await MainActor.run {
                        var fallbacks: [Int] = []
                        if let fid = notif.feedback?.id, fid != postID { fallbacks.append(fid) }
                        if let pid = notif.parent?.id, pid != postID { fallbacks.append(pid) }
                        commentsTarget = PostRef(ownerID: ownerID, postID: postID, fallbackIDs: fallbacks)
                    }
                } else {
                    #if DEBUG
                    print("[Notifications] wall.getComment: empty items")
                    #endif
                }
            }
        }
    }

    /// Аватар → профиль автора (сквозь handlesOVKLinks).
    private func goProfile(_ id: Int) {
        guard let url = URL(string: "https://openvk.org/\(id > 0 ? "id\(id)" : "club\(-id)")") else { return }
        openURL(url)
    }

    // RelativeDateTimeFormatter дорог — держим статически (вызывается в каждой строке).
    private static let relFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()

    private static func relativeTime(_ ts: Int) -> String {
        relFormatter.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ts)), relativeTo: Date())
    }
}
