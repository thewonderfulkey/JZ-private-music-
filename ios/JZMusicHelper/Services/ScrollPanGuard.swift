import Foundation
import Observation

// MARK: - 滚动时不许触发点击反馈（2026-11-27 老板）
//
// 老板原话：「当我上下滑动而不是点击的时候，不希望触发点击反馈，词条不亮；只有真正点击的时候才触发，
// 但点击松手的时候反馈要像现在这样完整显示再弹出播放页。滑动或者不想点的时候别触发点击反馈。」
//
// 为什么会亮：全 App 的统一按压反馈绑的是 `ButtonStyle.Configuration.isPressed`——
// 手指一落下就是 true，于是"想滑一下列表"也会先把那行点亮。SwiftUI 没有"正在滚动"的公开状态，
// 所以自己判：在根视图挂一个 `DragGesture(minimumDistance:)`，手指动了就记 `panning = true`。
//
// 判据放在纯函数里，CI 可断言；`ScrollPanGuard` 只负责广播这个状态。
enum PressFeedbackRules {
    /// 这一刻该不该显示按压反馈
    static func showsHighlight(pressed: Bool, panning: Bool) -> Bool {
        pressed && !panning
    }
}

@MainActor
@Observable
final class ScrollPanGuard {

    static let shared = ScrollPanGuard()

    /// 手指正在拖动（滚动）——这段时间里所有按压高亮都不亮
    private(set) var panning = false

    private var resetTask: Task<Void, Never>?

    private init() {}

    /// 拖动开始（`DragGesture.onChanged` 第一次触发）
    func begin() {
        resetTask?.cancel()
        resetTask = nil
        if !panning { panning = true }
    }

    /// 手指抬起。留 60ms 余量再复位：
    /// 抬手那一帧 `isPressed` 可能还残留 true，立刻复位会让"滑完刚好松手"闪一下高亮。
    func end() {
        resetTask?.cancel()
        resetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled else { return }
            self?.panning = false
        }
    }

    /// 测试/诊断用
    func resetForTesting() {
        resetTask?.cancel()
        resetTask = nil
        panning = false
    }
}
