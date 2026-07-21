import SwiftUI

/// Вкладка «Друзья» в таб-баре: поиск (сначала свои, потом глобально), онлайн-сначала.
struct FriendsTabView: View {
    @ObservedObject var model: FriendsTabViewModel
    @EnvironmentObject private var settings: AppSettings
    /// Видна ли вкладка сейчас (активна ли она в таб-баре).
    /// Используется чтобы ставить/паузить фоновый таймер онлайн-статусов.
    let isActive: Bool
    /// Идентификатор выбранного профиля для программной навигации.
    /// Отвязывает стек навигации от содержимого списка (ForEach), чтобы смена
    /// `searchResults` из-за автокоррекции поиска не «убивала» открытый профиль.
    @State private var selectedUserID: Int?

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                OVKSearchStrip(text: $model.query, prompt: "Поиск друзей")

                List {
                    if model.query.isEmpty {
                        tabContent
                    } else {
                        searchContent
                    }
                }
                .listStyle(.plain)
                .refreshable { await model.reload(settings: settings) }
            }
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle("Друзья")
            .navigationBarTitleDisplayMode(.inline)
            .pushesGlobalLinks(tab: 2) // ссылки из друзей пушатся в стек этой вкладки
            .task { await model.loadIfNeeded(settings: settings) }
            .task(id: model.query) {
                let query = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else {
                    await model.searchGlobal("", settings: settings)
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000) // дебаунс
                guard !Task.isCancelled else { return }
                await model.searchGlobal(query, settings: settings)
            }
            // Фоновый таймер онлайн-статусов: раз в ~2.5 мин, только пока вкладка активна.
            // При уходе с вкладки (isActive=false) SwiftUI отменяет этот .task.
            .task(id: isActive) {
                guard isActive else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150 * 1_000_000_000)
                    guard !Task.isCancelled else { return }
                    await model.refreshOnlineStatus(settings: settings)
                }
            }
            .background(
                NavigationLink(
                    isActive: Binding(
                        get: { selectedUserID != nil },
                        set: { if !$0 { selectedUserID = nil } }
                    )
                ) {
                    if let id = selectedUserID {
                        ProfileView(userID: id)
                    }
                } label: { EmptyView() }
                .hidden()
            )
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - Списки

    @ViewBuilder
    private var tabContent: some View {
        let online = model.friends.filter { $0.online }.sorted { $0.fullName < $1.fullName }
        let offline = model.friends.filter { !$0.online }.sorted { $0.fullName < $1.fullName }

        if model.isLoading && model.friends.isEmpty {
            FriendsStateView(message: "Загрузка друзей…", isLoading: true)
        } else if let error = model.errorMessage, model.friends.isEmpty {
            FriendsStateView(message: error) {
                Task { await model.load(settings: settings) }
            }
        } else if model.friends.isEmpty {
            FriendsStateView(message: "Нет друзей")
        } else {
            if !online.isEmpty {
                Section {
                    ForEach(online) { friendRow($0) }
                } header: {
                    sectionHeader("Онлайн (\(online.count))")
                }
            }
            if !offline.isEmpty {
                Section {
                    ForEach(offline) { friendRow($0) }
                } header: {
                    sectionHeader("Офлайн (\(offline.count))")
                }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let local = model.localMatches(model.query).sorted { $0.fullName < $1.fullName }
        if !local.isEmpty {
            Section {
                ForEach(local) { friendRow($0) }
            } header: {
                sectionHeader("Мои друзья")
            }
        }
        Section {
            if model.searchResults.isEmpty && local.isEmpty && !model.isSearching {
                FriendsStateView(message: "Ничего не найдено")
            } else {
                ForEach(model.searchResults) { friendRow($0) }
            }
        } header: {
            sectionHeader("Глобальный поиск", reservesProgress: true)
        }
    }

    private func sectionHeader(_ title: String, reservesProgress: Bool = false) -> some View {
        HStack {
            Text(title)
            Spacer()
            if reservesProgress {
                ProgressView()
                    .scaleEffect(0.75)
                    .opacity(model.isSearching ? 1 : 0)
                    .frame(width: 20, height: 20)
            }
        }
        .font(.footnote)
        .foregroundColor(OVK.Palette.textSecondary)
        .textCase(nil)
    }

    private func friendRow(_ user: User) -> some View {
        Button {
            selectedUserID = user.id
        } label: {
            FriendRow(user: user)
        }
        .buttonStyle(.plain)
    }
}
