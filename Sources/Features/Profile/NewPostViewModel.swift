import SwiftUI

@MainActor
final class NewPostViewModel: ObservableObject {
    @Published var text = ""
    @Published var images: [UIImage] = []
    @Published var isPosting = false
    @Published var errorMessage: String?

    var canPost: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty }

    func addImage(_ image: UIImage) { images.append(image) }
    func removeImage(at index: Int) { guard images.indices.contains(index) else { return }; images.remove(at: index) }

    /// Загружает вложения и публикует запись. Возвращает true при успехе.
    func publish(ownerID: Int, settings: AppSettings) async -> Bool {
        guard let token = settings.token, canPost else { return false }
        isPosting = true
        errorMessage = nil
        defer { isPosting = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            var attachments: [String] = []
            for image in images {
                if let data = image.jpegData(compressionQuality: 0.9),
                   let att = try await client.uploadWallPhoto(jpeg: data) {
                    attachments.append(att)
                }
            }
            try await client.execute(
                "wall.post",
                params: [
                    "owner_id": String(ownerID),
                    "message": text,
                    "attachments": attachments.joined(separator: ",")
                ]
            )
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
