import SwiftUI

// MARK: - 侧边栏（抽屉）
//
// 老板给的样式参考是网易云「发现」页左上角那个三横钮 → 拉出左侧抽屉。
// 我们这边原本没有抽屉，这一版从零做，但按现有设计令牌收口：
// 纸底、浮起卡片、朱砂只出现在"当前项"上。
//
// 这一期抽屉里只放「助眠模式」一项（老板口径：先做轻，设置/定时后期再搬进来）。
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
            // 遮罩
            Color.black
                .opacity(isOpen ? 0.45 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(isOpen)
                .onTapGesture { close() }

            // 抽屉
            panel
                .frame(width: panelWidth)
                .offset(x: isOpen ? 0 : -panelWidth - 24)
                .ignoresSafeArea(edges: .vertical)
                // 往里一划也能收起来（不用非得点遮罩）
                .gesture(
                    DragGesture(minimumDistance: 20)
                        .onEnded { v in
                            if v.translation.width < -40 { close() }
                        }
                )
        }
        .animation(Tokens.Motion.tabSwitch, value: isOpen)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            // 顶部：应用名
            VStack(alignment: .leading, spacing: 4) {
                Text("JZ 音乐助手")
                    .font(.title3.weight(.bold))
                Text("把夜里的声音调好")
                    .font(FontRole.metadata)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, Tokens.Spacing.xxl)

            // 功能卡
            VStack(spacing: 0) {
                row(icon: "moon.zzz.fill", title: "助眠模式",
                    subtitle: "八种环境音，可叠加循环", isAccent: true) {
                    close()
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
                .padding(.bottom, Tokens.Spacing.xl)
        }
        .padding(.horizontal, Tokens.Spacing.m)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            Tokens.Palette.paperElevated
                .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.sheet, style: .continuous))
                .ignoresSafeArea(edges: .vertical)
        )
        .shadow(color: .black.opacity(isOpen ? 0.28 : 0), radius: 24, x: 8, y: 0)
    }

    private func row(icon: String, title: String, subtitle: String,
                     isAccent: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tabChanged()
            action()
        } label: {
            HStack(spacing: Tokens.Spacing.s) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(isAccent ? Tokens.Palette.vermilion : Color.secondary)
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

    private func close() {
        isOpen = false
    }
}

