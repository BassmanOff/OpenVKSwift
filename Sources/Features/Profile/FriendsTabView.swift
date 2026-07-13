import SwiftUI

/// Вкладка «Друзья» в таб-баре: поиск (сначала свои, потом глобально), онлайн-сначала.
struct FriendsTabView: View {
    @ObservedObject var model: FriendsTabViewModel
    @EnvironmentObject private var settings: AppSettings
    /// Видна ли вкладка сейчас (активна ли она в таб-баре).
    /// Используется чтобы ставить/паузить фоновый таймер онлайн-статусов.
    var isActive: Binding<Bool>
    /// Идентификатор выбранного профиля для программной навигации.
    /// Отвязывает стек навигации от содержимого списка (ForEach), чтобы смена
    /// `searchResults` из-за автокоррекции поиска не «убивала» открытый профиль.
    @State private var selectedUserID: Int?

    var body: some View {
        NavigationView {
            List {
                if model.query.isEmpty {
                    tabContent
                } else {
                    searchContent
                }
            }
            .listStyle(.plain)
            .searchable(text: $model.query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск друзей")
            .navigationTitle("Друзья")
            .navigationBarTitleDisplayMode(.inline)
            .pushesGlobalLinks(tab: 2) // ссылки из друзей пушатся в стек этой вкладки
            .refreshable { await model.reload(settings: settings) }
            .task { await model.loadIfNeeded(settings: settings) }
            .task(id: model.query) {
                try? await Task.sleep(nanoseconds: 400_000_000) // дебаунс
                if !model.query.isEmpty { await model.searchGlobal(model.query, settings: settings) }
            }
            // Фоновый таймер онлайн-статусов: раз в ~2.5 мин, только пока вкладка активна.
            // При уходе с вкладки (isActive=false) SwiftUI отменяет этот .task.
            .task(id: isActive.wrappedValue) {
                guard isActive.wrappedValue else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150 * 1_000_000_000)
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
            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
        } else if model.friends.isEmpty {
            Text("Нет друзей")
                .foregroundColor(OVK.Palette.textSecondary)
                .listRowSeparator(.hidden)
        } else {
            if !online.isEmpty {
                Section {
                    ForEach(online) { friendRow($0) }
                } header: {
                    Text("Онлайн (\(online.count))")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .font(.footnote)
                }
            }
            if !offline.isEmpty {
                Section {
                    ForEach(offline) { friendRow($0) }
                } header: {
                    Text("Офлайн (\(offline.count))")
                        .foregroundColor(OVK.Palette.textSecondary)
                        .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let local = model.localMatches(model.query).sorted { $0.fullName < $1.fullName }
        if !local.isEmpty {
            Section("Мои друзья") {
                ForEach(local) { friendRow($0) }
            }
        }
        Section("Глобальный поиск") {
            if model.isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if model.searchResults.isEmpty && local.isEmpty {
                Text("Ничего не найдено").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ForEach(model.searchResults) { friendRow($0) }
            }
        }
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