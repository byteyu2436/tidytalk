import AppKit
import ImageIO
import UniformTypeIdentifiers

// 为网站压缩图片。
//
//   swift optimize-site-images.swift screenshot <窗口截图.png> <输出前缀> <宽度> [浅色背景 深色背景]
//     把带透明阴影的窗口截图缩放后，分别铺在浅色和深色页面背景上，生成 <前缀>-light.jpg 和 <前缀>-dark.jpg。
//     背景色默认是页面底色（浅色 ffffff、深色 000000）；放在灰色区块里的截图传 --surface-2 的颜色，
//     例如 f2f2f5 1d1d20，否则截图四周会露出一块颜色不同的方框。
//   swift optimize-site-images.swift jpeg <图片.png> <输出.jpg>
//     不透明的图片（例如分享封面图）直接转成 JPEG。
//   swift optimize-site-images.swift ico <图标.png> <输出.ico>
//     生成包含 16、32、48 像素的 favicon.ico。

func load(_ path: String) -> CGImage {
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(source, 0, nil)!
}

func draw(_ image: CGImage, width: Int, height: Int, background: CGColor?) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    if let background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

func write(_ images: [CGImage], to path: String, type: UTType, quality: Double? = nil) {
    let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                      type.identifier as CFString, images.count, nil)!
    let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
    for image in images { CGImageDestinationAddImage(destination, image, options) }
    precondition(CGImageDestinationFinalize(destination), "写入失败：\(path)")
}

let args = CommandLine.arguments
switch args[1] {
case "screenshot":
    let image = load(args[2])
    let width = Int(args[4])!
    let height = Int((Double(image.height) * Double(width) / Double(image.width)).rounded())
    func color(_ hex: String) -> CGColor {
        let value = Int(hex, radix: 16)!
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                       blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
    let backgrounds = [("light", color(args.count > 6 ? args[5] : "ffffff")),
                       ("dark", color(args.count > 6 ? args[6] : "000000"))]
    for (name, color) in backgrounds {
        write([draw(image, width: width, height: height, background: color)],
              to: "\(args[3])-\(name).jpg", type: .jpeg, quality: 0.82)
    }
    print("\(args[3])：\(width)×\(height)")
case "jpeg":
    let image = load(args[2])
    write([draw(image, width: image.width, height: image.height, background: CGColor(gray: 1, alpha: 1))],
          to: args[3], type: .jpeg, quality: 0.86)
case "ico":
    let image = load(args[2])
    write([16, 32, 48].map { draw(image, width: $0, height: $0, background: nil) }, to: args[3], type: .ico)
default:
    fatalError("未知命令：\(args[1])")
}
