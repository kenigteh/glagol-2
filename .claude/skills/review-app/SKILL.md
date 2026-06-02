---
name: review-app
description: >
  Local Senior code review for Glagol macOS dictation app.
  Reads working-tree changes (untracked + modified Swift files), spawns 6 specialist
  reviewers in parallel (architecture, concurrency, memory, swift quality, macOS UX,
  ASR/domain correctness), aggregates findings into a single report.
  Triggered by: /review-app, "проверь приложение", "ревью кода".
---

# Glagol Local Code Review

This is a single-user **macOS menubar dictation app** — Swift + AppKit + SwiftUI,
sherpa-onnx for ASR (GigaAM v3 RNN-T + BPE hotwords). No backend, no multi-tenant,
no SQL. Concerns are different from a typical server app: thread safety across
DispatchQueues, ARC retain cycles, recognizer lifecycle, AppKit/SwiftUI patterns,
bundling/sandboxing, audio pipeline correctness.

You ARE the reviewer — a Senior Swift/macOS developer who knows this codebase. You
read the changes, think about them, and produce concrete actionable findings.

## Scope

Local review of working-tree state. "Diff" = untracked + modified files since the
initial commit. Skip:

- `SherpaOnnx.swift` — vendored from k2-fsa/sherpa-onnx (no point reviewing third-party)
- `Frameworks/` — vendored binaries
- `glagol/Models/` — binary models, generated `bpe.vocab`, user `hotwords.txt`
- `.xcodeproj/project.pbxproj` — Xcode metadata

Review files:

- `glagol/GigaAMSherpaASR.swift` — ASR adapter, sliding window + hotwords
- `glagol/HotwordsStore.swift` — user dictionary persistence
- `glagol/HotwordsSettingsView.swift` — SwiftUI settings panel
- `glagol/glagolApp.swift` — AppDelegate, menubar, panel management
- `glagol/AudioRecorder.swift` — AVAudioEngine + VAD
- `glagol/HotkeyManager.swift` — CGEventTap hotkeys
- `glagol/TextInjector.swift` — diff-based keystroke injection
- `glagol/StreamingASR.swift` — protocol
- `scripts/patch_model_metadata.py`, `scripts/generate_bpe_vocab.py`

## Phases

### Phase 1: Gather

In parallel:
- `git status --short` — list untracked + modified files
- `git diff HEAD -- glagol/glagolApp.swift glagol/AudioRecorder.swift glagol.xcodeproj/project.pbxproj` — for modified files
- Read each file fully so the lead reviewer has end-to-end context

### Phase 2: Specialist reviewers (parallel)

Launch all 6 specialists from `references/specialist-prompts.md` as **Agent** subagents
in a single message (six tool calls). Each specialist reads the same set of files
and returns JSON.

Specialists:
1. **Architecture** — Ports/adapters (StreamingASR), MainActor isolation, separation of concerns
2. **Concurrency** — DispatchQueue patterns, race conditions, MainActor boundaries
3. **Memory & Lifecycle** — ARC cycles, recognizer/audio-buffer growth, [weak self]
4. **Swift Quality** — Force-unwrap, naming, error handling, idioms
5. **macOS UX & Integration** — NSStatusItem, NSPanel, sandboxing, accessibility, Info.plist
6. **Domain Correctness** — sherpa-onnx usage, sliding window soundness, hotwords pipeline, TextInjector diff

### Phase 3: Lead synthesis

You receive 6 JSON reports. Your job:

1. **Deduplicate** — multiple specialists may flag the same issue from different angles. Merge.
2. **Triage** — promote/demote severity based on judgment. Specialists tend to over-flag; the lead's job is to be honest about what actually matters.
3. **Discard false positives** — Swift-specific idioms a generalist linter might flag but are correct here.
4. **Group by severity** — 🔴 Blocker (must fix before release), 🟡 Concern (should fix), 💡 Suggestion.
5. **Write a Markdown report** to terminal (no GitLab post, no MR — just print).

## Output format

```
# Code Review: Glagol (commit <sha>)

## Verdict: <approve / approve-with-concerns / changes-required>

## Summary
<2-3 sentences>

## Blockers (N)
- **file:line** — [category] description. Fix: ...

## Concerns (N)
- **file:line** — [category] description. Fix: ...

## Suggestions (N)
- **file:line** — description.

## Per-file notes
<optional, only if a file deserves cross-cutting commentary>
```

## Severity convention

- **🔴 Blocker** — security, data-loss bug, crash, ARC cycle leaking ≥1MB, unsafe concurrency on shared state, broken architecture invariant
- **🟡 Concern** — quality issue that survives shipping but creates tech debt, missing error path, UX issue users will hit
- **💡 Suggestion** — taste, refactor opportunity, naming, micro-optimization

## Language

Report — Russian. Specialist agents return JSON in English (categories must match the
prompt). Final summary to the user — Russian.

## Don't

- Don't suggest splitting working code into smaller files just for size — Swift files
  are fine at 400-500 lines if they're cohesive.
- Don't flag Russian-language comments. The codebase convention is Russian.
- Don't try to integrate with GitLab/glab — this is local-only review.
- Don't try to fix things yourself — produce findings, let the user decide what to fix.
- Don't review `SherpaOnnx.swift` or `Frameworks/` — they're vendored.
