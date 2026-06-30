import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = LoginViewModel()

    var body: some View {
        ZStack {
            OVK.Palette.primary.ignoresSafeArea()

            VStack(spacing: 24) {
                Text("OpenVK")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(.white)

                card
            }
            .padding(.horizontal, 24)
        }
    }

    private var card: some View {
        VStack(spacing: 12) {
            Picker("Сервер", selection: $settings.instance) {
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
                Task { await model.login(settings: settings) }
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
        }
        .padding()
        .background(Color.white)
        .cornerRadius(12)
    }
}
