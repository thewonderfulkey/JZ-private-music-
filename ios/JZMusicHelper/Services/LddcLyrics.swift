import Foundation

// MARK: - LDDC 取词编排（酷狗 KG / QQ QM 双源）
//
// 与 Android `LddcLyrics.kt` 同口径（对齐 chenmozhijin/LDDC 的 auto_fetch）：
//   双源并行搜「歌名 歌手」→ 候选按 LDDC 评分选优（>55 分、时长 ±4s）→ 分数降序、同分 QQ 优先
//   → 取前 2 个候选取词（谁先成功用谁）→ 解密 → 要求 ≥6 行且不是乱码
//
// 两个源的脾气（都写在 Android 注释里，实测复核过）：
//   · 酷狗 `lyrics.kugou.com/v1/search` 与 `/download` 的签名**只含 appid+clientver+业务参数**，
//     塞公共参数会签名失配；搜索接口 `complexsearch` 反而要全套公共参数
//   · QQ 走 `musicu.fcg`，先 GetSession 拿 uid/sid/userip，再 DoSearch、GetPlayLyricInfo；
//     该接口对同 IP 高频请求会返回 `request.code=2001`（空候选），遇到就当这条源失败
enum LddcLyrics {

    private static let kgSalt = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
    private static let netTimeout: TimeInterval = 8
    private static let minScore = LddcMatch.minScore
    private static let durationTolerance = LddcMatch.durationToleranceSec

    // MARK: 候选

    struct Candidate: Sendable {
        let source: String          // "kg" / "qq"
        let title: String
        let artist: String
        let durationSec: Int
        var kgId: String? = nil
        var kgHash: String? = nil
        var qqId: String? = nil
        var qqSinger: String? = nil
        var qqAlbum: String? = nil
    }

    // MARK: 入口

    /// 双源并行搜索 → 评分选优 → 逐候选取词。全部失败返回 nil。
    static func fetch(song: Song) async -> LyricsResult? {
        let title = song.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = LyricsCleaning.cleanArtist(song.singer)
        guard !title.isEmpty else { return nil }

        async let kgTask = searchKg(title: title, artist: artist)
        async let qqTask = searchQq(title: title, artist: artist)
        let candidates = await kgTask + qqTask
        guard !candidates.isEmpty else { return nil }

        guard let lines = await pickBest(candidates: candidates, song: song,
                                         title: title, artist: artist) else { return nil }
        return LyricsResult(lines: lines, source: "LDDC")
    }

    /// 评分 + 时长过滤 + 排序 + 取前 2 个候选取词
    static func pickBest(candidates: [Candidate], song: Song,
                         title: String, artist: String) async -> [LyricLine]? {
        let targetDur = song.durationSec
        var scored: [(score: Double, candidate: Candidate)] = []
        for cand in candidates {
            if targetDur > 0 && cand.durationSec > 0 {
                if abs(targetDur - cand.durationSec) > durationTolerance { continue }
            }
            let total = LddcMatch.score(title: title, candidateTitle: cand.title,
                                        artist: artist, candidateArtist: cand.artist)
            if total > minScore {
                scored.append((total, cand))
            }
        }
        guard !scored.isEmpty else { return nil }
        // 分数降序；同分 QQ 优先（对齐 sources=(QM, KG)）
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return sourcePriority(a.candidate.source) < sourcePriority(b.candidate.source)
        }

