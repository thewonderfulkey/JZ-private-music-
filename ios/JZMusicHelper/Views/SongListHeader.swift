import SwiftUI

// MARK: - 歌曲集合页的头部三件套（2026-11-27 老板）
//
// 老板原话：「凡是歌单列表的地方，头部统一三件套：播放全部 / 随机播放 / 搜索框；
// 缺哪个补哪个，已有的不要重复加；行为和现有实现完全一致（复用现有组件，不要另造一套）；
// 搜索结果出现后，滑动列表时搜索框必须实时可见（吸顶/常驻）。」
//
// 所以这里**只做两件新东西**，其余全部复用：
//   · `ListSearchField`：本页搜索框（胶囊、放大镜、清除），和全 App 搜索入口同一套视觉；
//   · `SongListHeader`：把「页面自己的标题块 + PlayAllButtons + ListSearchField」按固定顺序摞起来，
//     页面只要把它塞进 `Section` 的 header，就能靠 `pinnedViews: [.sectionHeaders]` 吸顶。
// 「播放全部 / 随机」直接用现成的 `PlayAllButtons`（各列表页已经在用同一套）。

/// 列表内搜索框：胶囊 + 放大镜 + 清除，视觉与发现页/搜索页的入口一致
struct ListSearchField: View {

    @Binding var text: String
    var placeholder: String = "搜索本页歌曲、歌手、专辑"

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button {
                    text = ""
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

/// 歌曲集合页的统一头部：页面标题块 → 播放全部/随机 → 搜索框
///
/// - Parameters:
///   - songs: 本页**全量**歌曲（不是过滤后的）——播放全部/随机永远作用于整页
///   - query: 搜索框绑定（页面自己拿它过滤列表）
///   - onPlayAll / onShuffle: 与各页现有实现保持一致（复用现有调用）
struct SongListHeader<Title: View>: View {

    let songCount: Int
    @Binding var query: String
    var showsPlayAll: Bool = true
    var showsSearch: Bool = true
    var searchPlaceholder: String = "搜索本页歌曲、歌手、专辑"
    /// 过滤后还剩几首（0 且查询非空时给一句"本页没有匹配"的提示位，由页面决定要不要用）
    var shownCount: Int? = nil
    let onPlayAll: () -> Void
    let onShuffle: () -> Void
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

            if showsSearch {
                ListSearchField(text: $query, placeholder: searchPlaceholder)
                if let shownCount {
                    Text(SongListFilter.metaText(shown: shownCount, total: songCount, query: query))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
