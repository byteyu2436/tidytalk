import SwiftUI

/// 胶囊下方的实时文字：放得下时居中；放不下时最新的文字贴着右边，旧文字向左流出并淡出。
/// 直接显示在屏幕上，不加玻璃底板；用较小的灰色文字，避免抢过胶囊本身。
struct LivePreviewView: View {
    let model: AppModel
    static let font = Font.system(size: 12)
    static let color = Color.primary.opacity(0.5)
    private static let padding: CGFloat = 4

    var body: some View {
        let text = model.livePreview
        ViewThatFits(in: .horizontal) {
            line(text)
            overflowing(text)
        }
        .padding(.horizontal, Self.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.35), value: text)
    }

    private func line(_ text: String) -> some View {
        Text(text)
            .font(Self.font)
            .foregroundStyle(Self.color)
            .lineLimit(1)
            .fixedSize()
    }

    /// 文字比胶囊长：右对齐显示最新的内容，左边渐隐，新字出现时整行向左滑动。
    private func overflowing(_ text: String) -> some View {
        Color.clear
            .overlay(alignment: .trailing) { line(text) }
            .clipped()
            .mask(
                LinearGradient(stops: [.init(color: .clear, location: 0),
                                       .init(color: .black, location: 0.18),
                                       .init(color: .black, location: 1)],
                               startPoint: .leading, endPoint: .trailing)
            )
    }
}
