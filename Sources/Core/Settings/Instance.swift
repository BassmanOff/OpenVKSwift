import Foundation

/// Описание сервера OpenVK. Разделяем веб-домен (для /token, /authorize)
/// и API-домен (для /method/*), т.к. у официального инстанса они отличаются.
struct Instance: Codable, Identifiable, Hashable {
    let name: String
    let webURL: URL   // используется для /token и OAuth
    let apiURL: URL   // используется для /method/*
    let isInsecure: Bool

    var id: String { webURL.absoluteString }

    static let openvkOrg = Instance(
        name: "openvk.org",
        webURL: URL(string: "https://openvk.org")!,
        apiURL: URL(string: "https://api.openvk.org")!,
        isInsecure: false
    )

    static let openvkXyz = Instance(
        name: "openvk.xyz",
        webURL: URL(string: "http://openvk.xyz")!,
        apiURL: URL(string: "http://openvk.xyz")!,
        isInsecure: true
    )

    static let presets: [Instance] = [.openvkOrg, .openvkXyz]
}
