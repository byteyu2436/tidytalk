import AppKit
import SwiftUI
import TidytalkCore

/// 实时字幕条：浮在所有窗口（包括全屏视频）上方，显示最近两行字幕。
///
/// 不激活的面板，点它不会抢走当前应用的焦点；可以拖到任意位置。
/// 鼠标移上去时显示翻译、暂停和关闭按钮，关闭就是停止收听；停在某一句上时这句右边出现"粘贴"，
/// 点它从那一句粘贴到最新。点句子本身什么都不做，以免拖动字幕条时误粘贴。
/// 两种样式：深色（参照系统"实时字幕"，深色底板、白色文字，放在任何画面上都看得清），
/// 或者玻璃（和控制中心、说话指示器一样的清透玻璃，文字颜色跟随系统的深浅色）。
@MainActor
final class CaptionPanel {
    static let width: CGFloat = 720
    static let horizontalPadding: CGFloat = 20
    static let verticalPadding: CGFloat = 12
    /// 字幕条上方留出的透明区域：暂停、关闭按钮骑在右上角的边框上，不挡住字幕。
    private static let controlsInset: CGFloat = 15
    /// 默认位置：屏幕底部、说话指示器上方。
    private static let bottomMargin: CGFloat = 150
    private static let hideDelay: Duration = .seconds(10)
    private static let originKey = "captionPanelOrigin"

    private let model: AppModel
    private let panel: CaptionWindow
    private let container = CaptionContainerView()
    private let glass = NSGlassEffectView()
    private let controls: NSHostingView<CaptionControls>
    private var hideTask: Task<Void, Never>?
    private var fadingOut = false
    private var hovering = false
    fileprivate let targets = CaptionTargets()
    private let dimming = NSView()
    private var appliedStyle: CaptionStyle?
    fileprivate let textView: NSView

    /// 点了字幕条上的某一句（nil 表示正在说的这句）。
    var onPasteFrom: ((Int?) -> Void)?
    var onTranslate: ((Bool) -> Void)?
    var onPause: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    /// 截图用：一直显示鼠标移上去时的按钮。
    var showsControls = false {
        didSet { updateControls() }
    }

    init(model: AppModel) {
        self.model = model
        panel = CaptionWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                              backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.acceptsMouseMovedEvents = true

        glass.cornerRadius = 18
        dimming.wantsLayer = true
        dimming.layer?.cornerRadius = 18
        let text = PassthroughHostingView(rootView: CaptionTextView(model: model, targets: targets))
        text.autoresizingMask = [.width, .height]
        textView = text
        dimming.addSubview(text)
        glass.contentView = dimming

        controls = FirstMouseHostingView(rootView: CaptionControls(model: model))
        controls.alphaValue = 0
        controls.isHidden = true

        container.addSubview(glass)
        container.addSubview(controls)
        panel.contentView = container
        controls.rootView = CaptionControls(model: model,
                                            onTranslate: { [weak self] in self?.onTranslate?($0) },
                                            onPause: { [weak self] in self?.onPause?($0) },
                                            onClose: { [weak self] in self?.onClose?() })
        container.onHover = { [weak self] inside in
            self?.hovering = inside
            self?.updateControls()
            if !inside { self?.scheduleHide() }
        }
        container.onDragEnd = { [weak self] in self?.saveOrigin() }
        container.onMove = { [weak self] point in self?.hover(at: point) }
        container.onClick = { [weak self] point in self?.click(at: point) }
        applyStyle()
        observe()
    }

    /// 开始收听时显示在上次的位置（第一次在屏幕底部中间）。
    func show() {
        layout()
        reveal()
    }

