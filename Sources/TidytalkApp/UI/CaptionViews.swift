import AppKit
import SwiftUI
import TidytalkCore

// 字幕条里的 SwiftUI 视图：字幕文字、粘贴按钮和右上角的控制按钮。

struct CaptionTextView: View {
    let model: AppModel
    let targets: CaptionTargets
    /// 原文和译文之间、两句之间的间距。
    static let lineGap: CGFloat = 4
    static let highlightInset: CGFloat = 6
    private static let space = "captions"

    @ViewState private var contentHeight: CGFloat = 0

    private var size: CaptionSize { model.configStore.config.captionSize }
    private var translating: Bool { model.configStore.config.captionTranslate }
    private var visibleHeight: CGFloat { CaptionPanel.textHeight(size, translating: translating) }
    /// 内容比字幕条高，最上面有被裁掉的部分。
    private var overflows: Bool { !isPlaceholder && contentHeight > visibleHeight + 1 }

    var body: some View {
        content
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            // 留出悬停高亮的边，不被下面的裁剪切成直角
            .padding(.horizontal, Self.highlightInset)
            // 只显示最后几行：文字从底部往上长，超出的部分裁掉
            // 提示文字只有一行，垂直居中
            .frame(maxWidth: .infinity, maxHeight: visibleHeight,
                   alignment: isPlaceholder ? .leading : .bottomLeading)
            .clipped()
            // 句子较长时最上面会有半行被裁掉，让它渐渐淡出而不是硬切
            .mask {
                VStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                        .frame(height: overflows ? CaptionPanel.lineHeight(size) * 0.6 : 0)
                    Color.black
                }
            }
            .padding(.horizontal, CaptionPanel.horizontalPadding - Self.highlightInset)
            .padding(.vertical, CaptionPanel.verticalPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(.named(Self.space))
    }

    private var isPlaceholder: Bool { model.listeningPaused || model.captions.isEmpty }

    private var originalFont: Font { .system(size: size.pointSize, weight: .medium) }

    @ViewBuilder
    private var content: some View {
        if model.listeningPaused {
            Text("已暂停").font(originalFont).foregroundStyle(.secondary)
        } else if model.captions.isEmpty {
            Text("正在收听…").font(originalFont).foregroundStyle(.secondary)
        } else {
            sentences
        }
    }

    /// 一句一段，打开翻译时每句原文下面跟一行译文；前面的句子淡一些，最新的一句（或正在说的这句）最清楚。
    private var sentences: some View {
        let sentences = Array(model.captions.sentences.suffix(4))
        let partial = model.captions.partial
        return VStack(alignment: .leading, spacing: Self.lineGap * 2) {
            ForEach(sentences) { sentence in
                VStack(alignment: .leading, spacing: Self.lineGap) {
                    Text(sentence.text).font(originalFont)
                    if translating, let translation = sentence.translation {
                        // 正式译文回来之前显示的是边听边翻的译文，淡一些
                        Text(translation)
                            .font(.system(size: CaptionPanel.translationPointSize(size)))
                            .foregroundStyle(.primary.opacity(sentence.isTranslating ? 0.6 : 0.8))
                    } else if translating, sentence.isTranslating {
                        Text(verbatim: "…")
                            .font(.system(size: CaptionPanel.translationPointSize(size)))
                            .foregroundStyle(.tertiary)
                    }
                }
                .opacity(partial.isEmpty && sentence.id == sentences.last?.id ? 1 : 0.55)
                .modifier(Target(target: .sentence(sentence.id), targets: targets, space: Self.space))
            }
            if !partial.isEmpty {
                VStack(alignment: .leading, spacing: Self.lineGap) {
                    Text(partial).font(originalFont)
                    // 边听边翻译：随原文更新
                    if translating, !model.captions.partialTranslation.isEmpty {
                        Text(model.captions.partialTranslation)
                            .font(.system(size: CaptionPanel.translationPointSize(size)))
                            .foregroundStyle(.primary.opacity(0.6))
                    }
                }
                .modifier(Target(target: .partial, targets: targets, space: Self.space))
            }
        }
    }

    /// 记下每一句的位置，鼠标停在上面时加一个浅色底，提示可以点。
    private struct Target: ViewModifier {
        let target: CaptionTargets.Target
        let targets: CaptionTargets
        let space: String

        func body(content: Content) -> some View {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.primary.opacity(targets.hovered == target ? 0.12 : 0))
                        .padding(.horizontal, -CaptionTextView.highlightInset)
                        .padding(.vertical, -3)
                }
                .overlay(alignment: .topTrailing) {
                    if targets.hovered == target {
                        PasteBadge()
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
                                targets.buttonFrames[target] = frame
                            }
                            .onDisappear { targets.buttonFrames[target] = nil }
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(space)) } action: { frame in
                    targets.frames[target] = frame
                }
                .onDisappear { targets.frames[target] = nil }
        }
    }
}

/// 鼠标停在某一句上时出现在这句右上角的"粘贴"按钮（只是外观，点击由底层视图按位置判断）。
private struct PasteBadge: View {
    var body: some View {
        Label("粘贴", systemImage: "doc.on.clipboard")
            .font(.caption.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.primary.opacity(0.18), in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.2)))
            .accessibilityLabel(String(localized: "从这句开始粘贴到最新"))
    }
}

/// 鼠标移上去时出现在右上角的翻译、暂停、关闭按钮。
struct CaptionControls: View {
    let model: AppModel
    var onTranslate: (Bool) -> Void = { _ in }
    var onPause: (Bool) -> Void = { _ in }
    var onClose: () -> Void = {}

    var body: some View {
        let translating = model.configStore.config.captionTranslate
        HStack(spacing: 4) {
            CaptionButton(symbol: "translate",
                          help: translating ? String(localized: "关闭翻译") : String(localized: "翻译字幕"),
                          isOn: translating) {
                onTranslate(!translating)
            }
            CaptionButton(symbol: model.listeningPaused ? "play.fill" : "pause.fill",
                          help: model.listeningPaused ? String(localized: "继续") : String(localized: "暂停")) {
                onPause(!model.listeningPaused)
            }
            CaptionButton(symbol: "xmark", help: String(localized: "停止收听")) { onClose() }
        }
        .padding(3)
        .background {
            if model.configStore.config.captionStyle == .dark {
                Capsule().fill(Color(white: 0.22))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay(Capsule().strokeBorder(.primary.opacity(0.15)))
        .fixedSize()
    }
}

private struct CaptionButton: View {
    let symbol: String
    let help: String
    var isOn = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.primary)
                .frame(width: 22, height: 22)
                // 打开的开关（翻译）垫一个浅色圆底
                .background(isOn ? AnyShapeStyle(.primary.opacity(0.25)) : AnyShapeStyle(.clear), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
