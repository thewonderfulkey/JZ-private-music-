import SwiftUI

// MARK: - 底部主导航（第三十二轮：对齐 Light Player 的选中胶囊 + 滑动切换）
//
// 为什么不再用系统 TabView 的 tab bar：
// 老板 2026-11-18 发来 Light Player 实测录屏，明确说喜欢"切换底层栏的动画"——
// 选中项会从一排图标里"长"成一颗带文字的胶囊，切走时胶囊滑到下一个位置、文字交叉淡出。
// 系统 tab bar 的选中态是 tint 变色，没有可插手的位移，所以这里自绘一条；
// Tab 内容仍由 RootTabView 的 visited-set 容器托管（见 RootTabView）。
//
// 手感（照录屏逐帧对）：
//   · 按下：整颗图标缩到 0.93、压暗到 0.7（0.14s 紧 spring）
//   · 落点：胶囊 0.36s / 0.80 damping 滑过去，过冲一点点就停
//   · 选中：图标换成实心 + 朱砂，symbol 弹一下；文字只做淡入，不参与位移
//   · 触觉：只在真的换 Tab 时给一次 selection（同一次点击不给两下）
struct JZTabBar: View {

    @Binding var selection: AppRouter.Tab
    var downloadBadge: Int = 0

    @Namespace private var pillSpace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppRouter.Tab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: JZTabBarMetrics.height)
        // 第 41 轮 P0-1：栏自己的动画改成**值驱动**，只作用在栏这一棵子树里。
        // 以前是按钮 action 里 `withAnimation { selection = tab }` —— 那个事务同时把
        // "页面插入"也包进去了：下载页要建几百行，底部栏的按压回弹/胶囊滑动就跟着一起被冻住
        // （老板录屏里"点下载那一瞬间按钮变小一下"）。
        .animation(reduceMotion ? .easeOut(duration: 0.15) : Tokens.Motion.tabSwitch, value: selection)
        // 栏高固定 58：Dynamic Type 放到 AX5 时标签会顶破胶囊，这里把栏内字号上限收到 xxLarge。
        // 读屏用户走 VoiceOver 的完整标签，不依赖视觉字号。
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .background(alignment: .top) { topDivider }
        .background(Tokens.Palette.paper.ignoresSafeArea(edges: .bottom))
        .accessibilityElement(children: .contain)
    }

    // MARK: 单个 Tab

    private func tabButton(_ tab: AppRouter.Tab) -> some View {
        let selected = selection == tab
        return Button {
            guard selection != tab else { return }
            Haptics.tabChanged()
            PerfProbe.tabTapped(tab.rawValue)
            // 第 41 轮 P0-1：**不要**用 `withAnimation` 包这次赋值。
            // 它同时驱动页面插入，下载页（几百上千行）会在这个事务里建，
            // 栏自己的弹簧就被拖住不动了。动画改由上面 HStack 的 `.animation(_:value:)` 负责。
            selection = tab
        } label: {
            HStack(spacing: 5) {
                tabIcon(tab, selected: selected)
                if selected {
                    Text(tab.barTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Tokens.Palette.vermilion)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, selected ? 10 : 0)
            .frame(height: JZTabBarMetrics.pillHeight)
            .background {
                if selected {
                    pill
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: JZTabBarMetrics.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(TabItemPressStyle())
        .accessibilityLabel(tab.accessibilityTitle)
        .accessibilityValue(tab == .downloads && downloadBadge > 0 ? "\(downloadBadge) 个下载" : "")
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : [])
    }

    /// 选中胶囊：正常动效下用 matchedGeometry 在槽位之间滑动；
    /// 减弱动效下不滑，只换底色（位移全部取消）。
    @ViewBuilder
    private var pill: some View {
        if reduceMotion {
            Capsule(style: .continuous)
                .fill(Tokens.Palette.vermilion.opacity(0.10))
        } else {
            Capsule(style: .continuous)
                .fill(Tokens.Palette.vermilion.opacity(0.10))
                .matchedGeometryEffect(id: "tab.pill", in: pillSpace)
        }
    }

    private func tabIcon(_ tab: AppRouter.Tab, selected: Bool) -> some View {
        Image(systemName: selected ? tab.filledSymbol : tab.symbol)
            .font(.system(size: JZTabBarMetrics.iconSize,
                          weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? Tokens.Palette.vermilion : Color.secondary)
            .frame(width: 24, height: 24)
            .overlay(alignment: .topTrailing) {
                if tab == .downloads, downloadBadge > 0 {
                    badge
                }
            }
            .symbolEffect(.bounce, value: selected && !reduceMotion)
    }

    private var badge: some View {
        Text(downloadBadge > 99 ? "99+" : "\(downloadBadge)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Tokens.Palette.vermilion))
            .offset(x: 9, y: -6)
            .accessibilityHidden(true)
    }

    private var topDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
            .accessibilityHidden(true)
    }
}

// MARK: - 底部栏尺寸

enum JZTabBarMetrics {
    /// 内容高度（不含 home indicator 安全区）
    static let height: CGFloat = 58
    /// 选中胶囊高度
    static let pillHeight: CGFloat = 34
    /// 图标字号（图标允许硬编码字号，见 UI 卫生 R1）
    static let iconSize: CGFloat = 19
}

// MARK: - 按压

/// 底部栏专用：按下时整颗图标"陷"一下。不用 `.plain`——那样按下去毫无画面。
private struct TabItemPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .opacity(configuration.isPressed ? 0.70 : 1)
            .animation(configuration.isPressed ? Tokens.Motion.pressDown : Tokens.Motion.pressUp,
                       value: configuration.isPressed)
    }
}
