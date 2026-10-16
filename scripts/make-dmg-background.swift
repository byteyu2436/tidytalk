import AppKit

// 生成 DMG 安装窗口的背景图：左边放应用、右边放"应用程序"文件夹，中间一个箭头。
// 用法：swift make-dmg-background.swift <输出目录>，生成 background.png（1x）和 background@2x.png。
// 尺寸和图标位置要与 make-dmg.sh 里的窗口布局一致。

let width: CGFloat = 640
let height: CGFloat = 400
let iconY: CGFloat = 180          // 图标中心，从窗口顶部算起
let appX: CGFloat = 170
let applicationsX: CGFloat = 470

func render(scale: CGFloat, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    // 改成从左上角算起，和 Finder 的图标坐标一致
    context.translateBy(x: 0, y: height)
    context.scaleBy(x: 1, y: -1)

    // 很淡的上下渐变，接近系统窗口的白
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(gray: 1, alpha: 1), CGColor(gray: 0.955, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])

    // 箭头：在两个图标之间，留出图标本身的宽度
    let start = CGPoint(x: appX + 92, y: iconY)
    let end = CGPoint(x: applicationsX - 92, y: iconY)
    context.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: start)
    context.addLine(to: end)
    context.move(to: CGPoint(x: end.x - 20, y: end.y - 18))
    context.addLine(to: end)
    context.addLine(to: CGPoint(x: end.x - 20, y: end.y + 18))
    context.strokePath()

    // 底部提示，中英文各一行
    func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, gray: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: gray, alpha: 1),
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        // 文字要在未翻转的坐标里画，否则会上下颠倒
        context.saveGState()
        context.translateBy(x: 0, y: height)
        context.scaleBy(x: 1, y: -1)
        string.draw(at: NSPoint(x: (width - bounds.width) / 2, y: height - y - bounds.height / 2))
        context.restoreGState()
    }
    centered("把 Tidytalk 拖到 Applications 文件夹", y: 318, size: 15, weight: .medium, gray: 0.35)
    centered("Drag Tidytalk to the Applications folder", y: 342, size: 12, weight: .regular, gray: 0.55)

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
render(scale: 1, to: dir.appending(path: "background.png"))
render(scale: 2, to: dir.appending(path: "background@2x.png"))