        // 前 2 个候选并行取词，谁先成谁用（对齐 LDDC：不必等慢的那个）
        let top = Array(scored.prefix(2))
        return await withTaskGroup(of: (Int, [LyricLine]?).self) { group in
            for (idx, item) in top.enumerated() {
                group.addTask {
                    let lines = await fetchOne(item.candidate)
                    return (idx, lines)
                }
            }
            var results: [(Int, [LyricLine]?)] = []
            for await r in group { results.append(r) }
            // 按候选优先级取第一个合格的，保证结果稳定（不随网络先后抖动）
            for (idx, _) in top.enumerated() {
                if let hit = results.first(where: { $0.0 == idx })?.1 {
                    return hit
                }
            }
            return nil
        }
    }

    private static func sourcePriority(_ source: String) -> Int {
        source == "qq" ? 0 : 1
    }

    /// 单个候选取词 + 乱码校验；要求 ≥6 行
    private static func fetchOne(_ cand: Candidate) async -> [LyricLine]? {
        let lines: [LyricLine]?
        switch cand.source {
        case "kg": lines = await fetchKgLines(cand)
        case "qq": lines = await fetchQqLines(cand)
        default: lines = nil
        }
        guard let lines, !lines.isEmpty else { return nil }
        if LyricsCleaning.isBroken(lines.map(\.text).joined(separator: "\n")) { return nil }
        return lines.count >= 6 ? lines : nil
    }

    // ==================== 酷狗 ====================

    /// 进程级可变状态（酷狗 dfid、QQ 会话）：用带锁的小类，而不是 `static var`
    private final class SharedState: @unchecked Sendable {
        private let lock = NSLock()
        private var dfid: String?
        private var dfidAt = Date.distantPast
        private var qqSession: [String: String]?

        func cachedDfid() -> String? {
            lock.lock(); defer { lock.unlock() }
            guard let dfid, Date().timeIntervalSince(dfidAt) < 30 * 60 else { return nil }
            return dfid
        }

        func store(dfid: String) {
            lock.lock(); self.dfid = dfid; dfidAt = Date(); lock.unlock()
        }

        func session() -> [String: String]? {
            lock.lock(); defer { lock.unlock() }
            return qqSession
        }

        func store(session: [String: String]) {
            lock.lock(); qqSession = session; lock.unlock()
        }
    }

    private static let state = SharedState()

    private static func searchKg(title: String, artist: String) async -> [Candidate] {
        let dfid = await kgRegisterDfid() ?? "-"
        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let keyword = "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines)
        let params: [(String, String)] = [
            ("sorttype", "0"), ("keyword", keyword), ("pagesize", "20"), ("page", "1"),
        ]
        let query = kgQuery(params: params, module: "SearchSong", mid: mid, dfid: dfid)
        let url = "http://complexsearch.kugou.com/v2/search/song?" + query
        guard let json = try? await APIClient.shared.getJSON(
            url, headers: kgHeaders(module: "SearchSong", mid: mid), timeout: netTimeout),
              let lists = (json["data"] as? [String: Any])?["lists"] as? [[String: Any]] else {
            return []
        }
        var out: [Candidate] = []
        for item in lists {
            let name = (item["SongName"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let id = item["ID"] as? String ?? ""
            let hash = item["FileHash"] as? String ?? ""
            if name.isEmpty || id.isEmpty || hash.isEmpty { continue }
            let singers = (item["Singers"] as? [[String: Any]] ?? [])
                .compactMap { $0["name"] as? String }
                .joined(separator: "/")
            out.append(Candidate(source: "kg", title: name, artist: singers,
                                 durationSec: item["Duration"] as? Int ?? 0,
                                 kgId: id, kgHash: hash))
        }
        return out
    }

    private static func fetchKgLines(_ cand: Candidate) async -> [LyricLine]? {
        guard let id = cand.kgId, let hash = cand.kgHash else { return nil }
        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let durMs = cand.durationSec * 1000
        let lrcParams: [(String, String)] = [
            ("album_audio_id", id), ("duration", String(durMs)), ("hash", hash),
            ("keyword", "\(cand.artist) - \(cand.title)"), ("lrctxt", "1"), ("man", "no"),
        ]
        let lrcURL = "https://lyrics.kugou.com/v1/search?"
            + kgQuery(params: lrcParams, module: "Lyric", mid: mid)
        guard let lrcJson = try? await APIClient.shared.getJSON(
            lrcURL, headers: kgHeaders(module: "Lyric", mid: mid), timeout: netTimeout),
              let cands = lrcJson["candidates"] as? [[String: Any]],
              let first = cands.first,
              let cid = first["id"] as? String, !cid.isEmpty,
              let accesskey = first["accesskey"] as? String, !accesskey.isEmpty else {
            return nil
        }
        let dlParams: [(String, String)] = [
            ("accesskey", accesskey), ("charset", "utf8"), ("client", "mobi"),
            ("fmt", "krc"), ("id", cid), ("ver", "1"),
        ]
        let dlURL = "http://lyrics.kugou.com/download?"
            + kgQuery(params: dlParams, module: "Lyric", mid: mid)
        guard let dlJson = try? await APIClient.shared.getJSON(
            dlURL, headers: kgHeaders(module: "Lyric", mid: mid), timeout: netTimeout),
              let content = dlJson["content"] as? String, !content.isEmpty,
              let decoded = Data(base64Encoded: content) else {
            return nil
        }
        let contentType = dlJson["contenttype"] as? Int ?? -1
        if contentType == 2 {
            // contenttype==2：content 是 base64 纯文本 LRC（没有逐字时间）
            let lrc = LyricsCleaning.parseLrc(String(data: decoded, encoding: .utf8) ?? "")
            return lrc.isEmpty ? nil : lrc
        }
        guard let plain = LddcCrypto.krcDecrypt([UInt8](decoded)) else { return nil }
        let words = LddcCrypto.krcToLines(plain)
        if !words.isEmpty { return words }
        // 兜底：逐字解析失败但明文能压成整行 LRC
        let fallback = LyricsCleaning.parseLrc(LddcCrypto.krcToLrc(plain))
        return fallback.isEmpty ? nil : fallback
    }

    /// 设备 dfid 注册（酷狗搜索要求带 dfid；缓存 30 分钟）
    private static func kgRegisterDfid() async -> String? {
        if let hit = state.cachedDfid() { return hit }

        let mid = Digest.md5Hex(String(Int(Date().timeIntervalSince1970 * 1000)))
        let values = ["1014", "4", mid].sorted().joined()
        let signature = Digest.md5Hex("1014" + values + "1014")
        let url = "https://userservice.kugou.com/risk/v1/r_register_dev"
            + "?appid=1014&platid=4&mid=\(mid)&signature=\(signature)"
        let body = Data("{\"uuid\":\"\"}".utf8).base64EncodedString()
        guard let resp = try? await APIClient.shared.postString(
            url, body: body, contentType: "text/plain", timeout: netTimeout),
              let data = resp.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dfid = (json["data"] as? [String: Any])?["dfid"] as? String,
              !dfid.isEmpty else { return nil }

        state.store(dfid: dfid)
        return dfid
    }

    private static func kgHeaders(module: String, mid: String) -> [String: String] {
        [
            "User-Agent": "Android14-1070-11070-201-0-\(module)-wifi",
            "Connection": "Keep-Alive",
            "KG-Rec": "1",
            "KG-RC": "1",
            "KG-CLIENTTIMEMS": String(Int(Date().timeIntervalSince1970 * 1000)),
            "mid": mid,
        ]
    }

    /// 酷狗签名参数。`module == "Lyric"` 时只含 appid+clientver+业务参数（多塞会签名失配）
    static func kgQuery(params: [(String, String)], module: String, mid: String, dfid: String) -> String {
        var all = params
        if module == "Lyric" {
            all.append(("appid", "3116"))
            all.append(("clientver", "11070"))
        } else {
            all.append(("userid", "0"))
            all.append(("appid", "3116"))
            all.append(("token", ""))
            all.append(("clienttime", String(Int(Date().timeIntervalSince1970))))
            all.append(("iscorrection", "1"))
            all.append(("uuid", "-"))
            all.append(("mid", mid))
            all.append(("dfid", dfid))
            all.append(("clientver", "11070"))
            all.append(("platform", "AndroidFilter"))
        }
        let sorted = all.sorted { $0.0 < $1.0 }
        let signature = Digest.md5Hex(
            kgSalt + sorted.map { "\($0.0)=\($0.1)" }.joined() + kgSalt)
        return sorted.map { "\($0.0)=\(APIClient.encode($0.1))" }.joined(separator: "&")
            + "&signature=\(signature)"
    }

    // ==================== QQ ====================



    private static func qqComm() -> [String: Any] {
        [
            "ct": 11, "cv": "1003006", "v": "1003006", "os_ver": "15",
            "phonetype": "24122RKC7C",
            "rom": "Redmi/miro/miro:15/AE3A.240806.005/OS2.0.105.0.VOMCNXM:user/release-keys",
            "tmeAppID": "qqmusiclight", "nettype": "NETWORK_WIFI", "udid": "0",
        ]
    }

    private static func searchQq(title: String, artist: String) async -> [Candidate] {
        var comm = qqComm()
        await qqEnsureSession(&comm)
        let searchID = String(Int(Date().timeIntervalSince1970 * 1000))
        let param: [String: Any] = [
            "search_id": searchID,
            "remoteplace": "search.android.keyboard",
            "query": "\(title) \(artist)".trimmingCharacters(in: .whitespacesAndNewlines),
            "search_type": 0, "num_per_page": 20, "page_num": 1,
            "highlight": 0, "nqc_flag": 0, "page_id": 1, "grp": 1,
        ]
        guard let data = await qqRequest(comm: comm, method: "DoSearchForQQMusicLite",
                                         module: "music.search.SearchCgiService", param: param),
              let items = (data["body"] as? [String: Any])?["item_song"] as? [[String: Any]] else {
            return []
        }
        var out: [Candidate] = []
        for item in items {
            let t = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let qid = item["id"] as? String ?? ""
            if t.isEmpty || qid.isEmpty { continue }
            let singer = ((item["singer"] as? [[String: Any]])?.first)?["name"] as? String ?? ""
            let album = ((item["album"] as? [String: Any])?["name"] as? String) ?? ""
            out.append(Candidate(source: "qq", title: t, artist: singer,
                                 durationSec: item["interval"] as? Int ?? 0,
                                 qqId: qid, qqSinger: singer, qqAlbum: album))
        }
        return out
    }

    private static func fetchQqLines(_ cand: Candidate) async -> [LyricLine]? {
        guard let qid = cand.qqId else { return nil }
        var comm = qqComm()
        await qqEnsureSession(&comm)
        let param: [String: Any] = [
            "albumName": b64(cand.qqAlbum ?? ""),
            "crypt": 1, "ct": 19, "cv": 2111,
            "interval": cand.durationSec,
            "lrc_t": 0, "qrc": 1, "qrc_t": 0, "roma": 1, "roma_t": 0,
            "singerName": b64(cand.qqSinger ?? cand.artist),
            "songID": Int(qid) ?? 0,
            "songName": b64(cand.title),
            "trans": 1, "trans_t": 0, "type": 0,
        ]
        guard let data = await qqRequest(comm: comm, method: "GetPlayLyricInfo",
                                         module: "music.musichallSong.PlayLyricInfo", param: param) else {
            return nil
        }
        let encrypted = data["lyric"] as? String ?? ""
        // 对齐 LDDC：qrc_t ≠ 0 用 qrc_t，否则用 lrc_t；该值 != "0" 才解密
        let qrcT = data["qrc_t"] as? Int ?? 0
        let lrcT = String(describing: data["lrc_t"] ?? "0")
        let effectiveT = qrcT != 0 ? String(qrcT) : lrcT
        if encrypted.isEmpty || effectiveT == "0" { return nil }
        guard let plain = LddcCrypto.qrcDecrypt(hex: encrypted) else { return nil }
        let words = LddcCrypto.qrcToLines(plain)
        if !words.isEmpty { return words }
        let fallback = LyricsCleaning.parseLrc(LddcCrypto.qrcToLrc(plain))
        return fallback.isEmpty ? nil : fallback
    }

    /// 会话获取/复用（uid/sid/userip）：搜索与取词共用，少一次往返
    private static func qqEnsureSession(_ comm: inout [String: Any]) async {
        if let cached = state.session() {
            comm["uid"] = cached["uid"] ?? ""
            comm["sid"] = cached["sid"] ?? ""
            comm["userip"] = cached["userip"] ?? ""
            return
        }
        let param: [String: Any] = ["caller": 0, "uid": "0", "vkey": 0]
        guard let data = await qqRequest(comm: comm, method: "GetSession",
                                         module: "music.getSession.session", param: param),
              let session = data["session"] as? [String: Any] else { return }
        let snapshot: [String: String] = [
            "uid": session["uid"] as? String ?? "",
            "sid": session["sid"] as? String ?? "",
            "userip": session["userip"] as? String ?? "",
        ]
        state.store(session: snapshot)
        comm["uid"] = snapshot["uid"] ?? ""
        comm["sid"] = snapshot["sid"] ?? ""
        comm["userip"] = snapshot["userip"] ?? ""
    }

    private static func qqRequest(comm: [String: Any], method: String,
                                  module: String, param: [String: Any]) async -> [String: Any]? {
        let payload: [String: Any] = [
            "comm": comm,
            "request": ["method": method, "module": module, "param": param],
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: bodyData, encoding: .utf8) else { return nil }
        guard let json = try? await APIClient.shared.postJSON(
            "https://u.y.qq.com/cgi-bin/musicu.fcg", body: body,
            headers: ["Cookie": "tmeLoginType=-1;"], timeout: netTimeout),
              (json["code"] as? Int ?? -1) == 0,
              let request = json["request"] as? [String: Any],
              (request["code"] as? Int ?? -1) == 0 else { return nil }
        return request["data"] as? [String: Any]
    }

    private static func b64(_ s: String) -> String {
        Data(s.utf8).base64EncodedString()
    }
}
