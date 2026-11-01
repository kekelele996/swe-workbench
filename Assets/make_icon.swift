// 生成 SWE 工作台的 AppIcon.iconset。
// 用法：swift make_icon.swift <iconset 目录> [--variant dark|light] [--preview 目录]
//
// 图形：深色桌面上一张浅色任务卡，卡内三条阶梯任务行（100% / 78% / 52%），
// 最后一条用工作台的 signal 橙。缩到 16–32px 时仍是「浅色卡片 + 三道深色横线」的清晰轮廓。

import AppKit

// MARK: - 调色板（与 style.css 的 oklch 变量换算后一致）

func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

let ink = srgb(0x1A1E25)
let inkLifted = srgb(0x272C36)
let paper = srgb(0xF7F6F2)
let signal = srgb(0xD24515)

// MARK: - 几何

/// 超椭圆（squircle），指数 5 接近 macOS 图标的连续圆角。
func squircle(in rect: NSRect, exponent: CGFloat = 5) -> NSBezierPath {
    let path = NSBezierPath()
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let steps = 720
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let ct = cos(t), st = sin(t)
        let x = cx + a * copysign(pow(abs(ct), 2 / exponent), ct)
        let y = cy + b * copysign(pow(abs(st), 2 / exponent), st)
        if i == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
    }
    path.close()
    return path
}

func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

enum Variant: String {
    case dark
    case light

    var background: [NSColor] {
        switch self {
        case .dark: return [inkLifted, srgb(0x14171C)]
        case .light: return [srgb(0xFBFAF6), srgb(0xEFECE4)]
        }
    }

    var card: NSColor {
        switch self {
        case .dark: return paper
        case .light: return srgb(0xFFFEFA)
        }
    }

    /// 卡片上是否还需要一层细边框：浅色卡片放在深色底上需要，浅色底上则用阴影区分。
    var cardBorder: NSColor? {
        switch self {
        case .dark: return nil
        case .light: return NSColor.black.withAlphaComponent(0.07)
        }
    }

    var barPrimary: NSColor {
        switch self {
        case .dark: return ink
        case .light: return ink
        }
    }

    var barSecondary: NSColor {
        switch self {
        case .dark: return ink.withAlphaComponent(0.40)
        case .light: return ink.withAlphaComponent(0.35)
        }
    }

    var edge: NSColor {
        switch self {
        case .dark: return NSColor.white.withAlphaComponent(0.10)
        case .light: return NSColor.black.withAlphaComponent(0.08)
        }
    }

    var shadowAlpha: CGFloat {
        switch self {
        case .dark: return 0.42
        case .light: return 0.22
        }
    }
}

func drawIcon(in canvas: CGFloat, variant: Variant) {
    // 圆角底板
    let inset = canvas * 0.094
    let base = squircle(in: NSRect(x: inset, y: inset,
                                   width: canvas - inset * 2, height: canvas - inset * 2))

    if let gradient = NSGradient(colors: variant.background) {
        gradient.draw(in: base, angle: -90)
    } else {
        variant.background[0].setFill()
        base.fill()
    }

    // 顶部内高光
    NSGraphicsContext.saveGraphicsState()
    base.addClip()
    if let g = NSGradient(colors: [NSColor.white.withAlphaComponent(variant == .dark ? 0.07 : 0.50),
                                   NSColor.white.withAlphaComponent(0.0)]) {
        g.draw(in: NSRect(x: inset, y: canvas / 2, width: canvas - inset * 2, height: canvas / 2 - inset),
               angle: -90)
    }
    NSGraphicsContext.restoreGraphicsState()

    variant.edge.setStroke()
    base.lineWidth = max(1, canvas * 0.0045)
    base.stroke()

    // 任务卡
    let cardRect = NSRect(x: canvas * 0.178, y: canvas * 0.192,
                          width: canvas * 0.644, height: canvas * 0.616)
    let card = rounded(cardRect, canvas * 0.072)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(variant.shadowAlpha)
    shadow.shadowBlurRadius = canvas * 0.045
    shadow.shadowOffset = NSSize(width: 0, height: -canvas * 0.012)
    shadow.set()
    variant.card.setFill()
    card.fill()
    NSGraphicsContext.restoreGraphicsState()

    if let border = variant.cardBorder {
        border.setStroke()
        card.lineWidth = max(1, canvas * 0.002)
        card.stroke()
    }

    // 卡内三条阶梯任务行
    let pad = canvas * 0.060
    let barHeight = canvas * 0.060
    let gap = canvas * 0.040
    let totalHeight = barHeight * 3 + gap * 2
    let left = cardRect.minX + pad
    let width = cardRect.width - pad * 2
    let top = cardRect.midY + totalHeight / 2
    let ratios: [CGFloat] = [1.0, 0.78, 0.52]
    let colors: [NSColor] = [variant.barPrimary, variant.barSecondary, signal]

    for (index, ratio) in ratios.enumerated() {
        let y = top - CGFloat(index + 1) * barHeight - CGFloat(index) * gap
        let bar = rounded(NSRect(x: left, y: y, width: width * ratio, height: barHeight),
                          barHeight * 0.30)
        colors[index].setFill()
        bar.fill()
    }
}

func renderPNG(pixelSize: Int, variant: Variant) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixelSize,
                                     pixelsHigh: pixelSize,
                                     bitsPerSample: 8,
                                     samplesPerPixel: 4,
                                     hasAlpha: true,
                                     isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0,
                                     bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixelSize, height: pixelSize)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill()
    drawIcon(in: CGFloat(pixelSize), variant: variant)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// MARK: - 入口

let args = Array(CommandLine.arguments.dropFirst())
guard let output = args.first else {
    FileHandle.standardError.write("用法: make_icon.swift <iconset 目录> [--variant dark|light] [--preview 目录]\n".data(using: .utf8)!)
    exit(2)
}

var variant: Variant = .dark
var previewDirectory: String?
var index = 1
while index < args.count {
    switch args[index] {
    case "--variant":
        index += 1
        if index < args.count, let parsed = Variant(rawValue: args[index]) { variant = parsed }
    case "--preview":
        index += 1
        if index < args.count { previewDirectory = args[index] }
    default:
        break
    }
    index += 1
}

if let previewDirectory {
    try? FileManager.default.createDirectory(atPath: previewDirectory, withIntermediateDirectories: true)
    for size in [1024, 256, 128, 32] {
        for v in [Variant.dark, Variant.light] {
            if let data = renderPNG(pixelSize: size, variant: v) {
                try? data.write(to: URL(fileURLWithPath: "\(previewDirectory)/\(v.rawValue)-\(size).png"))
            }
        }
    }
    print("preview -> \(previewDirectory)")
    exit(0)
}

try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

// iconset 需要的点阵尺寸：16/32/128/256/512 各 @1x @2x。
let required: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]

for (points, scale) in required {
    let pixelSize = points * scale
    guard let data = renderPNG(pixelSize: pixelSize, variant: variant) else {
        FileHandle.standardError.write("渲染失败: \(pixelSize)px\n".data(using: .utf8)!)
        exit(1)
    }
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    try data.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}

print("iconset -> \(output) (\(variant.rawValue))")
