import SwiftUI
import AppKit

// MARK: - Waveform bars

/// Хранилище сглаженного уровня + времени последнего кадра. Reference-type,
/// чтобы мутировать внутри `TimelineView` body без перезапуска SwiftUI-цикла
/// (TimelineView и так перерисовывается по таймеру независимо).
private final class LevelEnvelope {
    var value: CGFloat = 0
    var lastT: Double = 0
    /// Время последнего «активного» кадра (уровень выше порога речи). По нему
    /// решаем входить ли в hold-фазу при уходе к нулю.
    var lastActiveT: Double = 0
}

/// Живая waveform-визуализация: вертикальные полоски, высота которых
/// модулируется громкостью (`level`) + временной синусоидой (волнообразность).
///
/// **Сглаживание (attack-release):** raw `level` приходит редко (~12 раз/сек,
/// на аудио-буфер) и скачкообразно (речь → пауза → речь). Мы интерполируем
/// его к плавному `value` НА КАЖДОМ КАДРЕ (30fps) экспоненциальной огибающей:
///   - attack (рост) быстрый — полоски живо реагируют на голос
///   - release (спад) медленный — при паузе плавно опадают за ~0.5с, без
///     резкого «схлопывания»
/// Коэффициент frame-rate-independent (через `exp(-dt/tau)`), так что не
/// зависит от фактического FPS.
private struct WaveformBars: View {
    let level: CGFloat          // 0…1 текущая громкость (raw)
    var barCount: Int = 7
    var maxHeight: CGFloat = 22
    var baseHeight: CGFloat = 4
    var barWidth: CGFloat = 3

    /// Время сглаживания: attack короткое (быстрый подъём), release длинное
    /// (плавный спад). В секундах — «постоянная времени» экспоненты.
    private static let attackTau: Double = 0.10
    private static let releaseTau: Double = 0.30

    /// **Hold-фаза** против резкого ухода в ноль на паузах между словами:
    ///   - `activityThreshold` — уровень выше которого считаем «речь идёт».
    ///   - `holdDuration` — сколько ДЕРЖИМ waveform после того как уровень упал
    ///     к тишине, прежде чем начать спад. Покрывает короткие межсловные
    ///     паузы (waveform не схлопывается), длинные — спадают плавно.
    ///   - `holdTau` — очень длинная постоянная времени во время hold (почти
    ///     не спадаем, лёгкий дрейф вниз).
    /// Hold активируется ТОЛЬКО когда уровень ушёл ниже `activityThreshold`
    /// (очевидно к нулю). Переходы между средними-верхними значениями идут
    /// обычным attack/release — там задержка не нужна.
    private static let activityThreshold: CGFloat = 0.25
    private static let holdDuration: Double = 0.35
    private static let holdTau: Double = 2.5

    @State private var envelope = LevelEnvelope()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let smooth = smoothedLevel(at: t)
            HStack(spacing: 3) {
                ForEach(0..<barCount, id: \.self) { i in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [Color(red: 0.40, green: 0.62, blue: 1.0),
                                         Color(red: 0.25, green: 0.45, blue: 0.95)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(width: barWidth, height: height(i, t, smooth))
                }
            }
            .frame(height: maxHeight)
        }
    }

    /// Экспоненциальное сглаживание raw `level` → плавный уровень, пересчёт
    /// каждый кадр. attack/release разные + hold-фаза против резкого ухода в ноль.
    private func smoothedLevel(at t: Double) -> CGFloat {
        let dt = envelope.lastT == 0 ? 0 : (t - envelope.lastT)
        envelope.lastT = t
        guard dt > 0 else { envelope.value = level; return level }

        // Трекаем последнюю активность (речь выше порога тишины).
        if level > Self.activityThreshold {
            envelope.lastActiveT = t
        }

        let tau: Double
        if level > envelope.value {
            tau = Self.attackTau                       // рост — быстрый отклик
        } else {
            let goingSilent = level < Self.activityThreshold
            let sinceActive = t - envelope.lastActiveT
            if goingSilent && sinceActive < Self.holdDuration {
                tau = Self.holdTau                     // hold: придерживаем пик
            } else {
                tau = Self.releaseTau                  // обычный плавный спад
            }
        }
        let alpha = CGFloat(1 - exp(-dt / tau))
        envelope.value += (level - envelope.value) * alpha
        return envelope.value
    }

    private func height(_ i: Int, _ t: Double, _ smooth: CGFloat) -> CGFloat {
        // Волна по индексу полоски + времени — создаёт «бегущую» рябь.
        let wave = sin(t * 7.0 + Double(i) * 0.9)
        // Центральные полоски чуть выше краёв (эстетика «эквалайзера»).
        let center = 1.0 - abs(CGFloat(i) - CGFloat(barCount - 1) / 2.0) / CGFloat(barCount)
        let amp = smooth * maxHeight * (0.55 + 0.45 * center)
        // Idle-дыхание чтобы на тишине полоски не были мёртвыми.
        let idle = baseHeight + 1.5 * CGFloat(abs(sin(t * 2.0 + Double(i))))
        return max(idle, baseHeight + amp * (0.6 + 0.4 * CGFloat(abs(wave))))
    }
}

