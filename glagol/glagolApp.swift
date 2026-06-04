import SwiftUI
import AppKit
import AVFoundation
import Combine
import OSLog

private let qwenAppLog = Logger(subsystem: "com.sakovskii.glagol", category: "app")

@main
struct GlagolApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Settings { EmptyView() } раньше добавлял ⌘, шорткат, открывающий пустое окно.
        // Для menubar-only-app с LSUIElement=YES это мусорный UX. Используем кастомную
        // WindowGroup с handling'ом активации, которая никогда не открывается явно.
        Settings {
            EmptyView()
                .frame(width: 0, height: 0)
                .onAppear {
                    // Если ⌘, всё-таки сработал и macOS попыталась открыть окно —
                    // мгновенно закрываем его, чтобы пользователь не увидел пустоту.
                    DispatchQueue.main.async {
                        NSApplication.shared.keyWindow?.close()
                    }
                }
        }
    }
}

/// NSImageView, который пропускает клики мыши на родительский NSStatusBarButton.
private final class PassThroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let recorder: AudioRecorder
    let hotkey = HotkeyManager()
    /// Пользовательский словарь. Передаётся в Qwen-decoder как context-prompt
    /// при каждом transcribe — биасит модель к сохранению специфичных терминов
    /// в исходном написании. Файл живёт в Application Support.
    let hotwords: HotwordsStore
    /// Активный движок распознавания. Тип — порт `BatchASR`, конкретная
    /// реализация (`QwenASR` / `GigaAMSherpaASR`) подменяется через
    /// `switchEngine(to:)` при смене модели в меню. `var` — движок меняется.
    private(set) var asr: BatchASR
    let injector = TextInjector()

    /// Плавающий overlay диктовки (waveform + кнопки пауза/стоп). Показывается
    /// когда запись реально пошла, прячется на стопе. Создаётся лениво в
    /// `applicationDidFinishLaunching` (нужен @MainActor контекст).
    private var overlay: DictationOverlayController?

    /// Состояние ASR для меню. Не @Published — никто не подписывается, callbacks
    /// сами дёргают `rebuildMenu()`. Был бы @Published — публикации без подписчиков
    /// и ложное обещание реактивности.
    var asrReady: Bool = false
    var asrError: String?
    var asrStatus: String?
    /// Открыто ли сейчас menubar-меню. Пока меню открыто, переприсвоение
    /// `statusItem.menu` невидимо — AppKit показывает старый `NSMenu` до закрытия.
    /// Поэтому при открытом меню обновляем живые NSMenuItem in-place
    /// (см. `applyMenuState` / `updateLiveASRMenuItems`).
    private var menuIsOpen: Bool = false
    /// Weak-ref на пункт «Начать запись» — чтобы менять `isEnabled` in-place в
    /// открытом меню (иначе кнопка остаётся серой пока меню не переоткроют).
    private weak var startMenuItem: NSMenuItem?
    /// Статус mic-permission. `nil` пока не проверили; `true/false` после первой попытки.
    var micPermissionDenied: Bool = false

    /// Активный transcribe-Task. Отслеживаем чтобы при старте новой записи
    /// отменить предыдущий transcribe (его результат уже не нужен — это и есть
    /// защита от инжекции в чужое поле).
    private var transcribeTask: Task<Void, Never>?

    /// Готовность записи для UI (overlay + красная иконка). Запись стартует
    /// СРАЗУ на хоткей (аудио копится с первой мс), но overlay/анимация
    /// показываются с фиксированной задержкой `readyDelaySec` — к этому моменту
    /// железо микрофона гарантированно раскрутилось. Юзер ориентируется на
    /// появление overlay и начинает говорить когда запись уже идёт стабильно.
    ///
    /// Почему фикс-задержка, а не `isCapturing` (первый буфер): после warm-start
    /// движка (engine.prepare без reset) первый буфер приходит за ~50мс, ДО
    /// стабилизации звука — `isCapturing` стал срабатывать слишком рано, overlay
    /// показывался под мёртвый waveform и юзер терял первые слова. Фикс-задержка
    /// предсказуема и не зависит от тёплости движка.
    private var recordingReady: Bool = false
    private var readyTimer: Timer?
    private static let readyDelaySec: TimeInterval = 0.75

    /// Анимация прогресса транскрипции — печатается прямо в строку ввода пока
    /// модель обрабатывает аудио, чтобы юзер видел что процесс идёт.
    /// Цикл `progressFrames` через `injector` (diff сам стирает/печатает).
    /// Показывается ТОЛЬКО на время transcribe, не во время записи.
    ///
    /// Песочные часы emoji (⏳⌛) — «переворачиваются» раз в секунду.
    /// История: Braille (⠋⠙⠹…) показывал tofu-прямоугольник в терминале;
    /// быстрая смена кадров (0.1с) вдобавок мерцала из-за зазора между
    /// backspace старого символа и печатью нового (два CGEvent, приложение
    /// обрабатывает не атомарно). Решение: всего 2 кадра + смена раз в секунду —
    /// зазор delete/insert практически незаметен. Песочные часы интуитивно
    /// читаются как «идёт обработка, подожди».
    private var progressTimer: Timer?
    private var progressPhase: Int = 0
    private static let progressFrames = ["⏳", "⌛"]
    private static let progressTickSec: TimeInterval = 1.0

    /// VAD-gate против утечки контекст-prompt'а на тишине. Если голоса меньше
    /// `minVoicedSec` ИЛИ его доля от записи меньше `minVoicedRatio` — считаем
    /// что юзер молчал, transcribe не запускаем. Пороги мягкие: реальная (даже
    /// тихая/короткая) речь проходит, чистая тишина — отсекается.
    private static let minVoicedSec: Double = 0.3
    private static let minVoicedRatio: Double = 0.1

    // IUO: набивается в applicationDidFinishLaunching, до этого NSStatusBar ещё нет.
    private var statusItem: NSStatusItem!
    private var iconView: PassThroughImageView!
    private var hotkeyRecordingPanel: NSPanel?
    private var hotwordsPanel: NSPanel?
    private var firstLaunchTourPanel: NSPanel?
    private var helpPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    /// Слабая ссылка на NSMenuItem строки «ASR: …» в текущем меню.
    /// Используется чтобы обновлять прогресс загрузки in-place, не пересобирая
    /// меню целиком — иначе уже-открытое NSMenu остаётся со старым содержимым
    /// и юзер не видит обновлений процента до закрытия+открытия меню.
    private weak var asrStatusMenuItem: NSMenuItem?

    override init() {
        let store = HotwordsStore()
        self.hotwords = store
        // Weak-capture store: подсистемы не должны его удерживать сильно.
        self.recorder = AudioRecorder(
            silenceTimeoutProvider: { [weak store] in
                TimeInterval(store?.silenceTimeoutSec ?? HotwordsStore.defaultSilenceTimeoutSec)
            }
        )
        self.asr = AppDelegate.makeBatchASR(store: store)
        super.init()
    }

    /// **Точка подмены ASR-движка.**
    /// Текущий движок — Qwen3-ASR через speech-swift (MLX на Apple Silicon),
    /// multilingual из коробки.
    ///
    /// **Контекст-prompt вместо hotwords:** speech-swift кладёт переданную строку
    /// в system message Qwen-chat-template'а.
    ///
    /// **История промпта — важный контекст для редактуры:**
    /// 1. Короткий русский «Технические термины: …» — не утекал.
    /// 2. Длинный bilingual «These terms MUST be preserved…» — утекал.
    /// 3. Короткий английский «The speaker is a software developer dictating
    ///    text; expect mixed Russian and English IT vocabulary. Use short
    ///    sentences ending with periods; avoid long sentences joined by commas.»
    ///    — на тестах **тоже утёк** в финал транскрипта когда на хвосте записи
    ///    был тихий участок. Qwen-LLM на quiet audio с English context'ом
    ///    «сгенерировал» именно prompt как наиболее доступный английский текст
    ///    в его контексте.
    /// 4. **Текущий — короткий русский.** Минимизирует риск утечки (русский
    ///    output, русский prompt — нет language-switch hallucination'а).
    ///
    /// **Правило для будущего редактирования:** держать промпт КОРОТКИМ и НА
    /// ЯЗЫКЕ ЦЕЛЕВОГО OUTPUT'а. Английский можно вернуть когда у speech-swift
    /// появится protection против prompt-leak (например, явный suppression
    /// token в decoder pass).
    ///
    /// URL-база, откуда GigaAM-адаптер качает модель — НАПРЯМУЮ с официального
    /// HuggingFace (csukuangfj). Эмпирически проверено: sherpa-onnx v1.13.x
    /// грузит эту модель БЕЗ патча metadata (старая проблema, под которую
    /// писался patch_model_metadata.py в v1, в новой версии sherpa решена).
    /// Так что свой хостинг не нужен — качаем оригинал.
    /// Файлы: encoder.int8.onnx, decoder.onnx, joiner.onnx, tokens.txt.
    private static let gigaamModelBase =
        "https://huggingface.co/csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16/resolve/main"

    /// Создаёт движок для текущего выбора в `store.selectedModel`.
    private static func makeBatchASR(store: HotwordsStore) -> BatchASR {
        let choice = ModelChoice(rawValue: store.selectedModel) ?? .default
        return makeEngine(choice: choice, store: store)
    }

    /// Фабрика движка по `ModelChoice`. Qwen — context-prompt из словаря;
    /// GigaAM — sherpa-onnx, словарь пока не использует (другой механизм).
    private static func makeEngine(choice: ModelChoice, store: HotwordsStore) -> BatchASR {
        switch choice.engine {
        case .qwen:
            let modelId = choice.qwenModelId ?? ModelChoice.qwenLarge.qwenModelId!
            return QwenASR(
                modelId: modelId,
                contextProvider: { [weak store] in
                    let style = "Используй короткие предложения с точками."
                    guard let words = store?.words, !words.isEmpty else { return style }
                    return style + " Часто встречающиеся слова: " + words.joined(separator: ", ")
                }
            )
        case .gigaam:
            return GigaAMSherpaASR(modelDownloadBase: gigaamModelBase)
        }
    }

    /// Переключает активный движок. Старый выгружается, новый создаётся,
    /// callbacks переподписываются, запускается warmUp.
    /// Caller гарантирует что запись НЕ идёт.
    private func switchEngine(to choice: ModelChoice) {
        qwenAppLog.notice("switchEngine → \(choice.rawValue)")
        asr.shutdown()
        asrReady = false
        asrError = nil
        asrStatus = "Переключаю модель…"
        rebuildMenu()

        let newEngine = Self.makeEngine(choice: choice, store: hotwords)
        self.asr = newEngine
        setupASRHandlers()   // переподписать onReadyChange/onError/onStatus на новый движок
        newEngine.warmUp()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupHotkeyHandlers()
        setupASRHandlers()
        setupRecorderHandlers()
        setupOverlay()
        setupSubscriptions()

        hotkey.startMonitoring()
        asr.warmUp()
        checkMicPermissionPreemptive()

        updateIcon()
        rebuildMenu()

        // First-launch tour. Запускаем с задержкой 0.6с чтобы statusItem успел
        // встать в menubar (иначе позиция будет вычислена неточно).
        if !hotwords.didShowFirstLaunchTour {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showFirstLaunchTour()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Без явного teardown'а CGEventTap / AVAudioEngine процесс полагается на
        // OS-cleanup. Документируем интент даже если ARC + process exit это сделают.
        progressTimer?.invalidate()
        transcribeTask?.cancel()
        if recorder.isRecording { recorder.stop() }
        hotkey.stopMonitoring()
        asr.shutdown()
    }

    // MARK: - Setup helpers

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            iconView = PassThroughImageView(frame: button.bounds)
            iconView.autoresizingMask = [.width, .height]
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(
                pointSize: 14,
                weight: .regular
            )
            button.addSubview(iconView)
            // VoiceOver / a11y: NSImage.accessibilityDescription может быть не подхвачен
            // на самой кнопке status item — выставляем явно. Обновляется в updateIcon.
            button.setAccessibilityLabel("Glagol")
            button.setAccessibilityRole(.menuButton)
        }
    }

    private func setupHotkeyHandlers() {
        hotkey.onHotkey = { [weak self] in
            self?.toggleRecording()
        }
        hotkey.onEscape = { [weak self] in
            guard let self, self.recorder.isRecording else { return }
            self.stopRecordingFlow()
        }
        hotkey.onRecordingComplete = { [weak self] _ in
            self?.closeHotkeyRecording()
        }
        hotkey.onRecordingCancelled = { [weak self] in
            self?.closeHotkeyRecording()
        }
    }

    private func setupASRHandlers() {
        asr.onReadyChange = { [weak self] ready in
            guard let self else { return }
            self.asrReady = ready
            if ready { self.asrStatus = nil }
            self.applyMenuState()
        }
        asr.onError = { [weak self] msg in
            guard let self else { return }
            self.asrError = msg
            self.applyMenuState()
        }
        asr.onStatus = { [weak self] msg in
            guard let self else { return }
            self.asrStatus = msg
            self.applyMenuState()
        }
    }

    /// Единая точка обновления меню при смене ASR-состояния.
    ///
    /// **Почему не просто `rebuildMenu`:** пока меню ОТКРЫТО, переприсвоение
    /// `statusItem.menu` невидимо — AppKit продолжает показывать старый `NSMenu`
    /// до закрытия. Поэтому при открытом меню мутируем живые `NSMenuItem`
    /// in-place — `NSMenu` релэйаутит открытое меню при таких изменениях, и юзер
    /// видит результат сразу, не переоткрывая. В закрытом — обычная пересборка.
    private func applyMenuState() {
        guard menuIsOpen else {
            rebuildMenu()
            return
        }
        updateLiveASRMenuItems()
    }

    /// In-place обновление статус-строки и кнопки старта в уже открытом меню.
    /// При готовности модели строка статуса удаляется, а «Начать запись»
    /// становится активной — всё без переоткрытия меню.
    private func updateLiveASRMenuItems() {
        let showStatusLine = !asrReady && asrError == nil
        if let item = asrStatusMenuItem {
            if showStatusLine {
                item.title = asrStatus.map { "\($0)" } ?? "Запускается…"
            } else {
                // Модель готова (или ошибка) — убираем строку из открытого меню.
                item.menu?.removeItem(item)
                asrStatusMenuItem = nil
            }
        } else if showStatusLine {
            // Строки нет в текущем меню — пересборка (невидима сейчас, корректна
            // при следующем открытии). Редкий путь: меню открыли уже после ready.
            rebuildMenu()
        }
        if let start = startMenuItem, !recorder.isRecording {
            start.isEnabled = asrReady && !micPermissionDenied && hotkey.isAccessibilityGranted
        }
    }

    private func setupRecorderHandlers() {
        // В batch-режиме аудио просто копится в `recorder.capturedAudio`,
        // никаких per-chunk callback'ов не нужно. Транскрибируем целиком
        // на транзиции записи true→false (см. `setupSubscriptions`).
    }

    private func setupOverlay() {
        overlay = DictationOverlayController(
            recorder: recorder,
            onTogglePause: { [weak self] in self?.recorder.togglePause() },
            onStop: { [weak self] in self?.stopRecordingFlow() }
        )
    }

    private func setupSubscriptions() {
        // Pairwise (previous, current) — нам важна именно ТРАНЗИЦИЯ true→false,
        // чтобы дёрнуть transcribe ровно один раз (включая случай VAD-auto-stop).
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .scan((false, false)) { acc, new in (acc.1, new) }
            .sink { [weak self] (prev, curr) in
                guard let self else { return }
                self.updateIcon()
                self.rebuildMenu()

                // Транзиция «писали → перестали писать»: прячем overlay,
                // отменяем ready-таймер, запускаем batch transcribe.
                if prev && !curr {
                    self.readyTimer?.invalidate()
                    self.readyTimer = nil
                    self.recordingReady = false
                    self.overlay?.hide()
                    self.updateIcon()
                    self.startTranscribe()
                }
                // Транзиция «не писали → начали писать»: прерываем в-полёте
                // transcribe, стираем spinner, и запускаем ready-таймер.
                // Запись УЖЕ идёт (recorder.start вызван в beginRecordingSession),
                // аудио копится с первой мс. Overlay/анимация/красная иконка
                // появятся через `readyDelaySec` — к этому моменту железо готово.
                if !prev && curr {
                    self.transcribeTask?.cancel()
                    self.transcribeTask = nil
                    self.stopProgressAnimation(clear: true)

                    self.recordingReady = false
                    self.readyTimer?.invalidate()
                    self.readyTimer = Timer.scheduledTimer(
                        withTimeInterval: Self.readyDelaySec, repeats: false
                    ) { [weak self] _ in
                        MainActor.assumeIsolated {
                            guard let self, self.recorder.isRecording else { return }
                            self.recordingReady = true
                            self.updateIcon()
                            self.overlay?.show()
                        }
                    }
                }
            }
            .store(in: &cancellables)

        recorder.$lastError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        // Accessibility granted post-launch — пере-запускаем eventTap monitoring.
        // `HotkeyManager.startMonitoring()` фейлится при первом вызове если
        // permission ещё нет; без этой подписки после grant'а в System Settings
        // хоткей оставался мёртвым до перезапуска приложения.
        hotkey.$isAccessibilityGranted
            .receive(on: RunLoop.main)
            .sink { [weak self] granted in
                guard let self else { return }
                if granted && !self.hotkey.isMonitoring {
                    _ = self.hotkey.startMonitoring()
                }
                self.rebuildMenu()
            }
            .store(in: &cancellables)

        hotkey.$isMonitoring
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        hotkey.$hotkey
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)

        // Правки словаря — обновляем счётчик в меню. Сам контекст-prompt
        // подхватывается ASR'ом автоматически на следующем transcribe
        // (QwenASR снимает context-snapshot из contextProvider там).
        // Никаких reload'ов запускать не нужно.
        hotwords.$words
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    // MARK: - Recording flow

    /// Старт/стоп. Завязано на состояние recorder.
    /// При старте — поднимаем ASR-сессию ПЕРЕД началом записи.
    /// При стопе — закрываем ASR-сессию ПОСЛЕ остановки записи.
    private func toggleRecording() {
        if recorder.isRecording {
            stopRecordingFlow()
        } else {
            startRecordingFlow()
        }
    }

    private func startRecordingFlow() {
        guard !recorder.isRecording else { return }
        // ASR ещё не готов — silently игнорим вызов (хоткей, кнопка из меню
        // должна быть заблокирована, но защита на всякий случай).
        guard asr.isReady else {
            // beep — пользователь поймёт, что хоткей сработал, но запись не пошла
            NSSound.beep()
            return
        }
        // Без Accessibility CGEvent.post() не работает, текст не попадёт в
        // активное поле. Блокируем запись (даже если кто-то дёрнет хоткей
        // в момент когда меню ещё не успело перерисоваться).
        guard hotkey.isAccessibilityGranted else {
            NSSound.beep()
            // Подтаскиваем фокус к нашему menubar-индикатору, чтобы юзер
            // увидел подсказку.
            statusItem.button?.performClick(nil)
            return
        }
        // Mic permission: если уже знаем что denied — beep + поднять видимость
        // в меню. Если первый раз — запросим async и попробуем стартовать ещё раз.
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            beginRecordingSession()
        case .notDetermined:
            requestMicAndStart()
        case .denied, .restricted:
            micPermissionDenied = true
            asrError = nil
            rebuildMenu()
            NSSound.beep()
        @unknown default:
            beginRecordingSession()
        }
    }

    private func beginRecordingSession() {
        micPermissionDenied = false
        // injector.reset() здесь НЕ вызываем: если в поле остались точки
        // прогресс-анимации от предыдущего (отменённого) transcribe, их нужно
        // стереть через diff — а reset() забыл бы про них и точки остались бы.
        // Стирание делает `stopProgressAnimation(clear: true)` в subscription
        // при транзиции записи false→true.
        recorder.start()
    }

    private func stopRecordingFlow() {
        guard recorder.isRecording else { return }
        recorder.stop()
        // `startTranscribe()` НЕ вызываем здесь — её триггерит subscription на
        // recorder.$isRecording через транзицию true→false (см. setupSubscriptions).
        // Этот же путь покрывает и VAD auto-stop, где stopRecordingFlow не вызывается.
    }

    /// Дёргает `asr.transcribe(audio:)` на накопленной записи, после получения
    /// результата инжектит в активное поле. Вызывается из subscription на
    /// `recorder.$isRecording` при транзиции true→false (включая VAD-auto-stop).
    private func startTranscribe() {
        let audio = recorder.capturedAudio
        guard !audio.isEmpty else {
            qwenAppLog.notice("startTranscribe: empty audio buffer, skipping")
            return
        }
        let durationSec = Double(audio.count) / 16_000.0

        // VAD-gate: если в записи почти нет голоса — это тишина. На тишине
        // Qwen-LLM генерирует наиболее «доступный» текст из контекста = наш
        // context-prompt (словарь хотвордов) утекает в выход. Не транскрибируем.
        let voicedSec = recorder.voicedDurationSec
        let voicedRatio = durationSec > 0 ? voicedSec / durationSec : 0
        if voicedSec < Self.minVoicedSec || voicedRatio < Self.minVoicedRatio {
            qwenAppLog.notice("startTranscribe: too little voice (voiced=\(voicedSec)s ratio=\(voicedRatio)) — skipping (silence)")
            return
        }

        qwenAppLog.notice("startTranscribe: \(audio.count) samples (\(durationSec)s), voiced=\(voicedSec)s")
        asrStatus = "Транскрибирую…"
        rebuildMenu()

        // Чистый старт injector'а + анимация точек прямо в строке ввода.
        injector.reset()
        startProgressAnimation()

        transcribeTask?.cancel()
        transcribeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.asrStatus = nil
                self.transcribeTask = nil
                self.rebuildMenu()
            }
            do {
                let text = try await self.asr.transcribe(audio: audio)
                // Если в-полёте отменили — юзер успел стартовать новую запись,
                // старый результат уже не нужен. Это ЕДИНСТВЕННАЯ защита от
                // инжекции в чужое поле в batch-режиме, и её достаточно:
                // новая запись отменяет старый transcribe.
                //
                // Time-based дедлайн НЕ используем: в batch время transcribe
                // растёт с длиной записи (58с аудио → ~6.5с transcribe),
                // фиксированный порог ложно срабатывал и текст не вставлялся.
                // Юзер ОЖИДАЕТ результат после диктовки — инжектим когда придёт.
                if Task.isCancelled {
                    self.stopProgressAnimation(clear: true)
                    return
                }
                guard !text.isEmpty else {
                    self.stopProgressAnimation(clear: true)
                    return
                }
                // Output-фильтр против утечки промпта (defense-in-depth поверх
                // VAD-gate). Двухступенчато:
                //   1. Вырезаем непрерывные цепочки словарных терминов через
                //      запятую («…, Anthropic, ASR, CI/CD, Claude, …») — это
                //      формат утечки, в т.ч. когда она приклеилась хвостом к
                //      реальному тексту. Реальную речь не трогаем.
                //   2. Если после вырезки текст всё ещё на большую долю из
                //      терминов (утечка без запятых) — отбрасываем целиком.
                let cleaned = self.stripPromptLeakRuns(text)
                if cleaned.isEmpty || self.looksLikePromptLeak(cleaned) {
                    qwenAppLog.notice("transcribe output looks like prompt leak — discarding. raw=\"\(text)\" cleaned=\"\(cleaned)\"")
                    self.stopProgressAnimation(clear: true)
                    return
                }
                if cleaned != text {
                    qwenAppLog.notice("stripped prompt-leak run. raw=\"\(text)\" → \"\(cleaned)\"")
                }
                // Останавливаем анимацию БЕЗ стирания: `update(to: text)` сам
                // сделает diff от текущих точек (backspace точек + печать текста)
                // одной операцией — без мигания пустотой между ними.
                self.stopProgressAnimation(clear: false)
                self.injector.update(to: cleaned)
                self.injector.reset()
            } catch {
                self.stopProgressAnimation(clear: true)
                if !Task.isCancelled {
                    qwenAppLog.error("transcribe failed: \(error.localizedDescription)")
                    self.asrError = error.localizedDescription
                }
            }
        }
    }

    /// Эвристика: похож ли результат transcribe на утечку context-prompt'а
    /// (словарь хотвордов), а не на реальную речь.
    ///
    /// **Сигнал:** не просто «содержит термины» (реальная речь их тоже содержит —
    /// юзер для того их и добавил), а **высокая ДОЛЯ** слов результата = словарные
    /// термины. Утечка выглядит как «Anthropic, ASR, CI/CD, Claude, …» — почти
    /// 100% слов из словаря, подряд. Реальная фраза с парой терминов («добавил
    /// Claude через FastAPI») имеет низкую долю и не отсекается.
    ///
    /// Срабатывает только если: словарь ≥ 5 слов (иначе не на чем судить),
    /// совпало ≥ 5 слов И их доля ≥ 60%.
    private func looksLikePromptLeak(_ text: String) -> Bool {
        // Множество слов словаря (термины могут быть многословными — «Docker
        // Compose», «pull request» — разбиваем на отдельные слова).
        let dictWords = Set(hotwords.words.flatMap { Self.normalizeWords($0) })
        guard dictWords.count >= 5 else { return false }

        let resultWords = Self.normalizeWords(text)
        guard !resultWords.isEmpty else { return false }

        let matched = resultWords.filter { dictWords.contains($0) }.count
        let ratio = Double(matched) / Double(resultWords.count)
        return matched >= 5 && ratio >= 0.6
    }

    /// Нормализация строки в массив слов: lowercase, разбивка по пробелам,
    /// срезание окраинной пунктуации. «CI/CD» остаётся одним токеном (внутренний
    /// слэш не режем — он есть и в словарном термине).
    private static func normalizeWords(_ s: String) -> [String] {
        s.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?()[]{}\"'«»—-")) }
            .filter { !$0.isEmpty }
    }

    /// Минимальная длина непрерывной цепочки терминов-через-запятую, считающаяся
    /// утечкой. 6 — реальный список из 6+ словарных терминов подряд через запятую
    /// крайне редок, а утечка обычно длинная (весь словарь, 20+ терминов).
    private static let minPromptLeakRun: Int = 6

    /// Вырезает из текста непрерывные цепочки словарных терминов через запятую
    /// (формат утечки context-prompt'а). Разбивает по запятым, помечает
    /// сегменты, целиком состоящие из словарных слов, находит непрерывные
    /// run'ы длиной ≥ `minPromptLeakRun` и удаляет их. Остальной текст склеивает
    /// обратно и чистит осиротевшую пунктуацию.
    private func stripPromptLeakRuns(_ text: String) -> String {
        let dictWords = Set(hotwords.words.flatMap { Self.normalizeWords($0) })
        guard dictWords.count >= Self.minPromptLeakRun else { return text }

        let segments = text.components(separatedBy: ",")
        guard segments.count >= Self.minPromptLeakRun else { return text }

        // Сегмент «термин», если непуст и ВСЕ его слова — словарные.
        let isTerm: [Bool] = segments.map { seg in
            let w = Self.normalizeWords(seg)
            return !w.isEmpty && w.allSatisfy { dictWords.contains($0) }
        }

        // Помечаем на удаление сегменты внутри run'ов длиной ≥ порога.
        var keep = [Bool](repeating: true, count: segments.count)
        var i = 0
        while i < segments.count {
            if isTerm[i] {
                var j = i
                while j < segments.count && isTerm[j] { j += 1 }
                if j - i >= Self.minPromptLeakRun {
                    for k in i..<j { keep[k] = false }
                }
                i = j
            } else {
                i += 1
            }
        }

        guard keep.contains(false) else { return text }  // ничего не вырезали

        let kept = zip(segments, keep).filter { $0.1 }.map { $0.0 }
        var result = kept.joined(separator: ",")
        // Чистим осиротевшую пунктуацию/пробелы по краям и схлопываем дыры.
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:—-"))
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Progress animation (точки в строке ввода во время transcribe)

    /// Запускает анимацию `.` → `..` → `...` → (пусто) → цикл прямо в активном
    /// поле через `injector`. Каждый кадр — `injector.update(to:)`, который
    /// diff'ом стирает старые точки и печатает новые. Вызывать на main.
    private func startProgressAnimation() {
        progressPhase = 0
        injector.update(to: Self.progressFrames[0])  // мгновенная реакция
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(
            withTimeInterval: Self.progressTickSec, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.progressPhase = (self.progressPhase + 1) % Self.progressFrames.count
                self.injector.update(to: Self.progressFrames[self.progressPhase])
            }
        }
    }

    /// Останавливает таймер анимации. Если `clear` — стирает текущие точки из
    /// поля (`update(to: "")`). При успешном transcribe передаём `clear: false`,
    /// чтобы последующий `update(to: text)` сам убрал точки одним diff'ом.
    private func stopProgressAnimation(clear: Bool) {
        progressTimer?.invalidate()
        progressTimer = nil
        if clear {
            injector.update(to: "")
            injector.reset()
        }
    }

    /// Запрашивает доступ к микрофону. Если получили — стартуем; нет — пишем флаг
    /// и показываем меню-пункт «Открыть настройки микрофона…».
    private func requestMicAndStart() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if granted {
                    self.beginRecordingSession()
                } else {
                    self.micPermissionDenied = true
                    self.rebuildMenu()
                    NSSound.beep()
                }
            }
        }
    }

    /// Превентивная проверка mic-permission на старте app. Не запрашиваем — только
    /// смотрим текущий статус, чтобы меню сразу было корректным.
    private func checkMicPermissionPreemptive() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        micPermissionDenied = (status == .denied || status == .restricted)
    }

    // MARK: - Status item icon

    private func updateIcon() {
        guard let iconView, let button = statusItem.button else { return }

        if recordingReady {
            // Готовность по фикс-таймеру (0.5с) — запись идёт стабильно,
            // красная анимированная. Сигнал «говори». Юзер ориентируется на него.
            let image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Идёт запись"
            )
            image?.isTemplate = false
            iconView.image = image
            iconView.contentTintColor = .systemRed
            iconView.addSymbolEffect(
                .variableColor.iterative.reversing,
                options: .repeating
            )
            button.setAccessibilityLabel("Glagol, идёт запись")
        } else if recorder.isRecording {
            // Хоткей нажат, идёт раскрутка железа (~0.5с до readyTimer).
            // Жёлтая статичная — «подожди, готовлюсь». НЕ говори ещё.
            iconView.removeAllSymbolEffects()
            let image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Подготовка записи"
            )
            image?.isTemplate = false
            iconView.image = image
            iconView.contentTintColor = .systemYellow
            button.setAccessibilityLabel("Glagol, подготовка записи")
        } else {
            iconView.removeAllSymbolEffects()
            let image = NSImage(
                systemSymbolName: "waveform",
                accessibilityDescription: "Glagol"
            )
            image?.isTemplate = true
            iconView.image = image
            iconView.contentTintColor = nil
            button.setAccessibilityLabel("Glagol")
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        // По дефолту NSMenu автоматически валидирует кнопки и игнорирует наш
        // ручной isEnabled = false. Отключаем — чтобы наши блокировки работали.
        menu.autoenablesItems = false

        // 1. Главное действие: старт / стоп
        startMenuItem = nil
        if recorder.isRecording {
            menu.addItem(NSMenuItem(
                title: "Остановить (Esc)",
                action: #selector(stopRecording),
                keyEquivalent: ""
            ))
        } else {
            let startItem = NSMenuItem(
                title: "Начать запись",
                action: #selector(startRecording),
                keyEquivalent: ""
            )
            // Запись нельзя начать пока:
            //   • модель не загрузилась
            //   • микрофон не разрешён
            //   • Accessibility не разрешён (иначе нечем будет вставить текст
            //     в активное поле — CGEvent.post молча проигнорится)
            startItem.isEnabled = asrReady
                && !micPermissionDenied
                && hotkey.isAccessibilityGranted
            menu.addItem(startItem)
            startMenuItem = startItem  // weak-ref для in-place isEnabled в открытом меню
        }

        // ASR-статус (между основным действием и Accessibility).
        // Сохраняем weak-ref на NSMenuItem чтобы потом обновлять `.title` или
        // удалять строку in-place (см. `updateLiveASRMenuItems`). Без in-place
        // update прогресс загрузки и переход в «готово» не видны пока меню открыто.
        asrStatusMenuItem = nil
        if !asrReady && asrError == nil {
            let title = asrStatus.map { "\($0)" } ?? "Запускается…"
            let s = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
            asrStatusMenuItem = s
        }
        if let err = asrError {
            menu.addItem(.separator())
            let e = NSMenuItem(title: "ASR-ошибка: \(err)", action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }

        // 2. Микрофон — если permission denied
        if micPermissionDenied {
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: "⚠ Нужен доступ к микрофону",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)

            menu.addItem(NSMenuItem(
                title: "Открыть настройки микрофона…",
                action: #selector(openMicrophoneSettings),
                keyEquivalent: ""
            ))
        }

        // 3. Accessibility — только если permission ещё нет.
        // Это блокирует запись: без Accessibility CGEvent.post() не сработает
        // и Glagol не сможет напечатать распознанный текст в активное поле.
        if !hotkey.isAccessibilityGranted {
            menu.addItem(.separator())
            let header = NSMenuItem(
                title: "⚠ Нужен доступ к Accessibility — без него Glagol не сможет вставить текст в активное поле",
                action: nil,
                keyEquivalent: ""
            )
            header.isEnabled = false
            menu.addItem(header)

            menu.addItem(NSMenuItem(
                title: "Открыть настройки Accessibility…",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            ))
        }

        // 4. Хоткей: подсказка + изменение
        menu.addItem(.separator())
        let hint: String
        if recorder.isRecording {
            hint = "Хоткей: \(hotkey.hotkey.displayName)"
        } else if hotkey.isMonitoring {
            hint = "Хоткей: \(hotkey.hotkey.displayName) — старт"
        } else {
            hint = "Хоткей: \(hotkey.hotkey.displayName) (нужен Accessibility)"
        }
        let hintItem = NSMenuItem(title: hint, action: nil, keyEquivalent: "")
        hintItem.isEnabled = false
        menu.addItem(hintItem)

        menu.addItem(NSMenuItem(
            title: "Изменить хоткей…",
            action: #selector(openHotkeyRecording),
            keyEquivalent: ""
        ))

        // 5. Словарь
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Словарь… (\(hotwords.words.count))",
            action: #selector(openHotwordsSettings),
            keyEquivalent: ""
        ))

        // 5а. Пауза для авто-стопа — подменю с фиксированными опциями.
        // Текущее значение помечено галкой; смена применяется немедленно
        // через provider в AudioRecorder (без рестарта записи).
        let pauseSubmenu = NSMenu()
        // NSMenu по умолчанию `autoenablesItems = true` — AppKit сам валидирует
        // items и ИГНОРИРУЕТ выставленный нами `isEnabled = false`. Выключаем,
        // чтобы наши флаги работали (для пункта пауз это не критично, но
        // держим консистентность с modelSubmenu ниже, где это важно).
        pauseSubmenu.autoenablesItems = false
        for opt in HotwordsStore.silenceTimeoutOptions {
            let item = NSMenuItem(
                title: "\(opt) сек",
                action: #selector(setSilenceTimeout(_:)),
                keyEquivalent: ""
            )
            item.tag = opt
            item.state = (hotwords.silenceTimeoutSec == opt) ? .on : .off
            item.target = self
            pauseSubmenu.addItem(item)
        }
        let pauseHeader = NSMenuItem(
            title: "Пауза до авто-стопа: \(hotwords.silenceTimeoutSec) сек",
            action: nil,
            keyEquivalent: ""
        )
        pauseHeader.submenu = pauseSubmenu
        menu.addItem(pauseHeader)

        // 5б. Модель — submenu с выбором размера. Заблокирован пока модель
        // не загружена, идёт запись, или уже идёт переключение модели
        // (нельзя свапнуть посреди транскрипции; нельзя стартовать второй swap
        // поверх первого — параллельные fromPretrained подерутся за кэш).
        let modelSubmenu = NSMenu()
        // NSMenu по умолчанию `autoenablesItems = true` — AppKit игнорирует
        // ручное `isEnabled = false`. Отключаем, чтобы пункты были серыми
        // во время загрузки/записи (нельзя свапнуть посреди транскрипции).
        modelSubmenu.autoenablesItems = false
        let canSwitchModel = asrReady && !recorder.isRecording
        let currentChoice = ModelChoice(rawValue: hotwords.selectedModel) ?? .default
        for choice in ModelChoice.allCases {
            let item = NSMenuItem(
                title: choice.displayName,
                action: #selector(setModel(_:)),
                keyEquivalent: ""
            )
            item.representedObject = choice.rawValue
            item.state = (choice == currentChoice) ? .on : .off
            item.isEnabled = canSwitchModel
            item.target = self
            modelSubmenu.addItem(item)
        }
        let modelHeader = NSMenuItem(
            title: "Модель: \(currentChoice.displayName)",
            action: nil,
            keyEquivalent: ""
        )
        modelHeader.submenu = modelSubmenu
        menu.addItem(modelHeader)

        // 5в. Справка
        menu.addItem(NSMenuItem(
            title: "Справка…",
            action: #selector(openHelp),
            keyEquivalent: ""
        ))

        // 6. Ошибка recorder (если была)
        if let error = recorder.lastError {
            menu.addItem(.separator())
            let errorItem = NSMenuItem(
                title: "Ошибка: \(error)",
                action: nil,
                keyEquivalent: ""
            )
            errorItem.isEnabled = false
            menu.addItem(errorItem)
        }

        // 7. Выход
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Выход",
            action: #selector(quit),
            keyEquivalent: "q"
        ))

        for item in menu.items where item.action != nil && item.target == nil {
            item.target = self
        }

        // Если идёт first-launch tour и юзер кликнул на иконку — `menuWillOpen` это
        // зафиксирует и закроет панель. Цель туриста (показать «вот здесь!») достигнута,
        // больше не нужна.
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Hotkey recording panel

    @objc private func openHotkeyRecording() {
        if let existing = hotkeyRecordingPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Активный titled-panel (без .nonactivatingPanel) — иначе SwiftUI
        // `.keyboardShortcut(.cancelAction)` на кнопке «Отмена» не сработает,
        // потому что panel не становится key window.
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Изменить хоткей"
        panel.center()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let view = HotkeyRecordingView(
            currentDisplayName: hotkey.hotkey.displayName,
            onCancel: { [weak self] in
                self?.cancelHotkeyRecording()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        hotkeyRecordingPanel = panel

        hotkey.startRecordingHotkey()
    }

    private func cancelHotkeyRecording() {
        hotkey.cancelRecordingHotkey()
        closeHotkeyRecording()
    }

    private func closeHotkeyRecording() {
        guard let panel = hotkeyRecordingPanel else { return }
        panel.close()
        hotkeyRecordingPanel = nil
    }

    // MARK: - Hotwords settings panel

    @objc private func openHotwordsSettings() {
        if let existing = hotwordsPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Словарь"
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 380, height: 360)

        let view = HotwordsSettingsView(store: hotwords)
        panel.contentView = NSHostingView(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        hotwordsPanel = panel
    }

    // MARK: - Menu actions

    @objc private func startRecording() {
        startRecordingFlow()
    }

    @objc private func stopRecording() {
        stopRecordingFlow()
    }

    @objc private func openAccessibilitySettings() {
        hotkey.openAccessibilitySettings()
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() {
        // applicationWillTerminate сделает полный teardown; terminate триггерит его
        // синхронно перед фактическим выходом процесса.
        NSApplication.shared.terminate(nil)
    }

    @objc private func setSilenceTimeout(_ sender: NSMenuItem) {
        let new = sender.tag
        guard HotwordsStore.silenceTimeoutOptions.contains(new) else { return }
        hotwords.silenceTimeoutSec = new
        rebuildMenu()  // обновить заголовок подменю и галки
    }

    @objc private func setModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = ModelChoice(rawValue: raw) else { return }
        guard raw != hotwords.selectedModel else { return }
        // Нельзя свапнуть посреди записи (меню это и так disabled'ит, но юзер
        // мог успеть кликнуть до перерисовки).
        guard !recorder.isRecording else { return }

        hotwords.selectedModel = raw
        switchEngine(to: choice)
    }

    // MARK: - First-launch tour

    /// Показывает стрелку-подсказку под menubar-иконкой при первом запуске.
    /// Закрывается кнопкой «Понял» или автоматически через 25 секунд.
    private func showFirstLaunchTour() {
        guard firstLaunchTourPanel == nil else { return }

        let panelWidth: CGFloat = 320
        let panelHeight: CGFloat = 170

        // Позиционируем под menubar-иконкой если её окно доступно. Если не доступно
        // (timing issue) — fallback в верхний правый угол экрана (там обычно и стоит
        // статус-итем). Главное — попасть в visibleFrame активного экрана.
        guard let screen = statusItem.button?.window?.screen ?? NSScreen.main else {
            hotwords.didShowFirstLaunchTour = true
            return
        }
        let visible = screen.visibleFrame
        let panelX: CGFloat
        let panelY: CGFloat

        if let buttonFrame = statusItem.button?.window?.frame {
            // Центрируем по X относительно иконки, по Y — сразу под menubar.
            // Поджимаем X в границы visibleFrame, если иконка близко к правому краю.
            let rawX = buttonFrame.midX - panelWidth / 2
            panelX = min(max(rawX, visible.minX + 8), visible.maxX - panelWidth - 8)
            panelY = buttonFrame.minY - panelHeight - 12
        } else {
            // Fallback — правый-верхний угол.
            panelX = visible.maxX - panelWidth - 20
            panelY = visible.maxY - panelHeight - 12
        }

        // Простая видимая панель — БЕЗ .nonactivatingPanel и .clear background.
        // Прошлая версия могла оказаться невидимой из-за transparent background
        // + SwiftUI-фон, который не всегда заполняет всю площадь панели.
        let panel = NSPanel(
            contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: panelHeight),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Glagol запущен"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Для LSUIElement-app окна по умолчанию не привязаны к активному Space —
        // Window Server отмечает их `isOnscreen=false`. canJoinAllSpaces заставляет
        // окно появляться на любом текущем Space пользователя; fullScreenAuxiliary
        // даёт показ поверх full-screen приложений.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false

        let view = FirstLaunchTourView(
            onDismiss: { [weak self] in
                self?.dismissFirstLaunchTour()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Strong-arm: иногда LSUIElement-приложения не могут вытащить окно вперёд
        // через обычный orderFront. orderFrontRegardless игнорирует app-activation.
        panel.orderFrontRegardless()
        firstLaunchTourPanel = panel

        // Автозакрытие через 25 секунд, если пользователь не закрыл сам.
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
            self?.dismissFirstLaunchTour()
        }
    }

    private func dismissFirstLaunchTour() {
        guard let panel = firstLaunchTourPanel else { return }
        panel.close()
        firstLaunchTourPanel = nil
        hotwords.didShowFirstLaunchTour = true
    }

    // MARK: - Help panel

    @objc private func openHelp() {
        if let existing = helpPanel {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "О Glagol"
        panel.center()
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 420, height: 480)

        let view = HelpView(
            currentHotkey: hotkey.hotkey.displayName,
            onOpenAccessibilitySettings: { [weak self] in
                self?.hotkey.openAccessibilitySettings()
            },
            onOpenMicrophoneSettings: { [weak self] in
                self?.openMicrophoneSettings()
            }
        )
        panel.contentView = NSHostingView(rootView: view)

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        helpPanel = panel
    }
}

extension AppDelegate: NSMenuDelegate {
    /// Срабатывает когда юзер кликает на menubar-иконку и наша menu раскрывается.
    /// Используем это как сигнал «пользователь нашёл иконку» и закрываем first-launch tour.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
        if firstLaunchTourPanel != nil {
            dismissFirstLaunchTour()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        // Пока меню было открыто, мы обновляли только живые итемы. Пересобираем
        // в закрытом состоянии, чтобы следующее открытие имело свежую структуру.
        rebuildMenu()
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel else { return }
        if window === hotkeyRecordingPanel {
            hotkey.cancelRecordingHotkey()
            hotkeyRecordingPanel = nil
        } else if window === hotwordsPanel {
            hotwordsPanel = nil
            rebuildMenu()  // обновить счётчик слов в пункте меню
        } else if window === firstLaunchTourPanel {
            firstLaunchTourPanel = nil
            // Сам факт закрытия (любым способом) — значит tour показан.
            hotwords.didShowFirstLaunchTour = true
        } else if window === helpPanel {
            helpPanel = nil
        }
    }
}

/// Подсказка-приветствие первого запуска. Стрелка ↑ указывает на menubar,
/// над ней — короткий текст «Glagol живёт здесь». Кнопка «Понял» закрывает
/// панель и помечает tour как показанный.
private struct FirstLaunchTourView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "arrow.up")
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce.up, options: .repeating)

            Text("Glagol живёт в верхнем меню")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("Нажми иконку-волну в строке меню,\nчтобы открыть настройки и начать запись.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Понял", action: onDismiss)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Окно «Справка / О Glagol». Краткое описание возможностей и подробное
