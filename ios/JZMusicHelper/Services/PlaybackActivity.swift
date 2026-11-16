import ActivityKit
import Foundation

// MARK: - 锁屏歌词 / 灵动岛的活动定义
//
// 这个类型必须同时被**主 App**（要 request / update 活动）和 **Widget 扩展**（要渲染）编译，
// 所以两边都把它加进 Sources。静态属性只放 songID（换歌就重开一个活动），
// 会变的东西全在 ContentState 里——这是 ActivityKit 的硬约束：Attributes 一旦创建不可变。
struct SongActivityAttributes: ActivityAttributes {

    struct ContentState: Codable, Hashable {
        var title: String
        var artist: String
        var lyricLine: String
        var progress: Double
        var isPlaying: Bool
    }

    var songID: String
}

extension SongActivityAttributes.ContentState {
    init(snapshot: PlaybackActivitySnapshot) {
        self.init(title: snapshot.title,
                  artist: snapshot.artist,
                  lyricLine: snapshot.lyricLine,
                  progress: snapshot.progress,
                  isPlaying: snapshot.isPlaying)
    }
}
