import Foundation

/// Выбор размера Qwen3-ASR модели.
///
/// **Trade-off:**
///   - `small` (0.6B, ~700 МБ) — быстрее загрузка, быстрее transcribe, меньше
///     памяти. На code-switching русский+английский может «съедать» сложные
///     термины (CI/CD, Qwen, имена собственные).
///   - `large` (1.7B, ~1.6 ГБ) — наш дефолт. На IT-диктовке заметно точнее,
///     особенно на аббревиатурах и собственных именах. Latency transcribe
///     ~2-3× выше, но всё ещё намного быстрее реального времени.
///
/// При переключении в UI: `QwenASR.swapModel(to:)` стирает с диска предыдущую
/// модель и качает новую (~700 МБ или ~1.6 ГБ). Не тратим лишнее место.
enum QwenModelChoice: String, CaseIterable, Identifiable {
    case small
    case large

    var id: String { rawValue }

    /// HuggingFace repo id, который скармливается `Qwen3ASRModel.fromPretrained`.
    var modelId: String {
        switch self {
        case .small: return "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        case .large: return "mlx-community/Qwen3-ASR-1.7B-4bit"
        }
    }

    /// Подпись для меню.
    var displayName: String {
        switch self {
        case .small: return "Быстрая (0.6B, ~700 МБ)"
        case .large: return "Точная (1.7B, ~1.6 ГБ) — рекомендуется"
        }
    }

    /// Обратный lookup по `modelId` — нужен AppDelegate'у чтобы отобразить
    /// галку в меню для текущего значения из HotwordsStore.
    static func from(modelId: String) -> QwenModelChoice? {
        Self.allCases.first { $0.modelId == modelId }
    }
}
