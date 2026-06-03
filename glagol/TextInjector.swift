import Foundation
import AppKit

/// Инжектор текста в активное поле через эмуляцию клавиш CGEvent.
///
/// При каждом `update(to:)` считает diff с предыдущим состоянием:
/// - находит длину общего префикса с предыдущим эмитированным текстом
/// - удаляет лишние символы с конца (backspace ×N)
/// - набивает новый суффикс через `keyboardSetUnicodeString` (любой Unicode, любая раскладка)
///
/// Это даёт UX «текст появляется по мере речи и может переписываться» —
/// классическая streaming-ASR-инжекция.
///
/// **Производительность:** `lastEmitted` хранится как `[Character]`, а не как `String`,
/// потому что `update` дёргается каждые 500мс с растущим текстом — `Array(String)`
/// в горячем пути на 30-минутной диктовке = квадратичная стоимость.
@MainActor
final class TextInjector {
    /// Carbon kVK_Delete — клавиша Backspace.
    private static let kVKDelete: CGKeyCode = 51

    /// Уже введённый текст в активное поле в рамках текущей сессии (как массив
    /// extended grapheme clusters, чтобы корректно считать backspace'ы для emoji
    /// и комбинирующих знаков).
    private var lastEmittedChars: [Character] = []

    /// Обновить инжектированный текст до `current`.
    /// Считает diff с lastEmitted и эмитит keystrokes.
    func update(to current: String) {
        let curr = Array(current)
        let prev = lastEmittedChars

        var prefix = 0
        let minLen = min(prev.count, curr.count)
        while prefix < minLen && prev[prefix] == curr[prefix] {
            prefix += 1
        }

        let backspaces = prev.count - prefix
        let toType = String(curr[prefix...])

        if backspaces > 0 {
            sendBackspaces(count: backspaces)
        }
        if !toType.isEmpty {
            sendText(toType)
        }

        lastEmittedChars = curr
    }

    /// Сбросить tracker для новой сессии. То, что уже введено в поле, остаётся.
    func reset() {
        lastEmittedChars = []
    }

    // MARK: - CGEvent helpers

    private func sendBackspaces(count: Int) {
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            if let down = CGEvent(keyboardEventSource: src, virtualKey: Self.kVKDelete, keyDown: true) {
                down.flags = []   // см. clearModifiers-коммент в postUnicodeChunk
                down.post(tap: .cghidEventTap)
            }
            if let up = CGEvent(keyboardEventSource: src, virtualKey: Self.kVKDelete, keyDown: false) {
                up.flags = []
                up.post(tap: .cghidEventTap)
            }
        }
    }

    /// Размер чанка для отправки в `keyboardSetUnicodeString`.
    /// Apple-документация даёт максимум 20 unicode chars per event; берём
    /// **8 для запаса** (надёжно во всех терминалах, IDE, чатах).
    ///
    /// **Почему не 1 (по символу):** Регрессия найдена 2026-05-15 — при
    /// 1-char-per-event отдельный пробел " " как одиночный CGEvent unicode
    /// **тихо игнорируется** некоторыми приложениями (видимые символы
    /// проходят, пробелы нет). Внутри чанка пробел — часть unicode-буфера,
    /// обрабатывается атомарно вместе с соседними буквами → не теряется.
    ///
    /// **Почему не 60 (одним блоком):** Предыдущая регрессия — терминалы
    /// тихо обрезают unicode-event >~20 chars. 8 chars × N чанков = и
    /// безопасно от обрезки, и пробелы внутри чанка сохраняются.
    private static let maxCharsPerEvent: Int = 8

    private func sendText(_ text: String) {
        let src = CGEventSource(stateID: .hidSystemState)

        // Чанкуем по N графемов (Character). Каждый чанк — один CGEvent с
        // unicode-буфером, содержащим целиком до N символов (включая пробелы
        // и пунктуацию). Backspace-логика остаётся char-by-char.
        var chunk: [Character] = []
        chunk.reserveCapacity(Self.maxCharsPerEvent)
        for char in text {
            chunk.append(char)
            if chunk.count >= Self.maxCharsPerEvent {
                postUnicodeChunk(String(chunk), source: src)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if !chunk.isEmpty {
            postUnicodeChunk(String(chunk), source: src)
        }
    }

    private func postUnicodeChunk(_ chunk: String, source: CGEventSource?) {
        let utf16 = Array(chunk.utf16)
        guard !utf16.isEmpty else { return }

        utf16.withUnsafeBufferPointer { buf in
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
            // **Сброс модификаторов.** Хоткей остановки — двойной Control. Если
            // юзер ещё физически держит Control в момент инжекции, система ОР'ит
            // hardware-modifier state с нашими synthetic-событиями: «⏳» стал бы
            // Ctrl+⏳ (команда, не печать), Backspace → Ctrl+Backspace (удалить
            // слово/перенос), буквы → Ctrl-навигация (курсор в начало строки).
            // Явный `flags = []` говорит системе «эти события без модификаторов».
            down.flags = []
            up.flags = []
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: buf.baseAddress)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }
}
