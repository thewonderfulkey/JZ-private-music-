import SwiftUI
import UIKit

// MARK: - 全局「点/滑别处就收键盘」（2026-11-27 老板）
//
// 老板口径：键盘弹起时，**点键盘以外任何区域**要收；**滑动列表/页面**也要收；
// 全 App 一处能力，不要每个页面各写一遍；不能吞掉业务点击（点歌要能播、点行进详情、左滑出按钮）。
//
// 做法两层：
//   ① 点击：根视图挂一个 `simultaneousGesture(TapGesture)`——它**只旁听不抢**，
//      所以点歌/点行照常先执行，我们顺手 resignFirstResponder（"收键盘"和"点击"两件事同时发生）。
//   ② 滑动：不用每页加 `.scrollDismissesKeyboard`，而是把窗口里所有 `UIScrollView` 的
//      `keyboardDismissMode` 设成 `.onDrag`（iOS 上"拖动即收"就是这一条）。
//      滚动视图是随页面懒创建的，所以在键盘每次弹出时（`keyboardWillShow`）重扫一遍窗口。
//
// Sheet 是独立呈现层，根视图的手势盖不到，用 `.dismissKeyboardOnTap()` 单独挂（见各类编辑 Sheet）。

enum KeyboardDismiss {

    /// 立刻收起键盘
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }

    /// 全窗口只装一次：键盘弹出时重扫滚动视图，把"拖动收键盘"打开
    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { configureScrollViews() }
        }
        // 页面切换后新滚动视图会冒出来：回到前台 / 窗口可见时也补一遍
        NotificationCenter.default.addObserver(
            forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main
        ) { _ in
            DispatchQueue.main.async { configureScrollViews() }
        }
        configureScrollViews()
    }

    private static var installed = false

    /// 把当前所有窗口里的 UIScrollView 都设成"拖动即收键盘"
    static func configureScrollViews() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                setKeyboardDismissMode(in: window)
            }
        }
    }

    private static func setKeyboardDismissMode(in view: UIView) {
        if let scroll = view as? UIScrollView, scroll.keyboardDismissMode != .onDrag {
            scroll.keyboardDismissMode = .onDrag
        }
        for child in view.subviews {
            setKeyboardDismissMode(in: child)
        }
    }
}

// MARK: - Sheet 用：点空白收键盘

private struct DismissKeyboardOnTap: ViewModifier {
    func body(content: Content) -> some View {
        content
            // 同样只旁听：Sheet 里的按钮/开关/输入框点击不受影响
            .simultaneousGesture(TapGesture().onEnded { KeyboardDismiss.dismiss() })
    }
}

extension View {
    /// Sheet / 独立呈现层用：点这一层的任意位置都收键盘（不吞点击）
    func dismissKeyboardOnTap() -> some View {
        modifier(DismissKeyboardOnTap())
    }
}
