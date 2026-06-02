import Foundation
import AppKit
import CoreGraphics
import Combine

/// Хоткей: либо двойной тап по модификатору, либо обычное сочетание клавиш.
enum Hotkey: Codable, Equatable {
    /// Двойной тап по модификатору. keyCode — Carbon kVK_*, deviceMask — IOKit NX_DEVICE*_*_MASK
    /// (для отличия левой/правой стороны).
    case modifierDoubleTap(keyCode: UInt16, deviceMask: UInt64, displayName: String)
    /// Обычная клавиша + модификаторы. modifierFlags — биты CGEventFlags
    /// (только Cmd/Ctrl/Option/Shift, без CapsLock и т.п.).
    case keyCombo(keyCode: UInt16, modifierFlags: UInt64, displayName: String)

    var displayName: String {
        switch self {
        case .modifierDoubleTap(_, _, let n): return n
        case .keyCombo(_, _, let n):          return n
        }
    }

    static let `default`: Hotkey = .modifierDoubleTap(
        keyCode: 59,                 // kVK_Control (левый Control)
        deviceMask: 0x00000001,      // NX_DEVICELCTLKEYMASK
        displayName: "Left ⌃ ×2"
    )
}

/// Глобальный монитор клавиш через CGEventTap.
@MainActor
final class HotkeyManager: ObservableObject {
    @Published private(set) var isAccessibilityGranted: Bool = false
    @Published private(set) var isMonitoring: Bool = false
    @Published private(set) var isRecordingHotkey: Bool = false
    @Published private(set) var hotkey: Hotkey {
        didSet {
            if let data = try? JSONEncoder().encode(hotkey) {
                UserDefaults.standard.set(data, forKey: Self.hotkeyUserDefaultsKey)
            }
            lastModifierDownAt = 0
            lastModifierKeyCode = 0
        }
    }

    var onHotkey: (() -> Void)?
    var onEscape: (() -> Void)?
    var onRecordingComplete: ((Hotkey) -> Void)?
    var onRecordingCancelled: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityCheckTimer: Timer?

    private var lastModifierDownAt: TimeInterval = 0
    private var lastModifierKeyCode: UInt16 = 0
    private let doubleTapWindow: TimeInterval = 0.4

    private static let escapeKeyCode: CGKeyCode = 53
    private static let hotkeyUserDefaultsKey = "glagol.hotkey"

    /// Маска модификаторов CGEventFlags, которые мы учитываем в keyCombo.
    /// CapsLock, Fn, NumPad — игнорируем.
    private static let cgEventModifierMask: UInt64 =
        UInt64(CGEventFlags.maskCommand.rawValue) |
        UInt64(CGEventFlags.maskShift.rawValue) |
        UInt64(CGEventFlags.maskAlternate.rawValue) |
        UInt64(CGEventFlags.maskControl.rawValue)

