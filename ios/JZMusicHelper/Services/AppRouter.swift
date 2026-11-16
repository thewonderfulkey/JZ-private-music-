import Foundation
import Observation

// MARK: - 全局导航状态
//
// 为什么要它：App Intents（快捷指令 / Siri）进来时只拿到"要做什么"，拿不到视图层级。
// 把"当前在哪个 Tab""有没有一条待执行的搜索词"放在这里，Intent 侧只投递请求、
// 视图侧读这份状态，两边都不用互相持有。
@Observable
final class AppRouter {

    enum Tab: Hashable {
        case discover, search, recognize, downloads, library
    }

    /// 当前 Tab（TabView 直接绑它）
    var tab: Tab = .discover
    /// 待消费的搜索词（搜索页取走后置 nil）
    var pendingSearch: String?
    /// 待消费的"立刻开始识曲"标记
    var pendingRecognize = false

}
