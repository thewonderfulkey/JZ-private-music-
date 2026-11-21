import Foundation
import Observation

// MARK: - 我的歌单（导入进来的歌单，一次性快照）
//
// 老板 2026-11-19 口径：
//   · 入口在设置页（"导入歌单"）——发现页在没有歌单时**一个像素都不多**（最近播放直接接最新单曲）；
//   · 导入一次之后把歌单**连歌带封面全部写死在本地**，往后不再请求（"加载一次后写死，往后不再加载"）；
//   · 所以这里存的是 `ImportedPlaylist`（含 `[Song]` 快照），不是"平台 id + 每次现拉"。
//
// 存储与 `LibraryStore` 同一套：Documents 下 JSON 文件，原子写。
// 为什么不用 UserDefaults：一个 300 首的歌单 JSON 约 100~200 KB，塞 UserDefaults 会拖慢启动；
// 收藏/最近播放已经走文件，这里保持一致。
@Observable
final class MyPlaylistStore {

    static let shared = MyPlaylistStore()

    /// 导入的歌单，最近导入的在前
    private(set) var playlists: [ImportedPlaylist] = []

    private let fileURL: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("my_playlists.json")
    }()

    private init() {
        load()
    }

    // MARK: 读

    var isEmpty: Bool { playlists.isEmpty }

    func playlist(id: String) -> ImportedPlaylist? {
        playlists.first { $0.id == id }
    }

    // MARK: 导入

    /// 从一段分享文案 / 链接导入。成功即落盘（歌单已写死）。
    /// 失败抛 `PlaylistImportError`（认不出 / 空歌单 / 平台拒绝），调用方直接把 `localizedDescription` 显示出来。
    ///
    /// `@MainActor`：网络回来后要改 `playlists`（@Observable 状态），必须在主线程落，
    /// 否则发现页要在后台线程上被通知刷新。
    @MainActor
    @discardableResult
    func importLink(_ text: String) async throws -> ImportedPlaylist {
        guard let link = await PlaylistImport.resolve(text) else {
            throw PlaylistImportError.unrecognized
        }
        let playlist = try await PlaylistImport.fetch(link)
        add(playlist)
        return playlist
    }

    /// 同一家的同一个歌单重复导入 = 替换旧快照（不是再添一条，规则见 `PlaylistImport.replacing`）
    func add(_ playlist: ImportedPlaylist) {
        playlists = PlaylistImport.replacing(playlists, with: playlist)
        save()
    }

    /// 元数据写回（第 44 轮）：导入歌单是**一次性快照**，但老板改了某首歌的名字/歌手/封面之后，
    /// 快照里那一份也要跟着换（否则发现页「我的歌单」还显示旧名字）。
    /// `ImportedPlaylist` 的字段是 let，所以是"整条歌单重建"，不是原地改。
    func applySongMetadata(_ song: Song) {
        var changed = false
        for i in playlists.indices {
            guard let j = playlists[i].songs.firstIndex(where: { $0.id == song.id }) else { continue }
            let current = playlists[i].songs[j]
            guard current.name != song.name || current.singer != song.singer
                || current.album != song.album || current.picURL != song.picURL
                || current.meta != song.meta else { continue }
            var songs = playlists[i].songs
            songs[j] = song
            let p = playlists[i]
            playlists[i] = ImportedPlaylist(platform: p.platform, sourceID: p.sourceID,
                                            name: p.name, creator: p.creator, cover: p.cover,
                                            songs: songs, importedAt: p.importedAt)
            changed = true
        }
        if changed { save() }
    }

    func remove(_ id: String) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        playlists.removeAll()
        save()
    }

    // MARK: 持久化

    private func save() {
        guard let data = try? JSONEncoder().encode(playlists) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([ImportedPlaylist].self, from: data) else {
            return
        }
        playlists = list
    }
}