    /// keyCode → (device-mask для отличия сторон, человекочитаемое название).
    static let modifierLookup: [UInt16: (deviceMask: UInt64, label: String)] = [
        59: (0x00000001, "Left ⌃"),
        62: (0x00002000, "Right ⌃"),
        55: (0x00000008, "Left ⌘"),
        54: (0x00000010, "Right ⌘"),
        58: (0x00000020, "Left ⌥"),
        61: (0x00000040, "Right ⌥"),
        56: (0x00000002, "Left ⇧"),
        60: (0x00000004, "Right ⇧"),
    ]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hotkeyUserDefaultsKey),
           let saved = try? JSONDecoder().decode(Hotkey.self, from: data) {
            self.hotkey = saved
        } else {
            self.hotkey = .default
        }
        refreshAccessibility()

        // Подписка на возврат app на передний план — повод перепроверить Accessibility
        // без активного polling-таймера. Срабатывает быстрее (~мгновенно после клика
        // в systray) и не тратит wake-up'ы пока пользователь не возвращается.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        // Нет вызова teardownEventTap() — он @MainActor, а deinit — nonisolated.
        // В реальной жизни AppDelegate удерживает HotkeyManager на всё время
        // жизни процесса; `applicationWillTerminate` дёргает `stopMonitoring()`
        // явно, что и есть наш единственный путь освобождения tap'а.
        NotificationCenter.default.removeObserver(self)
    }

    /// Полная остановка event tap + освобождение mach port. `CGEvent.tapEnable(false)`
    /// — это только пауза; для освобождения системного ресурса нужен `CFMachPortInvalidate`.
    private func teardownEventTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAccessibility() {
        let granted = AXIsProcessTrusted()
        if granted != isAccessibilityGranted {
            isAccessibilityGranted = granted
        }
    }

    /// Открывает System Settings → Privacy → Accessibility.
    /// Без системного prompt'а — иначе появляется два окна (prompt + Settings).
    /// Polling в фоне всё равно подхватит, как только пользователь переключит галочку.
    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        startAccessibilityPolling()
    }

    @discardableResult
    func startMonitoring() -> Bool {
        refreshAccessibility()
        guard isAccessibilityGranted else {
            startAccessibilityPolling()
            return false
        }
        guard eventTap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue)

        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
                MainActor.assumeIsolated {
                    manager.handle(event: event, type: type)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isMonitoring = true
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        return true
    }

    func stopMonitoring() {
        teardownEventTap()
        isMonitoring = false
    }

    func startRecordingHotkey() {
        lastModifierDownAt = 0
        lastModifierKeyCode = 0
        isRecordingHotkey = true
    }

    func cancelRecordingHotkey() {
        if isRecordingHotkey {
            isRecordingHotkey = false
            lastModifierDownAt = 0
            lastModifierKeyCode = 0
        }
    }

    /// Polling-таймер на случай если пользователь меняет галочку Accessibility пока
    /// app на переднем плане (без didBecomeActive-сигнала). Интервал 3 сек — UX
    /// не страдает (пользователь всё равно идёт в Settings и переключает рукой),
    /// батарея бережётся (× 3 меньше wake-up'ов).
    private static let accessibilityPollingInterval: TimeInterval = 3.0

    private func startAccessibilityPolling() {
        if accessibilityCheckTimer != nil { return }
        accessibilityCheckTimer = Timer.scheduledTimer(
            withTimeInterval: Self.accessibilityPollingInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkAndPromoteAccessibility()
            }
        }
    }

    private func checkAndPromoteAccessibility() {
        refreshAccessibility()
        if isAccessibilityGranted && !isMonitoring {
            startMonitoring()
        }
    }

    @objc private func applicationDidBecomeActive(_ note: Notification) {
        // Дешёвый внеочередной чек — мгновенно подхватываем включённую галочку
        // после возвращения из System Settings, без ожидания таймера.
        Task { @MainActor [weak self] in
            self?.checkAndPromoteAccessibility()
        }
    }

    fileprivate func handle(event: CGEvent, type: CGEventType) {
        if isRecordingHotkey {
            handleRecording(event: event, type: type)
            return
        }
        handleNormal(event: event, type: type)
    }

    // MARK: - Normal mode

    private func handleNormal(event: CGEvent, type: CGEventType) {
        // Esc обрабатываем независимо от типа хоткея
        if type == .keyDown {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == Self.escapeKeyCode {
                onEscape?()
                // После Esc continue — не выходим, вдруг хоткей это keyCombo с Esc
                // (на практике Esc для хоткея запрещён, но не помешает.)
            }
        }

        switch hotkey {
        case .modifierDoubleTap(let targetKeyCode, let deviceMask, _):
            guard type == .flagsChanged else { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == targetKeyCode else { return }

            let isDown = (event.flags.rawValue & deviceMask) != 0
            guard isDown else { return }

            let now = Date().timeIntervalSinceReferenceDate
            if keyCode == lastModifierKeyCode,
               now - lastModifierDownAt < doubleTapWindow {
                lastModifierDownAt = 0
                lastModifierKeyCode = 0
                onHotkey?()
            } else {
                lastModifierKeyCode = keyCode
                lastModifierDownAt = now
            }

        case .keyCombo(let targetKeyCode, let targetFlags, _):
            guard type == .keyDown else { return }
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard keyCode == targetKeyCode else { return }

            let currentFlags = event.flags.rawValue & Self.cgEventModifierMask
            guard currentFlags == targetFlags else { return }

            onHotkey?()
        }
    }

    // MARK: - Recording mode

    private func handleRecording(event: CGEvent, type: CGEventType) {
        switch type {
        case .keyDown:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if keyCode == Self.escapeKeyCode {
                let cb = onRecordingCancelled
                cancelRecordingHotkey()
                cb?()
                return
            }
            // Любая другая обычная клавиша → записываем как keyCombo
            let flags = event.flags.rawValue & Self.cgEventModifierMask
            let name = Self.keyComboDisplayName(keyCode: keyCode, modifierFlags: flags)
            finishRecording(.keyCombo(keyCode: keyCode, modifierFlags: flags, displayName: name))

        case .flagsChanged:
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            guard let info = Self.modifierLookup[keyCode] else { return }

            let isDown = (event.flags.rawValue & info.deviceMask) != 0
            guard isDown else { return }

            let now = Date().timeIntervalSinceReferenceDate
            if keyCode == lastModifierKeyCode,
               now - lastModifierDownAt < doubleTapWindow {
                finishRecording(.modifierDoubleTap(
                    keyCode: keyCode,
                    deviceMask: info.deviceMask,
                    displayName: "\(info.label) ×2"
                ))
            } else {
                lastModifierKeyCode = keyCode
                lastModifierDownAt = now
            }

        default:
            break
        }
    }

    private func finishRecording(_ newHotkey: Hotkey) {
        self.hotkey = newHotkey
        isRecordingHotkey = false
        lastModifierDownAt = 0
        lastModifierKeyCode = 0
        onRecordingComplete?(newHotkey)
    }

    // MARK: - Display helpers

    static func keyComboDisplayName(keyCode: UInt16, modifierFlags: UInt64) -> String {
        var parts: [String] = []
        if modifierFlags & UInt64(CGEventFlags.maskControl.rawValue) != 0   { parts.append("⌃") }
        if modifierFlags & UInt64(CGEventFlags.maskAlternate.rawValue) != 0 { parts.append("⌥") }
        if modifierFlags & UInt64(CGEventFlags.maskShift.rawValue) != 0     { parts.append("⇧") }
        if modifierFlags & UInt64(CGEventFlags.maskCommand.rawValue) != 0   { parts.append("⌘") }
        parts.append(keyCodeDisplayName(keyCode))
        return parts.joined()
    }

    /// keyCode → отображаемое имя. Используем словарь вместо switch — легче добавлять/искать
    /// (grep по строке `case 96:` ничего не нашёл бы; по `96:` находит сразу).
    private static let keyCodeNames: [UInt16: String] = [
        // Letters
        0: "A", 1: "S", 2: "D", 3: "F",
        4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q",
        13: "W", 14: "E", 15: "R", 16: "Y",
        17: "T", 31: "O", 32: "U", 34: "I",
        35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M",
        // Numbers (top row)
        18: "1", 19: "2", 20: "3", 21: "4",
        22: "6", 23: "5", 25: "9", 26: "7",
        28: "8", 29: "0",
        // Punctuation
        24: "=", 27: "-", 30: "]", 33: "[",
        39: "'", 41: ";", 42: "\\", 43: ",",
        44: "/", 47: ".", 50: "`",
        // Special
        36: "↩", 48: "⇥", 49: "Space",
        51: "⌫", 53: "⎋", 117: "⌦",
        // Function keys
        96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11",
        105: "F13", 107: "F14", 109: "F10",
        111: "F12", 113: "F15",
        118: "F4", 120: "F2", 122: "F1",
        // Navigation
        114: "Help", 115: "Home", 116: "PgUp",
        119: "End", 121: "PgDn",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    private static func keyCodeDisplayName(_ keyCode: UInt16) -> String {
        keyCodeNames[keyCode] ?? "Key #\(keyCode)"
    }
}
