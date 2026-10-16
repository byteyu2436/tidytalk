import AppKit

// 生成 AI 服务选项用的图标（应用和官网共用）：统一成 256×256 的圆角方块。
//
//   swift make-provider-icons.swift <Ollama 标志.png> <LM Studio 标志.png> <输出目录>
//
// 标志文件来自各自官网：https://ollama.com/public/ollama.png 和
// https://lmstudio.ai/assets/marketing/logo-192x192.png 。
// Ollama 的标志是透明底上的黑色线条，深色背景上看不见，所以铺在白色圆角方块上；
// LM Studio 的标志本身就是圆角方块，直接缩放；云端服务画一个白色云朵。

let size: CGFloat = 256
let radius: CGFloat = 58

func render(_ name: String, to dir: URL, draw: (CGContext) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(NSGraphicsContext.current!.cgContext)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appending(path: "\(name).png"))
}

func tile(_ context: CGContext, fill: [CGColor], border: CGColor?) {
    let rect = CGRect(x: 4, y: 4, width: size - 8, height: size - 8)
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    context.saveGState()
    context.addPath(path)
    context.clip()
    if fill.count > 1 {
        let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: fill as CFArray, locations: nil)!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size), end: .zero, options: [])
    } else {
        context.setFillColor(fill[0])
        context.fill(rect)
    }
    context.restoreGState()
    if let border {
        context.addPath(path)
        context.setStrokeColor(border)
        context.setLineWidth(4)
        context.strokePath()
    }
}

let args = CommandLine.arguments
let ollama = NSImage(contentsOfFile: args[1])!
let lmstudio = NSImage(contentsOfFile: args[2])!
let dir = URL(fileURLWithPath: args[3])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

render("ollama", to: dir) { context in
    tile(context, fill: [CGColor(gray: 1, alpha: 1)], border: CGColor(gray: 0, alpha: 0.12))
    // 标志高度占方块的 62%，按原比例居中
    let height = size * 0.62
    let width = height * ollama.size.width / ollama.size.height
    ollama.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
}

render("lmstudio", to: dir) { _ in
    lmstudio.draw(in: NSRect(x: 4, y: 4, width: size - 8, height: size - 8))
}

render("cloud", to: dir) { context in
    tile(context, fill: [CGColor(srgbRed: 0.31, green: 0.56, blue: 1, alpha: 1),
                         CGColor(srgbRed: 0.10, green: 0.38, blue: 0.93, alpha: 1)], border: nil)
    let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    let width = size * 0.6
    let height = width * symbol.size.height / symbol.size.width
    symbol.draw(in: NSRect(x: (size - width) / 2, y: (size - height) / 2, width: width, height: height))
}
print("完成：\(dir.path)")
