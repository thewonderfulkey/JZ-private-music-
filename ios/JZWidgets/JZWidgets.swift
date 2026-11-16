import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - 今日精选小组件
//
// 数据从哪来：`DiscoverCatalog`（内置歌单池）+ `DiscoverRules.rotate`（按天滑窗）——
// 两个都是纯 Foundation 的静态/纯函数，所以**不需要 App Group、不需要共享容器**
// 就能出真内容。这是这个组件能在自签包里安全落地的关键：
// 一旦要读主 App 的 UserDefaults/文件，就得配 App Group 与对应的 provisioning，
// 自签（免费账号）签名会直接失败。
//
// 每天 0 点刷新一批；点一下打开 App（Deep link 走主 App 的 URL scheme，没配也不会崩）。

struct DailyPicksEntry: TimelineEntry {
    let date: Date
    let category: String
    let songs: [String]
}

struct DailyPicksProvider: TimelineProvider {

    func placeholder(in context: Context) -> DailyPicksEntry {
        DailyPicksEntry(date: Date(), category: "华语经典", songs: ["晴天", "七里香", "青花瓷"])
    }

    func getSnapshot(in context: Context, completion: @escaping (DailyPicksEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailyPicksEntry>) -> Void) {
        let entry = currentEntry()
        // 下一个整点零点换一批（不顺延到"明天此刻"，这样每天固定时间刷新）
        let tomorrow = Calendar.current.startOfDay(for: entry.date.addingTimeInterval(86_400))
        completion(Timeline(entries: [entry], policy: .after(tomorrow)))
    }

    private func currentEntry() -> DailyPicksEntry {
        let day = Int(Date().timeIntervalSince1970 / 86_400)
        let playlists = DiscoverCatalog.playlists
        guard !playlists.isEmpty else {
            return DailyPicksEntry(date: Date(), category: "今日精选", songs: [])
        }
        let playlist = playlists[day % playlists.count]
        let picked = DiscoverRules.rotate(playlist.seeds, day: day, take: 3)
        return DailyPicksEntry(date: Date(), category: playlist.title, songs: picked.map { $0.name })
    }
}

struct DailyPicksView: View {
    @Environment(\.widgetFamily) private var family
    let entry: DailyPicksEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color(.sRGB, red: 0.69, green: 0.23, blue: 0.18))
                    .frame(width: 8, height: 8)
                Text("今日精选 · \(entry.category)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            ForEach(entry.songs.prefix(family == .systemSmall ? 3 : 4), id: \.self) { name in
                Text(name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct DailyPicksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "JZDailyPicks", provider: DailyPicksProvider()) { entry in
            DailyPicksView(entry: entry)
        }
        .configurationDisplayName("今日精选")
        .description("每天换一批三首歌，点开会进 JZ 音乐。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - 锁屏歌词 / 灵动岛（Live Activity）
//
// 一个活动 = 一首歌。标题/歌手/歌词行/进度都在 ContentState 里（Attributes 只放 songID），
// 主 App 侧的 LiveActivityController 负责 request / update / end。
struct SongLockScreenView: View {
    let state: SongActivityAttributes.ContentState

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(state.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(state.lyricLine.isEmpty ? " " : state.lyricLine)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                ProgressView(value: state.progress)
                    .tint(Color(.sRGB, red: 0.69, green: 0.23, blue: 0.18))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
            Image(systemName: state.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.primary)
        }
        .padding(14)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(state.title)，\(state.artist)，\(state.lyricLine)")
    }
}

struct SongLiveActivity: Widget {
    private var accent: Color { Color(.sRGB, red: 0.69, green: 0.23, blue: 0.18) }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SongActivityAttributes.self) { context in
            SongLockScreenView(state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .foregroundStyle(accent)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(context.state.title)
                            .font(.caption)
                            .lineLimit(1)
                        Text(context.state.lyricLine.isEmpty ? context.state.artist : context.state.lyricLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: context.state.progress)
                        .tint(accent)
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.lyricLine.isEmpty ? context.state.artist : context.state.lyricLine)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 60)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .foregroundStyle(accent)
            }
            .keylineTint(accent)
        }
    }
}

@main
struct JZWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DailyPicksWidget()
        SongLiveActivity()
    }
}
