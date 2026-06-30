import SwiftUI

@MainActor
final class VideosViewModel: ObservableObject {
    @Published private(set) var videos: [Video] = []
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
            let res: ItemsResponse<Video> = try await client.call(
                "video.get",
                params: ["owner_id": String(ownerID), "count": "100"]
            )
            videos = res.items
            loaded = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct VideosView: View {
    let ownerID: Int
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = VideosViewModel()

    var body: some View {
        Group {
            if model.isLoading && model.videos.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage, model.videos.isEmpty {
                ErrorRetry(message: error) { Task { await model.load(ownerID: ownerID, settings: settings) } }
            } else if model.videos.isEmpty {
                Text("Нет видеозаписей")
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.videos) { video in
                    HStack(spacing: 12) {
                        ZStack(alignment: .bottomTrailing) {
                            CachedImage(url: video.thumbURL) {
                                ZStack { OVK.Palette.background; Image(systemName: "play.rectangle").foregroundColor(OVK.Palette.textSecondary) }
                            }
                            .frame(width: 100, height: 60)
                            .clipped()
                            .cornerRadius(4)

                            Text(video.durationText)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.black.opacity(0.7))
                                .foregroundColor(.white)
                                .cornerRadius(3)
                                .padding(4)
                        }
                        Text(video.title)
                            .foregroundColor(OVK.Palette.textPrimary)
                            .lineLimit(3)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
                .refreshable { await model.load(ownerID: ownerID, settings: settings) }
            }
        }
        .background(OVK.Palette.background.ignoresSafeArea())
        .navigationTitle("Видеозаписи")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.loadIfNeeded(ownerID: ownerID, settings: settings) }
    }
}
