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
    /// 上次排版时的字号、翻译开关和样式。
    private var layoutKey = ""
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
        // 自动隐藏后再关闭时也要复位，否则下次打开会停在上次的位置（可能在另一块屏幕上）
        fadingOut = false
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
                // 只有字号、翻译开关、样式变了才需要重新排版；字幕文字更新只需要显示出来
                let config = self.model.configStore.config
                let key = "\(config.captionSize)-\(config.captionTranslate)-\(config.captionStyle)"
                if key != self.layoutKey || !self.panel.isVisible {
                    self.layoutKey = key
                    self.layout()
                }
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

    // 行高只和字号有关，算一次记下来：每次字幕更新都会用到
    private static var lineHeights: [CaptionSize: CGFloat] = [:]
    private static var translationLineHeights: [CaptionSize: CGFloat] = [:]

    static func lineHeight(_ size: CaptionSize) -> CGFloat {
        if let cached = lineHeights[size] { return cached }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size.pointSize, weight: .medium)))
        lineHeights[size] = height
        return height
    }

    /// 译文比原文小一号。
    static func translationPointSize(_ size: CaptionSize) -> CGFloat {
        (size.pointSize * 0.86).rounded()
    }

    static func translationLineHeight(_ size: CaptionSize) -> CGFloat {
        if let cached = translationLineHeights[size] { return cached }
        let height = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: translationPointSize(size),
                                                                               weight: .regular)))
        translationLineHeights[size] = height
        return height
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
