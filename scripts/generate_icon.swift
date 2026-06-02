#!/usr/bin/env swift

import AppKit

/// Генератор иконки Glagol: тот же SF Symbol «waveform», что в menubar,
/// на нейтральном тёмно-сером squircle-фоне.
///
/// Идея: app-иконка и menubar-иконка визуально единый бренд — одна и та же
/// «волна», только в menubar она шаблонная (адаптируется к светлому/тёмному
/// фону системы), а в app-иконке — белая на тёмно-сером.
///
/// Запуск:
///   swift scripts/generate_icon.swift <output-dir>

guard CommandLine.arguments.count == 2 else {
    print("Использование: swift generate_icon.swift <output-dir>")
    exit(1)
}
let outDir = CommandLine.arguments[1]

// ── Палитра ─────────────────────────────────────────────────────────────
// Тёмно-серый charcoal (как у Apple Black Background apps типа Voice Memos).
// Не чисто чёрный — чёрный смотрится мёртво на light mode.
let backgroundColor = NSColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1.0)
// Белая «волна» — основной акцент.
let foregroundColor = NSColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1.0)

func makeIcon(size: Int) -> NSImage {
    let dim = CGFloat(size)
    let image = NSImage(size: NSSize(width: dim, height: dim))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    // Squircle фон. macOS HIG: ≈22% от стороны для радиуса.
    let cornerRadius = dim * 0.22
    let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
    let bg = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    backgroundColor.setFill()
    bg.fill()

    // Лёгкая внутренняя «подсветка» сверху для объёма (на крупных размерах).
    if size >= 64 {
        let highlight = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.06),
            NSColor.white.withAlphaComponent(0.0),
        ])
        highlight?.draw(in: rect, angle: 90)
    }

    // SF Symbol «waveform» — тот же что в menubar.
    // SymbolConfiguration с paletteColors красит символ в нужный цвет (macOS 12+).
    let symbolPointSize = dim * 0.62
    let baseConfig = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .regular)
    let coloredConfig: NSImage.SymbolConfiguration
    if #available(macOS 12.0, *) {
        coloredConfig = baseConfig.applying(NSImage.SymbolConfiguration(paletteColors: [foregroundColor]))
    } else {
        coloredConfig = baseConfig
    }

    guard let symbol = NSImage(
        systemSymbolName: "waveform",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(coloredConfig) else {
        return image
    }

    // Центрируем символ по фактическим размерам после applying configuration.
    let symSize = symbol.size
    let symRect = NSRect(
        x: (dim - symSize.width) / 2,
        y: (dim - symSize.height) / 2,
        width: symSize.width,
        height: symSize.height
    )
    symbol.draw(in: symRect)

    return image
}

func savePNG(_ image: NSImage, to path: String) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        print("Не удалось сжать в PNG: \(path)")
        return
    }
    do {
        try png.write(to: URL(fileURLWithPath: path))
        print("✓ \(path)")
    } catch {
        print("✗ \(path): \(error.localizedDescription)")
    }
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
for s in sizes {
    let img = makeIcon(size: s)
    savePNG(img, to: "\(outDir)/icon_\(s).png")
}
