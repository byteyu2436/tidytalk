import AppKit
import SwiftUI

/// 屏幕底部居中的状态指示器。
///
/// 使用不激活的浮动面板：永远不会成为焦点窗口，也不响应鼠标，
/// 保证文字粘贴回用户原来的输入框。
///
/// 玻璃效果使用 AppKit 的 `NSGlassEffectView`（Liquid Glass）。SwiftUI 的 `.glassEffect()`
/// 放在透明的无边框窗口里时取不到窗口后面的内容，看起来只是一块灰色底板。
@MainActor
final class IndicatorPanel {
    static let height: CGFloat = 48
    /// 胶囊外圈背景模糊的宽度，向外逐渐淡出。
    private static let haloWidth: CGFloat = 28
    /// 胶囊四周留出的透明区域，容纳外圈模糊，并避免玻璃的高光被窗口边缘裁掉。
    static let margin: CGFloat = haloWidth + 12
    private static let bottomMargin: CGFloat = 72
    private static let horizontalPadding: CGFloat = 22
    private static let meterWidth: CGFloat = 120
    static let messageFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    static let tagFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let tagSpacing: CGFloat = 10

    private let model: AppModel
    private let panel: NSPanel
    private let glass = NSGlassEffectView()
    /// 胶囊下方的实时文字，直接显示，不加玻璃底板。
    private var preview: NSView!
    private var particles: NSView!
    static let previewSize = NSSize(width: 340, height: 18)
    static let previewGap: CGFloat = 8
    /// 胶囊外圈的背景模糊，让指示器融进屏幕，而不是硬生生贴在上面。
    private let halo = NSVisualEffectView()
    private var maskedCapsuleSize: NSSize?
    private var hideWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        panel = NonActivatingPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // 清透样式：与控制中心等浮在桌面上的系统控件一致，背后内容透出得更多、边缘高光更明显。
        // 不设 tintColor，"系统设置 › 外观 › Liquid Glass"和"降低透明度"仍由系统自动应用。
        glass.style = .clear
        glass.cornerRadius = Self.height / 2
        glass.contentView = NSHostingView(rootView: IndicatorView(model: model))

        halo.material = .hudWindow
        halo.blendingMode = .behindWindow
        // 面板永远不会成为活跃窗口，必须固定为 active，否则模糊会退化成灰色底板
        halo.state = .active

        preview = NSHostingView(rootView: LivePreviewView(model: model))
        preview.alphaValue = 0

        let container = NSView()
        container.addSubview(halo)
        // 语音改写时环绕胶囊的光点，位于外圈模糊和玻璃之间
        particles = NSHostingView(rootView: RewriteParticles(model: model, margin: Self.margin))
        container.addSubview(particles)
        container.addSubview(glass)
        container.addSubview(preview)
        panel.contentView = container
        layout(animated: false)
        observePhase()
    }

    func show() {
        hideWork?.cancel()
        hideWork = nil
        if !panel.isVisible {
            layout(animated: false, repositionToMouseScreen: true)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible, hideWork == nil else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
            self?.hideWork = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }

    /// 内容变化时（录音 → 处理中 → 提示文字）调整胶囊宽度。
    private func observePhase() {
        withObservationTracking {
            _ = model.visiblePhase
            _ = model.indicatorTag
            _ = model.showsLivePreview
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.layout(animated: self.panel.isVisible)
                self.observePhase()
            }
        }
    }

    private var capsuleWidth: CGFloat {
        let content: CGFloat
        if case .message(let text) = model.visiblePhase {
            let width = (text as NSString).size(withAttributes: [.font: Self.messageFont]).width
            content = max(Self.meterWidth, ceil(width))
        } else if let tag = model.indicatorTag {
            // 录音和处理中：电平条右边加上模式标签
            let width = (tag as NSString).size(withAttributes: [.font: Self.tagFont]).width
            content = Self.meterWidth + Self.tagSpacing + ceil(width)
        } else {
            content = Self.meterWidth
        }
        return content + Self.horizontalPadding * 2
    }

    /// 胶囊放在屏幕底部中间：首次显示时选鼠标所在的屏幕，之后保持在同一块屏幕上。
    private func layout(animated: Bool, repositionToMouseScreen: Bool = false) {
        let capsule = NSSize(width: capsuleWidth, height: Self.height)
        // 实时文字在胶囊下方：面板向下加高，胶囊在屏幕上的位置保持不变
        let showsPreview: Bool
        switch model.visiblePhase {
        case .recording, .processing: showsPreview = model.showsLivePreview
        default: showsPreview = false
        }
        let below = Self.previewSize.height + Self.previewGap
        let size = NSSize(width: max(capsule.width, Self.previewSize.width) + Self.margin * 2,
                          height: capsule.height + Self.margin * 2 + below)

        let screen: NSScreen?
        if repositionToMouseScreen || panel.screen == nil {
            let mouse = NSEvent.mouseLocation
            screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        } else {
            screen = panel.screen
        }
        guard let visible = screen?.visibleFrame else { return }

        let frame = NSRect(x: (visible.midX - size.width / 2).rounded(),
                           y: visible.minY + Self.bottomMargin - Self.margin - below,
                           width: size.width, height: size.height)
        let glassFrame = NSRect(x: ((size.width - capsule.width) / 2).rounded(), y: Self.margin + below,
                                width: capsule.width, height: capsule.height)
        let previewFrame = NSRect(x: ((size.width - Self.previewSize.width) / 2).rounded(), y: Self.margin,
                                  width: Self.previewSize.width, height: Self.previewSize.height)
        let particlesFrame = glassFrame.insetBy(dx: -Self.margin, dy: -Self.margin)
        let haloFrame = glassFrame.insetBy(dx: -Self.haloWidth, dy: -Self.haloWidth)
        if maskedCapsuleSize != capsule {
            halo.maskImage = Self.haloMask(capsule: capsule)
            maskedCapsuleSize = capsule
        }

        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                panel.animator().setFrame(frame, display: true)
                glass.animator().frame = glassFrame
                halo.animator().frame = haloFrame
                particles.animator().frame = particlesFrame
                preview.animator().frame = previewFrame
                preview.animator().alphaValue = showsPreview ? 1 : 0
            }
        } else {
            panel.setFrame(frame, display: false)
            glass.frame = glassFrame
            halo.frame = haloFrame
            particles.frame = particlesFrame
            preview.frame = previewFrame
            preview.alphaValue = showsPreview ? 1 : 0
        }
    }

    /// 外圈模糊的遮罩：胶囊内部留空，让玻璃直接透出背后的原始内容；
    /// 紧贴胶囊边缘也留一道很窄的过渡，模糊从那里才渐浓，再向外淡出，
    /// 避免模糊和玻璃边缘的高光融在一起，导致胶囊上下边看不清。
    private static func haloMask(capsule: NSSize) -> NSImage {
        let size = NSSize(width: capsule.width + haloWidth * 2, height: capsule.height + haloWidth * 2)
        let width = haloWidth
        let gap: CGFloat = 6        // 从胶囊边缘到模糊最浓处的距离
        let peak: CGFloat = 0.85
        return NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let inner = rect.insetBy(dx: width, dy: width)
            func capsulePath(_ r: NSRect) -> CGPath {
                CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
            }
            func alpha(atDistance d: CGFloat) -> CGFloat {
                if d < gap {
                    let t = d / gap
                    return peak * t * t * (3 - 2 * t)       // smoothstep 渐浓
                }
                let t = (d - gap) / (width - gap)
                return peak * pow(1 - t, 2)                 // 缓出淡出
            }
            ctx.setBlendMode(.copy)
            let steps = 40
            // 从外向内逐圈覆盖，每圈决定该距离处的透明度
            for step in stride(from: steps, through: 0, by: -1) {
                let d = width * CGFloat(step) / CGFloat(steps)
                let r = inner.insetBy(dx: -d, dy: -d)
                ctx.setFillColor(NSColor(white: 0, alpha: alpha(atDistance: d)).cgColor)
                ctx.addPath(capsulePath(r))
                ctx.fillPath()
            }
            ctx.setBlendMode(.clear)
            ctx.addPath(capsulePath(inner))
            ctx.fillPath()
            return true
        }
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - 视图

