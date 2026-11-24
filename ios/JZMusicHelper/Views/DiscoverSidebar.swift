import SwiftUI

// MARK: - 侧边栏（抽屉）
//
// 版式参考网易云「发现」页左上角的三横钮 → 左侧抽屉。
//
// 2026-11-25 修：上一版把 `.ignoresSafeArea(edges: .vertical)` 加在了**整块面板**上，
// 于是标题被顶到状态栏底下、和「00:49」叠在一起。正确做法是
// **背景铺满（可以 ignore）、内容留在安全区**。这一版用 `.background { ... .ignoresSafeArea() }` 实现。
struct SidebarMenuButton: View {

    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tabChanged()
            action()
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .minimumTapTarget()
        }
        .accessibilityLabel("打开侧边栏")
    }
}

struct SidebarOverlay: View {

    @Binding var isOpen: Bool
    /// 点「助眠模式」
    let onSleep: () -> Void

    private let panelWidth: CGFloat = 300

    var body: some View {
        ZStack(alignment: .leading) {
            Color.black
                .opacity(isOpen ? 0.45 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(isOpen)
                .onTapGesture { isOpen = false }

            panel
                .frame(width: panelWidth)
                .offset(x: isOpen ? 0 : -panelWidth - 24)
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { v in if v.translation.width < -40 { isOpen = false } }
                )
        }
        .animation(Tokens.Motion.tabSwitch, value: isOpen)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            // 顶部：应用名（在安全区内，不再压状态栏）
            VStack(alignment: .leading, spacing: 4) {
                Text("JZ 音乐助手").font(.title3.weight(.bold))
                Text("把夜里的声音调好").font(FontRole.metadata).foregroundStyle(.secondary)
            }
            .padding(.top, Tokens.Spacing.m)

            VStack(spacing: 0) {
                row(icon: "moon.zzz.fill", title: "助眠模式",
                    subtitle: "八十四种环境音，可叠加") {
                    isOpen = false
                    onSleep()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.paper)
            )

            Spacer()

            Text("更多入口陆续搬进来")
                .font(FontRole.metadata)
                .foregroundStyle(.tertiary)
                .padding(.bottom, Tokens.Spacing.l)
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .frame(maxHeight: .infinity, alignment: .top)
        // 背景铺满整条（含状态栏），但**内容**留在安全区
        .background {
            Tokens.Palette.paperElevated
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
                .ignoresSafeArea(edges: .vertical)
        }
        .shadow(color: .black.opacity(isOpen ? 0.28 : 0), radius: 24, x: 8, y: 0)
    }

    private func row(icon: String, title: String, subtitle: String,
                     action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tabChanged()
            action()
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(Tokens.Palette.vermilion)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(FontRole.songTitle)
                    Text(subtitle).font(FontRole.metadata).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Tokens.Spacing.m)
            .padding(.vertical, Tokens.Spacing.s)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
