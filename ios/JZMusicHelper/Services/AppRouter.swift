import Foundation
import Observation

// MARK: - 全局导航状态
//
// 为什么要它：App Intents（快捷指令 / Siri）进来时只拿到"要做什么"，拿不到视图层级。
// 把"当前在哪个 Tab""有没有一条待执行的搜索词""播放页要不要弹"放在这里，Intent 侧只投递请求、
// 视图侧读这份状态，两边都不用互相持有。
//
// 2026-11-16 改版（老板反馈 ⑥）：**搜索不再是 Tab**，入口挪到发现页最上方。
// 2026-11-16 第二轮（老板反馈 ⑤）：**资料库 → 我的收藏**，并挪到发现与识曲之间。
// 2026-11-16 第四轮（老板反馈 ③）：**设置从收藏页右上角挪出来，单独一个 Tab**。
// 所以 Tab 是 5 个：发现 / 我的收藏 / 识曲 / 下载 / 设置，搜索变成发现页 push 出来的页面。
@Observable
final class AppRouter {

    enum Tab: String, CaseIterable, Hashable {
        case discover, favorites, recognize, downloads, settings

        /// 底部栏里显示的单字标签（导航标题仍用「我的收藏」全称）
        var barTitle: String {
            switch self {
            case .discover: return "发现"
            case .favorites: return "收藏"
            case .recognize: return "识曲"
            case .downloads: return "下载"
            case .settings: return "设置"
            }
        }

        /// 未选中（线框）符号
        var symbol: String {
            switch self {
            case .discover: return "house"
            case .favorites: return "heart"
            case .recognize: return "waveform"
            case .downloads: return "arrow.down.circle"
            case .settings: return "gearshape"
            }
        }

        /// 选中（实心）符号
        var filledSymbol: String {
            switch self {
            case .discover: return "house.fill"
            case .favorites: return "heart.fill"
            case .recognize: return "waveform"
            case .downloads: return "arrow.down.circle.fill"
            case .settings: return "gearshape.fill"
            }
        }

        /// VoiceOver 用的完整名称（栏里是"收藏"，读屏要读"我的收藏"）
        var accessibilityTitle: String {
            switch self {
            case .discover: return "发现"
            case .favorites: return "我的收藏"
            case .recognize: return "识曲"
            case .downloads: return "下载"
            case .settings: return "设置"
            }
        }
    }

    /// 当前 Tab（TabView 直接绑它）
    var tab: Tab = .discover
    /// 待消费的搜索词（搜索页取走后置 nil）
    var pendingSearch: String?
    /// 待消费的"立刻开始识曲"标记
    var pendingRecognize = false
    /// 播放页（全屏）是否展示。点歌 / 点迷你条 / 快捷指令都往这里写。
    var showPlayer = false
}
