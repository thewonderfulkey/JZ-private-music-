import Foundation

// MARK: - 助眠模式的声音目录
//
// 八条内置素材，全部是**5 分钟严格无缝环**（`ios/JZMusicHelper/SleepLoops/*.m4a`）。
// 素材来源与响度口径见同目录 `manifest.json`：-20 LUFS 目标、真峰值 ≤ -3 dBFS、
// 80 Hz 二级×2 高通、8 秒等功率交叉淡化做环。
//
// 为什么是 8 条而不是更多：这是把参考样片（10 小时 / 30 个场景）按声音类型归并后的
// 最小完备集——水（湖/海/溪）、火、雨、风、植被、虫林六大类全覆盖。
// 目录顺序 = 助眠页九宫格的排列顺序。
struct SleepSound: Identifiable, Hashable, Sendable {

    /// 与 bundle 里的文件名一致（`SleepLoops/<id>.m4a`）
    let id: String
    /// 宫格下面的名字（短，两个汉字最好）
    let name: String
    /// SF Symbol
    let symbol: String
    /// 一句话说明：音量面板和无障碍朗读用
    let caption: String

    static let all: [SleepSound] = [
        SleepSound(id: "fire", name: "篝火", symbol: "flame.fill",
                   caption: "柴火爆裂"),
        SleepSound(id: "lake", name: "湖水", symbol: "drop.fill",
                   caption: "静水轻拍"),
        SleepSound(id: "sea", name: "海浪", symbol: "water.waves",
                   caption: "涌浪拍岸"),
        SleepSound(id: "stream", name: "溪流", symbol: "aqi.medium",
                   caption: "林间流水"),
        SleepSound(id: "rain", name: "雨叶", symbol: "cloud.rain.fill",
                   caption: "雨点打叶"),
        SleepSound(id: "wind", name: "风", symbol: "wind",
                   caption: "风过草坡"),
        SleepSound(id: "plants", name: "植被", symbol: "leaf.fill",
                   caption: "竹林摩挲"),
        SleepSound(id: "forest", name: "虫林", symbol: "tree.fill",
                   caption: "夜虫与鸟"),
    ]

    static func find(_ id: String) -> SleepSound? {
        all.first { $0.id == id }
    }

    /// bundle 里的循环文件。素材是蓝色文件夹引用（`SleepLoops`），所以带 subdirectory。
    var fileURL: URL? {
        Bundle.main.url(forResource: id, withExtension: "m4a", subdirectory: "SleepLoops")
            ?? Bundle.main.url(forResource: id, withExtension: "m4a")
    }
}

// MARK: - 定时关闭的档位
//
// 老板口径：15 / 30 / 60 / 90 分钟，到点后 **30 秒淡出**再停。
enum SleepTimerMinutes: Int, CaseIterable, Identifiable {
    case m15 = 15, m30 = 30, m60 = 60, m90 = 90

    var id: Int { rawValue }
    var title: String { "\(rawValue) 分钟" }

    /// 到点后的淡出时长（秒）
    static let fadeOutSeconds: Double = 30
}
