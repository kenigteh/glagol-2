import Foundation
import OSLog

private let gigaLog = Logger(subsystem: "com.sakovskii.glagol", category: "gigaam")

/// Batch-адаптер `BatchASR` поверх sherpa-onnx + GigaAM v3 RNN-T (Сбер).
///
/// **Архитектура:** `AudioRecorder` копит аудио до stop'а, затем целиком
/// передаёт сюда. Используем `SherpaOnnxOfflineRecognizer.decode(samples:)` —
/// offline (batch) распознавание: подаём весь буфер, получаем текст. Без
/// streaming-стейта, ровно семантика `BatchASR`.
///
/// **Модель:** GigaAM v3 e2e_rnnt с встроенной пунктуацией И капитализацией
/// (`csukuangfj/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16`,
/// предварительно пропатченная — metadata скопирована в decoder/joiner для
/// совместимости с sherpa-onnx v1.13). ~220 МБ. Топ качество русского.
///
/// **Только русский** — нет code-switching. Английские термины транслитерирует
/// в кириллицу. Для IT-речи с английскими словами лучше Qwen.
///
/// **Производительность:** ~0.3с на 20с аудио (RNN-T легче Qwen-LLM).
final class GigaAMSherpaASR: BatchASR {

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

    /// Папка с файлами модели в кэше:
    /// `~/Library/Caches/glagol/gigaam-v3/{encoder.int8,decoder,joiner}.onnx + tokens.txt`
    private static func modelDir() -> URL? {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return caches?
            .appendingPathComponent("glagol/gigaam-v3", isDirectory: true)
    }

    /// Файлы, которые должны лежать в `modelDir` чтобы модель загрузилась.
    private static let requiredFiles = ["encoder.int8.onnx", "decoder.onnx", "joiner.onnx", "tokens.txt"]

    /// HuggingFace base для скачивания (модель уже пропатчена и захостена как
    /// release-asset glagol-2; см. `modelDownloadBase`).
    private let modelDownloadBase: String

    // MARK: - Очередь

    /// Серийная очередь — recognizer не thread-safe, сериализуем доступ.
    private let workQueue = DispatchQueue(label: "glagol.gigaam.work", qos: .userInitiated)

    // MARK: - Состояние

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var shuttingDown: Bool = false

    init(modelDownloadBase: String) {
        self.modelDownloadBase = modelDownloadBase
    }

    // MARK: - BatchASR

