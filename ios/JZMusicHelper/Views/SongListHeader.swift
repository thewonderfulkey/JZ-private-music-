import SwiftUI

// MARK: - 本页搜索的两段式状态（2026-11-27 老板纠正后重做）
//
// 老板口径（原话大意）：**「zh」还没敲完、回车还没按，列表就被清空了**——不对。
// 正确行为是：输入过程中**只改文字、不过滤**；按键盘上的「搜索/回车」才把关键词应用到列表。
//
// 所以搜索词有两份：
//   · `typed`     —— 输入框里正在打的字（每敲一下就变，但**不影响列表**）
//   · `committed` —— 已经按过回车的关键词（列表只认这一份）
// 列表过滤、计数行、"没匹配"提示、播放范围，全部只看 `committed`。
//
// 「空结果不是死路」也靠这里保证：`clear()` 会同时清掉两份，
// 输入框（常驻在头部）里那行字也一并清空，列表立刻回到全量。

// MARK: - 歌曲集合页的头部（2026-11-27 老板：歌单/收藏/下载头部统一三件套）
//
// 老板原话：「凡是歌单列表的地方，头部统一三件套：播放全部 / 随机 / 搜索框；
// 缺哪个补哪个，已有的不要重复加；行为和现有实现完全一致（另造一套不行）。」
//
// 「播放全部 / 随机」用现成的 `PlayAllButtons`；搜索框是这一层新增，
// 吸顶靠页面的 `LazyVStack(pinnedViews: [.sectionHeaders])` + 这里的不透明纸底。

/// 列表内搜索框：胶囊 + 放大镜 + 清除 + 键盘「搜索」键
struct ListSearchField: View {

    @Binding var state: ListSearchState
    var placeholder: String = "搜索本页歌曲、歌手、专辑"

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $state.typed)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                // 老板：键盘上要有「搜索」键，点了就执行搜索并收键盘
                .submitLabel(.search)
                .onSubmit {
                    state.submit()
                    KeyboardDismiss.dismiss()
                }
                .accessibilityLabel(placeholder)
            if !state.typed.isEmpty || state.isFiltering {
                Button {
                    state.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.press)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.leading, Tokens.Spacing.s)
        .padding(.trailing, Tokens.Spacing.xxs)
        .frame(minHeight: 38)
        .background(Capsule().fill(Tokens.Palette.paperElevated))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// 歌曲集合页的统一头部：标题块 → 播放全部/随机 → 搜索框 →（仅筛选时）计数行
struct SongListHeader<Title: View>: View {

    let songCount: Int
    @Binding var search: ListSearchState
    var showsPlayAll: Bool = true
    var searchPlaceholder: String = "搜索本页歌曲、歌手、专辑"
    /// 过滤后还剩几首（只在已提交关键词时显示计数行）
    var shownCount: Int? = nil
    var onPlayAll: () -> Void = {}
    var onShuffle: () -> Void = {}
    @ViewBuilder var title: () -> Title

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            HStack(alignment: .center, spacing: Tokens.Spacing.s) {
                title()
                Spacer(minLength: 0)
                if showsPlayAll {
                    PlayAllButtons(isEnabled: songCount > 0) {
                        onPlayAll()
                    } onShuffle: {
                        onShuffle()
                    }
                }
            }

            ListSearchField(state: $search, placeholder: searchPlaceholder)

            // 没搜索词时不显示计数行（页面标题块里已有「N 首」），只有筛选时才出现
            if let shownCount,
               let text = SongListFilter.filteredMetaText(shown: shownCount,
                                                           total: songCount,
                                                           query: search.committed) {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.bottom, Tokens.Spacing.xs)
        // 吸顶时要盖住下面滚过去的行：必须是不透明底色
        .background(Tokens.Palette.paper)
    }
}

extension View {
    /// 让 `LazyVStack` 的 section header 吸顶时有一个干净的纸底（不带阴影，避免页内出现横条）
    func stickySectionBackground() -> some View {
        background(Tokens.Palette.paper)
    }
}

/// 列表区里的"搜了但没命中"行（2026-11-27 真机 bug 的修法）
///
/// 只占列表区域，**不动头部**——搜索框常驻，用户可以改词，也可以点「清除搜索」回到全量。
struct ListNoMatchRow: View {

    let query: String
    let onClear: () -> Void

    var body: some View {
        VStack(spacing: Tokens.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("没有匹配「\(query.trimmingCharacters(in: .whitespacesAndNewlines))」的歌")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                Haptics.trackChange()
                onClear()
            } label: {
                Text("清除搜索")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, Tokens.Spacing.m)
                    .frame(minHeight: 34)
                    .background(Capsule().fill(Tokens.Palette.vermilion.opacity(0.12)))
                    .foregroundStyle(Tokens.Palette.vermilion)
            }
            .buttonStyle(.press)
            .accessibilityHint("清空搜索词，恢复整页列表")
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Tokens.Spacing.pageMargin)
        .padding(.vertical, Tokens.Spacing.xl)
        .accessibilityElement(children: .contain)
    }
}
