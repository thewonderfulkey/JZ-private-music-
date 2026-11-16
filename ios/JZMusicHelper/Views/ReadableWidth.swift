import SwiftUI

// MARK: - iPad 单列限宽
//
// 设计口径（IOS-IA-SCREENS §4.1）：iPad 不做侧栏，仍用顶部 Tab，但内容**限宽 700 居中**——
// 否则在 1024×1366 上，一行歌名会被拉成一条横贯全屏的白带，读起来很散。
// 判定逻辑在 LayoutRules（纯函数，有断言），这里只负责套布局。
extension View {
    /// 套在页面内容的容器上（ScrollView 里的 VStack / LazyVStack）：iPhone 上等于原宽，iPad 上居中 700
    func readableWidth() -> some View {
        modifier(ReadableWidthModifier())
    }
}

private struct ReadableWidthModifier: ViewModifier {
    @Environment(\.horizontalSizeClass) private var sizeClass

    func body(content: Content) -> some View {
        if sizeClass == .regular {
            content
                .frame(maxWidth: LayoutRules.maxContentWidth)
                .frame(maxWidth: .infinity)
        } else {
            content
        }
    }
}