    func close() {
        hideTask?.cancel()
        hideTask = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.model.isListening else { return }
                self.panel.orderOut(nil)
                self.hovering = false
                self.updateControls()
            }
        }
    }

    private func reveal() {
        fadingOut = false
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
        scheduleHide()
    }

    private func updateControls() {
        let visible = hovering || showsControls
        if visible { controls.isHidden = false }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            controls.animator().alphaValue = visible ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !(self.hovering || self.showsControls) else { return }
                self.controls.isHidden = true
            }
        }
    }

    /// 一段时间没有新字幕就淡出；暂停时、鼠标停在上面时保持显示。
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard !Task.isCancelled, let self, self.model.isListening, !self.model.listeningPaused,
                  self.model.configStore.config.captionAutoHide, !self.hovering
            else { return }
            self.fadingOut = true
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                self.panel.animator().alphaValue = 0
            }, completionHandler: nil)
        }
    }

    private func observe() {
        withObservationTracking {
            _ = model.captions
            _ = model.listeningPaused
            _ = model.configStore.config.captionSize
            _ = model.configStore.config.captionTranslate
            _ = model.configStore.config.captionStyle
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observe()
                self.applyStyle()
                guard self.model.isListening else { return }
                self.layout()
                self.reveal()
            }
        }
    }

    private func applyStyle() {
        let style = model.configStore.config.captionStyle
        guard style != appliedStyle else { return }
        appliedStyle = style
        switch style {
        case .dark:
            // 视频画面再亮，白字也看得清（玻璃的 tintColor 压不暗白色背景，在玻璃里再垫一层半透明黑色）
            panel.appearance = NSAppearance(named: .darkAqua)
            glass.style = .regular
            dimming.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        case .glass:
            // 和说话指示器一样的清透玻璃，不设 tintColor，"降低透明度"等系统设置照常生效
            panel.appearance = nil
            glass.style = .clear
            dimming.layer?.backgroundColor = nil
        }
    }

    static func lineHeight(_ size: CaptionSize) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size.pointSize, weight: .medium)))
    }

    /// 译文比原文小一号。
    static func translationPointSize(_ size: CaptionSize) -> CGFloat {
        (size.pointSize * 0.86).rounded()
    }

    static func translationLineHeight(_ size: CaptionSize) -> CGFloat {
        ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: translationPointSize(size), weight: .regular)))
    }

    /// 文字区域的高度：正好放下两句（各一行）；打开翻译时每句下面再加一行译文。
    static func textHeight(_ size: CaptionSize, translating: Bool) -> CGFloat {
        let gap = CaptionTextView.lineGap
        return translating ? (lineHeight(size) + gap + translationLineHeight(size)) * 2 + gap * 2
            : lineHeight(size) * 2 + gap * 2
    }

    private func layout() {
        let size = model.configStore.config.captionSize
        let glassHeight = Self.textHeight(size, translating: model.configStore.config.captionTranslate)
            + Self.verticalPadding * 2
        let height = glassHeight + Self.controlsInset
        let mouse = NSEvent.mouseLocation
        let screen = panel.isVisible ? panel.screen
            : NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let width = min(Self.width, visible.width - 40)
        let frameSize = NSSize(width: width, height: height)

        var origin: NSPoint
        if panel.isVisible || fadingOut {
            // 已经显示时保持底边不动，只调整高度
            origin = panel.frame.origin
        } else if let saved = UserDefaults.standard.string(forKey: Self.originKey).map(NSPointFromString),
                  NSScreen.screens.contains(where: { $0.visibleFrame.insetBy(dx: -1, dy: -1)
                      .contains(NSRect(origin: saved, size: frameSize)) }) {
            origin = saved
        } else {
            origin = NSPoint(x: (visible.midX - width / 2).rounded(), y: visible.minY + Self.bottomMargin)
        }
        if panel.frame.size != frameSize || panel.frame.origin != origin {
            panel.setFrame(NSRect(origin: origin, size: frameSize), display: true)
        }
        glass.frame = NSRect(x: 0, y: 0, width: width, height: glassHeight)
        glass.contentView?.subviews.first?.frame = glass.contentView?.bounds ?? .zero
        let controlsSize = controls.fittingSize
        controls.frame = NSRect(x: width - controlsSize.width - 12,
                                y: glassHeight - controlsSize.height / 2,
                                width: controlsSize.width, height: controlsSize.height)
    }

    private func saveOrigin() {
        UserDefaults.standard.set(NSStringFromPoint(panel.frame.origin), forKey: Self.originKey)
    }

    // MARK: - 点句子粘贴

    /// 窗口坐标 → 鼠标下面是哪一句。
    private func target(at windowPoint: NSPoint) -> CaptionTargets.Target? {
        guard model.isListening, !model.listeningPaused else { return nil }
        return targets.target(at: textView.convert(windowPoint, from: nil))
    }

    /// 鼠标下面的"粘贴"按钮属于哪一句。
    private func pasteButton(at windowPoint: NSPoint) -> CaptionTargets.Target? {
        guard model.isListening, !model.listeningPaused else { return nil }
        return targets.pasteButton(at: textView.convert(windowPoint, from: nil))
    }

    private func hover(at windowPoint: NSPoint?) {
        let target = windowPoint.flatMap(target(at:))
        if targets.hovered != target { targets.hovered = target }
        let onButton = windowPoint.flatMap(pasteButton(at:)) != nil
        container.toolTip = onButton ? String(localized: "从这句开始粘贴到最新") : nil
        if onButton { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
    }

    /// 只有点在"粘贴"按钮上才粘贴。
    fileprivate func click(at windowPoint: NSPoint) {
        guard let target = pasteButton(at: windowPoint) else { return }
        switch target {
        case .sentence(let id): onPasteFrom?(id)
        case .partial: onPasteFrom?(nil)
        }
    }
}

