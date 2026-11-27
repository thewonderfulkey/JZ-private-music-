import Foundation

// MARK: - 本页搜索状态（2026-11-27 老板第二次纠正后定稿：**实时过滤**）
//
// 老板口径（最终版，覆盖"提交式"那版）：
//   · **保持实时过滤**——边打边筛，不要按回车才搜；
//   · 但**不能卡死**：搜索框常驻（吸顶）、自带清除入口、空结果只在列表区提示，
//     任何情况下都能一键回到全量；
//   · 切 Tab / 返回再进来不残留上次关键词（页面 `.onDisappear { search.clear() }`）。
//
// 为什么还留 `committed` 这个名字：各页面的过滤/计数/播放范围都写的是
// `search.committed`，这里让它**永远等于正在输入的文字**，于是语义变回实时，
// 而页面代码一行都不用改（少改一处就少一次编译风险）。
// `submit()` 保留为空实现：键盘「搜索」键仍可点，只是不再需要它才生效。

struct ListSearchState: Equatable {

    /// 输入框里正在打的字——**就是过滤依据**（实时）
    var typed: String = ""

    /// 兼容旧调用名：始终等于 `typed`，所以过滤是实时的
    var committed: String { typed }

    /// 现在是否处于"筛选生效"状态
    var isFiltering: Bool {
        !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 键盘「搜索」键：实时模式下无事可做（保留接口，避免改所有页面）
    mutating func submit() {}

    /// 清除：输入框与过滤一起清空 → 立刻回到全量
    mutating func clear() {
        typed = ""
    }
}
