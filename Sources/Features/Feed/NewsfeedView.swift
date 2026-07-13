import SwiftUI

/// Вкладка «Новости»: лента записей друзей и сообществ (newsfeed.get).
struct NewsfeedView: View {
    @EnvironmentObject private var settings: AppSettings
    @StateObject private var model = NewsfeedViewModel()
    /// «Ответы» — активность (лайки/комменты/упоминания/заявки). ЕДИНЫЙ источник правды
    /// для бейджа колокольчика И бейджа вкладки «Новости» — владелец MainTabView, чтобы
    /// оба бейджа читали одно и то же и обновлялись вместе. Экран открывается пушем и
    /// переиспользует эту же модель.
    @ObservedObject var activity: ActivityViewModel
    /// Программное открытие «Ответов» (тап по баннеру активности) + обычный тап по колокольчику.
    @State private var showActivity = false

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: Binding(
                    get: { model.kind },
                    set: { newKind in Task { await model.switchTo(newKind, settings: settings) } }
                )) {
                    Text("Моя лента").tag(NewsfeedViewModel.Kind.my)
                    Text("Все записи").tag(NewsfeedViewModel.Kind.global)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(OVK.Palette.background.ignoresSafeArea())
            .navigationTitle("Новости")
            .navigationBarTitleDisplayMode(.inline)
            .pushesGlobalLinks(tab: 0) // ссылки из ленты/«Ответов» пушатся в стек этой вкладки
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    NavigationLink(isActive: $showActivity) {
                        ActivityView(model: activity)
                    } label: {
                        Image(systemName: "bell")
                            .overlay(alignment: .topTrailing) {
                                let _ = print("[UI] \(debugNow()) колокольчик рисует бейдж unread=\(activity.unreadCount)")
                                if activity.unreadCount > 0 {
                                    Text(activity.unreadCount > 99 ? "99+" : "\(activity.unreadCount)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(Color.red))
                                        .offset(x: 11, y: -8)
                                }
                            }
                    }
                }
            }
            .task { await model.loadIfNeeded(settings: settings) }
            // Первичная загрузка активности; периодический refresh ведёт MainTabView
            // (чтобы бейдж вкладки жил независимо от того, открыта ли лента).
            .task { await activity.loadIfNeeded(settings: settings) }
            // Тап по баннеру активности — пушим «Ответы» (вкладку переключил MainTabView).
            .onReceive(NotificationRouter.shared.$pendingActivity) { pending in
                guard pending else { return }
                NotificationRouter.shared.pendingActivity = false
                showActivity = true
            }
        }
        // Явный stack-стиль: без него NavigationView в кастомном контейнере может
        // выбрать split-раскладку с некорректным позиционированием навбара (iOS 15).
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private var content: some View {
        // Каждая «маленькая» ветка растянута на всё оставшееся место —
        // иначе VStack сжимается и переключатель лент уезжает в центр экрана.
        if model.posts.isEmpty && model.isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.posts.isEmpty, let error = model.errorMessage {
            VStack(spacing: 12) {
                Text(error)
                    .foregroundColor(OVK.Palette.textSecondary)
                    .multilineTextAlignment(.center)
                Button("Повторить") { Task { await model.reload(settings: settings) } }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.posts.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "newspaper")
                    .font(.system(size: 40))
                    .foregroundColor(OVK.Palette.textSecondary)
                Text("В ленте пока пусто")
                    .foregroundColor(OVK.Palette.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            feedList
        }
    }

    private var feedList: some View {
        List {
            ForEach(model.posts) { post in
                card {
                    PostRow(post: post, authors: model.authors) { p in
                        Task { await model.delete(p, settings: settings) }
                    }
                }
                .onAppear {
                    if post.id == model.posts.last?.id {
                        print("[Feed] onAppear last item: \(post.id), loadingMore: \(model.isLoadingMore)")
                        Task { await model.loadMore(settings: settings) }
                    }
                }
            }
            if model.isLoadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(OVK.Palette.background)
            }
        }
        .listStyle(.plain)
        .refreshable { await model.reload(settings: settings) }
    }

    private func card<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(OVK.Palette.card)
            .padding(.bottom, 8)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(OVK.Palette.background)
    }
}