#if DEBUG || TIDYTALK_DEV_TOOLS
extension CaptionPanel {
    /// 开发用：让鼠标"停在"某一句上，截图看高亮。
    func debugHover(_ target: CaptionTargets.Target?) {
        targets.hovered = target
    }

    /// 开发用：在某一句（或它的"粘贴"按钮，需先 `debugHover` 到这一句）的中心模拟一次点击，走和真实点击相同的坐标换算。
    func debugClick(_ target: CaptionTargets.Target, onButton: Bool) {
        guard let frame = onButton ? targets.buttonFrames[target] : targets.frames[target] else { return }
        click(at: textView.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil))
    }
}
#endif

/// 字幕条上每一句的位置（文字视图的坐标，左上角为原点），用来判断鼠标在哪一句上。
@MainActor
@Observable
final class CaptionTargets {
    enum Target: Hashable {
        case sentence(Int)
        case partial
    }

    /// 布局时写入，不需要触发界面刷新。
    @ObservationIgnored var frames: [Target: CGRect] = [:]
    /// 鼠标停在某一句上时出现的"粘贴"按钮的位置。
    @ObservationIgnored var buttonFrames: [Target: CGRect] = [:]
    /// 鼠标所在的句子，高亮显示并出现"粘贴"按钮。
    var hovered: Target?

    func target(at point: CGPoint) -> Target? {
        frames.first { $0.value.insetBy(dx: -6, dy: -3).contains(point) }?.key
    }

    func pasteButton(at point: CGPoint) -> Target? {
        guard let hovered, let frame = buttonFrames[hovered], frame.insetBy(dx: -4, dy: -4).contains(point) else { return nil }
        return hovered
    }
}

private final class CaptionWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// 字幕条的底层视图：鼠标移入移出时显示、隐藏按钮；按住拖动整个字幕条。
private final class CaptionContainerView: NSView {
    var onHover: ((Bool) -> Void)?
    var onDragEnd: (() -> Void)?
    /// 鼠标在窗口里移动（窗口坐标），移出时为 nil。
    var onMove: ((NSPoint?) -> Void)?
    /// 按下后没有拖动就松开：当作点击（窗口坐标）。
    var onClick: ((NSPoint) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // 面板永远不是活跃窗口，必须用 activeAlways 才收得到移入移出
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) {
        onHover?(false)
        onMove?(nil)
    }
    override func mouseMoved(with event: NSEvent) { onMove?(event.locationInWindow) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let origin = window?.frame.origin
        window?.performDrag(with: event)
        if window?.frame.origin == origin {
            onClick?(event.locationInWindow)
        } else {
            onDragEnd?()
        }
    }
}

/// 只显示文字，鼠标事件交给底下的视图处理拖动。
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 面板不会成为活跃窗口，第一次点击就要响应按钮。
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - 视图

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
