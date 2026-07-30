import SwiftUI

@MainActor
final class PhotosViewModel: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    private var loaded = false

    func loadIfNeeded(ownerID: Int, settings: AppSettings) async {
        guard !loaded else { return }
        await load(ownerID: ownerID, settings: settings)
    }

    func load(ownerID: Int, settings: AppSettings) async {
        guard let token = settings.token else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: ItemsResponse<Photo> = try await client.call(
                "photos.getAll",
                params: ["owner_id": String(ownerID), "photo_sizes": "1", "count": "200"]
            )
            photos = res.items
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Лёгкая выборка для шапки профиля: сначала пять фото для первого кадра, затем
/// ещё пятнадцать. Полная библиотека остаётся ответственностью PhotosView.
@MainActor
final class ProfilePhotosPreviewModel: ObservableObject {
    @Published private(set) var photos: [Photo] = []
    @Published private(set) var totalCount = 0
    private var loadedOwnerID: Int?

    func loadIfNeeded(ownerID: Int, settings: AppSettings) async {
        guard loadedOwnerID != ownerID, let token = settings.token else { return }
        loadedOwnerID = ownerID
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let first: ItemsResponse<Photo> = try await client.call(
                "photos.getAll", params: ["owner_id": String(ownerID), "photo_sizes": "1", "count": "5"]
            )
            totalCount = first.count
            photos = first.items
            guard first.count > first.items.count else { return }
            let rest: ItemsResponse<Photo> = try await client.call(
                "photos.getAll", params: ["owner_id": String(ownerID), "photo_sizes": "1", "offset": "5", "count": "15"]
            )
            let existing = Set(photos.map(\.id))
            photos += rest.items.filter { !existing.contains($0.id) }
        } catch {
            // Фотоблок вторичен: профиль остаётся полезным, даже если он недоступен.
        }
    }
}

struct PhotosView: View {
    let ownerID: Int
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var photoHero: PhotoHeroCoordinator
    @StateObject private var model = PhotosViewModel()

    private let columns = [
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
        GridItem(.flexible(), spacing: 2),
    ]

    var body: some View {
        Group {
            if model.isLoading && model.photos.isEmpty {
                OVKListStateView(message: "Загрузка фотографий…", isLoading: true)
            } else if let error = model.errorMessage, model.photos.isEmpty {
                ErrorRetry(message: error) { Task { await model.load(ownerID: ownerID, settings: settings) } }
            } else if model.photos.isEmpty {
                OVKListStateView(message: "Нет фотографий")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(model.photos.enumerated()), id: \.element.id) { i, photo in
                            // Гарантированно квадратная ячейка 1:1. Картинке хит не нужен:
                            // .clipped() не режет хит-тест, и «хвост» .fill крал бы тапы соседей.
                            Color.clear
                                .aspectRatio(1, contentMode: .fit)
                                .overlay(
                                    CachedImage(url: photo.thumbURL) { OVK.Palette.background }
                                        .allowsHitTesting(false)
                                )
                                .clipped()
                                .photoHeroSource(photos: model.photos, index: i, post: nil, coordinator: photoHero)
                        }
                    }
                }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Фотографии")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(ownerID: ownerID, settings: settings) }
    }
}