// MARK: - Overlay capsule view

/// Плавающая капсула диктовки (адаптация Aqua Voice). Слева — пульсирующий
/// акцент-кружок (или жёлтый «готовлюсь»), по центру — waveform, справа —
/// кнопки пауза/продолжить и стоп.
struct DictationOverlayView: View {
    @ObservedObject var recorder: AudioRecorder
    let onTogglePause: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            // 7 полосок (~39pt) в фрейме 58 → небольшие чёрные отступы ~9.5pt
            // по бокам. Ширина чуть меньше прежней (72), но waveform плотнее.
            WaveformBars(level: recorder.isPaused ? 0 : CGFloat(recorder.audioLevel))
                .frame(width: 58)
                .opacity(recorder.isPaused ? 0.4 : 1.0)
            divider
            pauseButton
            stopButton
        }
        .padding(.leading, 13)
        .padding(.trailing, 11)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
            // Тень убрана: shadow radius 14 заполнял прямоугольную область
            // вокруг капсулы размытой полупрозрачной заливкой, которая на фоне
            // читалась как «серый прямоугольник». Капсула тёмная и так читается.
        )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 20)
    }

    private var pauseButton: some View {
        Button(action: onTogglePause) {
            Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.10)))
        }
        .buttonStyle(.plain)
        .help(recorder.isPaused ? "Продолжить" : "Пауза")
    }

    private var stopButton: some View {
        Button(action: onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color(red: 0.85, green: 0.23, blue: 0.27)))
        }
        .buttonStyle(.plain)
        .help("Остановить и распознать")
    }
}

// MARK: - Floating panel

/// NSPanel, который НИКОГДА не становится key/main window.
///
/// **Зачем:** обычный NSPanel (даже с `.nonactivatingPanel`) при показе со
/// SwiftUI-кнопками может стать key window. Тогда активное текстовое поле под
/// overlay теряет first-responder. У многих полей (и TUI, и нативных) потеря+
/// возврат фокуса сбрасывает курсор в начало строки — и наш инжектируемый
/// текст уезжает не в позицию курсора, а в начало. Переопределяя
/// `canBecomeKey`/`canBecomeMain` в `false`, гарантируем что фокус ВСЕГДА
/// остаётся в исходном поле. Кнопки overlay кликаются через mouse-tracking
/// и без key-статуса (panel принимает mouse events).
private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Floating panel controller

/// Управляет borderless non-activating NSPanel'ом с overlay-капсулой.
/// Non-activating — чтобы активное текстовое поле под overlay оставалось
/// в фокусе (инжекция текста туда), но кнопки overlay всё равно кликались.
@MainActor
final class DictationOverlayController {
    private var panel: NSPanel?
    private let recorder: AudioRecorder
    private let onTogglePause: () -> Void
    private let onStop: () -> Void

    /// Отступ капсулы от нижнего края экрана.
    private static let bottomMargin: CGFloat = 90

    init(
        recorder: AudioRecorder,
        onTogglePause: @escaping () -> Void,
        onStop: @escaping () -> Void
    ) {
        self.recorder = recorder
        self.onTogglePause = onTogglePause
        self.onStop = onStop
    }

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        positionPanel()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let hosting = NSHostingView(
            rootView: DictationOverlayView(
                recorder: recorder,
                onTogglePause: onTogglePause,
                onStop: onStop
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        // NSHostingView по умолчанию рисует непрозрачный фон → вокруг скруглённой
        // капсулы был виден серый прямоугольник. Делаем layer прозрачным +
        // non-opaque, чтобы фон панели (clear) просвечивал — видна только сама
        // капсула. `isOpaque = false` обязателен: без него слой рисует
        // непрозрачную подложку даже при clear backgroundColor.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.isOpaque = false

        let panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 52),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false  // тень рисует сама Capsule в SwiftUI
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = hosting
        panel.ignoresMouseEvents = false
        return panel
    }

    private func positionPanel() {
        guard let panel else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 52)
        panel.setContentSize(size)

        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.midX - size.width / 2
        let y = frame.minY + Self.bottomMargin
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
