import AppKit

// 生成社交分享封面图（微信、X、Slack 等分享链接时显示）。
// 用法：swift make-site-images.swift <应用图标 PNG> <输出目录>，生成网站用的 og-zh.png 和 og-en.png（1200×630）；
// 末尾加 github 参数时改为生成 GitHub 仓库的社交预览图 github-social-preview.png（1280×640），
// 以及 README 中文版头图用的 github-social-preview-zh.png。

var width: CGFloat = 1200
var height: CGFloat = 630

func render(icon: NSImage, title: String, tagline: String, footnote: String, chips: [String] = [], to url: URL) {
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
        (block(tagline, size: 38, weight: .semibold, gray: 0.22, maxWidth: textWidth), CGFloat(chips.isEmpty ? 22 : 30)),
        (block(footnote, size: 26, weight: .regular, gray: 0.5, maxWidth: textWidth), CGFloat(0)),
    ]

    // 功能标签：圆角胶囊，放不下时换行
    let chipFont = NSFont.systemFont(ofSize: 24, weight: .medium)
    let chipHeight: CGFloat = 46, chipGap: CGFloat = 12, chipPadding: CGFloat = 20
    var chipRows: [[(NSAttributedString, CGFloat)]] = chips.isEmpty ? [] : [[]]
    var rowWidth: CGFloat = 0
    for chip in chips {
        let string = NSAttributedString(string: chip, attributes: [
            .font: chipFont, .foregroundColor: NSColor(white: 0.2, alpha: 1)])
        let chipWidth = ceil(string.size().width) + chipPadding * 2
        if rowWidth > 0 && rowWidth + chipWidth > textWidth {
            chipRows.append([])
            rowWidth = 0
        }
        chipRows[chipRows.count - 1].append((string, chipWidth))
        rowWidth += chipWidth + chipGap
    }
    let chipsHeight = chipRows.isEmpty ? 0 : CGFloat(chipRows.count) * (chipHeight + chipGap) - chipGap + 30

    let total = blocks.reduce(0) { $0 + $1.0.1 + $1.1 } + chipsHeight
    var top = (height + total) / 2
    for (index, ((string, blockHeight), gap)) in blocks.enumerated() {
        string.draw(with: NSRect(x: textX, y: top - blockHeight, width: textWidth, height: blockHeight),
                    options: [.usesLineFragmentOrigin])
        top -= blockHeight + gap
        // 标签放在副标题和脚注之间
        guard index == 1, !chipRows.isEmpty else { continue }
        for row in chipRows {
            var x = textX
            for (string, chipWidth) in row {
                let rect = NSRect(x: x, y: top - chipHeight, width: chipWidth, height: chipHeight)
                NSColor(white: 0, alpha: 0.06).setFill()
                NSBezierPath(roundedRect: rect, xRadius: chipHeight / 2, yRadius: chipHeight / 2).fill()
                let size = string.size()
                string.draw(at: NSPoint(x: x + chipPadding, y: rect.midY - size.height / 2))
                x += chipWidth + chipGap
            }
            top -= chipHeight + chipGap
        }
        top += chipGap - 30
    }

    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let icon = NSImage(contentsOfFile: CommandLine.arguments[1])!
let dir = URL(fileURLWithPath: CommandLine.arguments[2])
if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "github" {
    width = 1280
    height = 640
    render(icon: icon, title: "Tidytalk", tagline: "Hold to talk. Let go, and you get clean text.",
           footnote: "Free and open source · macOS 26+ on Apple silicon",
           chips: ["On-device speech", "Live captions", "File transcription"],
           to: dir.appending(path: "github-social-preview.png"))
    render(icon: icon, title: "Tidytalk", tagline: "按住说话，松开就是整理好的文字",
           footnote: "免费开源 · macOS 26 及以上 · Apple 芯片",
           chips: ["本机识别语音", "实时字幕", "转写文件和链接"],
           to: dir.appending(path: "github-social-preview-zh.png"))
    exit(0)
}
render(icon: icon, title: "Tidytalk", tagline: "按住说话，松开就是整理好的文字",
       footnote: "macOS 段落式语音输入 · 免费开源", to: dir.appending(path: "og-zh.png"))
render(icon: icon, title: "Tidytalk", tagline: "Hold to talk. Let go, and you get clean text.",
       footnote: "Voice input for Mac · Free and open source", to: dir.appending(path: "og-en.png"))
