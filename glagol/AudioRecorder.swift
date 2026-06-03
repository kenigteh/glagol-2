import Foundation
@preconcurrency import AVFoundation
import Combine
import OSLog

private let recLog = Logger(subsystem: "com.sakovskii.glagol", category: "recorder")

/// VAD-порог RMS для определения тишины (нормализованный диапазон [-1, 1]).
/// Используется для авто-стопа по продолжительной тишине.
enum VADConstants {
    static let rmsThreshold: Float = 0.008
}

/// Запись с микрофона через AVAudioEngine. 16 kHz mono Float32 — копится в
/// памяти до `stop()`. После остановки `capturedAudio` возвращает массив
/// сэмплов готовый для batch-транскрипции.
///
/// **На диск ничего не пишется** — диктовка не нуждается в архиве.
///
/// **VAD auto-stop:** если RMS аудио держится ниже `VADConstants.rmsThreshold`
/// дольше `silenceTimeoutProvider()` секунд — запись автостопится. Это даёт
/// классическую диктовка-фишку «замолчал → транскрипция началась».
///
/// **Потоковая модель:**
/// - `start()`/`stop()`/`toggle()` вызываются с main thread.
/// - `installTap`-callback приходит с приватного аудио-потока AVAudioEngine.
/// - `capturedSamples` защищён `samplesLock` — пишется с audio thread, читается
///   с main после stop.
final class AudioRecorder: ObservableObject {
    @Published var isRecording = false
    /// `true` когда железо РЕАЛЬНО выдало первый аудио-буфер (через ~200-275мс
    /// после `start()` — раскрутка микрофона). UI показывает иконку «слушаю»
    /// именно по этому флагу, а не по `isRecording`, чтобы юзер начинал
    /// говорить когда запись реально идёт (иначе первые слова теряются).
    @Published var isCapturing = false
    @Published var lastError: String?

    private let engine = AVAudioEngine()
    private let workQueue = DispatchQueue(label: "glagol.audio", qos: .userInitiated)

    /// Накопленные сэмплы текущей записи (16 kHz mono Float32). Пишется с
    /// audio thread через `samplesLock`, читается с main через `capturedAudio`.
    private var capturedSamples: [Float] = []
    private let samplesLock = NSLock()

    // Silence-detection (auto-stop по тишине).
    private let silenceTracker = SilenceTracker()
    /// Provider — closure читает АКТУАЛЬНОЕ значение из user-settings на каждый
    /// чанк. Смена через menubar немедленно действует, без рестарта записи.
    private let silenceTimeoutProvider: () -> TimeInterval

    private static let inputTapBufferSize: AVAudioFrameCount = 4096
    /// Лимит длины записи — защита от утечки памяти если юзер забыл стоп.
    /// 5 минут × 16000 Hz × 4 байта = 19 МБ — приемлемо.
    private static let maxRecordingSec: Double = 300.0

    /// Инструментация задержки старта: момент вызова `start()` и флаг что
    /// первый буфер ещё не пришёл (чтобы залогировать разовую задержку).
    private var startRequestedAt: Date?
    private var awaitingFirstBuffer: Bool = false

    init(silenceTimeoutProvider: @escaping () -> TimeInterval = { 7.0 }) {
        self.silenceTimeoutProvider = silenceTimeoutProvider
        // ВНИМАНИЕ: engine.prepare() здесь НЕЛЬЗЯ — на пустом графе (inputNode
        // ещё не материализован, нет tap'а) AVAudioEngine крашится с
        // "inputNode != nullptr || outputNode != nullptr". prepare() вызываем
        // в startInternal после installTap, когда граф настроен.
    }

    /// Сэмплы текущей записи (после `stop()`). Возвращает копию — caller
    /// может свободно работать.
    var capturedAudio: [Float] {
        samplesLock.lock(); defer { samplesLock.unlock() }
        return capturedSamples
    }

    /// Длительность текущей записи в секундах. Удобно для UI.
    var capturedDurationSec: Double {
        samplesLock.lock(); defer { samplesLock.unlock() }
        return Double(capturedSamples.count) / 16_000.0
    }

    func start() {
        guard !isRecording else { return }
        lastError = nil
        isRecording = true   // оптимистично — UI не ждёт инициализации
        isCapturing = false  // станет true когда придёт первый реальный буфер
        startRequestedAt = Date()
        awaitingFirstBuffer = true

        samplesLock.lock()
        capturedSamples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        workQueue.async { [weak self] in
            self?.startInternal()
        }
    }

