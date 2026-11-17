import Foundation

// MARK: - 「歌名 + 歌手」→ 真实 Song 的本地解析缓存
//
// 编辑精选的池子里只存了「歌名 + 歌手」，封面 / 专辑 / 平台 id / 时长全靠一次四平台搜索才能拿到。
// 老板 r84："编辑精选跟第 3 问一样，要经常加载，连整个条目都要加载，有什么办法迅速加载好、
// 不用重复请求，能写死的写死。"
//
// 这些对应关系（《晴天 / 周杰伦》= 酷我 228908 …）**基本不会再变**，所以落盘长期保存：
//   第一次进歌单 → 逐首解析并写进 `Documents/resolved_songs.json`
//   以后每次进歌单 → **同步读盘直接渲染**（一行都不转圈），只有磁盘里没有的那几首才去搜。
//
// 上限 800 条：十几个歌单 × 20 首全命中还富余很多；超出按插入顺序淘汰最旧的。
final class ResolvedSongCache {

    static let shared = ResolvedSongCache()

    private let fileURL = ResolvedSongCache.docURL("resolved_songs.json")
    private let limit = 800
    private let lock = NSLock()
    private var map: [String: Song] = [:]
    /// 插入顺序（淘汰用）
    private var order: [String] = []
    private var saveTask: Task<Void, Never>?

    private init() {
        load()
    }

    // MARK: 读

    /// 同步读（启动即用，不阻塞 UI），命中就返回
    func song(name: String, singer: String) -> Song? {
        let key = Self.key(name: name, singer: singer)
        lock.lock()
        defer { lock.unlock() }
        return map[key]
    }

    func contains(name: String, singer: String) -> Bool {
        song(name: name, singer: singer) != nil
    }

    // MARK: 写

    /// 解析成功后落盘。同一个键只留一条（后来的覆盖旧的，比如平台换了源）。
    func store(_ song: Song) {
        let key = Self.key(name: song.name, singer: song.singer)
        lock.lock()
        if map[key] == nil {
            order.append(key)
        }
        map[key] = song
        if order.count > limit {
            let drop = order.count - limit
            for k in order.prefix(drop) { map[k] = nil }
            order.removeFirst(drop)
        }
        lock.unlock()
        scheduleSave()
    }

    /// 键：歌名 + 歌手（小写、去首尾空白）——与搜索去重同一个口径，不做模糊匹配
    static func key(name: String, singer: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let s = singer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(n)|\(s)"
    }

    // MARK: 落盘

    private struct Payload: Codable {
        let order: [String]
        let items: [String: Song]
    }

    /// 攒 1 秒再写：一次解析 20 首时不会写 20 次盘
    private func scheduleSave() {
        lock.lock()
        if saveTask != nil {
            lock.unlock()
            return
        }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            self?.flush()
        }
        lock.unlock()
    }

    func flush() {
        lock.lock()
        let payload = Payload(order: order, items: map)
        saveTask = nil
        lock.unlock()
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return }
        map = payload.items
        order = payload.order.filter { payload.items[$0] != nil }
    }

    private static func docURL(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(name)
    }
}
