import Foundation

// MARK: - 开屏闸门（2026-11-27：开屏动画又开始"时不时顿一下"）
//
// 背景：`JZMusicHelperApp` 里首页是**在开屏底下照常挂载**的（当初为了"动画一退场就是现成的界面，
// 不用再等一次白屏"）。副作用是发现页会在动画那 1.4 秒里同时拉网络、解图、搭首帧——
// 主线程一被抢，动画就顿。
//
// 逐帧实测（2026-11-27 老板录屏，30fps）：
//   · 每次启动都在同一处静止 ≈130ms（时间轴自己的空档，所有人一样）；
//   · **额外 100–200ms 的停顿只在部分启动出现**，位置在动画最开头 → 那是启动那一下的主线程竞争。
//
// 做法：网络/解码这些"不急的活"等开屏退场后再开始。缓存依然在 `init` 里同步读进来，
// 所以动画退场那一刻页面**照样有内容**，不会回到"先闪一屏骨架"。
//
// 为什么不用固定延时：延时是猜的，改动一处就得重猜；这里由开屏自己发信号，谁先谁后是确定的。
// 超时兜底 3 秒：万一开屏因为别的原因没退场（比如被系统打断），不能把整页数据永远卡死。

@MainActor
final class LaunchGate {

    static let shared = LaunchGate()

    private(set) var splashFinished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private init() {}

    /// 开屏退场（自然播完 / 用户点击跳过，两条路都走这里）
    func markSplashFinished() {
        guard !splashFinished else { return }
        splashFinished = true
        let pending = waiters
        waiters.removeAll()
        for cont in pending { cont.resume() }
    }

    /// 等开屏退场；`timeout` 秒还没等到就自己放行（不让数据永远等着）
    func waitForSplash(timeout: Double = 3) async {
        if splashFinished { return }
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.markSplashFinished()
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            if splashFinished {
                cont.resume()
            } else {
                waiters.append(cont)
            }
        }
        timeoutTask.cancel()
    }

    /// 测试/诊断用：把闸门复位（线上不调用）
    func resetForTesting() {
        splashFinished = false
    }
}
