import SwiftUI

/// Экран «Ответы»: заявки в друзья + лента уведомлений (лайки/комменты/упоминания/…).
struct ActivityView: View {
    @ObservedObject var model: ActivityViewModel
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.openURL) private var openURL
    /// Открытые комментарии к записи-цели уведомления.
    @State private var commentsTarget: PostRef?

    private struct PostRef: Identifiable { let ownerID: Int; let postID: Int; var id: String { "\(ownerID)_\(postID)" } }

    var body: some View {
        content
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle("Ответы")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(item: $commentsTarget) { ref in
                CommentsView(ownerID: ref.ownerID, postID: ref.postID)
            }
            .task {
                await model.loadIfNeeded(settings: settings)
                await model.markViewed(settings: settings) // открыли — гасим бейдж
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
                            Button { open(notif) } label: { notificationRow(notif) }
                                .buttonStyle(.plain)
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
            Button { openProfile(user.id) } label: {
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
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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

    private func open(_ notif: ActivityNotification) {
        // Ссылку /wall… перехватчик не ловит (уходит в Safari) — открываем комментарии
        // к записи прямо в приложении. Для остального (нет записи) — профиль автора.
        if let owner = notif.targetOwnerID, let post = notif.targetPostID, post != 0 {
            commentsTarget = PostRef(ownerID: owner, postID: post)
        } else if let actor = notif.actorID {
            openProfile(actor)
        }
    }

    private func openProfile(_ id: Int) {
        // id…/club… перехватчик handlesOVKLinks открывает в приложении.
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
