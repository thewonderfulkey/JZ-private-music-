import Foundation

// MARK: - 启动阶段面包屑（2026-11-27）
//
// 目的：闪退时**没有栈**也要知道"崩在哪一步"。做法是每个启动阶段往
// UserDefaults 写一个阶段名 + 时间，同时写进播放诊断（`PlaybackTrace` → `诊断/trace.log`）。
//
// 下次启动时，`reportLastRun()` 会把"上一次停在哪一阶段"作为第一条诊断记录下来：
//   · 如果上次最后一条是 `splash-done` 之后的阶段，说明是**用着用着崩的**；
//   · 如果停在 `splash-start` 之前，说明**还没进界面就崩了**（首装最可疑的那条路）。
//
// 只做记录，不改任何行为，开销是一次 UserDefaults 写（阶段总共十来次）。

enum LaunchBreadcrumbs {

    private static let stageKey = "launch.lastStage"
    private static let timeKey = "launch.lastStageAt"
    private static let cleanKey = "launch.lastExitClean"

    /// 记一个启动阶段
    @MainActor
    static func mark(_ stage: String) {
        let d = UserDefaults.standard
        d.set(stage, forKey: stageKey)
        d.set(Date().timeIntervalSince1970, forKey: timeKey)
        PlaybackTrace.shared.log("启动:\(stage)")
    }

    /// App 进入后台 = 这一次运行基本正常（闪退不会走这里）
    static func markCleanExit() {
        UserDefaults.standard.set(true, forKey: cleanKey)
    }

    /// 回到前台：清掉"干净退出"标记，下一次启动才能区分"上次是切后台还是崩了"
    static func markForeground() {
        UserDefaults.standard.set(false, forKey: cleanKey)
    }

    /// 上一次运行的收尾报告（在启动最早期调用，写进诊断）
    @MainActor
    static func reportLastRun() {
        let d = UserDefaults.standard
        guard let stage = d.string(forKey: stageKey), !stage.isEmpty else { return }
        let ts = d.double(forKey: timeKey)
        let clean = d.bool(forKey: cleanKey)
        let when = ts > 0
            ? DateFormatter.localizedString(from: Date(timeIntervalSince1970: ts),
                                            dateStyle: .none, timeStyle: .medium)
            : "—"
        let verdict = clean ? "上次正常退到后台" : "上次**没有**正常退到后台（可能是闪退/被杀）"
        PlaybackTrace.shared.log("上次运行", "最后阶段=\(stage) @\(when) · \(verdict)")
    }
}