    func stop() {
        guard isRecording else { return }
        isRecording = false  // UI сразу реагирует
        isCapturing = false

        workQueue.async { [weak self] in
            self?.stopInternal()
        }
    }

    func toggle() {
        if isRecording { stop() } else { start() }
    }

    // MARK: - Internals (workQueue / audio thread)

    private func startInternal() {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            failOnMain("Не удалось создать целевой формат")
            return
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            failOnMain("Не удалось создать конвертер аудио")
            return
        }

        silenceTracker.reset()

        input.installTap(onBus: 0, bufferSize: Self.inputTapBufferSize, format: inputFormat) {
            [weak self] buffer, _ in
            self?.handle(buffer: buffer, converter: converter, targetFormat: targetFormat)
        }

        // prepare() с уже установленным tap'ом — граф валиден, preallocate
        // ресурсы перед start() для ускорения cold-start аудио-железа.
        engine.prepare()

        do {
            let t0 = Date()
            try engine.start()
            recLog.notice("[Rec] engine.start() returned in \(Date().timeIntervalSince(t0) * 1000, privacy: .public)ms")
        } catch {
            input.removeTap(onBus: 0)
            failOnMain("Не удалось запустить движок: \(error.localizedDescription)")
        }
    }

    private func stopInternal() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // НЕ вызываем engine.reset(): он сбрасывает граф в холодное состояние,
        // из-за чего следующий engine.start() снова раскручивает аудио-железо
        // с нуля (~сотни мс → потеря первых слов). Просто stop без reset
        // оставляет граф теплее. prepare() здесь НЕ вызываем — после removeTap
        // граф может быть невалиден (краш как в init); prepare идёт в
        // startInternal с уже установленным tap'ом.
        silenceTracker.reset()
    }

    private func handle(
        buffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio))
        guard let outBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else { return }

        // Первый реальный буфер = железо раскрутилось, запись пошла.
        // Выставляем isCapturing на main → UI меняет иконку на «слушаю»,
        // юзер начинает говорить когда запись уже идёт.
        if awaitingFirstBuffer, let t0 = startRequestedAt {
            awaitingFirstBuffer = false
            recLog.notice("[Rec] first audio buffer \(Date().timeIntervalSince(t0) * 1000, privacy: .public)ms after start()")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isRecording else { return }
                self.isCapturing = true
            }
        }

        let state = ConversionState(input: buffer)
        var error: NSError?
        converter.convert(to: outBuffer, error: &error) { _, statusPtr in
            if state.consumed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            state.consumed = true
            statusPtr.pointee = .haveData
            return state.input
        }

        let frameLength = Int(outBuffer.frameLength)
        guard frameLength > 0, let floatData = outBuffer.floatChannelData?[0] else { return }

        // Накапливаем сэмплы.
        var sumSquares: Float = 0
        var newSamples = [Float](repeating: 0, count: frameLength)
        for i in 0..<frameLength {
            let s = floatData[i]
            newSamples[i] = s
            sumSquares += s * s
        }
        let rms = sqrt(sumSquares / Float(frameLength))

        samplesLock.lock()
        capturedSamples.append(contentsOf: newSamples)
        let totalCount = capturedSamples.count
        samplesLock.unlock()

        // Защита от утечки памяти: автостоп при превышении max длительности.
        if Double(totalCount) / 16_000.0 >= Self.maxRecordingSec {
            DispatchQueue.main.async { [weak self] in self?.stop() }
            return
        }

        // VAD: продолжительная тишина → автостоп.
        let shouldStop = silenceTracker.update(
            rms: rms,
            threshold: VADConstants.rmsThreshold,
            timeout: silenceTimeoutProvider()
        )
        if shouldStop {
            DispatchQueue.main.async { [weak self] in self?.stop() }
        }
    }

    private func failOnMain(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.lastError = message
            self?.isRecording = false
        }
    }

    private final class ConversionState: @unchecked Sendable {
        var consumed = false
        let input: AVAudioPCMBuffer
        init(input: AVAudioPCMBuffer) { self.input = input }
    }
}

/// Отслеживает накопленную тишину. Доступен с audio-потока и с main — поэтому
/// внутри NSLock. Возвращает `true` если порог `timeout` достигнут (caller
/// должен вызвать stop).
private final class SilenceTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var startTime: Date?

    func update(rms: Float, threshold: Float, timeout: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rms < threshold {
            if let start = startTime {
                if Date().timeIntervalSince(start) >= timeout {
                    startTime = nil
                    return true
                }
            } else {
                startTime = Date()
            }
        } else {
            startTime = nil
        }
        return false
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        startTime = nil
    }
}
