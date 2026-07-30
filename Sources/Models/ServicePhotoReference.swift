import Foundation

/// Фото сервисного аккаунта, которое нужно удалить вместе с отправленным сообщением.
struct ServicePhotoReference: Codable, Equatable {
    let ownerID: Int
    let photoID: Int

    init?(ownerID: Int, photoID: Int) {
        guard ownerID > 0, photoID > 0 else { return nil }
        self.ownerID = ownerID
        self.photoID = photoID
    }

    static func storageKey(userID: Int, messageID: Int) -> String {
        "service_pm_photo_\(userID)_\(messageID)"
    }
}
