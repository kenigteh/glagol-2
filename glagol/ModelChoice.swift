import Foundation

/// Какой ASR-движок стоит за выбором модели.
enum ASREngine {
    case qwen    // Qwen3-ASR через speech-swift / MLX
    case gigaam  // GigaAM v3 (Сбер) через sherpa-onnx
}

/// Плоский список доступных моделей. Один уровень — движок + размер сразу.
///
/// **Trade-off движков:**
///   - `gigaam` (GigaAM v3, Сбер) — топ качество РУССКОГО, быстрая (~0.3с),
///     лёгкая (~220 МБ). НО только русский: английские термины транслитерирует
///     («Кубернетес» вместо «Kubernetes»). Для чисто русской диктовки — лучшая.
///   - `qwenSmall`/`qwenLarge` (Qwen3-ASR, Alibaba) — multilingual
///     code-switching из коробки. Для IT-речи с английскими терминами.
///
/// При переключении в UI весь движок меняется: старый выгружается, новый
/// грузится (модель скачивается если её нет в кэше).
enum ModelChoice: String, CaseIterable, Identifiable {
    // Порядок в меню: сначала рекомендуемая точная, потом быстрая, потом лёгкая.
    case qwenLarge
    case qwenSmall
    case gigaam

    var id: String { rawValue }

    var engine: ASREngine {
        switch self {
        case .gigaam: return .gigaam
        case .qwenSmall, .qwenLarge: return .qwen
        }
    }

    /// HuggingFace repo id для Qwen (для GigaAM — nil, у неё свой загрузчик).
    var qwenModelId: String? {
        switch self {
        case .qwenSmall: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .qwenLarge: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        case .gigaam: return nil
        }
    }

    /// Подпись для меню. Прилагательное-характеристика + тех-название в скобках.
    /// У GigaAM явно помечаем «только русский» — иначе юзер выберет её и
    /// удивится, что английские термины транслитерируются в кириллицу.
    var displayName: String {
        switch self {
        case .qwenLarge: return "Точная (Qwen 1.7B) — рекомендуется"
        case .qwenSmall: return "Быстрая (Qwen 0.6B)"
        case .gigaam: return "Лёгкая (GigaAM, Сбер — только русский)"
        }
    }

    static func from(rawValue: String) -> ModelChoice? {
        ModelChoice(rawValue: rawValue)
    }

    /// Дефолт — Qwen 1.7B (наш baseline для IT-диктовки с code-switching).
    static let `default`: ModelChoice = .qwenLarge
}