/// объяснение что зачем разрешать (микрофон, Accessibility).
private struct HelpView: View {
    let currentHotkey: String
    let onOpenAccessibilitySettings: () -> Void
    let onOpenMicrophoneSettings: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                section(
                    title: "Что это",
                    icon: "waveform",
                    bullets: [
                        "Голосовой ввод для macOS. Жмёшь хоткей — говоришь — текст появляется прямо в активном поле ввода (любое приложение).",
                        "Распознавание полностью на устройстве. Сама речь и распознанный текст с устройства никуда не уходят.",
                        "Модель — Qwen3-ASR 1.7B (multilingual, code-switching ru↔en). Запускается через MLX на Apple Silicon (Neural Engine + GPU).",
                    ]
                )

                section(
                    title: "Как пользоваться",
                    icon: "hand.tap",
                    bullets: [
                        "Поставь курсор в нужное поле (любой текстовый редактор, Telegram, браузер).",
                        "Нажми хоткей \"\(currentHotkey)\" — иконка в menubar станет красной.",
                        "Говори. Текст печатается по мере распознавания.",
                        "Нажми хоткей ещё раз или Esc, или сделай длинную паузу — запись остановится.",
                    ]
                )

                section(
                    title: "Настройки",
                    icon: "slider.horizontal.3",
                    bullets: [
                        "Изменить хоткей — menubar → \"Изменить хоткей…\".",
                        "Словарь — menubar → \"Словарь…\". Опционально: добавь сюда специфичные термины (продукты, имена, склонения), если модель их путает. Передаются как контекст-prompt декодеру.",
                        "Пауза до авто-стопа — menubar → \"Пауза до авто-стопа\". По умолчанию 7 сек тишины завершают запись.",
                    ]
                )

