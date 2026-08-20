#!/usr/bin/env swift
import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon.swift <source-png> <output-icns>\n".utf8))
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[0])
let outputURL = URL(fileURLWithPath: arguments[1])
let fileManager = FileManager.default
let iconsetURL = outputURL
    .deletingLastPathComponent()
    .appendingPathComponent("AppIcon.iconset", isDirectory: true)

guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    throw NSError(
        domain: "IconGeneration",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unable to load the source icon: \(sourceURL.path)"]
    )
}

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// 描述 iconset 中单个 PNG 文件的名称与实际像素边长。
struct IconSize {
    let fileName: String
    let pixels: Int
}

let sizes = [
    IconSize(fileName: "icon_16x16.png", pixels: 16),
    IconSize(fileName: "icon_16x16@2x.png", pixels: 32),
    IconSize(fileName: "icon_32x32.png", pixels: 32),
    IconSize(fileName: "icon_32x32@2x.png", pixels: 64),
    IconSize(fileName: "icon_128x128.png", pixels: 128),
    IconSize(fileName: "icon_128x128@2x.png", pixels: 256),
    IconSize(fileName: "icon_256x256.png", pixels: 256),
    IconSize(fileName: "icon_256x256@2x.png", pixels: 512),
    IconSize(fileName: "icon_512x512.png", pixels: 512),
    IconSize(fileName: "icon_512x512@2x.png", pixels: 1024),
]

for size in sizes {
    let representation = try renderIcon(sourceImage, pixels: size.pixels)
    let pngURL = iconsetURL.appendingPathComponent(size.fileName)
    try writePNG(representation, to: pngURL)
}

try? fileManager.removeItem(at: outputURL)
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", outputURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconGeneration", code: Int(process.terminationStatus))
}

try? fileManager.removeItem(at: iconsetURL)

/// 将版本化源图缩放到目标像素，并用透明圆角遮罩清理生成图外围背景。
func renderIcon(_ sourceImage: NSImage, pixels: Int) throws -> NSBitmapImageRep {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "IconGeneration", code: 2)
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        throw NSError(domain: "IconGeneration", code: 3)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let side = CGFloat(pixels)
    let bounds = NSRect(x: 0, y: 0, width: side, height: side)
    NSColor.clear.setFill()
    bounds.fill()
    NSBezierPath(
        roundedRect: bounds,
        xRadius: side * 0.22,
        yRadius: side * 0.22
    ).addClip()
    sourceImage.draw(
        in: bounds,
        from: NSRect(origin: .zero, size: sourceImage.size),
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()
    return representation
}

/// 将单个像素表示编码为无损 PNG，供 iconutil 组装 `.icns`。
func writePNG(_ representation: NSBitmapImageRep, to url: URL) throws {
    guard let png = representation.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGeneration", code: 4)
    }
    try png.write(to: url)
}