    func warmUp() {
        emitStatus("Загрузка модели…")
        gigaLog.notice("[GigaAM] warmUp start")
        Task.detached { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureModelDownloaded()
            } catch {
                gigaLog.error("[GigaAM] model download FAILED: \(error.localizedDescription, privacy: .public)")
                self.emitError("Не удалось скачать модель GigaAM: \(error.localizedDescription)")
                return
            }

            self.workQueue.async { [weak self] in
                guard let self, !self.shuttingDown else { return }
                guard let dir = Self.modelDir() else {
                    self.emitError("Не найден каталог кэша")
                    return
                }
                self.emitStatus("Почти готово…")
                let t0 = Date()
                let rec = Self.makeRecognizer(modelDir: dir)
                gigaLog.notice("[GigaAM] recognizer created in \(Date().timeIntervalSince(t0), privacy: .public)s")
                self.recognizer = rec
                DispatchQueue.main.async { [weak self] in
                    self?.isReady = true
                }
            }
        }
    }

    /// Создаёт offline transducer recognizer для GigaAM v3.
    private static func makeRecognizer(modelDir: URL) -> SherpaOnnxOfflineRecognizer {
        let encoder = modelDir.appendingPathComponent("encoder.int8.onnx").path
        let decoder = modelDir.appendingPathComponent("decoder.onnx").path
        let joiner = modelDir.appendingPathComponent("joiner.onnx").path
        let tokens = modelDir.appendingPathComponent("tokens.txt").path

        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: encoder, decoder: decoder, joiner: joiner
        )
        // GigaAM фичи: 16kHz, 80 mel bins (стандарт NeMo Conformer).
        let feat = sherpaOnnxFeatureConfig(sampleRate: sampleRate, featureDim: 80)
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokens,
            transducer: transducer,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            modelType: "nemo_transducer"
        )
        var recConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: feat,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )
        return SherpaOnnxOfflineRecognizer(config: &recConfig)
    }

    func transcribe(audio: [Float]) async throws -> String {
        let durationSec = Double(audio.count) / Double(Self.sampleRate)
        gigaLog.notice("[GigaAM] transcribe start: \(audio.count, privacy: .public) samples (\(durationSec, privacy: .public)s)")
        let inputAudio = audio

        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: "")
                    return
                }
                guard let rec = self.recognizer else {
                    continuation.resume(throwing: GigaAMError.modelNotLoaded)
                    return
                }
                guard !self.shuttingDown else {
                    continuation.resume(returning: "")
                    return
                }

                let t0 = Date()
                let result = rec.decode(samples: inputAudio, sampleRate: Self.sampleRate)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let took = Date().timeIntervalSince(t0)
                gigaLog.notice("[GigaAM] transcribe done in \(took, privacy: .public)s → '\(text, privacy: .public)'")
                continuation.resume(returning: text)
            }
        }
    }

    func shutdown() {
        workQueue.async { [weak self] in
            guard let self else { return }
            self.shuttingDown = true
            self.recognizer = nil
        }
    }

    // MARK: - Загрузка модели

    /// Примерные размеры файлов (байты) — для общего процента загрузки.
    /// encoder доминирует (~97%), так что общий % почти линеен по нему.
    private static let fileSizes: [String: Int64] = [
        "encoder.int8.onnx": 224_570_839,
        "decoder.onnx": 4_600_132,
        "joiner.onnx": 2_712_896,
        "tokens.txt": 13_354,
    ]

    /// Проверяет наличие всех файлов модели в кэше; если чего-то нет — скачивает
    /// с прогрессом (общий процент по всем файлам, без имён файлов в UI).
    private func ensureModelDownloaded() async throws {
        guard let dir = Self.modelDir() else { throw GigaAMError.cacheUnavailable }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let missing = Self.requiredFiles.filter {
            !FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        guard !missing.isEmpty else {
            gigaLog.notice("[GigaAM] model already cached")
            return
        }

        let totalBytes = missing.reduce(Int64(0)) { $0 + (Self.fileSizes[$1] ?? 0) }
        var completedBytes: Int64 = 0
        gigaLog.notice("[GigaAM] downloading \(missing.count, privacy: .public) files, ~\(totalBytes / 1024 / 1024, privacy: .public)MB…")
        emitStatus("Загрузка GigaAM: 0%")

        for file in missing {
            let fileSize = Self.fileSizes[file] ?? 0
            let url = URL(string: "\(modelDownloadBase)/\(file)")!
            let dst = dir.appendingPathComponent(file)
            let base = completedBytes

            try await ModelDownloader.download(from: url, to: dst) { [weak self] fileFraction in
                // Общий процент: завершённые файлы + доля текущего.
                let overall = totalBytes > 0
                    ? Double(base + Int64(fileFraction * Double(fileSize))) / Double(totalBytes)
                    : 0
                self?.emitStatus("Загрузка GigaAM: \(Int(overall * 100))%")
            }
            completedBytes += fileSize
            gigaLog.notice("[GigaAM] downloaded \(file, privacy: .public)")
        }
        // НЕ показываем «100%»: байты скачаны, но recognizer ещё создаётся
        // (грузится ONNX). «100%» читался бы как «ещё обрабатывается». Дальше
        // warmUp эмитит «Почти готово…», а по факту готовности — «готово ✓».
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

/// Загрузка файла с побайтовым прогрессом через URLSessionDownloadDelegate.
/// `URLSession.shared.download(from:)` не даёт прогресса — статус висел бы без
/// движения весь долгий encoder (~220 МБ), выглядя зависшим.
private final class ModelDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: (Double) -> Void
    private var continuation: CheckedContinuation<Void, Error>?

    private init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func download(from url: URL, to dst: URL, onProgress: @escaping (Double) -> Void) async throws {
        let downloader = ModelDownloader(destination: dst, onProgress: onProgress)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            downloader.continuation = cont
            let session = URLSession(configuration: .default, delegate: downloader, delegateQueue: nil)
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // location — временный файл, удаляется после возврата метода. Копируем
        // СИНХРОННО здесь же.
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                continuation?.resume(throwing: GigaAMError.downloadFailed(destination.lastPathComponent))
                continuation = nil
                session.invalidateAndCancel()
                return
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            continuation?.resume()
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Сетевая ошибка (нет didFinishDownloadingTo).
        if let error, continuation != nil {
            continuation?.resume(throwing: error)
            continuation = nil
        }
        session.invalidateAndCancel()
    }
}

enum GigaAMError: Error, LocalizedError {
    case modelNotLoaded
    case cacheUnavailable
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded: return "GigaAM модель ещё не загружена"
        case .cacheUnavailable: return "Каталог кэша недоступен"
        case .downloadFailed(let f): return "Не удалось скачать \(f)"
        }
    }
}
