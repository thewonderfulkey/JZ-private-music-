import Foundation

// MARK: - 列表页"头部该不该在"的规则（2026-11-27 真机 bug 后补）
//
// 真机 bug（2.4.130，老板 18:24 录屏）：「我的收藏」输入 `zh` 没有命中时，
// **整个头部（标题卡 + 播放全部/随机 + 搜索框）被空态顶掉**，搜索词还留着，
// 用户没有任何入口清除 → 卡在「还没有收藏的歌」出不来。
//
// 根因是把"筛选后为空"当成"本页没有内容"，用空态替换了整页。
//
// 定成两条规则（纯逻辑，CI 断言），各页一律照此渲染：
//   ① `showsChrome`：只要本页**有数据**（未筛选的全量非空），头部（含搜索框）就必须常驻——
//      哪怕筛选结果为空。搜索框是"清除搜索"的唯一入口，不能跟着空态一起消失。
//   ② `noMatch`：有数据 + 有搜索词 + 筛选结果为空 → 只在**列表区域**显示"没有匹配"，
//      并且要带一个清除搜索的按钮。

enum SongListRules {

    /// 头部（标题块 + 播放全部/随机 + 搜索框）是否应当渲染
    static func showsChrome(totalCount: Int) -> Bool {
        totalCount > 0
    }

    /// 是否属于"搜了但没命中"（此时列表区给提示 + 清除按钮，而不是整页空态）
    static func noMatch(totalCount: Int, shownCount: Int, query: String) -> Bool {
        guard totalCount > 0, shownCount == 0 else { return false }
        return !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 是否属于"本页真的没有内容"（例如真的一首收藏都没有）：这时才允许整页空态
    static func trulyEmpty(totalCount: Int) -> Bool {
        totalCount == 0
    }
}
