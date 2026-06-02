import SwiftUI

/// Окно настроек словаря (контекст-prompt для Qwen).
///
/// **Что умеет:**
///   — Список слов, отсортированный case-insensitive по алфавиту
///   — Поиск (фильтрация по подстроке) + CTA добавления из пустого результата
///   — Добавление (TextField + кнопка)
///   — Удаление (кнопка trash)
///   — Редактирование (двойной клик / Enter → коммит, Esc → откат)
///   — Очистка всего словаря (с подтверждением)
///
/// **Что НЕ делает:**
///   — Не вызывает ASR напрямую. Словарь читается адаптером (QwenASR) через
///     closure-provider, и применяется на каждой новой сессии (см. AppDelegate
///     wiring). Так не плодим side-effects из UI.
struct HotwordsSettingsView: View {

    @ObservedObject var store: HotwordsStore

    @Environment(\.colorSchemeContrast) private var contrast

    @State private var searchText: String = ""
    @State private var newWordText: String = ""
    @State private var addError: String?

    @State private var editingWord: String?
    @State private var editingText: String = ""

    @State private var showClearConfirm: Bool = false

    private var editingHighlightOpacity: Double {
        contrast == .increased ? 0.25 : 0.08
    }

    private var filteredWords: [String] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.words }
        return store.words.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    /// Поиск ничего не нашёл → CTA «добавить запрос как новое слово».
    private var showsEmptyCTA: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty && filteredWords.isEmpty
    }

    /// Словарь полностью пуст и поиск не активен → показываем onboarding-копию.
    /// На свежей установке списка нет (bundled defaults пусты по дизайну).
    private var showsEmptyDictionary: Bool {
        searchText.trimmingCharacters(in: .whitespaces).isEmpty && store.words.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            if showsEmptyCTA {
                emptySearchCTA
            } else if showsEmptyDictionary {
                emptyDictionaryHint
            } else {
                list
            }

            Divider()

            footer
        }
        .frame(minWidth: 380, idealWidth: 420, minHeight: 480, idealHeight: 560)
        .alert("Очистить словарь?", isPresented: $showClearConfirm) {
            Button("Отмена", role: .cancel) {}
            Button("Очистить", role: .destructive) {
                store.clearAll()
            }
        } message: {
            Text("Все слова будут удалены. Действие не отменить.")
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Поиск…", text: $searchText)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        if showsEmptyCTA { addFromSearch() }
                    }
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))

            HStack(spacing: 8) {
                TextField("Новое слово…", text: $newWordText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submitAdd)

                Button {
                    submitAdd()
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 20, height: 20)
                }
                .disabled(newWordText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Добавить (Enter)")
            }

            if let err = addError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let saveErr = store.lastSaveError {
                Text(saveErr)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
    }

    /// Onboarding-копия когда словарь пустой и поиск не активен.
    private var emptyDictionaryHint: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "text.book.closed")
                .font(.system(size: 38))
                .foregroundStyle(.secondary)
            Text("Словарь пуст")
                .font(.headline)
            Text("Это нормально — Qwen3-ASR хорошо распознаёт русский и английский без подсказок.\n\nДобавь сюда специфичные термины (продукты, имена, склонения), если модель их путает.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Empty-state когда поиск ничего не нашёл.
    private var emptySearchCTA: some View {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(spacing: 16) {
            Spacer()
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Ничего не найдено")
                .font(.headline)
                .foregroundStyle(.secondary)

            Button {
                addFromSearch()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("Добавить «\(trimmed)»")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Text("Или нажмите Enter в поле поиска")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredWords, id: \.self) { word in
                    row(for: word)
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
    }

    private func row(for word: String) -> some View {
        HStack(spacing: 8) {
            if editingWord == word {
                TextField("", text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(originalWord: word) }
                    .onExitCommand { cancelEdit() }

                Button("OK") { commitEdit(originalWord: word) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Отмена") { cancelEdit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Text(word)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEditing(word) }

                Button {
                    startEditing(word)
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Изменить")

                Button {
                    store.remove(word)
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Удалить")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(editingWord == word
                    ? Color.accentColor.opacity(editingHighlightOpacity)
                    : Color.clear)
        .contextMenu {
            if editingWord != word {
                Button("Изменить") { startEditing(word) }
                Button("Удалить", role: .destructive) { store.remove(word) }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(store.words.count) слов")
                .foregroundStyle(.secondary)
                .font(.callout)

            Spacer()

            Button("Очистить словарь…") {
                showClearConfirm = true
            }
            .controlSize(.small)
            .disabled(store.words.isEmpty)
        }
        .padding(12)
    }

    // MARK: - Actions

    private func submitAdd() {
        let trimmed = newWordText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.add(trimmed) {
            newWordText = ""
            addError = nil
        } else {
            addError = "Это слово уже есть в словаре"
        }
    }

    private func addFromSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if store.add(trimmed) {
            searchText = ""
            addError = nil
        } else {
            addError = "Это слово уже есть в словаре"
        }
    }

    private func startEditing(_ word: String) {
        editingWord = word
        editingText = word
        addError = nil
    }

    private func commitEdit(originalWord: String) {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            store.remove(originalWord)
            editingWord = nil
            return
        }
        if store.update(old: originalWord, to: trimmed) {
            editingWord = nil
        } else {
            addError = "Не удалось изменить: такое слово уже есть"
        }
    }

    private func cancelEdit() {
        editingWord = nil
        addError = nil
    }
}
