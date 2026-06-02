#!/usr/bin/env bash
#
# Setup для Glagol после клонирования.
#
# На ветке qwen-asr: всё что нужно — это Metal Toolchain (MLX компилирует
# Metal-шейдеры на этапе билда). Сама модель Qwen3-ASR-1.7B-4bit скачивается
# приложением автоматически при первом запуске в ~/Library/Caches/qwen3-speech/.
#
# Запуск из корня репо:
#   ./scripts/setup.sh

set -euo pipefail

echo "▸ Setup Glagol dependencies..."
echo ""

# ── Metal Toolchain ─────────────────────────────────────────────────────
#
# speech-swift (MLX) использует Metal-шейдеры. Apple их компилирует через
# отдельный downloadable component, который не идёт по умолчанию с Xcode.
echo "▸ Проверяю Metal Toolchain…"
if xcodebuild -checkComponentRequirements 2>&1 | grep -qi "MetalToolchain"; then
    echo "  ⬇ Качаю Metal Toolchain (~688 МБ, один раз)…"
    xcodebuild -downloadComponent MetalToolchain 2>&1 | tail -2
else
    echo "  ✓ Metal Toolchain уже стоит."
fi

echo ""
echo "✓ Setup завершён."
echo ""
echo "Дальше:"
echo "  1. Открой glagol.xcodeproj в Xcode"
echo "  2. ⌘B соберёт; ⌘R запустит."
echo "  3. При первом запуске app скачает модель Qwen3-ASR-1.7B-4bit"
echo "     (~1.6 ГБ из HuggingFace в ~/Library/Caches/qwen3-speech/)."
echo "     Видишь статус в menubar-меню — «ASR: Загружаю…»."
