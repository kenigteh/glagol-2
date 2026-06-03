import SwiftUI
import AppKit

// MARK: - Waveform bars

/// Живая waveform-визуализация: вертикальные полоски, высота которых
/// модулируется громкостью (`level`) + временной синусоидой (волнообразность).
/// На тишине/паузе полоски опускаются к базовой высоте.
private struct WaveformBars: View {
    let level: CGFloat          // 0…1 текущая громкость
    var barCount: Int = 5
    var maxHeight: CGFloat = 22
    var baseHeight: CGFloat = 4
    var barWidth: CGFloat = 3

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
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
                        .frame(width: barWidth, height: height(i, t))
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func height(_ i: Int, _ t: Double) -> CGFloat {
        // Волна по индексу полоски + времени — создаёт «бегущую» рябь.
        let wave = sin(t * 7.0 + Double(i) * 0.9)
        // Центральные полоски чуть выше краёв (эстетика «эквалайзера»).
        let center = 1.0 - abs(CGFloat(i) - CGFloat(barCount - 1) / 2.0) / CGFloat(barCount)
        let amp = level * maxHeight * (0.55 + 0.45 * center)
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
        HStack(spacing: 12) {
            WaveformBars(level: recorder.isPaused ? 0 : CGFloat(recorder.audioLevel))
                .frame(width: 72)
                .opacity(recorder.isPaused ? 0.4 : 1.0)
            divider
            pauseButton
            stopButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule(style: .continuous)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.13))
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
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

        let panel = NSPanel(
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
