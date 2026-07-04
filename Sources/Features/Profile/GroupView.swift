import SwiftUI

/// Страница сообщества: шапка (аватар, название, участники, описание) + стена.
struct GroupView: View {
    let community: Community
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var wall = WallViewModel()
    @StateObject private var detail = GroupDetailViewModel()

    private enum Route: Hashable { case members, audio, topics }
    @State private var route: Route?
    @State private var showAvatar = false

    private var ownerID: Int { -community.groupID }   // стена сообщества = отрицательный id
    private var info: Community { detail.details ?? community }

    var body: some View {
        List {
            card { header }
            card { categoryBar }
            if let desc = info.description, !desc.isEmpty {
                card { descriptionView(desc) }
            }

            sectionLabel("Записи")
            if wall.posts.isEmpty && !wall.isLoading {
                card {
                    Text("Записей пока нет")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .padding()
                }
            } else {
                ForEach(wall.posts) { post in
                    card {
                        PostRow(post: post, authors: wall.authors) { p in
                            Task { await wall.delete(p, settings: settings) }
                        }
                    }
                    .onAppear {
                        if post.id == wall.posts.last?.id {
                            Task { await wall.loadMore(ownerID: ownerID, settings: settings) }
                        }
                    }
                }
                if wall.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding()
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(OVK.Palette.background)
                }
            }
        }
        .listStyle(.plain)
        .background(OVK.Palette.background.ignoresSafeArea())
        .background(
            NavigationLink(
                isActive: Binding(get: { route != nil }, set: { if !$0 { route = nil } })
            ) {
                routeDestination
            } label: { EmptyView() }
            .hidden()
        )
        .navigationTitle(community.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await detail.load(community: community, settings: settings)
            await wall.loadIfNeeded(ownerID: ownerID, settings: settings)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                // Тап по аватару — просмотр в полном размере.
                Button { showAvatar = true } label: {
                    CachedImage(url: info.avatarURL) {
                        ZStack { OVK.Palette.background; Image(systemName: "person.3").font(.title).foregroundColor(OVK.Palette.textSecondary) }
                    }
                    .frame(width: 80, height: 80)
                    .clipped()
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
                .disabled(info.avatarURL == nil)

                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name)
                        .font(.title3).fontWeight(.semibold)
                        .foregroundColor(OVK.Palette.textPrimary)
                    if let count = info.membersCount {
                        Text("\(count) участников")
                            .font(.caption)
                            .foregroundColor(OVK.Palette.textSecondary)
                    }
                    if info.isAdmin {
                        Label("Вы администратор", systemImage: "star.fill")
                            .font(.caption)
                            .foregroundColor(OVK.Palette.primary)
                    }
                }
                Spacer(minLength: 0)
            }

            Button {
                Task { await detail.toggleMembership(groupID: community.groupID, settings: settings) }
            } label: {
                Text(detail.joined ? "Вы участник" : "Вступить")
                    .font(.subheadline).fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(detail.joined ? OVK.Palette.background : OVK.Palette.primary)
                    .foregroundColor(detail.joined ? OVK.Palette.textPrimary : .white)
                    .cornerRadius(6)
            }
            // ВАЖНО: без явного стиля кнопка в строке List срабатывает от тапа
            // по ВСЕЙ строке (тап по аватару отписывал от группы).
            .buttonStyle(.plain)
        }
        .padding()
        .fullScreenCover(isPresented: $showAvatar) {
            AvatarViewer(url: info.fullAvatarURL ?? info.avatarURL)
        }
    }

    private var categoryBar: some View {
        HStack(spacing: 0) {
            categoryButton("Участники", systemImage: "person.2", route: .members)
            categoryButton("Аудио", systemImage: "music.note", route: .audio)
            categoryButton("Обсуждения", systemImage: "bubble.left.and.bubble.right", route: .topics)
        }
        .padding(.vertical, 8)
    }

    private func categoryButton(_ title: String, systemImage: String, route dest: Route) -> some View {
        Button { route = dest } label: {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.title3)
                Text(title).font(.caption)
            }
            .foregroundColor(OVK.Palette.primary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var routeDestination: some View {
        switch route {
        case .members: MembersView(groupID: community.groupID)
        case .audio:   UserAudiosView(ownerID: ownerID)
        case .topics:  TopicsView(groupID: community.groupID)
        case .none:    EmptyView()
        }
    }

    private func descriptionView(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Информация")
                .font(.footnote).fontWeight(.semibold)
                .foregroundColor(OVK.Palette.textSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundColor(OVK.Palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVK.Palette.card)
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.footnote).fontWeight(.semibold)
            .foregroundColor(OVK.Palette.textSecondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
    }
}

@MainActor
final class GroupDetailViewModel: ObservableObject {
    @Published var details: Community?
    @Published var joined = false
    private var loaded = false

    private func client(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    func load(community: Community, settings: AppSettings) async {
        if !loaded { joined = community.isMember }
        guard let client = client(settings) else { return }
        do {
            // groups.getById возвращает массив клубов в response.
            let items: [Community] = try await client.call(
                "groups.getById",
                params: ["group_id": String(community.groupID), "fields": "description,members_count,photo_200,photo_100,photo_max,is_admin,is_member"]
            )
            // Берём описание/аватар/счётчики, но НЕ доверяем is_member из getById:
            // он не всегда заполнен и мог бы затереть верный статус на «Вступить».
            if let d = items.first { details = d }
        } catch {
            // Оставляем данные из списка (community).
        }
        // Авторитетно проверяем членство отдельным методом (user_id обязателен у OpenVK).
        if let uid = settings.userID {
            if let m: Int = try? await client.call(
                "groups.isMember",
                params: ["group_id": String(community.groupID), "user_id": String(uid)]
            ) {
                joined = m == 1
            }
        }
        loaded = true
    }

    /// Вступить/выйти (groups.join / groups.leave), оптимистично.
    func toggleMembership(groupID: Int, settings: AppSettings) async {
        guard let client = client(settings) else { return }
        let wasJoined = joined
        joined.toggle()
        do {
            try await client.execute(joined ? "groups.join" : "groups.leave", params: ["group_id": String(groupID)])
        } catch {
            joined = wasJoined // откат
        }
    }
}
