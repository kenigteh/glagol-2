<div align="center">

<img src="glagol/Assets.xcassets/AppIcon.appiconset/icon_256.png" alt="Glagol icon" width="160" />

# Glagol 2

**Локальный голосовой ввод для macOS — batch-режим.**
Нажал хоткей → продиктовал → отпустил → текст напечатался.

Никаких облаков, никакой телеметрии. Никакого streaming. Просто работает.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-blue.svg)](#требования)
[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![ASR](https://img.shields.io/badge/ASR-Qwen3--ASR%201.7B-purple.svg)](https://huggingface.co/mlx-community/Qwen3-ASR-1.7B-4bit)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

---

## Что это

Менюбар-приложение для macOS, которое принимает диктовку и печатает её в активное поле любого приложения. Распознавание полностью локальное на твоей Apple Silicon — через **Qwen3-ASR-1.7B-4bit** (MLX) от Alibaba.

**Архитектура batch:** запись копится в памяти от старта до stop'а. Когда юзер останавливает запись (хоткей, Esc, или auto-stop по тишине), вся запись разом подаётся в Qwen-модель, результат печатается одним блоком.

> 💡 **Зачем batch?** Streaming-диктовка фундаментально борется с современными LLM-based ASR-моделями (Qwen3-ASR, Whisper). Hallucination на silence, word-tail leakage при cut'ах, дрейф интерпретации на длинных буферах — всё это родовые болезни streaming-режима. Batch-режим избегает их по построению: модель видит полный контекст, никаких частичных прогонов, никаких склеек, глобально-консистентная пунктуация. Latency почти не страдает — на 20-секундной диктовке Qwen на M-серии Apple Silicon отдаёт результат за 0.6с.

## Возможности

- **Полностью локально** — модель работает на Apple Silicon GPU через MLX. Никаких внешних API.
- **Кастомный хоткей** — двойной модификатор (⌃⌃ по умолчанию) или произвольное сочетание
- **Auto-stop по тишине** — записи завершаются сами через настраиваемую паузу (7-30 секунд)
- **Hotwords / context-prompt** — пользовательский словарь редких терминов биасит модель к их сохранению (`Cursor`, `Kubernetes`, и др.)
- **Multilingual code-switching** — русский с английскими IT-терминами в одной фразе ловится корректно
- **Menubar-only** — никакой Dock-иконки, всегда под рукой
- **Per-grapheme injection** — текст печатается через CGEvent с правильным chunking'ом (работает в терминалах, IDE, чатах, везде)

## Требования

| | |
|---|---|
| **OS** | macOS 15+ (Sequoia, для MLState API в speech-swift) |
| **CPU** | Apple Silicon — M1 / M2 / M3 / M4 |
| **Свободное место** | ~1.6 ГБ под модель Qwen3-ASR-1.7B-4bit + кэш |
| **Разрешения** | Микрофон + Accessibility (для CGEvent-инжекции текста) |

Для сборки: Xcode 16+ + Metal Toolchain (см. ниже).

## Быстрый старт

```bash
git clone https://github.com/kenigteh/glagol-2.git
cd glagol-2
open glagol.xcodeproj
# ⌘R в Xcode для запуска
```

SPM сам стянет [`speech-swift`](https://github.com/soniqo/speech-swift). При первом запуске приложение скачает модель Qwen3-ASR-1.7B-4bit (~1.6 ГБ) в `~/Library/Caches/qwen3-speech/`.

Если Xcode ругается `cannot execute tool 'metal'`:

```bash
xcodebuild -downloadComponent MetalToolchain   # 688 МБ, один раз
```

MLX компилирует Metal-шейдеры через эту тулчейну.

## Архитектура

```
Микрофон → AudioRecorder (AVAudioEngine, 16kHz mono Float32)
              ↓
          (накапливает в [Float] до stop'а)
              ↓
   on stop / VAD-auto-stop:
              ↓
          QwenASR.transcribe(audio: [Float]) async → String
              ↓
          TextInjector (CGEvent → активное поле, chunks of 8 chars)
```

### Файлы

| Файл | Назначение |
|---|---|
| `BatchASR.swift` | Port (Protocol) для batch ASR-движка — `transcribe(audio:) → String` |
| `QwenASR.swift` | Адаптер Qwen3-ASR через speech-swift / MLX |
| `QwenModelChoice.swift` | UI-выбор размера модели (0.6B / 1.7B) |
| `AudioRecorder.swift` | AVAudioEngine pipeline, накопление сэмплов, VAD auto-stop |
| `HotkeyManager.swift` | CGEventTap, кастомный hotkey-recording panel |
| `TextInjector.swift` | CGEvent injection chunks of 8 chars (работает в терминалах) |
| `HotwordsStore.swift` | UserDefaults + текстовый файл со словарём пользователя |
| `glagolApp.swift` | AppDelegate, NSStatusItem, panels, wiring |

## Бенчмарк

Замеры на тестовом аудио 21.6с (русский с английскими IT-терминами), Qwen3-ASR-1.7B-4bit на Apple Silicon:

| Метрика | Значение |
|---|---|
| Cold load модели (с диска) | ~6-7с |
| Warm load (повторный запуск приложения) | ~3с |
| **Inference на 21.6с аудио (warm)** | **~0.63с** |
| Real-time factor | **34×** |

Для сравнения: WhisperKit Large-v3-Turbo на том же аудио — 2.06с inference, 13-14с warm load. Qwen быстрее **в 3× на warm-inference** и **в 4× на warm-load**.

## Связь с Glagol 1

Это **subtractive рерайт** из ветки `qwen-asr` оригинального [Glagol](https://github.com/kenigteh/glagol) (заархивирован). Из v1 удалены:

- VAD-streaming сегментация (`SileroVAD`, `StreamingVADProcessor`)
- Sentence-completeness merge (pending/accumulated state machine)
- ForcedAligner cut alignment
- LocalAgreement-2 candidates с penalty system
- Pause-fallback, word-growth guard, прочая боль streaming-режима

Что переиспользуется один в один:

- HotkeyManager
- TextInjector (с фиксом chunking-by-8 для терминалов)
- HotwordsStore + UI-словаря
- Menubar UI, panels, first-launch tour
- Иконка, AppIcon, DMG-фон

Код QwenASR.swift ужался с **700 строк до 270**. Все остальные файлы трогали минимально.

## Скрипты

| | |
|---|---|
| `scripts/package.sh` | Собрать релизный DMG end-to-end |
| `scripts/generate_icon.swift` | Регенерация AppIcon (waveform на charcoal squircle) |
| `scripts/generate_dmg_background.swift` | Регенерация фона DMG-окна |
| `scripts/set_dmg_icon.swift` | Прицепить custom Finder-иконку к любому файлу |

## Спасибо

- **[QwenLM/Qwen3-ASR](https://huggingface.co/Qwen)** ([Alibaba](https://github.com/QwenLM)) — Qwen3-ASR модель (SOTA open-source ASR 2026)
- **[soniqo/speech-swift](https://github.com/soniqo/speech-swift)** — Swift wrapper для Qwen3-ASR через MLX
- **[ml-explore/mlx](https://github.com/ml-explore/mlx)** ([Apple](https://github.com/apple)) — ML framework для Apple Silicon
- **[SF Symbols](https://developer.apple.com/sf-symbols/)** — иконка `waveform` (Apple)

## Лицензия

[MIT](LICENSE) © 2026 Artem Sakovskii

Модель Qwen3-ASR распространяется по лицензии Apache 2.0. См. её репозиторий на HuggingFace.
