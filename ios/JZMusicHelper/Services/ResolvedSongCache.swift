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
    /// **当日负缓存**：key → day。解析失败（真的没有原版）的歌当天不再重试，
    /// 否则每次进歌单页都会为同一首再搜一遍 —— 老板说的"多次加载后还是会重新加载"。
    private var failed: [String: Int] = [:]
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

    /// 解析成功后落盘。
    ///
    /// **必须同时按"种子键"存一份**（老板 r89：固定那几首歌每次进歌单都要重新加载）。
    /// 原因：`resolve(seed:)` 返回的 Song，歌名/歌手经常和池子里写的不完全一样——
    /// 例如池子写「海阔天空 / Beyond」，搜出来是「海阔天空 / BEYOND」；池子写「隐形的翅膀 / 张韶涵」，
    /// 搜出来带 `(Live)`；`ResolvedSongCache.key` 只做小写去空白，这类差一点就 miss，
    /// 于是每次进页面都重新解析。而 `prefillFromCache` 查的是**种子的键**，所以必须按种子键落盘。
    func store(_ song: Song, seedName: String? = nil, seedSinger: String? = nil) {
        var keys = [Self.key(name: song.name, singer: song.singer)]
        if let seedName, let seedSinger {
            let seedKey = Self.key(name: seedName, singer: seedSinger)
            if seedKey != keys[0] { keys.append(seedKey) }
        }
        lock.lock()
        for key in keys {
            if map[key] == nil { order.append(key) }
            map[key] = song
        }
        if order.count > limit {
            let drop = order.count - limit
            for k in order.prefix(drop) { map[k] = nil }
            order.removeFirst(drop)
        }
        lock.unlock()
        scheduleSave()
    }

    /// 兜底查法：按"核心歌名 + 歌手片段"在已缓存条目里找。
    ///
    /// 用来救"键对不上"的历史数据（池子名与平台名差一个版本后缀 / 歌手大小写 / 多歌手顺序不同）。
    /// 800 条上限，整表扫一遍是毫秒级。
    func fuzzyLookup(name: String, singer: String) -> Song? {
        let target = Self.loose(name)
        guard !target.isEmpty else { return nil }
        let targetCore = Self.loose(StudioPick.coreName(name))
        let singerKey = Self.loose(singer)

        lock.lock()
        let entries = Array(map.values)
        lock.unlock()

        var best: Song?
        for song in entries {
            let songName = Self.loose(song.name)
            let songCore = Self.loose(StudioPick.coreName(song.name))
            let songSinger = Self.loose(song.singer)
            let nameHit = songName == target || (!targetCore.isEmpty && songCore == targetCore)
            guard nameHit else { continue }
            let singerHit = !singerKey.isEmpty
                && (songSinger.contains(singerKey) || singerKey.contains(songSinger))
            if singerHit { return song }        // 名字和歌手都对上，直接给
            if best == nil { best = song }      // 名字对上、歌手对不上：只当备选
        }
        return best
    }

    /// 粗归一：小写、去空白与常见标点，只用于"名字像不像"的比较
    private static func loose(_ s: String) -> String {
        let punctuation = CharacterSet(charactersIn: " \t\n-_·、,，.。()（）[]【】《》'\"!?！？~&/")
        return String(s.lowercased().unicodeScalars.filter { !punctuation.contains($0) }
            .map(Character.init))
    }

    /// 键：歌名 + 歌手（小写、去首尾空白）——与搜索去重同一个口径，不做模糊匹配
    static func key(name: String, singer: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let s = singer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(n)|\(s)"
    }

    // MARK: 当日负缓存

    /// 记下"这一首今天确实没解析出来"，当天不再重试（跨天自动失效）
    func markUnresolved(name: String, singer: String, day: Int) {
        let key = Self.key(name: name, singer: singer)
        lock.lock()
        failed[key] = day
        lock.unlock()
        scheduleSave()
    }

    func isKnownUnresolved(name: String, singer: String, day: Int) -> Bool {
        let key = Self.key(name: name, singer: singer)
        lock.lock()
        defer { lock.unlock() }
        return failed[key] == day
    }

    // MARK: 落盘

    private struct Payload: Codable {
        let order: [String]
        let items: [String: Song]
        /// 老文件没有这个字段 → 用可选类型兼容
        let failed: [String: Int]?
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
        let payload = Payload(order: order, items: map, failed: failed)
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
        failed = payload.failed ?? [:]
    }

    private static func docURL(_ name: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(name)
    }
}
