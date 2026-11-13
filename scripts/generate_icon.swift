#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import SwiftUI

// Generates Resources/AppIcon.icns following macOS Sequoia / Sonoma human interface guidelines:
// - 1024x1024 canvas with 824x824 continuous-look rounded squircle + ambient drop shadow
// - Deep indigo-cyan studio lighting + tactile collector tray + dual signal/bookmark cards

func cgColor(_ hex: UInt32, alpha: CGFloat = 1.0) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF) / 255.0
    let g = CGFloat((hex >> 8) & 0xFF) / 255.0
    let b = CGFloat(hex & 0xFF) / 255.0
    return CGColor(srgbRed: r, green: g, blue: b, alpha: alpha)
}

func roundedSquirclePath(in rect: CGRect, radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect).cgPath
}

func drawCard(
    ctx: CGContext,
    center: CGPoint,
    size: CGSize,
    angleDegrees: CGFloat,
    radius: CGFloat,
    topColor: UInt32,
    bottomColor: UInt32,
    isBookmarkNotched: Bool,
    drawLines: Bool
) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angleDegrees * .pi / 180.0)

    let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    let cardPath = CGMutablePath()

    if isBookmarkNotched {
        // Rounded card with a subtle ribbon bookmark badge on top-right
        cardPath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    } else {
        cardPath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
    }

    // Drop shadow behind card
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 32, color: cgColor(0x030712, alpha: 0.45))
    ctx.addPath(cardPath)
    ctx.setFillColor(cgColor(topColor))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient fill
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(
        colorsSpace: space,
        colors: [cgColor(bottomColor), cgColor(topColor)] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: 0, y: rect.minY),
        end: CGPoint(x: 0, y: rect.maxY),
        options: []
    )

    if isBookmarkNotched {
        // Crisp white/gold bookmark ribbon tucked into top-right of the card
        let bw: CGFloat = size.width * 0.20
        let bh: CGFloat = size.height * 0.34
        let bx = rect.maxX - bw - size.width * 0.13
        let by = rect.maxY - bh + 4
        let ribbon = CGMutablePath()
        ribbon.move(to: CGPoint(x: bx, y: rect.maxY + 4))
        ribbon.addLine(to: CGPoint(x: bx + bw, y: rect.maxY + 4))
        ribbon.addLine(to: CGPoint(x: bx + bw, y: by))
        ribbon.addLine(to: CGPoint(x: bx + bw * 0.5, y: by + bw * 0.34))
        ribbon.addLine(to: CGPoint(x: bx, y: by))
        ribbon.closeSubpath()

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: cgColor(0x0F172A, alpha: 0.25))
        ctx.addPath(ribbon)
        ctx.setFillColor(cgColor(0xFFFFFF, alpha: 0.95))
        ctx.fillPath()
        ctx.restoreGState()
    }

    if drawLines {
        // Minimalist text/media indicator bars on the card
        let padX = size.width * 0.14
        let barH: CGFloat = 20
        let y1 = rect.maxY - size.height * 0.28
        let y2 = y1 - 38
        let y3 = y2 - 38

        let pill1 = CGPath(roundedRect: CGRect(x: rect.minX + padX, y: y1, width: size.width * 0.42, height: barH), cornerWidth: 10, cornerHeight: 10, transform: nil)
        let pill2 = CGPath(roundedRect: CGRect(x: rect.minX + padX, y: y2, width: size.width * 0.66, height: barH), cornerWidth: 10, cornerHeight: 10, transform: nil)
        let pill3 = CGPath(roundedRect: CGRect(x: rect.minX + padX, y: y3, width: size.width * 0.52, height: barH), cornerWidth: 10, cornerHeight: 10, transform: nil)

        ctx.setFillColor(cgColor(0xFFFFFF, alpha: 0.85))
        ctx.addPath(pill1)
        ctx.fillPath()

        ctx.setFillColor(cgColor(0xFFFFFF, alpha: 0.55))
        ctx.addPath(pill2)
        ctx.addPath(pill3)
        ctx.fillPath()
    } else {
        // Play triangle glyph on the media card
        let triSize: CGFloat = 56
        let cx = rect.minX + size.width * 0.34
        let cy = rect.maxY - size.height * 0.32
        let play = CGMutablePath()
        play.move(to: CGPoint(x: cx - triSize * 0.36, y: cy + triSize * 0.48))
        play.addLine(to: CGPoint(x: cx - triSize * 0.36, y: cy - triSize * 0.48))
        play.addLine(to: CGPoint(x: cx + triSize * 0.52, y: cy))
        play.closeSubpath()
        ctx.setFillColor(cgColor(0xFFFFFF, alpha: 0.88))
        ctx.addPath(play)
        ctx.fillPath()
    }

    // Subtle glass border on card
    ctx.addPath(cardPath)
    ctx.setStrokeColor(cgColor(0xFFFFFF, alpha: 0.35))
    ctx.setLineWidth(5)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

