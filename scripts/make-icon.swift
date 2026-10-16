// 生成 1024×1024 的应用图标 PNG：白色圆角方块 + 黑色声波。
// 用法：swift scripts/make-icon.swift <输出.png>
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS 图标网格：内容区 824pt，四周留出阴影空间
let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: rect, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 白色底板 + 轻微投影，让白色图标在浅色背景上也有轮廓
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor(white: 0, alpha: 0.28).cgColor)
ctx.addPath(shape)
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillPath()
ctx.restoreGState()

// 极淡的描边，保证在白色背景上能看清边缘
ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.setStrokeColor(NSColor(white: 0, alpha: 0.08).cgColor)
ctx.setLineWidth(2)
ctx.strokePath()

// 黑色声波：7 根圆头竖条，中间高两侧低，略带起伏；竖条较粗，缩到 Dock、菜单大小也清楚
let heights: [CGFloat] = [0.30, 0.62, 0.88, 1.0, 0.74, 0.50, 0.26]
let barWidth: CGFloat = 64
let gap: CGFloat = 40
let maxHeight: CGFloat = 440
let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
var x = rect.midX - totalWidth / 2
ctx.setFillColor(NSColor.black.cgColor)
for h in heights {
    let height = max(barWidth, maxHeight * h)
    let bar = CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
    ctx.fillPath()
    x += barWidth + gap
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
