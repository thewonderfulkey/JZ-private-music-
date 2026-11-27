import Foundation

// MARK: - 本页搜索的两段式状态（2026-11-27 老板纠正后重做）
//
// 老板口径：**「zh」还没敲完、回车还没按，列表就被清空了**——不对。
// 正确行为是：输入过程中**只改文字、不过滤**；按键盘上的「搜索/回车」才把关键词应用到列表。
//
// 所以搜索词有两份：
//   · `typed`     —— 输入框里正在打的字（每敲一下就变，但**不影响列表**）
//   · `committed` —— 已经按过回车的关键词（列表只认这一份）
// 列表过滤、计数行、"没匹配"提示、播放范围，全部只看 `committed`。
//
// 「空结果不是死路」也靠这里保证：`clear()` 会同时清掉两份，
// 输入框（常驻在头部）里那行字也一并清空，列表立刻回到全量。
//
// 放在 Services 层（纯 Foundation）而不是视图文件里：这样 CI 能直接断言它。

struct ListSearchState: Equatable {

    /// 输入框里正在打的字（实时变，不过滤）
    var typed: String = ""
    /// 已提交（回车/搜索键）的关键词——列表只认它
    var committed: String = ""

    /// 现在是否处于"筛选生效"状态
    var isFiltering: Bool {
        !committed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 回车 / 点键盘「搜索」：把正在打的字变成生效关键词
    mutating func submit() {
        committed = typed
    }

    /// 清除：输入框和生效关键词一起清空（空状态里的「清除搜索」走这里）
    mutating func clear() {
        typed = ""
        committed = ""
    }
}