func renderIconImage(pixelSize: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixelSize, height: pixelSize)

    NSGraphicsContext.saveGraphicsState()
    let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Work in a normalized 1024x1024 coordinate space
    let scale = CGFloat(pixelSize) / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let iconRect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let cornerRadius: CGFloat = 186
    let squircle = roundedSquirclePath(in: iconRect, radius: cornerRadius)

    // 1. Ambient outer shadow under macOS squircle
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 34, color: cgColor(0x000000, alpha: 0.36))
    ctx.addPath(squircle)
    ctx.setFillColor(cgColor(0x0B132B))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. Clip inside squircle for background & interior elements
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    // Deep slate -> royal indigo -> electric navy vertical gradient
    let bgGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            cgColor(0x091124),
            cgColor(0x102347),
            cgColor(0x1B3B6F),
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: 512, y: 100),
        end: CGPoint(x: 512, y: 924),
        options: []
    )

    // Luminous cyan/azure radial aura behind the collector tray
    let auraGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            cgColor(0x38BDF8, alpha: 0.46),
            cgColor(0x6366F1, alpha: 0.18),
            cgColor(0x091124, alpha: 0.0),
        ] as CFArray,
        locations: [0.0, 0.48, 1.0]
    )!
    ctx.drawRadialGradient(
        auraGrad,
        startCenter: CGPoint(x: 512, y: 450),
        startRadius: 20,
        endCenter: CGPoint(x: 512, y: 450),
        endRadius: 430,
        options: []
    )

    // Subtle concentric radar / signal rings at top suggesting edge monitoring
    ctx.saveGState()
    ctx.setStrokeColor(cgColor(0x7DD3FC, alpha: 0.12))
    ctx.setLineWidth(3.5)
    for r: CGFloat in [220, 310, 400] {
        ctx.strokeEllipse(in: CGRect(x: 512 - r, y: 430 - r, width: r * 2, height: r * 2))
    }
    ctx.restoreGState()

    // 3. Back interior cavity of Collector Tray (drawn BEHIND the cards so cards sit inside the tray)
    let trayBackRect = CGRect(x: 222, y: 214, width: 580, height: 312)
    let trayBackPath = CGPath(roundedRect: trayBackRect, cornerWidth: 74, cornerHeight: 74, transform: nil)
    ctx.saveGState()
    ctx.addPath(trayBackPath)
    ctx.setFillColor(cgColor(0x071022, alpha: 0.68))
    ctx.fillPath()
    ctx.addPath(trayBackPath)
    ctx.setStrokeColor(cgColor(0x93C5FD, alpha: 0.34))
    ctx.setLineWidth(4.5)
    ctx.strokePath()
    ctx.restoreGState()

    // 4. Back-left media card (warm coral-orange for short video / media capture, tucked inside tray)
    drawCard(
        ctx: ctx,
        center: CGPoint(x: 396, y: 536),
        size: CGSize(width: 288, height: 360),
        angleDegrees: 12,
        radius: 44,
        topColor: 0xFB7185,
        bottomColor: 0xF97316,
        isBookmarkNotched: false,
        drawLines: false
    )

    // 5. Front-right bookmark/article card (vivid sky-cyan -> royal blue, tucked inside tray)
    drawCard(
        ctx: ctx,
        center: CGPoint(x: 586, y: 548),
        size: CGSize(width: 314, height: 384),
        angleDegrees: -9,
        radius: 46,
        topColor: 0x38BDF8,
        bottomColor: 0x2563EB,
        isBookmarkNotched: true,
        drawLines: true
    )

    // 6. Front sculpted pearl-white tray face overlapping the cards cleanly
    let trayLeft: CGFloat = 212
    let trayRight: CGFloat = 812
    let trayBottom: CGFloat = 200
    let trayTop: CGFloat = 434
    let trayCorner: CGFloat = 76

    let notchHalfWidth: CGFloat = 104
    let notchDepth: CGFloat = 58
    let cx: CGFloat = 512

    let frontTray = CGMutablePath()
    frontTray.move(to: CGPoint(x: trayLeft + trayCorner, y: trayBottom))
    frontTray.addLine(to: CGPoint(x: trayRight - trayCorner, y: trayBottom))
    frontTray.addArc(
        tangent1End: CGPoint(x: trayRight, y: trayBottom),
        tangent2End: CGPoint(x: trayRight, y: trayBottom + trayCorner),
        radius: trayCorner
    )
    frontTray.addLine(to: CGPoint(x: trayRight, y: trayTop - 44))
    frontTray.addQuadCurve(
        to: CGPoint(x: trayRight - 44, y: trayTop),
        control: CGPoint(x: trayRight, y: trayTop)
    )
    // Top-right lip into center scoop
    frontTray.addLine(to: CGPoint(x: cx + notchHalfWidth + 34, y: trayTop))
    frontTray.addCurve(
        to: CGPoint(x: cx, y: trayTop - notchDepth),
        control1: CGPoint(x: cx + notchHalfWidth - 4, y: trayTop),
        control2: CGPoint(x: cx + 56, y: trayTop - notchDepth)
    )
    frontTray.addCurve(
        to: CGPoint(x: cx - notchHalfWidth - 34, y: trayTop),
        control1: CGPoint(x: cx - 56, y: trayTop - notchDepth),
        control2: CGPoint(x: cx - notchHalfWidth + 4, y: trayTop)
    )
    // Top-left lip down to bottom-left
    frontTray.addLine(to: CGPoint(x: trayLeft + 44, y: trayTop))
    frontTray.addQuadCurve(
        to: CGPoint(x: trayLeft, y: trayTop - 44),
        control: CGPoint(x: trayLeft, y: trayTop)
    )
    frontTray.addLine(to: CGPoint(x: trayLeft, y: trayBottom + trayCorner))
    frontTray.addArc(
        tangent1End: CGPoint(x: trayLeft, y: trayBottom),
        tangent2End: CGPoint(x: trayLeft + trayCorner, y: trayBottom),
        radius: trayCorner
    )
    frontTray.closeSubpath()

    // Tray shadow onto cards
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 30, color: cgColor(0x020617, alpha: 0.42))
    ctx.addPath(frontTray)
    ctx.setFillColor(cgColor(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Tray pearl metallic gradient fill
    ctx.saveGState()
    ctx.addPath(frontTray)
    ctx.clip()
    let trayGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            cgColor(0xD8E8FF),
            cgColor(0xF5F9FF),
            cgColor(0xFFFFFF),
        ] as CFArray,
        locations: [0.0, 0.55, 1.0]
    )!
    ctx.drawLinearGradient(
        trayGrad,
        start: CGPoint(x: 512, y: trayBottom),
        end: CGPoint(x: 512, y: trayTop),
        options: []
    )

    // Subtle status indicator pill on the front of the collector tray (glowing cyan-blue)
    let pillRect = CGRect(x: 512 - 54, y: 274, width: 108, height: 22)
    let pillPath = CGPath(roundedRect: pillRect, cornerWidth: 11, cornerHeight: 11, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 14, color: cgColor(0x0EA5E9, alpha: 0.55))
    ctx.addPath(pillPath)
    ctx.setFillColor(cgColor(0x0284C7))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.restoreGState()

    // Crisp specular highlight along top lip of tray
    ctx.saveGState()
    ctx.addPath(frontTray)
    ctx.setStrokeColor(cgColor(0xFFFFFF, alpha: 0.9))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // 6. Outer squircle inner-rim highlight (macOS glass edge)
    ctx.addPath(squircle)
    ctx.setStrokeColor(cgColor(0xFFFFFF, alpha: 0.22))
    ctx.setLineWidth(6)
    ctx.strokePath()

    ctx.restoreGState() // end squircle clip
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let rootDir = URL(fileURLWithPath: fm.currentDirectoryPath)
let resourcesDir = rootDir.appendingPathComponent("Resources", isDirectory: true)
let iconsetDir = rootDir.appendingPathComponent(".build/AppIcon.iconset", isDirectory: true)
let icnsOutput = resourcesDir.appendingPathComponent("AppIcon.icns")
let previewPNG = rootDir.appendingPathComponent(".build/AppIcon-preview-1024.png")

try? fm.removeItem(at: iconsetDir)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try fm.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

let specs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for spec in specs {
    let rep = renderIconImage(pixelSize: spec.pixels)
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to encode PNG for \(spec.name)")
    }
    let outURL = iconsetDir.appendingPathComponent(spec.name)
    try pngData.write(to: outURL)
    if spec.pixels == 1024 {
        try pngData.write(to: previewPNG)
    }
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsOutput.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fatalError("iconutil failed with status \(proc.terminationStatus)")
}

print("Generated \(icnsOutput.path)")
