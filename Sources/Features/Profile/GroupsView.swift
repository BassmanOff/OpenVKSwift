import SwiftUI

/// Список сообществ: вкладки «Сообщества» / «Управление», поиск (сначала свои, потом глобально).
struct GroupsView: View {
    var userID: Int = 0
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = GroupsViewModel()

    enum Tab { case all, admin }
    @State private var tab: Tab = .all
    @State private var query = ""

    var body: some View {
        List {
            if query.isEmpty {
                tabContent
            } else {
                searchContent
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Поиск")
        .navigationTitle("Сообщества")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) { bottomBar }
        .task { await model.loadIfNeeded(userID: userID, settings: settings) }
        .task(id: query) {
            try? await Task.sleep(nanoseconds: 400_000_000) // дебаунс
            if !query.isEmpty { await model.searchGlobal(query, settings: settings) }
        }
    }

    // MARK: - Списки

    @ViewBuilder
    private var tabContent: some View {
        let groups = tab == .all ? model.allGroups : model.adminGroups
        if model.isLoading && groups.isEmpty {
            HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
        } else if groups.isEmpty {
            Text(tab == .all ? "Нет сообществ" : "Нет управляемых сообществ")
                .foregroundColor(OVK.Palette.textSecondary)
                .listRowSeparator(.hidden)
        } else {
            ForEach(groups) { groupRow($0) }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        let local = model.localMatches(query)
        if !local.isEmpty {
            Section("Мои сообщества") {
                ForEach(local) { groupRow($0) }
            }
        }
        Section("Глобальный поиск") {
            if model.isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }.listRowSeparator(.hidden)
            } else if model.searchResults.isEmpty && local.isEmpty {
                Text("Ничего не найдено").foregroundColor(OVK.Palette.textSecondary)
            } else {
                ForEach(model.searchResults) { groupRow($0) }
            }
        }
    }

    private func groupRow(_ group: Community) -> some View {
        NavigationLink {
            GroupView(community: group)
        } label: {
            HStack(spacing: 12) {
                CachedImage(url: group.avatarURL) {
                    ZStack { OVK.Palette.background; Image(systemName: "person.3").foregroundColor(OVK.Palette.textSecondary) }
                }
                .frame(width: 44, height: 44)
                .clipped()
                .cornerRadius(4)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .foregroundColor(OVK.Palette.textPrimary)
                        .lineLimit(2)
                    if group.isAdmin {
                        Label("Администратор", systemImage: "star.fill")
                            .font(.caption2)
                            .foregroundColor(OVK.Palette.primary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Нижние вкладки (как в старом VK)

    private var bottomBar: some View {
        HStack(spacing: 0) {
            tabButton("Сообщества", .all, count: model.allGroups.count)
            tabButton("Управление", .admin, count: model.adminGroups.count)
        }
        .background(OVK.Palette.card)
        .overlay(Divider(), alignment: .top)
    }

    private func tabButton(_ title: String, _ value: Tab, count: Int) -> some View {
        Button { tab = value } label: {
            VStack(spacing: 1) {
                Text("\(count)").font(.caption).fontWeight(.semibold)
                Text(title).font(.caption2)
            }
            .foregroundColor(tab == value ? OVK.Palette.primary : OVK.Palette.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
    }
}
