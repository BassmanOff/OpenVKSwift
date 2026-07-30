import Foundation

/// Описание сервера OpenVK. Разделяем веб-домен (для /token, /authorize)
/// и API-домен (для /method/*), т.к. у официального инстанса они отличаются.
struct Instance: Codable, Identifiable, Hashable {
    let name: String
    let webURL: URL   // используется для /token и OAuth
    let apiURL: URL   // используется для /method/*
    let isInsecure: Bool

    var id: String { webURL.absoluteString }
    var registrationURL: URL { webURL.appendingPathComponent("reg") }
    /// OpenVK раздаёт direct-auth с API-домена, а VepurOVK — с веб-домена.
    /// Методный API при этом у обоих остаётся на `apiURL`.
    var tokenURL: URL {
        (apiURL == Self.vepurOVK.apiURL ? webURL : apiURL)
            .appendingPathComponent("token")
    }

    var isVepurOVK: Bool { apiURL == Self.vepurOVK.apiURL }

    /// VepurOVK's `audio.get` currently does not resolve owner_id=0 to the current user.
    var needsExplicitAudioOwner: Bool { isVepurOVK }
    var supportsTypingActivity: Bool { !isVepurOVK }

    /// Names/parameters that differ in the older VKAPI snapshot used by VepurOVK.
    func routedAPICall(method: String, params: [String: String]) -> (String, [String: String]) {
        guard isVepurOVK else { return (method, params) }
        var routedParams = params
        if method == "polls.addVote", let answerIDs = routedParams.removeValue(forKey: "answer_ids") {
            routedParams["answers_ids"] = answerIDs
        }
        return (method == "audio.getPlaylists" ? "audio.getAlbums" : method, routedParams)
    }

    /// VepurOVK returns LongPoll/upload paths on its API host, although those routes
    /// are served by the website host. Preserve the path/query and only replace host.
    func routedServiceURL(_ url: URL) -> URL {
        guard isVepurOVK,
              url.host?.lowercased() == apiURL.host?.lowercased(),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.scheme = webURL.scheme
        components.host = webURL.host
        components.port = webURL.port
        return components.url ?? url
    }

    static let openvkOrg = Instance(
        name: "OpenVK",
        webURL: URL(string: "https://openvk.org")!,
        apiURL: URL(string: "https://api.openvk.org")!,
        isInsecure: false
    )

    static let vepurOVK = Instance(
        name: "VepurOVK",
        webURL: URL(string: "https://vepurovk.xyz")!,
        apiURL: URL(string: "https://api.vepurovk.fun")!,
        isInsecure: false
    )

    static let presets: [Instance] = [.openvkOrg, .vepurOVK]

    static func matchingPreset(for saved: Instance) -> Instance? {
        presets.first { $0.apiURL == saved.apiURL }
    }

    /// Обновляет подпись сохранённого пресета; удалённый сервер заменяет на VepurOVK.
    static func loginPreset(for saved: Instance) -> Instance {
        matchingPreset(for: saved) ?? .vepurOVK
    }
}