                permissionsSection
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Glagol")
                .font(.largeTitle.bold())
            Text("Голосовой ввод для macOS")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private func section(title: String, icon: String, bullets: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.title2.bold())
            }
            ForEach(bullets, id: \.self) { bullet in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(bullet)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.callout)
            }
        }
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(.tint)
                Text("Разрешения")
                    .font(.title2.bold())
            }

            permissionRow(
                icon: "mic",
                title: "Микрофон",
                description: "Чтобы записывать твою речь и распознавать её локально. Аудио не покидает устройство.",
                actionLabel: "Открыть настройки",
                action: onOpenMicrophoneSettings
            )

            permissionRow(
                icon: "accessibility",
                title: "Accessibility",
                description: "Чтобы ловить глобальный хоткей (когда фокус в другом приложении) и эмулировать набор текста в активное поле. Без этого Glagol не сможет ни услышать хоткей, ни напечатать результат.",
                actionLabel: "Открыть настройки",
                action: onOpenAccessibilitySettings
            )

            Text("Никакие другие разрешения не запрашиваются.\n\nПри первом запуске модель (~1.6 ГБ) скачивается из HuggingFace в кэш приложения. Дальше работа полностью офлайн — речь не покидает устройство.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func permissionRow(
        icon: String,
        title: String,
        description: String,
        actionLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 18)
                Text(title)
                    .font(.callout.bold())
                Spacer()
                Button(actionLabel, action: action)
                    .controlSize(.small)
            }
            Text(description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct HotkeyRecordingView: View {
    let currentDisplayName: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)

            Text("Нажмите ваш хоткей")
                .font(.headline)

            VStack(spacing: 4) {
                Text("• Сочетание (например, ⌘⇧Space или F5)")
                Text("• Или дважды нажмите модификатор (⌃, ⌘, ⌥, ⇧)")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

            Text("Сейчас: \(currentDisplayName)")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)

            HStack {
                Spacer()
                Button("Отмена (Esc)", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
