import AppKit

// 生成网站的社交分享封面图（1200×630，微信、X、Slack 等分享链接时显示）。
// 用法：swift make-site-images.swift <应用图标 PNG> <输出目录>，生成 og-zh.png 和 og-en.png。

let width: CGFloat = 1200
let height: CGFloat = 630

func render(icon: NSImage, title: String, tagline: String, footnote: String, to url: URL) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext

    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [CGColor(gray: 0.985, alpha: 1), CGColor(gray: 0.93, alpha: 1)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: .zero, options: [])

    // 图标：左侧垂直居中，带一点阴影
    let iconSize: CGFloat = 300
    let iconRect = NSRect(x: 110, y: (height - iconSize) / 2, width: iconSize, height: iconSize)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -10), blur: 40, color: CGColor(gray: 0, alpha: 0.18))
    icon.draw(in: iconRect)
    context.restoreGState()

    // 从上往下排三段文字，整体在右半边垂直居中
    func block(_ text: String, size: CGFloat, weight: NSFont.Weight, gray: CGFloat, maxWidth: CGFloat) -> (NSAttributedString, CGFloat) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = size * 0.2
        let string = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(white: gray, alpha: 1),
            .paragraphStyle: paragraph,
        ])
        let bounds = string.boundingRect(with: NSSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin])
        return (string, ceil(bounds.height))
    }
    let textX: CGFloat = 480
    let textWidth = width - textX - 70
    let blocks = [
        (block(title, size: 92, weight: .bold, gray: 0.08, maxWidth: textWidth), CGFloat(18)),
        (block(tagline, size: 38, weight: .semibold, gray: 0.22, maxWidth: textWidth), CGFloat(22)),
        (block(footnote, size: 26, weight: .regular, gray: 0.5, maxWidth: textWidth), CGFloat(0)),
    ]
    let total = blocks.reduce(0) { $0 + $1.0.1 + $1.1 }
    var top = (height + total) / 2
    for ((string, blockHeight), gap) in blocks {
        string.draw(with: NSRect(x: textX, y: top - blockHeight, width: textWidth, height: blockHeight),
                    options: [.usesLineFragmentOrigin])
        top -= blockHeight + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!
let dir = URL(fileURLWithPath: CommandLine.arguments[2])
render(icon: icon, title: "Tidytalk", tagline: "按住说话，松开就是整理好的文字",
       footnote: "macOS 段落式语音输入 · 免费开源", to: dir.appending(path: "og-zh.png"))
render(icon: icon, title: "Tidytalk", tagline: "Hold to talk. Let go, and you get clean text.",
       footnote: "Voice input for Mac · Free and open source", to: dir.appending(path: "og-en.png"))
