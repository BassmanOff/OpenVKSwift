import SwiftUI

struct AccountsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var pendingDeletion: SavedAccount?
    @State private var errorMessage: String?
    @State private var showAddAccount = false

    var body: some View {
        List {
            Section {
                ForEach(settings.savedAccounts) { account in
                    HStack(spacing: 12) {
                        Button {
                            if !settings.switchAccount(to: account) {
                                errorMessage = "Токен этого аккаунта не найден. Удалите запись и войдите снова."
                            }
                        } label: {
                            SavedAccountLabel(account: account, showsCurrent: true)
                        }
                        .buttonStyle(.plain)

                        Button(role: .destructive) {
                            pendingDeletion = account
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 32, height: 32)
                        }
                        .accessibilityLabel("Удалить \(account.name)")
                    }
                }
            }

            Section {
                Button {
                    showAddAccount = true
                } label: {
                    Label("Добавить аккаунт", systemImage: "person.badge.plus")
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Аккаунты")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showAddAccount) {
            LoginView(onCancel: { showAddAccount = false })
        }
        .confirmationDialog(
            "Удалить аккаунт из списка?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { account in
            Button("Удалить \(account.name)", role: .destructive) {
                settings.deleteAccount(account)
            }
        } message: { account in
            Text("Для повторного добавления аккаунта \(account.name) потребуется снова войти.")
        }
        .alert("Не удалось переключиться", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("ОК", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

}

struct SavedAccountLabel: View {
    @EnvironmentObject private var settings: AppSettings
    let account: SavedAccount
    var showsCurrent = false

    var body: some View {
        HStack(spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 3) {
                Text(account.name)
                    .foregroundColor(OVK.Palette.textPrimary)
                    .lineLimit(1)
                Text(account.instance.name)
                    .font(.footnote)
                    .foregroundColor(OVK.Palette.textSecondary)
            }

            Spacer()

            if showsCurrent && settings.isCurrentAccount(account) {
                Image(systemName: "checkmark")
                    .foregroundColor(OVK.Palette.primary)
            }
        }
        .contentShape(Rectangle())
    }

    private var avatar: some View {
        CachedImage(url: account.avatarURL, maxPixelSize: 96) {
            ZStack {
                Color(white: 0.92)
                Image(systemName: "person.fill")
                    .foregroundColor(OVK.Palette.textSecondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(Circle())
    }
}
