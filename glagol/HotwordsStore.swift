import Foundation
import Combine
import OSLog

/// Управляет пользовательским словарём для ASR.
///
/// **Где живёт файл:**
///   `~/Library/Application Support/Glagol/hotwords.txt` — один термин на строку.
///   Bundled-дефолт пустой (новые пользователи начинают с чистого листа).
///
/// **Как используется:**
///   На ветке `qwen-asr` адаптер `QwenASR` читает `words` через closure
///   (контекст-prompt в decoder Qwen). Прямого доступа к файлу из ASR нет —
///   все взаимодействия идут через in-memory `words` массив на main thread.
///
/// **Инвариант:** `@MainActor`-class. Все мутации и чтения через main.
@MainActor
final class HotwordsStore: ObservableObject {

    private static let log = Logger(subsystem: "com.sakovskii.glagol", category: "hotwords-store")

    /// Текущий список слов, отсортированный case-insensitive по алфавиту.
    /// UI биндится сюда; запись только через `add/remove/update/resetToDefaults`.
    @Published private(set) var words: [String] = []

    /// Монотонный счётчик. Растёт на каждое изменение — UI слушает и реагирует.
    @Published private(set) var version: Int = 0

    /// Последняя ошибка записи в файл. UI настроек подписывается чтобы показать
    /// пользователю «не удалось сохранить» (например, диск полон).
    @Published private(set) var lastSaveError: String?

    /// Длительность тишины (в секундах) после которой запись авто-останавливается.
    /// Persistится в UserDefaults; читается AudioRecorder через provider-closure.
    @Published var silenceTimeoutSec: Int {
        didSet {
            UserDefaults.standard.set(silenceTimeoutSec, forKey: Self.silenceTimeoutKey)
        }
    }

    /// Допустимые значения паузы для выпадающего меню.
    static let silenceTimeoutOptions: [Int] = [7, 10, 15, 20, 30]
    static let defaultSilenceTimeoutSec: Int = 7
    private static let silenceTimeoutKey = "Glagol.silenceTimeoutSec"

    /// Был ли уже показан tour первого запуска (стрелка-подсказка на menubar-иконку).
    @Published var didShowFirstLaunchTour: Bool {
        didSet {
            UserDefaults.standard.set(didShowFirstLaunchTour, forKey: Self.firstLaunchTourKey)
        }
    }

    private static let firstLaunchTourKey = "Glagol.didShowFirstLaunchTour"

    /// Выбранная пользователем модель/движок (`ModelChoice.rawValue`).
    /// При смене весь движок переключается (см. `AppDelegate.switchEngine`).
    @Published var selectedModel: String {
        didSet {
            UserDefaults.standard.set(selectedModel, forKey: Self.selectedModelKey)
        }
    }

    private static let selectedModelKey = "Glagol.selectedModel"

    private let fileURL: URL
    private let bundleDefaultsURL: URL?

    init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true))
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let glagolDir = appSupport.appendingPathComponent("Glagol", isDirectory: true)
        do {
            try fm.createDirectory(at: glagolDir, withIntermediateDirectories: true)
        } catch {
            Self.log.error("Failed to create Application Support directory: \(error.localizedDescription)")
        }

        self.fileURL = glagolDir.appendingPathComponent("hotwords.txt")
        self.bundleDefaultsURL = Bundle.main.url(forResource: "hotwords", withExtension: "txt")

        // Первый запуск — заливаем дефолты из bundle (на ветке qwen-asr они пустые).
        if !fm.fileExists(atPath: fileURL.path), let defaults = bundleDefaultsURL {
            do {
                try fm.copyItem(at: defaults, to: fileURL)
            } catch {
                Self.log.error("Failed to copy bundled hotwords defaults: \(error.localizedDescription)")
            }
        }

        // Silence timeout
        let storedTimeout = UserDefaults.standard.object(forKey: Self.silenceTimeoutKey) as? Int
        if let t = storedTimeout, Self.silenceTimeoutOptions.contains(t) {
            self.silenceTimeoutSec = t
        } else {
            self.silenceTimeoutSec = Self.defaultSilenceTimeoutSec
        }

        // First-launch tour
        self.didShowFirstLaunchTour = UserDefaults.standard.bool(forKey: Self.firstLaunchTourKey)

        // Выбор модели. Если в UserDefaults лежит «битый» rawValue (не из
        // списка поддерживаемых) — сбрасываем к дефолту.
        let stored = UserDefaults.standard.string(forKey: Self.selectedModelKey)
        if let raw = stored, ModelChoice(rawValue: raw) != nil {
            self.selectedModel = raw
        } else {
            self.selectedModel = ModelChoice.default.rawValue
        }

        reload()
    }

    // MARK: - Mutations

    /// Добавляет слово. Возвращает `false`, если пустое или уже есть.
    @discardableResult
    func add(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !words.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return false
        }
        words.append(trimmed)
        sortAndPublish()
        return true
    }

    /// Удаляет слово (exact match по содержимому).
    func remove(_ word: String) {
        guard let idx = words.firstIndex(of: word) else { return }
        words.remove(at: idx)
        sortAndPublish()
    }

    /// Заменяет старое значение на новое. Возвращает `false`, если новое пустое
    /// или конфликтует с другим существующим словом (case-insensitive).
    @discardableResult
    func update(old: String, to new: String) -> Bool {
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if old == trimmed { return true }

        let collision = words.contains { existing in
            existing != old && existing.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        if collision { return false }

        guard let idx = words.firstIndex(of: old) else { return false }
        words[idx] = trimmed
        sortAndPublish()
        return true
    }

    /// Очищает весь словарь.
    func clearAll() {
        guard !words.isEmpty else { return }
        words = []
        sortAndPublish()
    }

    // MARK: - Persistence

    private func reload() {
        let contents = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let parsed = contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var unique: [String] = []
        for w in parsed {
            let key = w.lowercased()
            if seen.insert(key).inserted {
                unique.append(w)
            }
        }

        words = unique
        sortAndPublish(persist: false)
    }

    private func sortAndPublish(persist: Bool = true) {
        words.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        version += 1
        if persist {
            save()
        }
    }

    private func save() {
        let content = words.joined(separator: "\n") + "\n"
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            if lastSaveError != nil { lastSaveError = nil }
        } catch {
            Self.log.error("Failed to save hotwords: \(error.localizedDescription)")
            lastSaveError = "Не удалось сохранить словарь: \(error.localizedDescription)"
        }
    }
}
