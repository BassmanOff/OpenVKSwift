import Foundation

enum ProfileIdentity {
    static func isOwn(requestedUserID: Int?, currentUserID: Int?) -> Bool {
        requestedUserID == nil || requestedUserID == currentUserID
    }

    static func url(webURL: URL, userID: Int) -> URL {
        webURL.appendingPathComponent("id\(userID)")
    }
}
