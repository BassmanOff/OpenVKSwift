import Foundation

extension String {
    /// OpenVK прогоняет текст постов/сообщений/комментариев через PHP htmlspecialchars()
    /// даже в API-ответах (общий код с рендерингом HTML-страниц — см. Entity-трейт
    /// TRichText::getText(), вызывается независимо от параметра $html). Из-за этого «<», «>»,
    /// «&», «"», «'» приходят как `&lt;` `&gt;` `&amp;` `&quot;` `&#039;` вместо самих символов.
    /// Раскодируем только этот фиксированный набор (НЕ универсальный HTML-декодер — сервер
    /// в этих полях больше ничего не генерирует, `&nbsp;` и т.п. не нужны).
    /// Порядок важен: `&amp;` — ПОСЛЕДНИМ, иначе `&amp;lt;` превратится в `<`, а не в `&lt;`
    /// (сервер кодирует за один проход, декодировать тоже нужно за один).
    var decodingHTMLEntities: String {
        guard contains("&") else { return self } // быстрый путь — большинство текста без сущностей
        return self
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#039;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