struct IndicatorView: View {
    let model: AppModel

    /// 电平条、处理动画和文字共用的颜色，保持一致。
    static let contentColor = Color.primary.opacity(0.85)

    var body: some View {
        // 玻璃底板由外层的 NSGlassEffectView 提供，这里只画内容。
        // 不给文字加阴影或光晕：浅色背景上光晕会向外扩散，文字边缘看起来发虚。
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.smooth(duration: 0.25), value: model.visiblePhase)
    }

    @ViewBuilder
    private var content: some View {
        switch model.visiblePhase {
        case .recording:
            withTag(LevelMeter(levels: model.levels))
                .transition(.opacity)
        case .processing:
            withTag(FlowingBars())
                .transition(.opacity)
        case .message(let text):
            Text(text)
                .font(Font(IndicatorPanel.messageFont))
                .foregroundStyle(IndicatorView.contentColor)
                .lineLimit(1)
                .transition(.opacity)
        case .idle:
            Color.clear.frame(width: 120, height: 20)
        }
    }

    private func withTag(_ meter: some View) -> some View {
        HStack(spacing: IndicatorPanel.tagSpacing) {
            meter
            if let tag = model.indicatorTag {
                // 和电平条同一个颜色；不用次要文字颜色，它在玻璃上会混入背景色，看起来发灰发虚
                Text(tag)
                    .font(Font(IndicatorPanel.tagFont))
                    .foregroundStyle(IndicatorView.contentColor)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

/// 录音时随音量跳动的电平条：中间高、两侧低，最新的电平在中间。
private struct LevelMeter: View {
    let levels: [Float]
    private let barCount = 11

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(IndicatorView.contentColor)
                    .frame(width: 4, height: height(for: index))
            }
        }
        .frame(width: 120, height: 28)
        .animation(.interactiveSpring(duration: 0.12), value: levels)
    }

    private func height(for index: Int) -> CGFloat {
        let center = barCount / 2
        let distance = abs(index - center)
        // 离中间越远，取越早的电平，形成向两侧扩散的效果
        let sample = levels.indices.contains(levels.count - 1 - distance * 2)
            ? levels[levels.count - 1 - distance * 2] : 0
        let falloff = 1 - Double(distance) / Double(center + 2)
        return 4 + CGFloat(Double(sample) * falloff) * 24
    }
}

/// 处理中：一道波从左到右流过。
private struct FlowingBars: View {
    private let barCount = 11

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<barCount, id: \.self) { index in
                    let phase = t * 4 - Double(index) * 0.45
                    let wave = (sin(phase) + 1) / 2
                    Capsule()
                        .fill(IndicatorView.contentColor.opacity(0.4 + 0.6 * wave))
                        .frame(width: 4, height: 6 + 14 * wave)
                }
            }
            .frame(width: 120, height: 28)
        }
    }
}
