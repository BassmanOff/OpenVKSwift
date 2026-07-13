import SwiftUI

/// Редактирование профиля — account.saveProfileInfo + account.saveInterestsInfo (два разных
/// метода на сервере, шлём последовательно). Пуш в стек (как SettingsView), не модалка —
/// та же причина: ссылки/дальнейшая навигация не должны открываться «за» sheet'ом.
struct ProfileEditView: View {
    let user: User
    var onSaved: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var firstName: String
    @State private var lastName: String
    @State private var screenName: String
    @State private var status: String
    @State private var telegram: String
    @State private var isFemale: Bool
    @State private var birthday: Date
    /// Видимость года рождения тут НЕ редактируется — account.saveProfileInfo не умеет
    /// достоверно включить показ года (см. историю правок), только выключить. Чтобы не
    /// путать пользователя полурабочим тумблером — просто не трогаем текущую видимость.

    @State private var about: String
    @State private var interests: String
    @State private var music: String
    @State private var movies: String
    @State private var tv: String
    @State private var books: String
    @State private var quote: String
    @State private var games: String

    @State private var isSaving = false
    @State private var errorMessage: String?

    @FocusState private var focusedField: FocusedField?

    private enum FocusedField: Hashable {
        case status, firstName, lastName, screenName, telegram
        case about, interests, music, movies, tv, books, games, quote
    }

