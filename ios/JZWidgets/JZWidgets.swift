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

@main
struct JZWidgetsBundle: WidgetBundle {
    var body: some Widget {
        // r65：实时活动（锁屏歌词卡 / 灵动岛）已整体下线——老板要的是"只留系统自带的透明播放器"。
        // 扩展留着是给主屏幕的「每日推荐」小组件用。
        DailyPicksWidget()
    }
}
