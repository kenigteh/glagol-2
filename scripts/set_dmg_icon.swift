#!/usr/bin/env swift

import AppKit
import Foundation

/// Ставит custom Finder-иконку на любой файл (в т.ч. DMG).
///
/// macOS хранит её в resource fork (`com.apple.ResourceFork`) + флаг
/// «has custom icon» в FinderInfo. NSWorkspace.setIcon делает обе вещи разом.
///
/// Использование:
///   swift scripts/set_dmg_icon.swift glagol/Assets.xcassets/AppIcon.appiconset/icon_1024.png ~/Downloads/Glagol.dmg
///
/// Можно скармливать PNG или .icns — NSImage.init(contentsOfFile:) умеет оба.

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(
        "Usage: swift set_dmg_icon.swift <icon-path> <target-path>\n".data(using: .utf8)!
    )
    exit(1)
}
let iconPath = args[1]
let targetPath = args[2]

guard let img = NSImage(contentsOfFile: iconPath) else {
    FileHandle.standardError.write("Не удалось прочитать иконку: \(iconPath)\n".data(using: .utf8)!)
    exit(2)
}
let ok = NSWorkspace.shared.setIcon(img, forFile: targetPath, options: [])
print("setIcon → \(ok)")
exit(ok ? 0 : 3)
