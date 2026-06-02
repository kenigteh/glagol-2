#!/usr/bin/env swift

import AppKit
import CoreText

/// Генератор фонового изображения для DMG-окна (классический «drag to install» UI).
///
/// Размер: 600×400. Иконки .app и Applications будут расставлены Finder'ом
/// поверх через `.DS_Store` (см. package.sh). Здесь — только статика: цвет,
/// curved arrow между точками куда лягут иконки, и подпись по центру.
///
/// Запуск:
///   swift scripts/generate_dmg_background.swift <output.png>

guard CommandLine.arguments.count == 2 else {
    print("Usage: swift generate_dmg_background.swift <output.png>")
    exit(1)
}
let outPath = CommandLine.arguments[1]

let width: CGFloat = 600
let height: CGFloat = 400

// Координаты центров будущих иконок (должны совпадать с теми, что выставит
// AppleScript в package.sh).
let leftIconCenter  = NSPoint(x: 150, y: 180)
let rightIconCenter = NSPoint(x: 450, y: 180)

// Нейтральная палитра в духе нашей иконки (тёмно-серая waveform на charcoal).
// Светло-серый фон даёт хороший контраст для тёмной иконки на нём.
let backgroundColor = NSColor(red: 0.96, green: 0.96, blue: 0.97, alpha: 1.0)
let accentColor     = NSColor(red: 0.18, green: 0.18, blue: 0.20, alpha: 1.0)
// Стрелка рисуется КАК ОПАКЫЙ цвет — не с opacity 0.55. Иначе в точках
// пересечения main-кривой с наконечником прозрачности складываются и
// проявляется тёмное «пятно». Вычисляем итоговый видимый цвет напрямую
// (что получилось бы при 55% непрозрачности accent поверх backgroundColor)
// и используем его с alpha=1.
let arrowColor = backgroundColor.blended(withFraction: 0.55, of: accentColor) ?? accentColor

let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()

if let ctx = NSGraphicsContext.current?.cgContext {
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
}

// ── Фон ────────────────────────────────────────────────────────────────
backgroundColor.setFill()
NSRect(x: 0, y: 0, width: width, height: height).fill()

// Лёгкий вертикальный градиент (сверху чуть светлее) для глубины.
if let gradient = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.15),
    NSColor.white.withAlphaComponent(0.0),
]) {
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)
}

// ── Стрелка ────────────────────────────────────────────────────────────
//
// Лёгкая дуга чуть ниже нижнего края иконок. Берём концы примерно на
// уровне «пола» иконок (y ≈ icon center − 40), control-точки сводим близко
// к концам — мелкий провал ~20px вместо S-curve.
//
// `arrowHorizontalOffset` — глобальный сдвиг по X для всей стрелки.
// Отрицательное значение — влево, положительное — вправо.
let arrowHorizontalOffset: CGFloat = -5
let arrowStart = NSPoint(x: leftIconCenter.x + 60  + arrowHorizontalOffset, y: leftIconCenter.y - 40)
let arrowEnd   = NSPoint(x: rightIconCenter.x - 60 + arrowHorizontalOffset, y: rightIconCenter.y - 40)
let ctrl1      = NSPoint(x: leftIconCenter.x + 100 + arrowHorizontalOffset, y: leftIconCenter.y - 60)
let ctrl2      = NSPoint(x: rightIconCenter.x - 100 + arrowHorizontalOffset, y: rightIconCenter.y - 60)

let arrowPath = NSBezierPath()
arrowPath.move(to: arrowStart)
arrowPath.curve(to: arrowEnd, controlPoint1: ctrl1, controlPoint2: ctrl2)
arrowPath.lineWidth = 4
arrowPath.lineCapStyle = .round
arrowColor.setStroke()
arrowPath.stroke()

// Наконечник стрелки — два штриха в конце пути.
// Аппроксимируем угол касательной у конца кривой Bezier: вектор от ctrl2 к end.
let tangent = NSPoint(x: arrowEnd.x - ctrl2.x, y: arrowEnd.y - ctrl2.y)
let tangentLen = sqrt(tangent.x * tangent.x + tangent.y * tangent.y)
let dirX = tangent.x / tangentLen
let dirY = tangent.y / tangentLen
let arrowHeadLen: CGFloat = 18
let arrowHeadAngle: CGFloat = 0.5  // ~28°

func rotated(_ x: CGFloat, _ y: CGFloat, by angle: CGFloat) -> (CGFloat, CGFloat) {
    let c = cos(angle), s = sin(angle)
    return (x * c - y * s, x * s + y * c)
}

let (lx, ly) = rotated(-dirX * arrowHeadLen, -dirY * arrowHeadLen, by:  arrowHeadAngle)
let (rx, ry) = rotated(-dirX * arrowHeadLen, -dirY * arrowHeadLen, by: -arrowHeadAngle)

let head = NSBezierPath()
head.move(to: NSPoint(x: arrowEnd.x + lx, y: arrowEnd.y + ly))
head.line(to: arrowEnd)
head.line(to: NSPoint(x: arrowEnd.x + rx, y: arrowEnd.y + ry))
head.lineWidth = 4
head.lineCapStyle = .round
head.lineJoinStyle = .round
arrowColor.setStroke()
head.stroke()

// ── Текст по центру ────────────────────────────────────────────────────
//
// Один лаконичный CTA, без подзаголовка. Чуть выше уровня иконок.
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 22, weight: .semibold),
    .foregroundColor: accentColor,
]
let title = NSAttributedString(string: "Перенеси Glagol в Applications", attributes: titleAttrs)
let titleSize = title.size()
title.draw(at: NSPoint(
    x: (width - titleSize.width) / 2,
    y: 300
))

image.unlockFocus()

// ── Сохранение ─────────────────────────────────────────────────────────
guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    print("Не удалось сжать в PNG")
    exit(2)
}
do {
    try png.write(to: URL(fileURLWithPath: outPath))
    print("✓ \(outPath)")
} catch {
    print("✗ \(outPath): \(error.localizedDescription)")
    exit(3)
}