    init(user: User, onSaved: @escaping () -> Void) {
        self.user = user
        self.onSaved = onSaved
        _firstName = State(initialValue: user.firstName)
        _lastName = State(initialValue: user.lastName)
        _screenName = State(initialValue: user.screenName ?? "")
        _status = State(initialValue: user.status ?? "")
        _telegram = State(initialValue: user.telegram ?? "")
        _isFemale = State(initialValue: user.sex == 1)
        _about = State(initialValue: user.about ?? "")
        _interests = State(initialValue: user.interests ?? "")
        _music = State(initialValue: user.music ?? "")
        _movies = State(initialValue: user.movies ?? "")
        _tv = State(initialValue: user.tv ?? "")
        _books = State(initialValue: user.books ?? "")
        _quote = State(initialValue: user.quotes ?? "")
        _games = State(initialValue: user.games ?? "")

        // Черновая затравка из user.bdate (users.get, отфильтрован приватностью) — только
        // чтобы пикер не был пустым до ответа account.getProfileInfo в .task ниже, который
        // даёт настоящую (не обрезанную приватностью) дату.
        let parts = (user.bdate ?? "").split(separator: ".").compactMap { Int($0) }
        if parts.count >= 2 {
            let year = parts.count >= 3 ? parts[2] : Calendar.current.component(.year, from: Date()) - 18
            _birthday = State(initialValue: Self.makeDate(year: year, month: parts[1], day: parts[0]) ?? Date())
        } else {
            _birthday = State(initialValue: Calendar.current.date(byAdding: .year, value: -18, to: Date()) ?? Date())
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section(header: Text("Основное")) {
                    TextField("Статус", text: $status)
                        .focused($focusedField, equals: .status)
                        .id(FocusedField.status)
                    TextField("Имя", text: $firstName)
                        .focused($focusedField, equals: .firstName)
                        .id(FocusedField.firstName)
                    TextField("Фамилия", text: $lastName)
                        .focused($focusedField, equals: .lastName)
                        .id(FocusedField.lastName)
                    TextField("Короткий адрес", text: $screenName)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .screenName)
                        .id(FocusedField.screenName)
                    Picker("Пол", selection: $isFemale) {
                        Text("Мужской").tag(false)
                        Text("Женский").tag(true)
                    }
                    DatePicker("Дата рождения", selection: $birthday, displayedComponents: .date)
                    TextField("Telegram", text: $telegram)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .focused($focusedField, equals: .telegram)
                        .id(FocusedField.telegram)
                }

                Section(header: Text("О себе")) {
                    GrowingTextEditor(text: $about, minHeight: 80, onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .about)
                        .id(FocusedField.about)
                }

                // Многострочные — как в оригинале OpenVK (все поля интересов там <textarea>, не <input>).
                Section(header: Text("Интересы")) {
                    GrowingTextEditor(text: $interests, placeholder: "Интересы", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .interests)
                        .id(FocusedField.interests)
                    GrowingTextEditor(text: $music, placeholder: "Любимая музыка", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .music)
                        .id(FocusedField.music)
                    GrowingTextEditor(text: $movies, placeholder: "Любимые фильмы", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .movies)
                        .id(FocusedField.movies)
                    GrowingTextEditor(text: $tv, placeholder: "Любимые передачи", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .tv)
                        .id(FocusedField.tv)
                    GrowingTextEditor(text: $books, placeholder: "Любимые книги", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .books)
                        .id(FocusedField.books)
                    GrowingTextEditor(text: $games, placeholder: "Любимые игры", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .games)
                        .id(FocusedField.games)
                    GrowingTextEditor(text: $quote, placeholder: "Любимые цитаты", onGrow: { scrollToFocused(proxy) })
                        .focused($focusedField, equals: .quote)
                        .id(FocusedField.quote)
                }

                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundColor(.red)
                }
            }
            .onChange(of: focusedField) { field in
                guard let field else { return }
                withAnimation { proxy.scrollTo(field, anchor: .center) }
            }
        }
        .navigationTitle("Редактировать профиль")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button("Сохранить") { Task { await save() } }
                        .disabled(firstName.isEmpty || lastName.isEmpty)
                }
            }
        }
        // Настоящая дата рождения (users.get отдаёт то же поле bdate, УЖЕ обрезанное
        // приватностью — год, если скрыт, теряется безвозвратно на этом пути).
        // account.getProfileInfo — единственный метод, который отдаёт себе-владельцу полную
        // дату независимо от текущей приватности.
        .task { await loadAuthoritativeBirthday() }
    }

    private struct SelfProfileInfo: Decodable {
        let bdate: String?
    }

    private func loadAuthoritativeBirthday() async {
        guard let token = settings.token else { return }
        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        guard let info: SelfProfileInfo = try? await client.call("account.getProfileInfo") else { return }
        // %e в PHP-формате — день без ведущего нуля, дополненный ПРОБЕЛОМ ("18.04.2002" но
        // " 5.04.2002" для 5 числа) — Int(" 5") даёт nil без trim, парсинг молча ломался бы.
        let parts = (info.bdate ?? "").split(separator: ".")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 3, let date = Self.makeDate(year: parts[2], month: parts[1], day: parts[0]) else { return }
        birthday = date
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
    }

    /// Значение для отправки, только если оно отличается от исходного (nil = поле не трогаем).
    private func changed(_ current: String, _ original: String?) -> String? {
        current == (original ?? "") ? nil : current
    }

    /// Растущее поле уезжает под клавиатуру по мере ввода новых строк — подскролливаем вслед
    /// за курсором (в отличие от .onChange(focusedField) выше, который ловит только смену фокуса).
    private func scrollToFocused(_ proxy: ScrollViewProxy) {
        guard let focusedField else { return }
        withAnimation { proxy.scrollTo(focusedField, anchor: .bottom) }
    }

    private func save() async {
        guard let token = settings.token else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let client = OVKClient(instance: settings.instance, token: token, apiVersion: settings.apiVersion)
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: birthday)
        let bdate = "\(comps.year ?? 2000)-\(comps.month ?? 1)-\(comps.day ?? 1)" // strtotime съедает ISO без проблем

        do {
            // bdateVisibility: -1 — не трогаем текущую видимость года. account.saveProfileInfo
            // умеет только скрыть год, но не показать его обратно (маппинг на сервере не
            // покрывает этот случай) — сюда лучше вообще не лезть, чем ломать полурабочим тумблером.
            try await client.saveProfileInfo(
                firstName: firstName, lastName: lastName, screenName: screenName,
                sex: isFemale ? 1 : 2, bdate: bdate, bdateVisibility: -1,
                status: status, telegram: telegram
            )
            // Шлём только реально изменённые поля — иначе пустая строка перезапишет null на
            // сервере и поле «появится» пустым блоком в профиле (шаблон: {if !is_null}).
            try await client.saveInterestsInfo(
                about: changed(about, user.about), interests: changed(interests, user.interests),
                music: changed(music, user.music), movies: changed(movies, user.movies),
                tv: changed(tv, user.tv), books: changed(books, user.books),
                quote: changed(quote, user.quotes), games: changed(games, user.games)
            )
            onSaved()
            dismiss()
        } catch {
            if error.isCancellation { return }
            errorMessage = error.localizedDescription
        }
    }
}
