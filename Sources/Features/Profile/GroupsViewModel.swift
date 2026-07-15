import SwiftUI

@MainActor
final class GroupsViewModel: ObservableObject {
    @Published private(set) var allGroups: [Community] = []       // все мои сообщества
    @Published private(set) var adminGroups: [Community] = []     // где я админ
    @Published private(set) var searchResults: [Community] = []   // глобальный поиск
    @Published private(set) var isLoading = false
    @Published private(set) var isSearching = false
    @Published var errorMessage: String?

    private var loaded = false
    private static let fields = "is_admin,is_member,photo_50,photo_100,photo_200"

    private func makeClient(_ settings: AppSettings) -> OVKClient? {
        guard let token = settings.token else { return nil }
        return OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
    }

    func loadIfNeeded(userID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await load(userID: userID, settings: settings)
    }

    func load(userID: Int, settings: AppSettings) async {
        guard let client = makeClient(settings) else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        // Оба запроса независимы (разные фильтры одного user_id) — грузим параллельно,
        // а не один за другим, иначе к результату добавляется round-trip второго запроса.
        async let allTask: Result<ItemsResponse<Community>, Error> = {
            do {
                let all: ItemsResponse<Community> = try await client.call(
                    "groups.get",
                    params: ["user_id": String(userID), "extended": "1", "fields": Self.fields, "count": "1000"]
                )
                return .success(all)
            } catch {
                return .failure(error)
            }
        }()
        // Управляемые: filter=admin доступен только для своего профиля — у чужого просто пусто.
        async let adminTask: Result<ItemsResponse<Community>, Error> = {
            do {
                let admin: ItemsResponse<Community> = try await client.call(
                    "groups.get",
                    params: ["user_id": String(userID), "filter": "admin", "extended": "1", "fields": Self.fields, "count": "1000"]
                )
                return .success(admin)
            } catch {
                return .failure(error)
            }
        }()

        switch await allTask {
        case .success(let all): allGroups = all.items
        case .failure(let error):
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
        switch await adminTask {
        case .success(let admin): adminGroups = admin.items
        case .failure: adminGroups = []
        }
        loaded = true
    }

    /// Локальные совпадения среди моих сообществ (для «сначала свои»).
    func localMatches(_ query: String) -> [Community] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return allGroups.filter { $0.name.lowercased().contains(q) }
    }

    /// Глобальный поиск (groups.search), исключая уже найденные локально.
    func searchGlobal(_ query: String, settings: AppSettings) async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, let client = makeClient(settings) else {
            searchResults = []
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            let res: ItemsResponse<Community> = try await client.call(
                "groups.search",
                params: ["q": q, "count": "50"]
            )
            let localIDs = Set(localMatches(q).map { $0.id })
            searchResults = res.items.filter { !localIDs.contains($0.id) }
        } catch {
            searchResults = []
        }
    }
}
