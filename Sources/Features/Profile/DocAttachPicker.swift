import SwiftUI

/// Выбор файла для вложения: свои документы + поиск. Как аудио/видео — по ссылке,
/// без загрузки: VKAPI-загрузка документов на сервере — мёртвая заглушка
/// (docs.getUploadServer/getWallUploadServer/save все три безусловно `return 0`).
struct DocAttachPicker: View {
    var onPick: (Document) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var ownDocs: [Document] = []
    @State private var isLoadingOwn = false
    @State private var searchResults: [Document] = []
    @State private var isSearching = false
    @State private var searchText = ""

    private var showingSearch: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        NavigationView {
            Group {
                if showingSearch {
                    list(searchResults, empty: "Ничего не найдено", loading: isSearching)
                } else {
                    list(ownDocs, empty: "Нет файлов", loading: isLoadingOwn)
                }
            }
            .navigationTitle("Прикрепить файл")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Поиск файлов")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Отмена") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .task { await loadOwn() }
        .task(id: searchText) {
            let q = searchText.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { searchResults = []; return }
            try? await Task.sleep(nanoseconds: 600_000_000) // дебаунс, как в остальных пикерах
            if Task.isCancelled { return }
            await runSearch(q)
        }
    }

    @ViewBuilder
    private func list(_ docs: [Document], empty: String, loading: Bool) -> some View {
        if loading && docs.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if docs.isEmpty {
            Text(empty)
                .foregroundColor(OVK.Palette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(docs) { doc in
                Button { onPick(doc); dismiss() } label: { row(doc) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
    }

    private func row(_ doc: Document) -> some View {
        HStack(spacing: 12) {
            ZStack {
                OVK.Palette.background
                Text(doc.ext.uppercased())
                    .font(.caption2).fontWeight(.bold)
                    .foregroundColor(OVK.Palette.textSecondary)
            }
            .frame(width: 40, height: 40)
            .cornerRadius(6)

            VStack(alignment: .leading, spacing: 2) {
                Text(doc.title).foregroundColor(OVK.Palette.textPrimary).lineLimit(1)
                Text(doc.sizeText).font(.caption).foregroundColor(OVK.Palette.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func loadOwn() async {
        guard let token = settings.token else { return }
        isLoadingOwn = true
        defer { isLoadingOwn = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        // owner_id не передаём — сервер (docs.get) сам подставляет текущего пользователя.
        let res: ItemsResponse<Document>? = try? await client.call("docs.get", params: ["count": "100"])
        ownDocs = res?.items ?? []
    }

    private func runSearch(_ q: String) async {
        guard let token = settings.token else { return }
        isSearching = true
        defer { isSearching = false }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        do {
            let res: ItemsResponse<Document> = try await client.call(
                "docs.search", params: ["q": q, "count": "50"]
            )
            if Task.isCancelled { return }
            searchResults = res.items
        } catch {
            if Task.isCancelled { return }
            searchResults = []
        }
    }
}
