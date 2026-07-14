import SwiftUI
import Foundation

/// Base class for ViewModels that show paginated lists with disk cache.
/// Subclasses implement: Response type, cache key, API method, params, author merge, item extraction.
/// Handles: generation counter, isLoading/isLoadingMore, cache apply/load/save, dedup, refresh pattern.
@MainActor
class CachedListViewModel<PageResponse: Decodable, Item: Identifiable, CacheKey: Hashable>: ObservableObject {

    @Published var items: [Item] = []
    @Published var authors: [Int: WallViewModel.Author] = [:]
    @Published var isLoading = false
    @Published var isLoadingMore = false
    @Published var canLoadMore = true
    @Published var errorMessage: String?
    @Published var isLoaded = false

    private var nextCursor: String?
    private var generation = 0
    var pageSize: Int { 20 }

    init(pageSize: Int = 20) {}

    // MARK: - Subclass hooks (must override)

    /// Unique cache key for this list (e.g., feed kind, wall ownerID, chat peerID).
    var cacheKey: CacheKey { fatalError("override") }

    /// API method name (e.g., "newsfeed.get", "wall.get", "messages.getHistory").
    var method: String { fatalError("override") }

    /// Cursor parameter name (e.g., "start_from" for newsfeed, "offset" for wall).
    var cursorParamName: String { "start_from" }

    /// Parameters for API call (count, extended=1, etc.). Cursor injected by base.
    func params(cursor: String?) -> [String: String] { fatalError("override") }

    /// Merge profiles/groups from response into authors dict.
    func mergeAuthors(from response: PageResponse) { fatalError("override") }

    /// Extract items array from response.
    func items(from response: PageResponse) -> [Item] { fatalError("override") }

    /// Extract next cursor from response (nil = no more pages).
    func nextCursor(from response: PageResponse) -> String? { fatalError("override") }

    /// Cache file URL for given key.
    func cacheURL(for key: CacheKey) -> URL { fatalError("override") }

    // MARK: - Public API

    func loadIfNeeded(settings: AppSettings) async {
        guard !isLoaded else { return }
        isLoaded = true
        if items.isEmpty { applyCache() }
        await reload(settings: settings)
    }

    func reload(settings: AppSettings) async {
        generation += 1
        let gen = generation
        errorMessage = nil
        isLoading = true
        defer { if gen == generation { isLoading = false } }

        do {
            let raw = try await fetchRaw(cursor: nil, settings: settings)
            guard gen == generation else { return }
            let res: PageResponse = try OVKClient.decode(raw)
            mergeAuthors(from: res)
            items = dedup(items(from: res))
            nextCursor = nextCursor(from: res)
            canLoadMore = !(nextCursor ?? "").isEmpty && (items(from: res).count >= pageSize)
            saveCache(raw)
        } catch {
            guard gen == generation, !error.isCancellation else { return }
            if items.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    func loadMore(settings: AppSettings) async {
        guard !isLoading, !isLoadingMore, canLoadMore, !items.isEmpty else { 
            print("[CachedList] loadMore skipped: isLoading=\(isLoading), isLoadingMore=\(isLoadingMore), canLoadMore=\(canLoadMore), items.count=\(items.count)")
            return 
        }
        let gen = generation
        isLoadingMore = true
        defer { if gen == generation { isLoadingMore = false } }

        do {
            let res = try await fetchPage(cursor: nextCursor, settings: settings)
            guard gen == generation else { return }
            mergeAuthors(from: res)
            let fresh = items(from: res)
            let existing = Set(items.map(\.id))
            let newItems = fresh.filter { !existing.contains($0.id) }
            print("[CachedList] loadMore: fetched \(fresh.count) items, \(newItems.count) new, cursor before: \(nextCursor ?? "nil")")
            items += newItems
            let prev = nextCursor
            nextCursor = nextCursor(from: res)
            print("[CachedList] cursor: \(prev ?? "nil") -> \(nextCursor ?? "nil"), canLoadMore: \((nextCursor ?? "").isEmpty || nextCursor == prev || newItems.count < pageSize || newItems.isEmpty ? false : true)")
            if (nextCursor ?? "").isEmpty || nextCursor == prev || newItems.count < pageSize || newItems.isEmpty {
                canLoadMore = false
            }
        } catch {
            guard gen == generation, !error.isCancellation else { return }
            canLoadMore = false
            if items.isEmpty { errorMessage = error.localizedDescription }
        }
    }

    /// Call after subclass updates its `cacheKey` property (e.g., feed kind switch).
    func switchKey(_ newKey: CacheKey, settings: AppSettings) async {
        generation += 1
        items = []
        authors = [:]
        nextCursor = nil
        canLoadMore = true
        errorMessage = nil
        applyCache()
        await reload(settings: settings)
    }

    // MARK: - Cache

    private func applyCache() {
        guard let data = loadCache(),
              let res: PageResponse = try? OVKClient.decode(data) else { return }
        mergeAuthors(from: res)
        items = dedup(items(from: res))
        nextCursor = nextCursor(from: res)
    }

    // MARK: - Network

    private func fetchRaw(cursor: String?, settings: AppSettings) async throws -> Data {
        guard let token = settings.token else { throw OVKError.notAuthorized }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        var p = params(cursor: cursor)
        p["count"] = String(pageSize)
        p["extended"] = "1"
        if let cursor, !cursor.isEmpty { p[cursorParamName] = cursor }
        return Data(try await client.rawResponse(method, params: p).utf8)
    }

    private func fetchPage(cursor: String?, settings: AppSettings) async throws -> PageResponse {
        try OVKClient.decode(try await fetchRaw(cursor: cursor, settings: settings))
    }

    /// Save raw JSON to disk cache.
    func saveCache(_ raw: Data) {
        try? raw.write(to: cacheURL(for: cacheKey), options: .atomic)
    }

    /// Load raw JSON from disk cache.
    func loadCache() -> Data? {
        try? Data(contentsOf: cacheURL(for: cacheKey))
    }

    /// Clear all caches (on sign-out). Override to clear all cache files.
    func clearCache() {
        // Override to clear all cache files
    }

    // MARK: - Helpers

    private func dedup(_ items: [Item]) -> [Item] {
        var seen = Set<Item.ID>()
        return items.filter { seen.insert($0.id).inserted }
    }
}