import SwiftUI

@MainActor
final class LoginViewModel: ObservableObject {
    @Published var username = ""
    @Published var password = ""
    @Published var isLoading = false
    @Published var errorMessage: String?

    func login(settings: AppSettings) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let auth = AuthService(instance: settings.instance)
        do {
            let result = try await auth.signIn(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password
            )
            settings.signIn(token: result.accessToken, userID: result.userID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
