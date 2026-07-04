import SwiftUI

/// Перехват ссылок OpenVK: внутренние открываются в приложении (своим sheet на КАЖДОМ уровне,
/// поэтому работает и внутри уже открытых по ссылке экранов), остальные — системно.
private struct OVKLinkHandler: ViewModifier {
    @StateObject private var router = LinkRouter()
    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { router.open($0) ? .handled : .systemAction })
            .sheet(item: $router.destination) { destination in
                LinkDestinationView(destination: destination)
            }
    }
}

extension View {
    /// Включает открытие ссылок OpenVK внутри приложения для этого поддерева.
    func handlesOVKLinks() -> some View { modifier(OVKLinkHandler()) }
}

/// Экран, открываемый по внутренней ссылке (плейлист / профиль / сообщество / тема).
struct LinkDestinationView: View {
    let destination: LinkDestination
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            content
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Закрыть") { dismiss() }
                    }
                }
        }
        .navigationViewStyle(.stack)
        .handlesOVKLinks() // ссылки внутри этого экрана тоже открываются в приложении
    }

    @ViewBuilder
    private var content: some View {
        switch destination {
        case .profile(let userID):
            ProfileView(userID: userID)
        case .community(let groupID):
            CommunityLinkLoader(groupID: groupID)
        case .playlist(let ownerID, let id):
            PlaylistLinkLoader(ownerID: ownerID, id: id)
        case .topic(let groupID, let virtualID):
            // Из ссылки virtual_id известен точно — передаём его как guess без резолва.
            TopicView(groupID: groupID, topicDBID: nil, virtualIDGuess: virtualID, title: "Обсуждение")
        case .screenName(let name):
            ScreenNameLinkLoader(name: name)
        }
    }
}

/// Резолвит короткий адрес (utils.resolveScreenName) в профиль или сообщество.
private struct ScreenNameLinkLoader: View {
    let name: String
    @EnvironmentObject private var settings: AppSettings
    @State private var resolvedUserID: Int?
    @State private var resolvedGroupID: Int?
    @State private var failed = false

    private struct Resolved: Decodable {
        let objectID: Int?
        let type: String?
        enum CodingKeys: String, CodingKey {
            case objectID = "object_id"
            case type
        }
    }

    var body: some View {
        Group {
            if let uid = resolvedUserID {
                ProfileView(userID: uid)
            } else if let gid = resolvedGroupID {
                CommunityLinkLoader(groupID: gid)
            } else if failed {
                VStack(spacing: 12) {
                    Text("Не удалось открыть «\(name)»")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Открыть в браузере") {
                        // Напрямую через UIApplication — openURL из окружения зациклил бы
                        // ссылку обратно в наш перехватчик.
                        UIApplication.shared.open(
                            settings.instance.webURL.appendingPathComponent(name)
                        )
                    }
                }
                .padding()
            } else {
                ProgressView()
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard let token = settings.token else { failed = true; return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let r: Resolved = try await client.call(
                "utils.resolveScreenName",
                params: ["screen_name": name]
            )
            switch (r.type, r.objectID) {
            case ("user", .some(let id)):  resolvedUserID = id
            case ("group", .some(let id)): resolvedGroupID = id
            default:                       failed = true
            }
        } catch {
            failed = true
        }
    }
}

/// Загружает сообщество по id (groups.getById) и открывает его страницу.
private struct CommunityLinkLoader: View {
    let groupID: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var community: Community?
    @State private var failed = false

    var body: some View {
        Group {
            if let community {
                GroupView(community: community)
            } else if failed {
                Text("Сообщество не найдено").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let token = settings.token else { failed = true; return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let items: [Community] = try await client.call(
                "groups.getById",
                params: ["group_id": String(groupID), "fields": "description,members_count,photo_200,photo_100,is_admin,is_member"]
            )
            if let first = items.first { community = first } else { failed = true }
        } catch {
            failed = true
        }
    }
}

/// Загружает плейлист по owner_id+id (audio.getPlaylistById) и открывает его.
private struct PlaylistLinkLoader: View {
    let ownerID: Int
    let id: Int
    @EnvironmentObject private var settings: AppSettings
    @State private var album: Album?
    @State private var failed = false

    var body: some View {
        Group {
            if let album {
                AlbumDetailView(album: album)
            } else if failed {
                Text("Плейлист не найден").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let token = settings.token else { failed = true; return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let result: Album = try await client.call(
                "audio.getPlaylistById",
                params: ["owner_id": String(ownerID), "playlist_id": String(id)]
            )
            album = result
        } catch {
            failed = true
        }
    }
}
