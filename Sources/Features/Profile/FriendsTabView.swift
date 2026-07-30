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
    @State private var didSetInitialScrollPosition = false
    @State private var didSetInitialScrollPositionAfterLoad = false

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    List {
                        OVKSearchStrip(text: $model.query, prompt: "Поиск друзей", floatsOverPage: true)
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)

                        if model.query.isEmpty {
                            tabContent
                        } else {
                            searchContent
                        }

                        Color.clear
                            .frame(height: scrollFillerHeight(in: geometry.size.height))
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .listRowBackground(OVK.Palette.background)
                    }
                    .environment(\.defaultMinListRowHeight, 0)
                    .listStyle(.plain)
                    .refreshable { await model.reload(settings: settings) }
                    .onAppear {
                        guard !didSetInitialScrollPosition else { return }
                        didSetInitialScrollPosition = true
                        DispatchQueue.main.async {
                            proxy.scrollTo("friends-content-start", anchor: .top)
                        }
                    }
                    .onChange(of: model.isLoading) { isLoading in
                        guard !isLoading,
                              !didSetInitialScrollPositionAfterLoad,
                              model.query.isEmpty else { return }
                        didSetInitialScrollPositionAfterLoad = true
                        DispatchQueue.main.async {
                            proxy.scrollTo("friends-content-start", anchor: .top)
                        }
                    }
                    .onChange(of: model.friends.count) { _ in
                        guard !didSetInitialScrollPositionAfterLoad,
                              model.query.isEmpty else { return }
                        didSetInitialScrollPositionAfterLoad = true
                        DispatchQueue.main.async {
                            proxy.scrollTo("friends-content-start", anchor: .top)
                        }
                    }
                }
            }
            .background(OVK.Palette.background)
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
                .id("friends-content-start")
        } else if let error = model.errorMessage, model.friends.isEmpty {
            FriendsStateView(message: error) {
                Task { await model.load(settings: settings) }
            }
            .id("friends-content-start")
        } else if model.friends.isEmpty {
            FriendsStateView(message: "Нет друзей")
                .id("friends-content-start")
        } else {
            if !online.isEmpty {
                sectionHeaderRow("Онлайн (\(online.count))")
                    .id("friends-content-start")
                ForEach(online) { friendRow($0) }
            }
            if !offline.isEmpty {
                if online.isEmpty {
                    sectionHeaderRow("Офлайн (\(offline.count))")
                        .id("friends-content-start")
                } else {
                    sectionHeaderRow("Офлайн (\(offline.count))")
                }
                ForEach(offline) { friendRow($0) }
            }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let local = model.localMatches(model.query).sorted { $0.fullName < $1.fullName }
        if !local.isEmpty {
            sectionHeaderRow("Мои друзья")
            ForEach(local) { friendRow($0) }
        }
        sectionHeaderRow("Глобальный поиск", reservesProgress: true)
        if model.searchResults.isEmpty && local.isEmpty && !model.isSearching {
            FriendsStateView(message: "Ничего не найдено")
        } else {
            ForEach(model.searchResults) { friendRow($0) }
        }
    }

    private func sectionHeaderRow(_ title: String, reservesProgress: Bool = false) -> some View {
        sectionHeader(title, reservesProgress: reservesProgress)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, OVK.Metrics.sectionSpacing)
            .padding(.horizontal, OVK.Metrics.contentInset)
            .padding(.bottom, 6)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
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

    private func scrollFillerHeight(in listHeight: CGFloat) -> CGFloat {
        // ponytail: rows are at least the 44-pt tap target; measure actual content
        // only if a future compact row becomes shorter and breaks initial hiding.
        let rowCount: Int
        if model.query.isEmpty {
            rowCount = max(1, model.friends.count)
        } else {
            rowCount = max(1, model.localMatches(model.query).count + model.searchResults.count)
        }
        return max(0, listHeight - OVK.Metrics.minimumTapSize * CGFloat(rowCount))
    }
}
