import Foundation
import OSLog
// speech-swift (SPM): https://github.com/soniqo/speech-swift
// `@preconcurrency` глушит Swift 6 Sendable-варнинги на `Qwen3ASRModel`.
@preconcurrency import Qwen3ASR
// MLX (транзитивная зависимость speech-swift, добавлена явным product'ом).
// Нужна для GPU.clearCache() — освобождения накопленного GPU-кэша.
import MLX

private let qwenLog = Logger(subsystem: "com.sakovskii.glagol", category: "qwen-asr")

/// Batch-адаптер `BatchASR` поверх Qwen3-ASR через speech-swift (MLX).
///
/// **Архитектура:** `AudioRecorder` копит аудио до stop'а, затем целиком
/// передаёт сюда. Мы дёргаем `Qwen3ASRModel.transcribe(audio:)` один раз
/// и возвращаем результат. Без VAD, без segmentation, без streaming.
///
/// **Производительность (M-серия Apple Silicon, warm-up'нутая модель):**
///   - 5с аудио → ~0.2с
///   - 20с аудио → ~0.6с
///   - 60с аудио → ~2с (almost linear)
///
/// **Cold-start модели:** ~6-7с с диска (1.7B), 2-3с (0.6B). После warmUp()
/// модель остаётся в памяти на всё время работы приложения.
///
/// **Контекст-prompt (hotwords):** speech-swift кладёт переданную строку
/// в system message Qwen-chat-template'а. Биасит модель к сохранению
/// специфичных терминов в исходном написании (Cursor, Kubernetes, etc.)
/// **Промпт держим коротким и на языке выходного текста** — длинные/
/// иноязычные промпты могут утекать в результат (LLM-decoder hallucination).
final class QwenASR: BatchASR {

    // MARK: - BatchASR surface

    var onError: ((String) -> Void)?
    var onReadyChange: ((Bool) -> Void)?
    var onStatus: ((String) -> Void)?

    private(set) var isReady: Bool = false {
        didSet {
            guard isReady != oldValue else { return }
            dispatchPrecondition(condition: .onQueue(.main))
            onReadyChange?(isReady)
        }
    }

    // MARK: - Параметры

    private static let sampleRate: Int = 16_000

    /// HuggingFace repo id Qwen3-ASR.
    /// `mlx-community/Qwen3-ASR-1.7B-4bit` — наш дефолт (1.6 ГБ, multilingual).
    /// Альтернатива: `aufklarer/Qwen3-ASR-0.6B-MLX-4bit` (700 МБ, быстрее).
    private(set) var modelId: String

    // MARK: - Очередь

    /// Серийная очередь для всех вызовов модели. Qwen3ASRModel — НЕ
    /// thread-safe (см. предупреждение в speech-swift), поэтому
    /// сериализуем доступ.
    private let workQueue = DispatchQueue(label: "glagol.qwen.work", qos: .userInitiated)

    // MARK: - Состояние

    private var model: Qwen3ASRModel?
    private var shuttingDown: Bool = false

    // MARK: - Зависимости

    /// Provider контекста-промпта. Вызывается из main thread перед каждым
    /// transcribe — это позволяет хотвордам обновляться без рестарта.
    private let contextProvider: () -> String

    init(
        modelId: String = "mlx-community/Qwen3-ASR-1.7B-4bit",
        contextProvider: @escaping () -> String
    ) {
        self.modelId = modelId
        self.contextProvider = contextProvider
    }

    // MARK: - BatchASR

    func warmUp() {
        emitStatus("Загрузка модели…")
        qwenLog.notice("[Qwen] warmUp start, model=\(self.modelId, privacy: .public)")
        Task {
            do {
                let t0 = Date()
                let m = try await Qwen3ASRModel.fromPretrained(
                    modelId: modelId,
                    progressHandler: { [weak self] fraction, status in
                        let pct = Int(fraction * 100)
                        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
                        let msg = trimmed.isEmpty
                            ? "Загрузка модели: \(pct)%"
                            : "Загрузка модели: \(pct)% — \(trimmed)"
                        self?.emitStatus(msg)
                    }
                )
                let took = Date().timeIntervalSince(t0)
                qwenLog.notice("[Qwen] fromPretrained ok in \(took, privacy: .public)s")
                self.workQueue.async { [weak self] in
                    guard let self, !self.shuttingDown else { return }
                    self.model = m
                    DispatchQueue.main.async { [weak self] in
                        self?.isReady = true
                    }
                }
            } catch {
                qwenLog.error("[Qwen] fromPretrained FAILED: \(error.localizedDescription, privacy: .public)")
                self.emitError("Не удалось загрузить модель: \(error.localizedDescription)")
            }
        }
    }

    /// Маркер активного swap. Защищает от race'а быстрых кликов по моделям.
    @MainActor private(set) var isSwapInProgress: Bool = false

