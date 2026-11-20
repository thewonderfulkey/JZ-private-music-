import Observation
import SwiftUI
import UIKit

// MARK: - 列表页「定位到正在播放」
//
// 老板 2026-11-20（第四十四轮）：歌单/列表越存越多，当前播的那首在哪一行要靠自己滑很久。
// 每个歌曲列表页的导航栏右侧加一个「定位」：点一下 → 滚到当前播放那一行 → 闪一下；
// 没在播放、或者当前这首不在这张列表里 → 浮一条轻提示（`ToastView`），不改播放、不弹窗。
//
// 三件事分开写，页面只管接线：
//   · `SongLocator`     —— 状态与动作（滚动 / 高亮 / 提示 / VoiceOver 播报）
//   · `LocateNowPlayingButton` —— 导航栏按钮
//   · `.locatedFlash(active:)` —— 行高亮（朱砂底色 + 左侧竖条，1.6s 后淡出）
//
// 滚动的做法与播放页歌词「回到当前」同一套（见 `NowPlayingView.pinLine`）：
// `LazyVStack` 远跳时第一次 `scrollTo` 常常只把目标行实例化、落点不居中，
// 所以在 0 / 60 / 160 / 340ms 各贴一次；用户中途自己滑了也不会被抢（每次贴前查取消）。

@Observable
final class SongLocator {

    /// 需要高亮的歌（按 `Song.id` 记；定位成功 1.6 秒后自动淡出）
    private(set) var highlightedSongID: String?
    /// 轻提示文案（没有在播放 / 不在此列表），1.8 秒自动消失
    private(set) var toast: String?

    private var highlightTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var pinTask: Task<Void, Never>?

    func isHighlighted(_ song: Song) -> Bool {
        highlightedSongID == song.id
    }

    /// 定位一次（列表行用 `Song.id` 作为 ScrollView 的 `.id()`）。
    /// - Parameters:
    ///   - current: `player.currentSong`
    ///   - songs: 列表里按显示顺序排的歌
    ///   - proxy: 该列表的 `ScrollViewProxy`
    @MainActor
    func locate(current: Song?, songs: [Song], proxy: ScrollViewProxy) {
        locate(current: current,
               songs: songs,
               rowID: { songs[$0].id },
               scroll: { id in proxy.scrollTo(id, anchor: .center) })
    }

    /// 定位一次（行的 `.id()` 不是 `Song.id` 时走这个：下载页按 `DownloadItem.id` 认，
    /// 同一首歌可以有两档音质，用 `song.id` 会撞 id）。
    @MainActor
    func locate<ID: Hashable>(current: Song?,
                              songs: [Song],
                              rowID: (Int) -> ID,
                              scroll: @escaping (ID) -> Void) {
        guard let current else {
            flashToast("还没有在播放的歌")
            return
        }
        guard !songs.isEmpty else {
            // 还在加载 / 这张列表本来就是空的：别报"不在此列表"，那句话在这里是假的
            flashToast("列表还是空的")
            return
        }
        guard let index = ListLocate.index(of: current, in: songs) else {
            flashToast("《\(current.name)》不在这个列表里")
            return
        }

        let song = songs[index]
        let target = rowID(index)

        highlightTask?.cancel()
        highlightedSongID = song.id
        highlightTask = Task { @MainActor in
            // 闪一下：1.6s 足够眼睛从按钮移过去，又不至于长时间占着一块颜色
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.45)) {
                self.highlightedSongID = nil
            }
        }

        // VoiceOver：光滚动不播报，读屏用户不知道停在哪
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement,
                                 argument: "已定位到第 \(index + 1) 首：\(song.name)")
        }

        pin { scroll(target) }
    }

    /// 把某一行贴到屏幕中间（多次贴，见文件头说明）
    @MainActor
    private func pin(_ scroll: @escaping () -> Void) {
        pinTask?.cancel()
        pinTask = Task { @MainActor in
            for delayMs in [0, 60, 160, 340] {
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                }
                if Task.isCancelled { return }
                scroll()
            }
        }
    }

    @MainActor
    private func flashToast(_ text: String) {
        withAnimation(Tokens.Motion.stateChange) { toast = text }
        toastTask?.cancel()
        toastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { self.toast = nil }
        }
    }
}

// MARK: - 导航栏按钮

/// 所有列表页右上角同一颗按钮：箭头 + 「定位」，一枚浅朱砂胶囊。
///
/// 为什么不用纯图标：图标（向下箭头）在这个 App 里已经有「回到当前」的含义，
/// 但列表页的标题栏是空的、放得下两个字——写清楚比让老板猜更省事。
struct LocateNowPlayingButton: View {

    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.caption.weight(.semibold))
                Text("定位")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(Tokens.Palette.vermilion)
            .padding(.horizontal, Tokens.Spacing.xs)
            .frame(minHeight: 30)
            .background(Capsule().fill(Tokens.Palette.vermilion.opacity(0.10)))
            .contentShape(Capsule())
        }
        .buttonStyle(.press)
        .accessibilityLabel("定位到正在播放")
        .accessibilityHint("滚到当前播放的那首歌并闪一下；不在本列表会提示")
    }
}

// MARK: - 行高亮

extension View {

    /// 定位命中的那一行：朱砂淡底 + 左侧竖条，`active` 变回 false 时淡出。
    ///
    /// 不放进 `SongRow` 里：列表行在页面里还套着横向边距，套在**最外层**才能整条铺满，
    /// 看起来是"这一行亮了"而不是"这块内容亮了"。
    func locatedFlash(active: Bool) -> some View {
        modifier(LocatedFlash(active: active))
    }

    /// 定位失败的轻提示（浮在迷你条上方，不吃点击）
    func locateToast(_ text: String?) -> some View {
        overlay(alignment: .bottom) {
            if let text {
                ToastView(text: text)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
    }
}

private struct LocatedFlash: ViewModifier {

    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Palette.vermilion.opacity(active ? 0.14 : 0))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Tokens.Palette.vermilion.opacity(active ? 0.95 : 0))
                            .frame(width: 3)
                            .padding(.vertical, Tokens.Spacing.s)
                    }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : Tokens.Motion.stateChange,
                       value: active)
    }
}
