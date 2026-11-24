import SwiftUI

// MARK: - 页头的「播放全部 + 随机」一对键（2026-11-24）
//
// 老板：「只有我的收藏和下载页有随机，导入的歌单首页没有 —— 类似的首页全都加上」；
// 随后（15:47 截屏）：「按钮文案不许被省略，要全部显示；按钮前面的歌单文案可以省略」。
// 主键（朱红实心）保持原来的样子，随机键用同尺寸的描边胶囊，不抢主次；
// 两键一起禁用（列表还没加载出来时点不动）。
//
// **宽度口径**：整对键按内容取宽（`fixedSize` + `layoutPriority`），任何情况下都不许压缩 ——
// 以前没这两句，左边的标题/副行把宽度吃光，「播放全部」就被压成了「▶ …」。
// 压缩要发生在左边那两行文案上（老板允许省略），而不是按钮上。
struct PlayAllButtons: View {

    var isEnabled: Bool = true
    var onPlayAll: () -> Void
    var onShuffle: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Button(action: onPlayAll) {
                label("播放全部", icon: "play.fill", primary: true)
            }
            .buttonStyle(.press)
            .disabled(!isEnabled)

            Button(action: onShuffle) {
                label("随机", icon: "shuffle", primary: false)
            }
            .buttonStyle(.press)
            .disabled(!isEnabled)
            .accessibilityHint("从这份列表里随机挑一首开始播放")
        }
        // 按钮文字必须完整显示：按内容固定宽度，让左边的标题/副行去截断
        .fixedSize(horizontal: true, vertical: false)
        .layoutPriority(1)
    }

    private func label(_ title: String, icon: String, primary: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(FontRole.button)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, primary ? Tokens.Spacing.m : Tokens.Spacing.s)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(primary ? Tokens.Palette.vermilion : Tokens.Palette.paperElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Color.primary.opacity(primary ? 0 : 0.10), lineWidth: 0.5)
        )
        .foregroundStyle(primary ? Color.white : Color.primary)
    }
}
