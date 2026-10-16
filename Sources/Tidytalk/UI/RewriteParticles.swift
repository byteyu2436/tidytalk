import SwiftUI

/// 语音改写时环绕胶囊的光点：从胶囊边缘生成，沿法线方向向外发散，越飞越慢并淡出。
///
/// 每个光点的位置由时间和编号直接算出，不需要保存状态；不改写时暂停刷新，不占用资源。
struct RewriteParticles: View {
    let model: AppModel
    /// 胶囊到视图边缘的距离，光点在这段空间里活动。
    let margin: CGFloat

    private static let count = 64
    /// 接近 Apple 智能的配色：蓝、紫、粉、橙。
    private static let palette: [Color] = [
        Color(nsColor: .systemBlue), Color(nsColor: .systemPurple),
        Color(nsColor: .systemPink), Color(nsColor: .systemOrange), Color(nsColor: .systemTeal),
    ]

    var body: some View {
        let active = model.sparkles
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { context, size in
                guard active else { return }
                let time = timeline.date.timeIntervalSinceReferenceDate
                let capsule = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
                for index in 0..<Self.count {
                    draw(index, at: time, around: capsule, in: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ index: Int, at time: TimeInterval, around capsule: CGRect, in context: inout GraphicsContext) {
        let seed = Double(index)
        let lifetime = 0.9 + fract(seed * 0.618) * 0.7
        let cycleTime = time / lifetime + fract(seed * 0.381)
        let cycle = floor(cycleTime)
        let progress = cycleTime - cycle            // 0 → 1：从边缘出发到消失
        let random = hash(seed, cycle)

        // 出发点沿胶囊边缘随机分布，方向为边缘法线再随机偏转一点，形成放射状
        let (origin, normal) = Self.pointOnCapsule(capsule, at: random)
        let spread = (fract(random * 7.7) - 0.5) * 0.5   // 约 ±15°
        let direction = CGVector(dx: normal.dx * cos(spread) - normal.dy * sin(spread),
                                 dy: normal.dx * sin(spread) + normal.dy * cos(spread))
        // 先快后慢地飞出，最远接近面板边缘
        let reach = (margin - 6) * (0.55 + 0.45 * fract(random * 3.9))
        let travel = 1 + reach * (1 - pow(1 - progress, 2.2))
        let head = CGPoint(x: origin.x + direction.dx * travel, y: origin.y + direction.dy * travel)

        let alpha = progress < 0.15 ? progress / 0.15 : pow(1 - progress, 1.3)
        let radius = (0.9 + 1.3 * fract(random * 9.1)) * (1 - progress * 0.5)
        let color = Self.palette[index % Self.palette.count]

        // 拖尾：沿运动方向的一小段渐隐线，表现向外飞散的速度感
        let tailLength = 6 * (1 - progress) + 1
        let tail = CGPoint(x: head.x - direction.dx * tailLength, y: head.y - direction.dy * tailLength)
        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        context.stroke(streak, with: .linearGradient(Gradient(colors: [color.opacity(0), color.opacity(alpha * 0.7)]),
                                                     startPoint: tail, endPoint: head),
                       style: StrokeStyle(lineWidth: radius * 1.4, lineCap: .round))
        // 外层柔光 + 内层亮点
        context.fill(Path(ellipseIn: CGRect(x: head.x - radius * 2.6, y: head.y - radius * 2.6,
                                            width: radius * 5.2, height: radius * 5.2)),
                     with: .color(color.opacity(alpha * 0.22)))
        context.fill(Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius,
                                            width: radius * 2, height: radius * 2)),
                     with: .color(color.opacity(alpha)))
    }

    /// 胶囊边缘上按周长比例 `t`（0…1）取点，返回该点和向外的法线。
    static func pointOnCapsule(_ rect: CGRect, at t: Double) -> (CGPoint, CGVector) {
        let r = rect.height / 2
        let straight = max(0, rect.width - 2 * r)
        let arc = Double.pi * r
        var s = t * (2 * straight + 2 * arc)
        let leftCenter = CGPoint(x: rect.minX + r, y: rect.midY)
        let rightCenter = CGPoint(x: rect.maxX - r, y: rect.midY)

        if s < straight {                               // 上边，从左到右
            return (CGPoint(x: leftCenter.x + s, y: rect.minY), CGVector(dx: 0, dy: -1))
        }
        s -= straight
        if s < arc {                                    // 右半圆，从上到下
            let angle = -Double.pi / 2 + s / r
            return (CGPoint(x: rightCenter.x + r * cos(angle), y: rightCenter.y + r * sin(angle)),
                    CGVector(dx: cos(angle), dy: sin(angle)))
        }
        s -= arc
        if s < straight {                               // 下边，从右到左
            return (CGPoint(x: rightCenter.x - s, y: rect.maxY), CGVector(dx: 0, dy: 1))
        }
        s -= straight
        let angle = Double.pi / 2 + s / r               // 左半圆，从下到上
        return (CGPoint(x: leftCenter.x + r * cos(angle), y: leftCenter.y + r * sin(angle)),
                CGVector(dx: cos(angle), dy: sin(angle)))
    }

    private func fract(_ x: Double) -> Double { x - floor(x) }

    private func hash(_ a: Double, _ b: Double) -> Double {
        fract(sin(a * 12.9898 + b * 78.233) * 43758.5453)
    }
}