    /// Сменить активную модель.
    /// Caller должен убедиться что запись/transcribe НЕ идёт.
    @MainActor
    func swapModel(to newModelId: String) {
        let oldModelId = self.modelId
        guard newModelId != oldModelId else { return }
        guard !isSwapInProgress else {
            qwenLog.notice("[Qwen] swap already in progress, ignoring → \(newModelId, privacy: .public)")
            return
        }

        isSwapInProgress = true
        isReady = false
        emitStatus("Переключаю модель…")
        qwenLog.notice("[Qwen] swapModel \(oldModelId, privacy: .public) → \(newModelId, privacy: .public)")

        workQueue.async { [weak self] in
            guard let self else { return }
            self.model = nil
        }

        Self.deleteModelFromCache(modelId: oldModelId)
        self.modelId = newModelId

        Task {
            do {
                let t0 = Date()
                let m = try await Qwen3ASRModel.fromPretrained(
                    modelId: newModelId,
                    progressHandler: { [weak self] fraction, status in
                        let pct = Int(fraction * 100)
                        let trimmed = status.trimmingCharacters(in: .whitespacesAndNewlines)
                        let msg = trimmed.isEmpty
                            ? "Загрузка модели: \(pct)%"
                            : "Загрузка модели: \(pct)% — \(trimmed)"
                        self?.emitStatus(msg)
                    }
                )
                qwenLog.notice("[Qwen] swap fromPretrained ok in \(Date().timeIntervalSince(t0), privacy: .public)s")
                self.workQueue.async { [weak self] in
                    guard let self, !self.shuttingDown else { return }
                    self.model = m
                    DispatchQueue.main.async { [weak self] in
                        self?.isSwapInProgress = false
                        self?.isReady = true
                    }
                }
            } catch {
                qwenLog.error("[Qwen] swap fromPretrained FAILED: \(error.localizedDescription, privacy: .public)")
                await MainActor.run { [weak self] in
                    self?.isSwapInProgress = false
                }
                self.emitError("Не удалось загрузить модель: \(error.localizedDescription)")
            }
        }
    }

    /// Полный путь к папке с весами модели (для удаления при swapModel).
    /// speech-swift дефолт: `~/Library/Caches/qwen3-speech/models/<modelId>/`
    private static func cachedModelPath(for modelId: String) -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return caches?
            .appendingPathComponent("qwen3-speech/models", isDirectory: true)
            .appendingPathComponent(modelId, isDirectory: true)
    }

    private static func deleteModelFromCache(modelId: String) {
        guard let modelDir = cachedModelPath(for: modelId) else { return }
        guard FileManager.default.fileExists(atPath: modelDir.path) else { return }
        do {
            try FileManager.default.removeItem(at: modelDir)
            qwenLog.notice("[Qwen] removed cache: \(modelDir.path, privacy: .public)")
        } catch {
            qwenLog.error("[Qwen] failed to remove cache: \(error.localizedDescription, privacy: .public)")
        }
    }

    func transcribe(audio: [Float]) async throws -> String {
        // Снэпшот контекста на main thread (HotwordsStore — @MainActor).
        let context = await MainActor.run { contextProvider() }
        qwenLog.notice("[Qwen] transcribe start: \(audio.count, privacy: .public) samples (\(Double(audio.count) / 16000.0, privacy: .public)s), context=\"\(context, privacy: .public)\"")

        let inputAudio = audio
        let ctxParam = context.isEmpty ? nil : context

        // **maxTokens — критично для длинных диктовок.** Дефолт speech-swift
        // = 448 токенов: декодер останавливается на 448-м токене, обрезая
        // длинный текст. Считаем потолок из длины аудио.
        //
        // Коэффициент 10 ток/сек — эмпирический: замер реальным Qwen-токенайзером
        // на ОЧЕНЬ быстрой диктовке (222 слова/мин, русский литературный — самый
        // токеноёмкий, 2.17 ток/слово) дал 8.0 ток/сек. +25% запас = 10.
        // Минимум 512 — для коротких записей. Декодер всё равно остановится на
        // <eos> раньше для реальной речи (потолок не замедляет короткие записи),
        // а на runaway-loop ограничивает генерацию пропорционально длине.
        let durationSec = Double(audio.count) / Double(Self.sampleRate)
        let maxTokens = max(512, Int(durationSec * 10.0))

        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: "")
                    return
                }
                guard let model = self.model else {
                    continuation.resume(throwing: QwenASRError.modelNotLoaded)
                    return
                }
                guard !self.shuttingDown else {
                    continuation.resume(returning: "")
                    return
                }

                let t0 = Date()
                let text = model.transcribe(
                    audio: inputAudio,
                    sampleRate: Self.sampleRate,
                    language: nil,
                    maxTokens: maxTokens,
                    context: ctxParam
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let took = Date().timeIntervalSince(t0)

                // **Освобождаем накопленный GPU-кэш MLX.** Без этого MLX держит
                // переиспользуемые Metal-буферы всех встреченных размеров записей
                // (cacheMemory) — за часы работы они раздувались до десятков ГБ,
                // выдавливая систему в swap и роняя скорость в десятки раз.
                // clearCache() сбрасывает только cacheMemory; веса модели
                // (activeMemory) не трогаются. Между transcribe-вызовами кэш не
                // нужен, так что очистка безопасна и не замедляет inference.
                let cacheBefore = MLX.GPU.cacheMemory
                MLX.GPU.clearCache()
                qwenLog.notice("[Qwen] transcribe done in \(took, privacy: .public)s, cleared GPU cache \(cacheBefore / 1024 / 1024, privacy: .public)MB → '\(text, privacy: .public)'")
                continuation.resume(returning: text)
            }
        }
    }

    func shutdown() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.shuttingDown = true
            self.model = nil
        }
    }

    // MARK: - Helpers

    private func emitStatus(_ msg: String) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(msg) }
    }

    private func emitError(_ msg: String) {
        let cb = onError
        DispatchQueue.main.async { cb?(msg) }
    }
}

enum QwenASRError: Error, LocalizedError {
    case modelNotLoaded

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Qwen3-ASR модель ещё не загружена"
        }
    }
}
