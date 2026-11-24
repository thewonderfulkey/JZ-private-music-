import SwiftUI

// MARK: - 页头的「播放全部 + 随机」一对键（2026-11-24）
//
// 老板：「只有我的收藏和下载页有随机，导入的歌单首页没有 —— 类似的首页全都加上」。
// 主键（朱红实心）保持原来的样子，随机键用同尺寸的描边胶囊，不抢主次；
// 两键一起禁用（列表还没加载出来时点不动）。
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
            .accessibilityHint("把这份列表打乱后从第一首开始放")
        }
    }

    private func label(_ title: String, icon: String, primary: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
            Text(title)
                .font(FontRole.button)
                .lineLimit(1)
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
