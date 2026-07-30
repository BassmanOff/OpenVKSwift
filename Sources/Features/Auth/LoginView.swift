import SwiftUI
import SafariServices

struct LoginView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = LoginViewModel()
    @State private var selectedInstance = Instance.openvkOrg
    @State private var showRegistration = false
    var onCancel: (() -> Void)? = nil

    var body: some View {
        ZStack {
            OVK.Palette.primary.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 24) {
                    Text("OpenVK")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(.white)

                    card
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 56)
            }

            if let onCancel {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Отмена")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 8)
            }
        }
        .onAppear {
            selectedInstance = Instance.loginPreset(for: settings.instance)
        }
        .onChange(of: settings.sessionID) { _ in
            onCancel?()
        }
        .sheet(isPresented: $showRegistration) {
            RegistrationSafariView(url: selectedInstance.registrationURL)
        }
    }

    private var card: some View {
        VStack(spacing: 12) {
            Picker("Сервер", selection: $selectedInstance) {
                ForEach(Instance.presets) { inst in
                    Text(inst.name).tag(inst)
                }
            }
            .pickerStyle(.segmented)

            TextField("Логин или email", text: $model.username)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .textFieldStyle(.roundedBorder)

            SecureField("Пароль", text: $model.password)
                .textContentType(.password)
                .textFieldStyle(.roundedBorder)

            if let error = model.errorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Button {
                Task { await model.login(settings: settings, instance: selectedInstance) }
            } label: {
                Group {
                    if model.isLoading {
                        ProgressView()
                    } else {
                        Text("Войти").fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(OVK.Palette.primaryDark)
            .disabled(model.username.isEmpty || model.password.isEmpty || model.isLoading)

            Button("Зарегистрироваться") {
                showRegistration = true
            }
            .foregroundColor(OVK.Palette.primary)
            .disabled(model.isLoading)

            if !settings.savedAccounts.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                Text("Сохранённые аккаунты")
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(settings.savedAccounts) { account in
                    Button {
                        if settings.switchAccount(to: account) {
                            onCancel?()
                        } else {
                            model.errorMessage = "Токен этого аккаунта не найден. Войдите снова."
                        }
                    } label: {
                        SavedAccountLabel(account: account)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isLoading)
                }
            }
        }
        .padding()
        .background(Color.white)
        .cornerRadius(12)
    }
}

private struct RegistrationSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
