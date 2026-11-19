// 网络层纯逻辑自测（CI 用：macOS runner 上 swiftc 编译 + 直接运行，不碰模拟器、不碰网络）
//
// 为什么要有它：这台开发机是 Windows，没有 Swift 工具链；Swift 代码的正确性只能靠 CI。
// 而「能编译」不等于「口径对」——排序权重、原唱判定、码率区间、酷我文本解析这些数字一旦改了，
// 界面不会明显崩，只会"这首歌排到后面了""无损下成 128k 了"。所以这里把可判定的口径全部钉成断言。
//
// 跑法（CI 里由 .github/workflows/ios-ipa.yml 的 logic-tests job 执行）：
//   swiftc -Onone -o /tmp/jz-selftest \
//     ios/JZMusicHelper/Models/Song.swift \
//     ios/JZMusicHelper/Models/DownloadItem.swift \
//     ios/JZMusicHelper/Services/*.swift 中网络层若干文件 \
//     ios/SelfTest/main.swift
//   /tmp/jz-selftest

import Foundation

// MARK: - 断言小工具

var passed = 0
var failed = 0

func check(_ name: String, _ condition: @autoclosure () -> Bool, _ detail: @autoclosure () -> String = "") {
    if condition() {
        passed += 1
        print("  ✓ \(name)")
    } else {
        failed += 1
        let d = detail()
        print("  ✗ \(name)\(d.isEmpty ? "" : "  ← \(d)")")
    }
}

func section(_ title: String) {
    print("\n— \(title)")
}

func song(_ platform: MusicPlatform, _ name: String, _ singer: String,
          album: String = "", dur: Int = 269, id: String = UUID().uuidString) -> Song {
    Song(platform: platform, platformID: id, name: name, singer: singer,
         album: album, duration: Double(dur), picURL: nil)
}

// MARK: - 1 搜索结果排序（SearchRanker）

section("SearchRanker 排序口径")

do {
    let songs = [
        song(.qq, "晴天 (Live)", "周杰伦", album: "世界巡回演唱会", dur: 302, id: "q1"),
        song(.qq, "晴天", "周杰伦", album: "叶惠美", dur: 269, id: "q2"),
        song(.kuwo, "晴天", "周杰伦", album: "叶惠美", dur: 269, id: "k1"),
        song(.netease, "晴天", "周杰伦", album: "叶惠美", dur: 270, id: "n1"),
    ]
    let ranked = SearchRanker.rank(keyword: "晴天", songs: songs)
    check("裸歌名排在 (Live) 之前", ranked.first?.name == "晴天", "first=\(ranked.first?.name ?? "nil")")
    check("Live 版被排到最后", ranked.last?.name == "晴天 (Live)", "last=\(ranked.last?.name ?? "nil")")
    // 注意：位次先验是按「各平台自己的第几条」给的（每条平台的首条都 +10），
    // 所以三个平台的「晴天」都是 50+10=60 分，最后由平台优先级破同分（网易 → 酷我），
    // QQ 那条因为是该平台第 2 条只有 +6，落到后面。这就是 Android 的真实口径。
    check("平台首条先验 + 同分按平台优先级（网易 → 酷我）",
          ranked.count >= 3 && ranked[0].platform == .netease && ranked[1].platform == .kuwo,
          "order=\(ranked.map(\.platform.rawValue))")
    check("同平台第 2 条因位次先验更低排到后面",
          ranked[2].platform == .qq,
          "third=\(ranked.count > 2 ? ranked[2].platform.rawValue : "nil")")
}

do {
    // 平台位次先验：同平台内第 1 名 +10，足以压过完全相等的低名次
    let a = song(.qq, "夜曲", "周杰伦", album: "十一月的萧邦", id: "a")
    let b = song(.qq, "夜曲", "周杰伦", album: "十一月的萧邦", id: "b")
    let ranked = SearchRanker.rank(keyword: "夜曲", songs: [b, a])
    check("同分保持原始顺序（稳定排序）", ranked.first?.platformID == "b", "first=\(ranked.first?.platformID ?? "nil")")

    // 去重：同平台同 ID 只留一条
    let dup = SearchRanker.rank(keyword: "夜曲", songs: [a, a, b])
    check("同平台同 ID 去重", dup.count == 2, "count=\(dup.count)")
}

do {
    // "IVORY TOWER" 查询不应把只叫 "IVORY" 的另一首排到首行（封顶 40 分）
    let short = song(.qq, "IVORY", "Someone", id: "s")
    let long = song(.qq, "IVORY TOWER", "Someone", id: "l")
    let ranked = SearchRanker.rank(keyword: "IVORY TOWER", songs: [short, long])
    check("查询串更长时短标题被压制", ranked.first?.platformID == "l",
          "first=\(ranked.first?.name ?? "nil")")
}

do {
    // 专辑维度只对多词查询生效，且"专辑=歌名"的 UGC 不参与
    let sameAlbumAsTitle = song(.qq, "晴天", "周杰伦", album: "晴天", id: "x")
    let realAlbum = song(.qq, "晴天", "周杰伦", album: "叶惠美", id: "y")
    let ranked = SearchRanker.rank(keyword: "晴天 叶惠美", songs: [sameAlbumAsTitle, realAlbum])
    check("专辑维度参与多词查询", ranked.first?.platformID == "y",
          "first=\(ranked.first?.album ?? "nil")")
}

// MARK: - 2 原唱优选（StudioPick）

section("StudioPick 原唱判定")

do {
    check("裸名 = 原版名", StudioPick.isCleanTitle("晴天"))
    check("(Live) 不是裸名", !StudioPick.isCleanTitle("晴天 (Live)"))
    check("「- 伴奏」不是裸名", !StudioPick.isCleanTitle("晴天 - 伴奏"))
    check("（版本1）不是裸名", !StudioPick.isCleanTitle("晴天（版本1）"))
    check("核心名剥掉版本说明", StudioPick.coreName("富士山下（Live）") == "富士山下",
          "core=\(StudioPick.coreName("富士山下（Live）"))")
    check("核心名允许剥成空之外的合法结果", StudioPick.coreName("夜曲") == "夜曲")

    check("春晚现场版专辑判为 live", StudioPick.isLiveAlbum("2010 央视春晚"))
    check("正式专辑不判 live", !StudioPick.isLiveAlbum("叶惠美"))
    check("空专辑不判 live", !StudioPick.isLiveAlbum(""))
}

do {
    let studio = song(.qq, "龙文", "谭晶", album: "看见", dur: 313, id: "studio")
    let program = song(.qq, "龙文", "谭晶", album: "", dur: 243, id: "program")
    let live = song(.qq, "龙文 (Live)", "谭晶", album: "演唱会", dur: 236, id: "live")
    let cands = [program, live, studio]
    let best = StudioPick.pickBest(cands)
    check("同曲候选里挑出录音室原唱", best?.platformID == "studio", "best=\(best?.platformID ?? "nil")")

    let cons = StudioPick.consensusDuration(cands)
    check("共识时长取众数（313/243/236 → 三桶各1条 → nil）", cons == nil, "cons=\(String(describing: cons))")

    let deduped = StudioPick.dedupeByCore([program, studio, live])
    check("按核心名归并后只剩 1 条", deduped.count == 1, "count=\(deduped.count)")
    check("归并保留录音室版", deduped.first?.platformID == "studio")
}

// 第三十三轮（老板真机截图：识曲《阁爱你一摆》的「其他版本」六条不同的歌全被打成原唱）
do {
    let originalQQ = song(.qq, "阁爱妳一摆", "茄子蛋", album: "阁爱妳一摆", dur: 278, id: "orig_qq")
    let originalNE = song(.netease, "阁爱妳一摆", "茄子蛋", album: "阁爱妳一摆", dur: 278, id: "orig_ne")
    let live = song(.qq, "閣愛妳一擺 (Live)", "茄子蛋", album: "", dur: 293, id: "live")
    let dj = song(.qq, "阁爱妳一摆 (DJ Nova夜阑版)", "茄子蛋", album: "", dur: 194, id: "dj")
    let cover = song(.qq, "阁爱妳一摆", "陈吉雯", album: "陈素衣翻唱集", dur: 278, id: "cover")
    let unrelated1 = song(.qq, "我的未来不是梦", "茄子蛋", album: "我的未来不是梦", dur: 160, id: "u1")
    let unrelated2 = song(.qq, "浪子回头", "茄子蛋", album: "卡通人物", dur: 259, id: "u2")
    let pool = [unrelated1, originalQQ, live, dj, cover, originalNE, unrelated2]

    check("繁简/异体折叠：閣愛妳一擺 与 阁爱你一摆 视为同一首",
          StudioPick.normalizedCoreName("閣愛妳一擺 (Live)")
            == StudioPick.normalizedCoreName("阁爱你一摆"),
          "a=\(StudioPick.normalizedCoreName("閣愛妳一擺 (Live)")) b=\(StudioPick.normalizedCoreName("阁爱你一摆"))")

    let same = StudioPick.sameSongVersions(pool, matching: "阁爱你一摆")
    check("其他版本只留同一首歌（同歌手的别的歌不进）",
          same.count == 5 && !same.contains { $0.id == unrelated1.id || $0.id == unrelated2.id },
          "count=\(same.count)")

    let deduped = StudioPick.dedupeRecordings(same)
    check("跨平台同一条录音只留一条",
          deduped.filter { $0.name == "阁爱妳一摆" && $0.singer == "茄子蛋" }.count == 1,
          "count=\(deduped.count)")
    check("翻唱 / 现场 / Remix 不会被当重复合掉", deduped.count == 4, "count=\(deduped.count)")

    let others = StudioPick.excludingRecording(of: originalQQ, from: deduped)
    check("主结果那条录音（含跨平台副本）要从其他版本剔除",
          others.allSatisfy { $0.id != originalQQ.id && $0.id != originalNE.id },
          "ids=\(others.map(\.id))")

    check("主卡已经是原唱时，列表里不再批量打原唱",
          StudioPick.originalVersion(in: others, title: "阁爱你一摆",
                                     artist: "茄子蛋", durationSec: 278) == nil)
    check("主卡是翻唱时，列表里唯一原唱能被标出",
          StudioPick.originalVersion(in: [cover, originalQQ, live], title: "阁爱你一摆",
                                     artist: "茄子蛋", durationSec: 278)?.id == originalQQ.id)
    check("原唱判定：裸名 + 同歌手 + 长度吻合",
          StudioPick.isOriginalRecording(originalQQ, title: "阁爱你一摆",
                                         artist: "茄子蛋", durationSec: 278))
    check("原唱判定：翻唱不算",
          !StudioPick.isOriginalRecording(cover, title: "阁爱你一摆",
                                          artist: "茄子蛋", durationSec: 278))
    check("原唱判定：Live 不算",
          !StudioPick.isOriginalRecording(live, title: "阁爱你一摆",
                                          artist: "茄子蛋", durationSec: 278))
    check("原唱判定：同歌手别的歌不算",
          !StudioPick.isOriginalRecording(unrelated1, title: "阁爱你一摆",
                                          artist: "茄子蛋", durationSec: 278))
}

// 第三十四轮（老板真机：点《青花瓷》放出来是 DJ 版）
// 根因是跨源补源的 sameSong 允许"干净原唱 → 时长只差 3s 的 DJ Wave 版"。
// 现在原唱只能换到原唱，宁可无源也不能偷偷换版本。
do {
    let src = song(.kugou, "青花瓷", "周杰伦", album: "我很忙", dur: 239, id: "qh_src")
    let dj = song(.kugou, "青花瓷 (DJ Wave版)", "周杰伦", album: "", dur: 242, id: "qh_dj")
    let live = song(.kugou, "青花瓷 (Live)", "周杰伦", album: "", dur: 238, id: "qh_live")
    let cleanQQ = song(.qq, "青花瓷", "周杰伦", album: "我很忙", dur: 239, id: "qh_qq")
    let longClean = song(.qq, "青花瓷", "周杰伦", album: "", dur: 270, id: "qh_long")
    let remixSrc = song(.kugou, "青花瓷 (DJ版)", "周杰伦", album: "", dur: 378, id: "qh_remix")

    check("原唱不会跨源换到 DJ 版（时长只差 3s 也不行）",
          !SameSongCrossResolver.sameSong(src: src, cand: dj))
    check("原唱不会跨源换到 Live 版",
          !SameSongCrossResolver.sameSong(src: src, cand: live))
    check("原唱可以跨源换到另一条原唱",
          SameSongCrossResolver.sameSong(src: src, cand: cleanQQ))
    check("原唱不会换到时长差太多的同名条目",
          !SameSongCrossResolver.sameSong(src: src, cand: longClean))
    check("现场版可以升级到录音室原唱",
          SameSongCrossResolver.sameSong(src: live, cand: cleanQQ))
    check("DJ 源不会跨源换到更短的原唱（时长闸门仍生效）",
          !SameSongCrossResolver.sameSong(src: remixSrc, cand: cleanQQ))
}

// MARK: - 3 歌名/歌手匹配（NameMatch）

section("NameMatch 身份校验")

do {
    check("多歌手串顺序无关", NameMatch.singerMatches("谭晶/陈奕迅", "陈奕迅、谭晶"))
    check("多歌手空格分隔也认", NameMatch.singerMatches("谭晶 陈奕迅", "陈奕迅/谭晶"))
    check("无交集不匹配", !NameMatch.singerMatches("周杰伦", "蔡健雅"))
    check("任一方为空不拦", NameMatch.singerMatches("", "周杰伦"))
    check("歌名带版本后缀仍匹配", NameMatch.titleMatches("富士山下（Live）", "富士山下"))
    check("龙文 - Live 匹配 龙文", NameMatch.titleMatches("龙文 - Live", "龙文"))
    check("不同歌不匹配", !NameMatch.titleMatches("晴天", "夜曲"))
    check("妖狐标题取短横线前段", NameMatch.yaohuTitle("晴天 - 周杰伦 * 叶惠美") == "晴天",
          "got=\(NameMatch.yaohuTitle("晴天 - 周杰伦 * 叶惠美"))")
}

// MARK: - 4 音质判定（QualityFacts + SniffHead）

section("音质探测与档位判定")

do {
    check("flac 头 → flac", StreamVerifier.sniffHead(Array("fLaC".utf8)) == "flac")
    check("OggS 头 → ogg", StreamVerifier.sniffHead(Array("OggS".utf8)) == "ogg")
    check("ftyp(offset 4) → m4a",
          StreamVerifier.sniffHead([0, 0, 0, 0] + Array("ftyp".utf8)) == "m4a")
    check("ID3 头 → mp3", StreamVerifier.sniffHead(Array("ID3".utf8)) == "mp3")
    check("0xFF 0xFB → mp3", StreamVerifier.sniffHead([0xFF, 0xFB, 0x00]) == "mp3")
    check("RIFF 头 → wav", StreamVerifier.sniffHead(Array("RIFF".utf8)) == "wav")
    check("HTML 错误页 → unknown", StreamVerifier.sniffHead(Array("<html>".utf8)) == "unknown")
    check("空数据 → unknown", StreamVerifier.sniffHead([]) == "unknown")
}

do {
    // 实测基线：cyapi 的 QQ 直链 97kbps m4a，必须判成"标准"，不能标高品
    let qq = StreamVerifier.AudioFacts(container: "m4a", totalBytes: 3_280_000)
    let (q1, ext1) = QualityFacts.of(qq, durationSec: 269)
    check("3.28MB / 269s 的 m4a → 标准 128k", q1 == .standard, "got=\(q1.rawValue)")
    check("容器后缀 m4a", ext1 == "m4a", "ext=\(ext1)")
    check("97kbps 不命中高品 320k",
          !QualityFacts.matches(.high, container: "m4a", kbps: QualityFacts.kbps(3_280_000, 269)))

    // 实测基线：gdstudio 320k = 10.83MB / 269s
    let netease = StreamVerifier.AudioFacts(container: "mp3", totalBytes: 10_830_000)
    let (q2, _) = QualityFacts.of(netease, durationSec: 269)
    check("10.83MB / 269s 的 mp3 → 高品 320k", q2 == .high, "got=\(q2.rawValue)")
    check("320kbps 命中高品 320k",
          QualityFacts.matches(.high, container: "mp3", kbps: QualityFacts.kbps(10_830_000, 269)))

    // flac 容器不需要算码率就能定档
    let flac = StreamVerifier.AudioFacts(container: "flac", totalBytes: 55_397_039)
    let (q3, ext3) = QualityFacts.of(flac, durationSec: 269)
    check("flac 容器 → 无损", q3 == .lossless && ext3 == "flac", "got=\(q3.rawValue)/\(ext3)")
    check("无损容器命中无损档", QualityFacts.matches(.lossless, container: "flac", kbps: 1647))

    // 算不出码率（kbps=0）→ 一律不算命中
    check("kbps=0 不算命中任何档", !QualityFacts.matches(.standard, container: "mp3", kbps: 0))
    check("kbps=0 时 of() 往低标", {
        let (q, _) = QualityFacts.of(StreamVerifier.AudioFacts(container: "mp3", totalBytes: 0), durationSec: 0)
        return q == .standard
    }())

    // 区间边界
    check("255kbps 命中标准", QualityFacts.matches(.standard, container: "mp3", kbps: 255))
    check("256kbps 不算标准", !QualityFacts.matches(.standard, container: "mp3", kbps: 256))
    check("600kbps 命中高品上界", QualityFacts.matches(.high, container: "mp3", kbps: 600))
    check("601kbps 不算高品", !QualityFacts.matches(.high, container: "mp3", kbps: 601))

    // r122：探测链（peek 的纯函数部分）与按域名 Referer
    // 真机上 bytes(for:) 读不到 126.net 的字节，导致整条后端被判"没源"；这里钉住 peek 的判定口径
    let flacResp = HTTPURLResponse(url: URL(string: "https://m801.music.126.net/x.flac")!,
                                   statusCode: 206, httpVersion: "HTTP/2",
                                   headerFields: ["Content-Range": "bytes 0-4095/26281333",
                                                  "Content-Type": "audio/mpeg"])!
    let flacFacts = StreamVerifier.facts(from: flacResp, head: Data(Array("fLaC".utf8)))
    check("206 + Content-Range → 总长与容器都对", flacFacts?.totalBytes == 26_281_333
            && flacFacts?.container == "flac")
    check("这条 206 源按码率算就是无损",
          flacFacts.map { QualityFacts.of($0, durationSec: 194).0 == .lossless } ?? false)

    let mp3Resp = HTTPURLResponse(url: URL(string: "https://x/y.mp3")!,
                                  statusCode: 200, httpVersion: "HTTP/1.1",
                                  headerFields: ["Content-Length": "2414756",
                                                 "Content-Type": "audio/mpeg"])!
    let mp3Facts = StreamVerifier.facts(from: mp3Resp, head: Data(Array("ID3".utf8)))
    check("200 + Content-Length → 标准 128k",
          mp3Facts.map { QualityFacts.of($0, durationSec: 194).0 == .standard } ?? false)

    let htmlResp = HTTPURLResponse(url: URL(string: "https://x/y")!,
                                   statusCode: 403, httpVersion: "HTTP/1.1", headerFields: [:])!
    check("403 直接判不可用", StreamVerifier.facts(from: htmlResp, head: Data()) == nil)

    check("126.net 用网易 Referer",
          StreamVerifier.referer(forHost: "m801.music.126.net") == "https://music.163.com/")
    check("酷我域用酷我 Referer",
          StreamVerifier.referer(forHost: "car-lw.kuwo.cn") == "https://www.kuwo.cn/")
    check("QQ 域用 QQ Referer",
          StreamVerifier.referer(forHost: "isure.stream.qqmusic.qq.com") == "https://y.qq.com/")

    // r123：gdstudio 搜索兜底（官方 /api/search/get 在真机上对 iOS 回空/卡死）
    // 映射的纯函数部分钉死，避免"兜底看着有代码、实际映射不出候选"
    let gdItems: [[String: Any]] = [
        ["id": "27867073", "name": "연애의 조건 (Love Options)",
         "artist": ["BESTie"], "album": "연애의 조건 (Love Options)"],
        ["id": 28850832, "name": "연애의 조건", "artist": "BESTie", "album": "Hot Baby"],
        ["id": "27867073", "name": "重复 id 要去重", "artist": ["BESTie"], "album": ""],
        ["name": "没有 id 的行要丢掉", "artist": ["X"], "album": ""],
    ]
    let mapped = NeteaseSearchAdapter.songs(fromGdstudio: gdItems)
    check("gdstudio 兜底映射出 2 条（去重 + 丢无 id）", mapped.count == 2, "got=\(mapped.count)")
    check("兜底候选平台是网易", mapped.allSatisfy { $0.platform == .netease })
    check("兜底候选 id 正确", mapped.first?.platformID == "27867073")
    check("artist 数组拼成 /", mapped.first?.singer == "BESTie")
    check("artist 字符串直接用", mapped.count == 2 && mapped[1].singer == "BESTie")
    check("兜底候选没有时长（让 sameSong 跳过时长闸门）", mapped.allSatisfy { $0.durationSec == 0 })

    // 时长未知时靠接口自报 br 定档：1086kbps 必须判无损
    check("接口自报 1086kbps → 无损",
          QualityFacts.quality(container: "unknown", kbps: 1086) == .lossless)
    check("接口自报 320kbps → 高品",
          QualityFacts.quality(container: "unknown", kbps: 320) == .high)

    // r124：Meting 搜索结果里没有 id，得从 url 的 query 里抠（第三兜底源）
    check("meting url 抠出网易 id",
          NeteaseSearchAdapter.neteaseId(fromMetingURL:
            "https://api.qijieya.cn/meting/?server=netease&type=url&id=27867073") == "27867073")
    check("非 netease 的 url 不认",
          NeteaseSearchAdapter.neteaseId(fromMetingURL:
            "https://api.qijieya.cn/meting/?server=tencent&type=url&id=123") == nil)
    check("没有 id 的不认",
          NeteaseSearchAdapter.neteaseId(fromMetingURL: "https://api.qijieya.cn/meting/?type=url") == nil)

    let metingItems: [[String: Any]] = [
        ["name": "연애의 조건 (Love Options)", "artist": "BESTie",
         "url": "https://api.qijieya.cn/meting/?server=netease&type=url&id=27867073"],
        ["name": "重复", "artist": "BESTie",
         "url": "https://api.qijieya.cn/meting/?server=netease&type=url&id=27867073"],
        ["name": "别的平台", "artist": "X",
         "url": "https://api.qijieya.cn/meting/?server=tencent&type=url&id=999"],
    ]
    // r125：韩文歌名 NFC/NFD 混用时，同曲判定必须仍然通过（2.4.22 真机上检索到 10 条却全被丢）
    let nfcName = "연애의 조건 (Love Options)".precomposedStringWithCanonicalMapping
    let nfdName = nfcName.decomposedStringWithCanonicalMapping
    check("NFC/NFD 混用的歌名判为同一首", NameMatch.titleMatches(nfdName, nfcName))
    check("归一化后歌名相同", NameMatch.normTitle(nfdName) == NameMatch.normTitle(nfcName))

    let srcSong = Song.make(platform: .qq, platformID: "0008rnAh3oSbcW",
                            name: nfdName, singer: "BESTie (베스티)",
                            album: "", duration: 194, picURL: nil)
    let neSong = Song.make(platform: .netease, platformID: "27867073",
                           name: nfcName, singer: "BESTie",
                           album: "연애의 조건 (Love Options)", duration: 194, picURL: nil)
    check("专用检索的放宽判定接受跨平台同曲",
          NeteaseLookup.relaxedSame(src: srcSong, cand: neSong))
    check("放宽判定不放行不同歌名",
          !NeteaseLookup.relaxedSame(
            src: srcSong,
            cand: Song.make(platform: .netease, platformID: "1", name: "晴天", singer: "周杰伦",
                            album: "", duration: 194, picURL: nil)))
    check("放宽判定不放行同歌名但歌手完全不同的",
          !NeteaseLookup.relaxedSame(
            src: srcSong,
            cand: Song.make(platform: .netease, platformID: "2", name: "연애의 조건",
                            singer: "DJ铁叔", album: "", duration: 206, picURL: nil)))
    check("放宽判定接受候选人无歌手信息的",
          NeteaseLookup.relaxedSame(
            src: srcSong,
            cand: Song.make(platform: .netease, platformID: "3", name: "연애의 조건 (Love Options)",
                            singer: "", album: "", duration: 0, picURL: nil)))
    let metingSongs = NeteaseSearchAdapter.songs(fromMeting: metingItems)
    check("meting 映射：只留网易 + 按 id 去重", metingSongs.count == 1
            && metingSongs.first?.platformID == "27867073", "got=\(metingSongs.count)")

    // MARK: r120《연애의 조건》事故的两条根因
    // ① 126.net 的部分 fLaC 前面挂了一段 ID3v2，旧实现只看偏移 0 → 把真无损判成 mp3
    let id3PrefixedFlac: [UInt8] = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0] + Array("fLaC".utf8)
    check("ID3v2 前缀 + fLaC（前 16 字节内）→ flac",
          StreamVerifier.sniffHead(id3PrefixedFlac) == "flac",
          StreamVerifier.sniffHead(id3PrefixedFlac))
    check("ID3v2 前缀的 fLaC 命中无损档",
          QualityFacts.matches(.lossless, container: "flac", kbps: 1087))

    // ② of() 与 matches() 必须同一口径：1087kbps（容器认不出）既算命中无损、也要标成无损
    let highBitrate = StreamVerifier.AudioFacts(container: "mp3", totalBytes: 26_281_333)
    let (qHi, extHi) = QualityFacts.of(highBitrate, durationSec: 194)
    check("1087kbps（容器认不出）→ 无损，不再标 320k", qHi == .lossless, "got=\(qHi.rawValue)")
    check("1087kbps 命中无损档",
          QualityFacts.matches(.lossless, container: "mp3", kbps: 1087))
    check("无损档的容器后缀优先取探测值（此处 mp3，改名时以实测容器为准）",
          extHi == "mp3", "ext=\(extHi)")

    // 自检不变式：of() 给出的档位，必须能被 matches() 认成同一档
    for (container, kb) in [("flac", 1647), ("mp3", 1087), ("mp3", 320), ("mp3", 128), ("m4a", 97)] {
        let facts = StreamVerifier.AudioFacts(container: container,
                                             totalBytes: Int64(kb) * 194 / 8 * 1000)
        let (q, _) = QualityFacts.of(facts, durationSec: 194)
        check("of/matches 口径一致：\(container) \(kb)kbps → \(q.rawValue)",
              QualityFacts.matches(q, container: container, kbps: Int64(kb)),
              "of=\(q.rawValue)")
    }
}

// MARK: - 4.1 下载换源时的平台优先次序（r120）

section("下载换源平台优先次序")

do {
    let losslessOrder = MusicPlatform.allCases.map {
        ($0, SameSongCrossResolver.downloadPlatformRank($0, want: .lossless))
    }.sorted { $0.1 < $1.1 }.map(\.0)
    check("无损：网易最先（gdstudio 稳定出 fLaC）", losslessOrder.first == .netease,
          "\(losslessOrder.map(\.rawValue))")
    check("无损：酷我第二（妖狐常给 fLaC）",
          SameSongCrossResolver.downloadPlatformRank(.kuwo, want: .lossless) == 1)
    check("无损：QQ 最后（cyapi 只有 97kbps）",
          SameSongCrossResolver.downloadPlatformRank(.qq, want: .lossless) == 3)
    check("320k：网易最先（唯一按 br 给档）",
          SameSongCrossResolver.downloadPlatformRank(.netease, want: .high) == 0
            && SameSongCrossResolver.downloadPlatformRank(.qq, want: .high) == 3)
}

// MARK: - 5 酷我文本解析

section("KuwoParser（非 JSON 格式 + 相关性过滤）")

do {
    let fixture = """
    {'ARTISTPIC':'','abslist':[{'SONGNAME':'晴天','ARTIST':'周杰伦','ALBUM':'叶惠美','MUSICRID':'MUSIC_123','DURATION':'269','MVPIC':'324/s4s36/41/1.jpg'},\
    {'NAME':'晴天 (Live)','ARTIST':'周杰伦','ALBUM':'演唱会','MUSICRID':'MUSIC_456','DURATION':'302'},\
    {'SONGNAME':'夜曲','ARTIST':'周杰伦','MUSICRID':'MUSIC_789','DURATION':'03:47'}],'HIT':'1'}
    """
    let records = KuwoParser.extractAbsList(from: fixture)
    check("抽出 3 条记录", records.count == 3, "count=\(records.count)")
    check("新版 SONGNAME 可读", records.first?["SONGNAME"] == "晴天")
    check("老版 NAME 可读", records.count > 1 && records[1]["NAME"] == "晴天 (Live)")
    check("MUSIC_ 前缀可剥", (records.first?["MUSICRID"] ?? "").replacingOccurrences(of: "MUSIC_", with: "") == "123")

    check("DURATION 秒数直读", KuwoParser.parseDuration("269") == 269)
    check("DURATION mm:ss 兼容", KuwoParser.parseDuration("03:47") == 227)
    check("DURATION hh:mm:ss 兼容", KuwoParser.parseDuration("01:03:47") == 3827)
    check("DURATION 非法值 → 0", KuwoParser.parseDuration("abc") == 0)

    check("变体识别 DJ", KuwoParser.isVariant("晴天 (DJ阿lo版)"))
    check("变体识别 纯音乐", KuwoParser.isVariant("晴天 (纯音乐)"))
    check("原版不算变体", !KuwoParser.isVariant("晴天"))

    // 核心回归：两词查询不能被整串相关性过滤杀成 0 条（Android v2.1.95 的缺陷）
    let two = KuwoParser.relevantRecords(records, keyword: "晴天 周杰伦")
    check("两词查询有结果（旧口径为 0）", two.count >= 2, "count=\(two.count)")
    let one = KuwoParser.relevantRecords(records, keyword: "晴天")
    check("单词查询按词命中", one.count == 2, "count=\(one.count)")
    let none = KuwoParser.relevantRecords(records, keyword: "完全不相干的词xyz")
    check("不相关查询返回空", none.isEmpty, "count=\(none.count)")
}

// MARK: - 6 HTML 实体与转义

section("KuwoParser 边界")

do {
    let rec = KuwoParser.parseSingleQuotedDict("{'SONGNAME':'IVORY&nbsp;TOWER','ARTIST':'A\\'B'}")
    check("HTML 实体还原 &nbsp;", rec?["SONGNAME"] == "IVORY TOWER", "got=\(rec?["SONGNAME"] ?? "nil")")
    check("单引号转义还原", rec?["ARTIST"] == "A'B", "got=\(rec?["ARTIST"] ?? "nil")")
    check("非字典文本返回 nil", KuwoParser.parseSingleQuotedDict("not a dict") == nil)

    // 值里带逗号/括号不能把记录切坏
    let tricky = "{'SONGNAME':'歌 (Live), 第二版','ARTIST':'某人'}"
    let chunks = KuwoParser.splitTopLevel("[\(tricky),{'SONGNAME':'x','ARTIST':'y'}]")
    check("引号内逗号不切分", chunks.count == 2, "count=\(chunks.count)")
}

// MARK: - 7 源挑选（SourcePicker）

section("SourcePicker 择优")

do {
    let lossless = StreamSource(url: "a", backendName: "妖狐酷我", platform: .kuwo,
                                quality: .lossless, format: "flac", note: "", directId: false,
                                kbps: 1650, totalBytes: 55_000_000)
    let highM4a = StreamSource(url: "b", backendName: "cyapi QQ", platform: .qq,
                               quality: .high, format: "m4a", note: "", directId: true,
                               kbps: 320, totalBytes: 10_000_000)
    check("无损档优先无损", SourcePicker.pick([highM4a, lossless], want: .lossless)?.url == "a")
    // Android 的取舍：高品档里「按平台 ID 直连」优先于搜索式取流，
    // 所以 QQ 的 m4a 直链（3 分）会压过搜索式无损（3 分 -1 = 2 分）——这是有意为之，不是 bug。
    let pickedHigh = SourcePicker.pick([highM4a, lossless], want: .high)
    check("高品档优先「按 ID 直连」的后端", pickedHigh?.url == "b", "picked=\(pickedHigh?.url ?? "nil")")
}

// MARK: - 8 目标档判定

section("DownloadResolver.isExact")

do {
    let src = StreamSource(url: "u", backendName: "gdstudio 网易", platform: .netease,
                           quality: .high, format: "mp3", note: "", directId: true,
                           kbps: 320, totalBytes: 10_830_000)
    check("320kbps mp3 是 320k 目标档", DownloadResolver.isExact(src, want: .high, durationSec: 269))
    check("同一份不是无损目标档", !DownloadResolver.isExact(src, want: .lossless, durationSec: 269))
    let unknownDur = StreamSource(url: "u2", backendName: "x", platform: .qq, quality: .standard,
                                  format: "mp3", note: "", directId: false, kbps: 0, totalBytes: 0)
    check("时长未知时退回档位桶", DownloadResolver.isExact(unknownDur, want: .standard, durationSec: 0))
}

// MARK: - 9 播放推进规则（PlaybackRules）

section("PlaybackRules 播放推进")

do {
    // 单曲循环：还是当前这首（不是停止）
    check("单曲循环原地重播",
          PlaybackRules.nextIndex(count: 5, current: 2, mode: .singleLoop, randomIn: { _ in 0 }) == 2)

    // 列表循环：顺序取模，最后一首回到第 0 首
    check("列表循环前进",
          PlaybackRules.nextIndex(count: 5, current: 2, mode: .listLoop, randomIn: { _ in 0 }) == 3)
    check("列表循环末尾回到开头",
          PlaybackRules.nextIndex(count: 5, current: 4, mode: .listLoop, randomIn: { _ in 0 }) == 0)
    check("列表循环上一首从 0 绕到末尾",
          PlaybackRules.previousIndex(count: 5, current: 0, mode: .listLoop, randomIn: { _ in 0 }) == 4)

    // 随机：不允许随机到自己（注入一个"总是返回当前"的随机源来逼出兜底分支）
    let shuffleSameAsCurrent = PlaybackRules.nextIndex(
        count: 5, current: 2, mode: .shuffle, randomIn: { _ in 2 })
    check("随机不会随机到自己", shuffleSameAsCurrent != 2, "got=\(String(describing: shuffleSameAsCurrent))")
    check("随机只有一首就是它自己",
          PlaybackRules.nextIndex(count: 1, current: 0, mode: .shuffle, randomIn: { _ in 0 }) == 0)
    check("空队列没有下一首",
          PlaybackRules.nextIndex(count: 0, current: 0, mode: .listLoop, randomIn: { _ in 0 }) == nil)

    // 空队列 / 越界不崩
    check("空队列没有上一首",
          PlaybackRules.previousIndex(count: 0, current: 3, mode: .shuffle, randomIn: { _ in 0 }) == nil)
}

do {
    // 时长防线：差 >25s 才算"不是同一份音频"
    //
    // r66：原来是 5s，可"同一首歌的另一个剪辑"（多一段尾奏/前奏）动辄差 10~20 秒，
    // 那首歌本身没问题，却被判成坏源反复换源。真正的"冒充"（30 秒试听、别的歌）差得更远，
    // 所以门槛放宽到 25s；而且现在时长会跟着 AVPlayer 学会的真实值走（AudioPlayer.adoptDuration）。
    check("时长容差 = 25 秒", PlaybackRules.durationToleranceSec == 25)
    check("时长一致不拦", !PlaybackRules.durationMismatch(actual: 269, expected: 269))
    check("差 4s 不拦", !PlaybackRules.durationMismatch(actual: 273, expected: 269))
    check("差 16s 也不拦（同一首、多一段尾奏）",
          !PlaybackRules.durationMismatch(actual: 285, expected: 269))
    check("差 31s 拦下（现场版冒充原唱）",
          PlaybackRules.durationMismatch(actual: 300, expected: 269))
    check("曲目时长未知不拦", !PlaybackRules.durationMismatch(actual: 300, expected: 0))
    check("实际时长未知不拦", !PlaybackRules.durationMismatch(actual: .nan, expected: 269))

    // 连跳上限 3
    check("连跳 2 首继续", !PlaybackRules.shouldStopAfterSkips(2))
    check("连跳 3 首停下", PlaybackRules.shouldStopAfterSkips(3))
    check("停下的提示是完整句子", PlaybackRules.skipMessage(3).contains("3"))

    // 三态循环顺序：单曲 → 列表 → 随机 → 单曲
    check("模式循环顺序",
          PlayMode.singleLoop.cycled() == .listLoop
          && PlayMode.listLoop.cycled() == .shuffle
          && PlayMode.shuffle.cycled() == .singleLoop)
    check("三种模式都有文案", PlayMode.allCases.allSatisfy { !$0.displayName.isEmpty })
}

// MARK: - 10 歌词：清洗、LRC、逐字解密

section("歌词清洗与 LRC 解析")

do {
    check("多艺人取第一个（/）", LyricsCleaning.cleanArtist("A20 LITE/A20") == "A20 LITE",
          LyricsCleaning.cleanArtist("A20 LITE/A20"))
    check("多艺人取第一个（、）", LyricsCleaning.cleanArtist("谭晶、陈奕迅") == "谭晶")
    check("单艺人不改", LyricsCleaning.cleanArtist(" 周杰伦 ") == "周杰伦")
    check("空歌手返回空", LyricsCleaning.cleanArtist("") == "")
}

do {
    check("纯中文不算损坏", !LyricsCleaning.isBroken("故事的小黄花"))
    check("合法繁体不算损坏", !LyricsCleaning.isBroken("廣東話的歌詞"))
    check("中文里出现 ? 判损坏", LyricsCleaning.isBroken("?? 晴天"))
    check("中文里出现替换符判损坏", LyricsCleaning.isBroken("晴天\u{FFFD}"))
    check("中文里出现几何符号判损坏", LyricsCleaning.isBroken("晴天\u{25A0}"))
    check("空串算损坏", LyricsCleaning.isBroken("   "))
}

do {
    check("cleanLine 抹掉替换符", LyricsCleaning.cleanLine("晴\u{FFFD}天") == "晴天")
    check("cleanLine 丢弃 KRC 碎片行", LyricsCleaning.cleanLine("<1,2,3>") == "")
    check("cleanLine 抹掉中文里的问号", LyricsCleaning.cleanLine("晴天?") == "晴天")
    check("cleanLine 保留中文标点", LyricsCleaning.cleanLine("故事的小黄花，") == "故事的小黄花，")
    check("cleanLine 繁转简", LyricsCleaning.cleanLine("廣東話") == "广东话",
          LyricsCleaning.cleanLine("廣東話"))
}

do {
    let lrc = """
    [00:01.50]第一句
    [00:03.00]第二句
    [00:05.25][00:10.00]重复的一句
    [ar:周杰伦]
    """
    let lines = LyricsCleaning.parseLrc(lrc)
    check("LRC 行数（一个时间戳两次 = 两行）", lines.count == 4, "count=\(lines.count)")
    check("mm:ss.xx 按毫秒解析", lines.first?.timeMs == 1500, "t=\(lines.first?.timeMs ?? -1)")
    check("按时间排序", lines.map(\.timeMs) == lines.map(\.timeMs).sorted())
    check("非时间戳行被忽略", !lines.contains { $0.text.contains("ar:") })
    check("多时间戳展开", lines.filter { $0.text == "重复的一句" }.count == 2)
}

do {
    let lines = [LyricLine(timeMs: 0, text: "a"), LyricLine(timeMs: 1000, text: "b"),
                 LyricLine(timeMs: 2000, text: "c")]
    check("indexAt 命中第一行", LyricsCleaning.indexAt(lines, positionMs: 0) == 0)
    check("indexAt 命中中间", LyricsCleaning.indexAt(lines, positionMs: 1500) == 1)
    check("indexAt 超过最后一行取最后", LyricsCleaning.indexAt(lines, positionMs: 99_999) == 2)
    check("indexAt 在首行之前返回 -1", LyricsCleaning.indexAt(lines, positionMs: -1) == -1)
    check("indexAt 空数组返回 -1", LyricsCleaning.indexAt([], positionMs: 0) == -1)
}

do {
    check("繁简映射表规模够用", TradToSimpMap.pairCount > 1000, "count=\(TradToSimpMap.pairCount)")
    check("简体原样返回", TradToSimpMap.toSimplified("晴天") == "晴天")
}

section("歌词解密：真实酷狗 KRC + 合成 KRC/QRC + DES 向量")

func hexToBytes(_ hex: String) -> [UInt8] {
    var out: [UInt8] = []
    var i = hex.startIndex
    while i < hex.endIndex {
        let j = hex.index(i, offsetBy: 2)
        if let b = UInt8(hex[i..<j], radix: 16) { out.append(b) }
        i = j
    }
    return out
}

do {
    // 先单独验解压底座：这一层不通，KRC/QRC 全都解不开
    let hello = Zlib.inflate(Data(hexToBytes(LyricsFixtures.zlibHelloHex)))
    let helloText = hello.flatMap { String(data: $0, encoding: .utf8) }
    check("zlib 解压底座可用（zlib 包装）", helloText == "hello world",
          "err=\(Zlib.lastError) out=\(helloText ?? "nil")")

    // 对照：裸 deflate（无 zlib 头）也必须能解——SDK 的 COMPRESSION_ZLIB 实际吃裸流
    let rawBytes = hexToBytes(LyricsFixtures.rawDeflateHelloHex)
    let rawOut = Zlib.inflateRaw(Data(rawBytes))
    check("裸 deflate 可用",
          rawOut.flatMap { String(data: $0, encoding: .utf8) } == "hello world",
          "err=\(Zlib.lastError)")
}

do {
    // —— 真实数据：4192 字节 KRC 密文 → 63 行逐字歌词
    guard let data = Data(base64Encoded: LyricsFixtures.realKrcBase64) else {
        check("真实 KRC base64 可解码", false)
        exit(1)
    }
    let plain = LddcCrypto.krcDecrypt([UInt8](data))
    check("真实 KRC 解密成功", plain != nil, "err=\(Zlib.lastError)")
    if let plain {
        check("真实 KRC 明文含歌名", plain.contains(LyricsFixtures.realKrcContains))
        check("真实 KRC 明文够长", plain.count > 5000, "len=\(plain.count)")
        let lines = LddcCrypto.krcToLines(plain)
        check("真实 KRC 行数达到下限", lines.count >= LyricsFixtures.realKrcMinLines,
              "lines=\(lines.count)")
        check("真实 KRC 首行有逐字时间", lines.first?.hasWordTiming == true)
        check("真实 KRC 逐字时间递增", {
            guard let first = lines.first, first.words.count > 1 else { return false }
            return first.words[1].startMs >= first.words[0].startMs
        }())
        check("真实 KRC 逐字时间已换算成绝对时间（首行首词≥行首）", {
            guard let first = lines.first, let w = first.words.first else { return false }
            return w.startMs >= first.timeMs
        }())
    }
}

do {
    // —— 合成 KRC：逐字节往返
    guard let data = Data(base64Encoded: LyricsFixtures.synthKrcBase64),
          let plain = LddcCrypto.krcDecrypt([UInt8](data)) else {
        check("合成 KRC 解密成功", false, "err=\(Zlib.lastError)")
        exit(1)
    }
    let lines = LddcCrypto.krcToLines(plain)
    check("合成 KRC 行数", lines.count == LyricsFixtures.synthKrcExpectedLines,
          "got=\(lines.count)")
    check("合成 KRC 首行文本", lines.first?.text == LyricsFixtures.synthKrcExpectedFirstText,
          lines.first?.text ?? "nil")
    check("合成 KRC 首行时间", lines.first?.timeMs == LyricsFixtures.synthKrcExpectedFirstTimeMs)
    check("合成 KRC 首行逐字数量", lines.first?.words.count == LyricsFixtures.synthKrcExpectedFirstWords,
          "got=\(lines.first?.words.count ?? -1)")
    check("合成 KRC 首词时间 = 行首 + 0", lines.first?.words.first?.startMs == 0)
    check("合成 KRC 第二行逐字有偏移", {
        guard lines.count > 1, let w = lines[1].words.first else { return false }
        return w.startMs == lines[1].timeMs
    }())
    // 逐字拼接 = 整行文本（这是渲染层逐字染色的前提）
    check("逐字拼接与整行一致", {
        guard let first = lines.first else { return false }
        return first.words.map(\.text).joined().trimmingCharacters(in: .whitespaces) == first.text
    }())
    check("krcToLrc 兜底能出 LRC", !LddcCrypto.krcToLrc(plain).isEmpty)
    check("krcToLrc 的行数对得上", LddcCrypto.krcToLrc(plain).split(separator: "\n").count == lines.count)
}

do {
    // —— 合成 QRC：hex → 3DES → inflate → 逐字
    let plain = LddcCrypto.qrcDecrypt(hex: LyricsFixtures.synthQrcHex)
    check("合成 QRC 解密成功", plain != nil)
    if let plain {
        let lines = LddcCrypto.qrcToLines(plain)
        check("合成 QRC 行数", lines.count == LyricsFixtures.synthQrcExpectedLines,
              "got=\(lines.count)")
        check("合成 QRC 首行文本", lines.first?.text == LyricsFixtures.synthQrcExpectedFirstText,
              lines.first?.text ?? "nil")
        check("合成 QRC 首行时间", lines.first?.timeMs == LyricsFixtures.synthQrcExpectedFirstTimeMs)
        check("合成 QRC 首行逐字数量",
              lines.first?.words.count == LyricsFixtures.synthQrcExpectedFirstWords,
              "got=\(lines.first?.words.count ?? -1)")
        check("qrcToLrc 兜底能出 LRC", !LddcCrypto.qrcToLrc(plain).isEmpty)
    }
    check("非法 hex 返回 nil", LddcCrypto.qrcDecrypt(hex: "zz") == nil)
    check("空 hex 返回 nil", LddcCrypto.qrcDecrypt(hex: "") == nil)
}

do {
    // —— DES：与 Python 独立实现逐字节对齐（双向）
    for (index, vector) in LyricsFixtures.desVectors.enumerated() {
        let plain = hexToBytes(vector.plain)
        let cipher = hexToBytes(vector.cipher)
        let encrypted = LddcCrypto.tripledesEncryptBlock(plain)
        let decrypted = LddcCrypto.tripledesDecryptBlock(cipher)
        check("DES 向量 \(index + 1) 加密一致",
              encrypted.map { String(format: "%02x", $0) }.joined() == vector.cipher,
              encrypted.map { String(format: "%02x", $0) }.joined())
        check("DES 向量 \(index + 1) 解密一致",
              decrypted.map { String(format: "%02x", $0) }.joined() == vector.plain,
              decrypted.map { String(format: "%02x", $0) }.joined())
    }
}

// MARK: - 11 LDDC 评分（与 Python 参考实现对照）

section("LDDC 评分口径")

do {
    check("全角符号归一", LddcMatch.unifiedSymbol("（Live）：") == "(Live):")
    check("空白归一", LddcMatch.unifiedSymbol("  A   B ") == "A B")
    check("文本相似度完全相等 = 1", LddcMatch.textDifference("晴天", "晴天") == 1)
    check("文本相似度空串 = 0", LddcMatch.textDifference("", "晴天") == 0)
    check("LCS 相似度（abc/abd = 2·2/6）",
          abs(LddcMatch.textDifference("abc", "abd") - 2.0 / 3.0) < 0.001,
          "\(LddcMatch.textDifference("abc", "abd"))")
    check("歌手串拆分（斜杠）", LddcMatch.artistStr2List("A/B").count == 2)
    check("歌手括号别名", LddcMatch.artistStr2List("A (CV:B)") == [["A", "B"]],
          "\(LddcMatch.artistStr2List("A (CV:B)"))")
    check("歌手顺序无关（列表贪心配对）",
          abs(LddcMatch.listMaxDifference([["陈奕迅"], ["王菲"]], [["王菲"], ["陈奕迅"]]) - 1.0) < 0.001)
    check("歌手完全不同 = 0", LddcMatch.artistScore("周杰伦", "蔡健雅") == 0)
    check("同歌手 = 100", LddcMatch.artistScore("周杰伦", "周杰伦") == 100)
}

do {
    // 与 tools/ios/ref_match.py（照 Kotlin 独立转写的 Python 实现）逐条对齐
    for (index, v) in LyricsFixtures.matchVectors.enumerated() {
        let ts = LddcMatch.titleScore(v.title, v.candidateTitle)
        let asScore = LddcMatch.artistScore(v.artist, v.candidateArtist)
        let total = LddcMatch.score(title: v.title, candidateTitle: v.candidateTitle,
                                    artist: v.artist, candidateArtist: v.candidateArtist)
        check("评分向量 \(index + 1) 标题分（\(v.candidateTitle)）",
              abs(ts - v.titleScore) < 0.01, "\(ts) vs \(v.titleScore)")
        check("评分向量 \(index + 1) 歌手分", abs(asScore - v.artistScore) < 0.01,
              "\(asScore) vs \(v.artistScore)")
        check("评分向量 \(index + 1) 总分", abs(total - v.total) < 0.01,
              "\(total) vs \(v.total)")
    }
    // 反例：词完全对不上时要落在及格线以下（否则会把别的歌的歌词贴上来）
    let wrong = LddcMatch.score(title: "晴天", candidateTitle: "夜曲",
                                artist: "周杰伦", candidateArtist: "蔡健雅")
    check("完全不对的候选不及格", wrong < LddcMatch.minScore, "score=\(wrong)")
    check("及格线口径 = 55", LddcMatch.minScore == 55)
    check("时长容差 = 4 秒", LddcMatch.durationToleranceSec == 4)
}

// MARK: - 12 酷我歌词时间解析

section("酷我歌词时间")

do {
    check("秒（数字）→ 毫秒", KwLyrics.parseTimeMs(0.12) == 120)
    check("秒（字符串）→ 毫秒", KwLyrics.parseTimeMs("1.5") == 1500)
    check("整秒", KwLyrics.parseTimeMs(3) == 3000)
    check("负值无效", KwLyrics.parseTimeMs(-1.0) == nil)
    check("非数字无效", KwLyrics.parseTimeMs("abc") == nil)
    check("缺失无效", KwLyrics.parseTimeMs(nil) == nil)
}

// MARK: - 13 酷狗签名（与 Python 参考实现逐字节对照）

section("酷狗签名参数")

do {
    let search = LddcLyrics.kgQuery(
        params: [("sorttype", "0"), ("keyword", "晴天 周杰伦"), ("pagesize", "20"), ("page", "1")],
        module: "SearchSong", mid: "abcdef0123456789", dfid: "-", clientTime: 1700000000)
    check("SearchSong 查询串逐字节一致", search == LyricsFixtures.kgSearchSongQuery,
          "\n  got: \(search)\n  exp: \(LyricsFixtures.kgSearchSongQuery)")

    let lyric = LddcLyrics.kgQuery(
        params: [("album_audio_id", "123456"), ("duration", "269000"),
                 ("hash", "abc123def456"), ("keyword", "周杰伦 - 晴天"),
                 ("lrctxt", "1"), ("man", "no")],
        module: "Lyric", mid: "abcdef0123456789")
    check("Lyric 查询串逐字节一致（签名只含 appid/clientver+业务参数）",
          lyric == LyricsFixtures.kgLyricQuery,
          "\n  got: \(lyric)\n  exp: \(LyricsFixtures.kgLyricQuery)")
}

// MARK: - 14 封面兜底规则

section("封面兜底（严格匹配）")

do {
    check("同歌名同歌手命中",
          CoverResolver.isStrictMatch(name: "晴天", singer: "周杰伦",
                                      candidateName: "晴天", candidateSinger: "周杰伦"))
    check("歌名大小写不敏感",
          CoverResolver.isStrictMatch(name: "IVORY TOWER", singer: "A",
                                      candidateName: "ivory tower", candidateSinger: "a"))
    check("带版本后缀不算同一条（宁可没封面）",
          !CoverResolver.isStrictMatch(name: "晴天", singer: "周杰伦",
                                       candidateName: "晴天 (Live)", candidateSinger: "周杰伦"))
    check("多歌手里有一个相同即命中",
          CoverResolver.isStrictMatch(name: "因为爱情", singer: "陈奕迅/王菲",
                                      candidateName: "因为爱情", candidateSinger: "王菲"))
    check("歌手完全不同不命中",
          !CoverResolver.isStrictMatch(name: "晴天", singer: "周杰伦",
                                       candidateName: "晴天", candidateSinger: "蔡健雅"))
    check("目标无歌手时只比歌名",
          CoverResolver.isStrictMatch(name: "晴天", singer: "",
                                      candidateName: "晴天", candidateSinger: "任何人"))
    check("空歌名不命中",
          !CoverResolver.isStrictMatch(name: "  ", singer: "周杰伦",
                                       candidateName: "  ", candidateSinger: "周杰伦"))
    check("歌手片段拆分（斜杠）", CoverResolver.singerParts("A / B") == ["a", "b"],
          "\(CoverResolver.singerParts("A / B"))")
}

do {
    let kugouLegacy = Song(platform: .kugou, platformID: "h", name: "晴天", singer: "周杰伦",
                           album: "", duration: 269,
                           picURL: "https://imge.kugou.com/imgessl/500/12345.jpg")
    check("酷狗旧 imgessl 封面判死", CoverResolver.isLegacyDeadCover(kugouLegacy))
    let kugouNew = Song(platform: .kugou, platformID: "h", name: "晴天", singer: "周杰伦",
                        album: "", duration: 269,
                        picURL: "https://imge.kugou.com/stdmusic/500/x.jpg")
    check("酷狗新封面不判死", !CoverResolver.isLegacyDeadCover(kugouNew))
    let qqLegacy = Song(platform: .qq, platformID: "m", name: "晴天", singer: "周杰伦",
                        album: "", duration: 269, picURL: "https://imge.kugou.com/imgessl/x.jpg")
    check("非酷狗平台不套用 imgessl 规则", !CoverResolver.isLegacyDeadCover(qqLegacy))
    check("缓存键 = 歌名|歌手", CoverResolver.cacheKeyFor(kugouNew) == "晴天|周杰伦")
}

// MARK: - 下载校验（P2）

section("下载校验：95% 体积 / 仅 Wi-Fi / 档位顺序")

do {
    check("体积刚好 95% 判完整", DownloadGuard.isComplete(actual: 950, expected: 1000))
    check("体积 94.9% 判不完整", !DownloadGuard.isComplete(actual: 949, expected: 1000))
    check("实际比预期还大判完整", DownloadGuard.isComplete(actual: 1200, expected: 1000))
    check("预期未知（0）不做体积判定", DownloadGuard.isComplete(actual: 5_000_000, expected: 0))
    check("实际为 0 且预期已知判不完整", !DownloadGuard.isComplete(actual: 0, expected: 1000))

    check("缺口比例 5%", abs(DownloadGuard.shortfall(actual: 950, expected: 1000) - 0.05) < 0.0001,
          "\(DownloadGuard.shortfall(actual: 950, expected: 1000))")
    check("预期为 0 时缺口为 0", DownloadGuard.shortfall(actual: 100, expected: 0) == 0)

    check("仅 Wi-Fi 且非 Wi-Fi → 拒下",
          DownloadGuard.refusalReason(wifiOnly: true, onWiFi: false) != nil)
    check("仅 Wi-Fi 但在 Wi-Fi 上 → 放行",
          DownloadGuard.refusalReason(wifiOnly: true, onWiFi: true) == nil)
    check("没开仅 Wi-Fi，蜂窝也放行",
          DownloadGuard.refusalReason(wifiOnly: false, onWiFi: false) == nil)

    check("档位顺序：无损 → 高品 → 标准",
          DownloadGuard.qualityOptions() == [.lossless, .high, .standard],
          "\(DownloadGuard.qualityOptions())")

    check("体积文案 22.7MB", DownloadGuard.sizeText(22_700_000) == "22.7 MB",
          DownloadGuard.sizeText(22_700_000))
    check("体积文案 <1MB 用 KB", DownloadGuard.sizeText(520_000) == "520 KB",
          DownloadGuard.sizeText(520_000))
    check("体积未知写待核对", DownloadGuard.sizeText(0) == "待核对")
}

// MARK: - 发现页口径（轮换 / 原版判定 / 榜单 / 猜你喜欢）

section("发现页口径：每日轮换 / 原版判定 / 榜单挑选")

do {
    // ① 每日轮换
    let pool = Array(0..<10)
    check("轮换取前 3 首", DiscoverRules.rotate(pool, day: 0, take: 3) == [0, 1, 2])
    check("轮换按天滑窗", DiscoverRules.rotate(pool, day: 7, take: 3) == [7, 8, 9])
    check("轮换到尾回绕", DiscoverRules.rotate(pool, day: 8, take: 3) == [8, 9, 0])
    check("负天数也不越界", DiscoverRules.rotate(pool, day: -1, take: 2) == [9, 0])
    check("take 超过池子按池子长度", DiscoverRules.rotate(pool, day: 0, take: 99).count == 10)
    check("空池子返回空", DiscoverRules.rotate([Int](), day: 3, take: 5).isEmpty)

    // ①.5 热歌榜换榜核对（r121：老板"19 号了还显示 11-17 的内容"）
    // 旧口径"每个进程只查一次"在 App 后台挂几天时永远不核对，所以这里钉住新的节流规则
    check("从没查过 → 要查", DiscoverRules.needsHotRevalidate(lastCheckAt: nil, lastCheckDay: -1,
                                                          today: 100, now: Date()))
    check("跨本地日 → 必查（哪怕 1 秒前刚查过）",
          DiscoverRules.needsHotRevalidate(lastCheckAt: Date(), lastCheckDay: 99,
                                           today: 100, now: Date()))
    check("同一天、刚查过 → 不查",
          !DiscoverRules.needsHotRevalidate(lastCheckAt: Date(), lastCheckDay: 100,
                                            today: 100, now: Date()))
    check("同一天、超过间隔 → 再查",
          DiscoverRules.needsHotRevalidate(lastCheckAt: Date().addingTimeInterval(-601),
                                           lastCheckDay: 100, today: 100, now: Date()))
    check("核对间隔是 10 分钟", DiscoverRules.hotRevalidateIntervalSec == 600)

    // ② 原版判定
    check("去括号版本", DiscoverRules.coreName("晴天 (Live)") == "晴天",
          DiscoverRules.coreName("晴天 (Live)"))
    check("去中文括号", DiscoverRules.coreName("晴天（伴奏）") == "晴天",
          DiscoverRules.coreName("晴天（伴奏）"))
    check("去 DJ 版后缀并清尾部连接符", DiscoverRules.coreName("夜曲 - DJ版") == "夜曲",
          DiscoverRules.coreName("夜曲 - DJ版"))
    check("去纯音乐后缀", DiscoverRules.coreName("七里香 纯音乐") == "七里香",
          DiscoverRules.coreName("七里香 纯音乐"))
    check("干净名字原样返回", DiscoverRules.coreName("晴天") == "晴天")
    check("原版分高于 Live 版",
          DiscoverRules.plainScore("晴天") > DiscoverRules.plainScore("晴天 (Live)"))

    // ③ 歌手归一
    check("合唱取第一个歌手", DiscoverRules.singerKey("陈奕迅/华语群星") == "陈奕迅",
          DiscoverRules.singerKey("陈奕迅/华语群星"))
    check("单人歌手不变", DiscoverRules.singerKey("周杰伦") == "周杰伦")

    func mkSong(_ name: String, _ singer: String, _ id: String) -> Song {
        Song(platform: .qq, platformID: id, name: name, singer: singer,
             album: "", duration: 200, picURL: nil)
    }

    // ④ 榜单挑选：同曲只留原版、同歌手 ≤2、凑不满不硬凑
    let candidates = [
        mkSong("晴天", "周杰伦", "1"),
        mkSong("晴天 (Live)", "周杰伦", "2"),
        mkSong("七里香", "周杰伦", "3"),
        mkSong("青花瓷", "周杰伦", "4"),
        mkSong("夜曲", "周杰伦", "5"),
        mkSong("演员", "薛之谦", "6"),
    ]
    let picked = DiscoverRules.pick(candidates, limit: 7)
    check("同曲只留 1 首", picked.filter { $0.name == "晴天" }.count == 1,
          "\(picked.map(\.name))")
    check("非原版被剔除", !picked.contains { $0.name.contains("Live") })
    check("同歌手最多 2 首", picked.filter { $0.singer == "周杰伦" }.count <= DiscoverRules.maxPerSinger,
          "\(picked.filter { $0.singer == "周杰伦" }.count)")
    check("候选不够时不硬凑", picked.count == 3, "\(picked.count)")
    check("剔除听过的（按核心歌名）",
          DiscoverRules.pick(candidates, limit: 7, excluding: ["晴天"]).allSatisfy { $0.name != "晴天" })

    // ⑤ 猜你喜欢的关键词
    let recent = [mkSong("晴天", "周杰伦", "a"), mkSong("七里香", "周杰伦", "b"),
                  mkSong("演员", "薛之谦", "c")]
    check("关键词按歌手去重并保序",
          DiscoverRules.guessKeywords(from: recent, limit: 5) == ["周杰伦", "薛之谦"],
          "\(DiscoverRules.guessKeywords(from: recent, limit: 5))")

    // ⑥ 目录本身
    check("Widget「每日三首」4 类池子", DiscoverCatalog.playlists.count == 4)
    check("每类 30 首", DiscoverCatalog.playlists.allSatisfy { $0.seeds.count == 30 },
          "\(DiscoverCatalog.playlists.map { $0.seeds.count })")
    check("热门种子词 24 个", DiscoverCatalog.hotSeedWords.count == 24,
          "\(DiscoverCatalog.hotSeedWords.count)")
    check("每类每天都能凑 20 首",
          DiscoverCatalog.playlists.allSatisfy {
              DiscoverRules.rotate($0.seeds, day: 12_345, take: 20).count == 20
          })
}

// MARK: - 识曲打分（P3）

section("识曲打分：原唱标记 / 裸名 / 专辑 / 跨通道互证")

do {
    func hit(_ title: String, _ artist: String, _ album: String, _ dur: Int,
             _ source: String, _ rank: Int, _ isOriginal: Int) -> RecognizeCandidate {
        RecognizeCandidate(title: title, artist: artist, album: album, durationSec: dur,
                           source: source, rank: rank, isOriginal: isOriginal)
    }

    let kugouOriginal = hit("晴天", "周杰伦", "叶惠美", 269, RecognizeScore.sourceKugou, 0, 1)
    let kugouCover = hit("晴天 (Live)", "周杰伦", "叶惠美", 269, RecognizeScore.sourceKugou, 1, 2)
    let neteaseOriginal = hit("晴天", "周杰伦", "叶惠美", 269, RecognizeScore.sourceNetease, 0, -1)
    let neteaseCover = hit("晴天(深情版)", "Lucky小爱", "晴天(深情版)", 268,
                           RecognizeScore.sourceNetease, 0, -1)

    // ① 单条打分：45（原唱）+12（裸名）+15（正式专辑）+4（时长）+7（第 1 条）
    check("酷狗原唱单条 83 分", RecognizeScore.memberScore(kugouOriginal) == 83,
          "\(RecognizeScore.memberScore(kugouOriginal))")
    check("翻唱/现场版明显更低",
          RecognizeScore.memberScore(kugouCover) < RecognizeScore.memberScore(kugouOriginal),
          "\(RecognizeScore.memberScore(kugouCover))")
    check("同名合集专辑被压分", RecognizeScore.memberScore(neteaseCover) < 0,
          "\(RecognizeScore.memberScore(neteaseCover))")

    // ② 单通道：分数原样带出
    let single = RecognizeScore.fuse(kugou: [kugouOriginal], netease: [])
    check("单通道取最高分", single?.ranked.first?.score == 83, "\(single?.ranked.first?.score ?? -999)")
    check("单通道只报酷狗", single?.bestByChannel[RecognizeScore.sourceKugou] == 83)
    check("单通道没有网易分", single?.bestByChannel[RecognizeScore.sourceNetease] == nil)
    check("单通道结论写「采用酷狗」", single?.note.contains("采用酷狗") == true, single?.note ?? "")

    // ③ 双通道互证：同一身份合并 +50
    let fused = RecognizeScore.fuse(kugou: [kugouOriginal], netease: [neteaseOriginal])
    check("两通道同一首合成一个身份", fused?.ranked.count == 1, "\(fused?.ranked.count ?? -1)")
    check("互证加 50 分", fused?.ranked.first?.score == 133, "\(fused?.ranked.first?.score ?? -999)")
    check("互证结论", fused?.note.contains("双通道互证") == true, fused?.note ?? "")

    // ④ 酷狗给「别人的翻唱」、网易给原唱时，原唱那个身份要排前面
    let kugouCoverOther = hit("晴天 (Live)", "凌霄", "叶惠美", 269,
                              RecognizeScore.sourceKugou, 0, 2)
    let covered = RecognizeScore.fuse(kugou: [kugouCoverOther], netease: [neteaseOriginal])
    check("翻唱与原唱是两个身份", covered?.ranked.count == 2, "\(covered?.ranked.count ?? -1)")
    check("原唱身份排第一", covered?.ranked.first?.rep.artist == "周杰伦",
          covered?.ranked.first?.rep.artist ?? "")
    check("翻唱身份被压到后面",
          (covered?.ranked.first?.score ?? -999) > (covered?.ranked.last?.score ?? 999),
          "\(covered?.ranked.first?.score ?? -999) vs \(covered?.ranked.last?.score ?? 999)")

    // ⑤ 身份键：繁简/标点归一后同键
    check("身份键跨通道一致",
          RecognizeScore.identityKey(kugouOriginal) == RecognizeScore.identityKey(neteaseOriginal))
    check("合唱取第一位歌手", RecognizeScore.firstArtist("张杰、胡迪/范如臣") == "张杰",
          RecognizeScore.firstArtist("张杰、胡迪/范如臣"))

    // ⑥ 判词：专辑名就是歌名 / 综艺专辑
    check("专辑名等于歌名判同名合集",
          RecognizeJudge.isSameAlbumAsTitle("我们都一样 EP", "我们都一样"))
    check("综艺专辑被认出", RecognizeJudge.isVarietyAlbum("异口同声 第十二期"))
    check("正式专辑不误判", !RecognizeJudge.isVarietyAlbum("叶惠美"))
    check("Live 歌名被认出", RecognizeJudge.isVariantTitle("晴天 (Live)"))
    check("裸名不误判", !RecognizeJudge.isVariantTitle("晴天"))
}

// MARK: - 网易通道：指纹输入与响应解析（P3 第二段）

section("网易通道：Float32 指纹输入 / audio-match 解析")

do {
    // ① Int16LE → Float32LE base64
    //    三个样本：0、满量程 32767、-32768
    var pcm = Data()
    for value in [Int16(0), Int16(32767), Int16(-32768)] {
        withUnsafeBytes(of: value.littleEndian) { pcm.append(contentsOf: $0) }
    }
    // 不足 1 秒（8000 样本）应当拒绝
    check("不足 1 秒不做指纹", FingerprintPCM.float32Base64(pcm16: pcm) == nil)

    // 补到 1 秒整：后面全 0
    var oneSecond = pcm
    oneSecond.append(Data(repeating: 0, count: 8_000 * 2 - pcm.count))
    if let base64 = FingerprintPCM.float32Base64(pcm16: oneSecond) {
        let floats = FingerprintPCM.floats(fromBase64: base64)
        check("1 秒 → 8000 个 float", floats.count == 8_000, "\(floats.count)")
        check("首个样本为 0", floats.first == 0)
        check("满量程 32767 ≈ 0.99997", abs((floats[1]) - 0.99997) < 0.001, "\(floats[1])")
        check("负满量程 -32768 = -1", abs(floats[2] + 1) < 0.0001, "\(floats[2])")
        check("base64 长度为 4 字节/样本", Data(base64Encoded: base64)?.count == 8_000 * 4,
              "\(Data(base64Encoded: base64)?.count ?? -1)")
    } else {
        check("1 秒整应当能出指纹", false)
    }

    // ② 只取最后 12 秒
    var long = Data()
    for _ in 0..<(8_000 * 20) {
        withUnsafeBytes(of: Int16(1000).littleEndian) { long.append(contentsOf: $0) }
    }
    if let base64 = FingerprintPCM.float32Base64(pcm16: long) {
        check("20 秒只取最后 12 秒",
              Data(base64Encoded: base64)?.count == 8_000 * 12 * 4,
              "\(Data(base64Encoded: base64)?.count ?? -1)")
    } else {
        check("20 秒应当能出指纹", false)
    }

    // ③ 表单体：六个字段齐全，rawdata 参与编码
    let body = NeteaseRecognizer.formBody(fingerprint: "AA+/=", seconds: 12)
    check("表单含 algorithmCode=shazam_v2", body.contains("algorithmCode=shazam_v2"))
    check("表单含 duration=12", body.contains("duration=12"))
    check("rawdata 做了百分号编码", body.contains("rawdata=AA%2B%2F%3D"), body)
    check("sessionId 有值", body.contains("sessionId=\(NeteaseRecognizer.sessionID)"))

    // ④ 响应解析：命中
    let hitJSON = """
    {"code":200,"data":{"noMatchReason":0,"result":[
      {"song":{"name":"晴天","duration":269000,
        "album":{"name":"叶惠美"},
        "artists":[{"name":"周杰伦"}]}}
    ]}}
    """
    let hits = NeteaseRecognizer.parse(hitJSON)
    check("命中解析出 1 条", hits.count == 1, "\(hits.count)")
    check("歌名/歌手/专辑/时长", hits.first?.title == "晴天"
          && hits.first?.artist == "周杰伦"
          && hits.first?.album == "叶惠美"
          && hits.first?.durationSec == 269, "\(String(describing: hits.first))")
    check("来源标成网易", hits.first?.source == RecognizeScore.sourceNetease)
    check("网易不提供原唱标记", hits.first?.isOriginal == -1)

    // ⑤ 响应解析：没识别到（noMatchReason=10）
    let missJSON = """
    {"code":200,"data":{"noMatchReason":10,"result":[]}}
    """
    check("noMatchReason 非 0 判没识别到", NeteaseRecognizer.parse(missJSON).isEmpty)

    // ⑥ 响应解析：code 不是 200
    check("code 非 200 返回空", NeteaseRecognizer.parse("{\"code\":400}").isEmpty)

    // ⑦ 多歌手拼接与去重
    let multiJSON = """
    {"code":200,"data":{"noMatchReason":"0","result":[
      {"song":{"name":"凉凉","duration":260000,"album":{"name":"三生三世十里桃花"},
        "artists":[{"name":"张碧晨"},{"name":"杨宗纬"}]}},
      {"song":{"name":"凉凉","duration":260000,"album":{"name":"三生三世十里桃花"},
        "artists":[{"name":"张碧晨"},{"name":"杨宗纬"}]}}
    ]}}
    """
    let multi = NeteaseRecognizer.parse(multiJSON)
    check("多歌手用顿号拼接", multi.first?.artist == "张碧晨、杨宗纬", multi.first?.artist ?? "")
    check("同歌同歌手去重", multi.count == 1, "\(multi.count)")
}

// MARK: - 收尾口径（可配置跳过上限）

section("收尾口径：可配置跳过上限")

do {
    // ① 跳过上限（设置里「跳过上限」与「自动跳歌」开关都落到这两个函数）
    check("默认上限仍是 3",
          PlaybackRules.shouldStopAfterSkips(PlaybackRules.autoSkipLimit,
                                             limit: PlaybackRules.autoSkipLimit))
    check("上限 1 时第 1 首就停", PlaybackRules.shouldStopAfterSkips(1, limit: 1))
    check("上限 5 时第 4 首不停", !PlaybackRules.shouldStopAfterSkips(4, limit: 5))
    check("上限 0 也按 1 处理", PlaybackRules.shouldStopAfterSkips(1, limit: 0))
    check("停下文案写清楚", PlaybackRules.skipMessage(3, limit: 3).contains("先停在这里"),
          PlaybackRules.skipMessage(3, limit: 3))
    check("未到上限时不写停", !PlaybackRules.skipMessage(2, limit: 3).contains("先停在这里"),
          PlaybackRules.skipMessage(2, limit: 3))
}

// MARK: - 系统面：Intent 信箱与分享文案（P4）

section("系统面：Intent 信箱 / 分享文案")

do {
    // ① 信箱：先放先取、取完清空
    let inbox = IntentInbox()
    check("空信箱取到空数组", inbox.takeAll().isEmpty)
    inbox.post(.playFavorites)
    inbox.post(.search("晴天"))
    check("两条都在", inbox.pendingCount == 2, "\(inbox.pendingCount)")
    let taken = inbox.takeAll()
    check("顺序保持投递顺序", taken == [.playFavorites, .search("晴天")], "\(taken)")
    check("取完即清空", inbox.takeAll().isEmpty)
    check("清空后计数为 0", inbox.pendingCount == 0)

    // ② 分享文案：事实 + 来源，不带链接
    let shared = Song(platform: .qq, platformID: "1", name: "晴天", singer: "周杰伦",
                      album: "叶惠美", duration: 269, picURL: nil)
    let text = SongShare.text(song: shared)
    check("分享含歌名歌手", text.contains("晴天 - 周杰伦"), text)
    check("分享含专辑", text.contains("专辑：叶惠美"), text)
    check("分享含来源平台", text.contains("来源：QQ音乐"), text)
    check("分享不带链接", !text.contains("http"), text)

    // ③ 空歌手不产生 " - "
    let noSinger = Song(platform: .kuwo, platformID: "2", name: "纯音乐",
                        singer: "  ", album: "", duration: 100, picURL: nil)
    check("空歌手只写歌名", SongShare.text(song: noSinger).hasPrefix("纯音乐"), SongShare.text(song: noSinger))

    // ④ 带音源时的补充行
    let src = StreamSource(url: "https://x/y.m4a", backendName: "cyapi QQ", platform: .qq,
                           quality: .high, format: "m4a", note: "")
    check("分享补音源行",
          SongShare.text(song: shared, source: src).contains("音源：cyapi QQ · M4A · 0 kbps"),
          SongShare.text(song: shared, source: src))
}

// MARK: - 歌词滚动提前量 / 下拽关闭灵敏度（r65）

section("歌词滚动提前量与下拽关闭（r65）")

do {
    // ① 滚动要早于高亮（老板："歌词统一都是滚动晚了一些"）
    let lines = [
        LyricLine(timeMs: 1_000, text: "第一句", words: []),
        LyricLine(timeMs: 5_000, text: "第二句", words: []),
        LyricLine(timeMs: 9_000, text: "第三句", words: []),
    ]

    // r74：老板口径「滚动必须与时间戳严格对应」→ 提前量归零，滚动与高亮同一时刻
    check("提前量 0（滚动与时间戳严格对应）", LyricsUXRules.scrollLeadMs == 0)

    // 第 1 句唱到 4.9 秒时高亮还在第 1 句，但滚动目标已经是第 2 句（提前 220ms 起滚）
    check("高亮仍第 1 句",
          LyricsCleaning.indexAt(lines, positionMs: 4_900) == 0)
    check("提前量为 0 时滚动目标 == 高亮行（不再抢跑）",
          LyricsCleaning.scrollAnchorIndex(lines, positionMs: 4_900,
                                          leadMs: LyricsUXRules.scrollLeadMs) == 0)
    check("离切换还远时两者一致",
          LyricsCleaning.scrollAnchorIndex(lines, positionMs: 2_000,
                                          leadMs: LyricsUXRules.scrollLeadMs) == 0)
    check("提前量 0 时退化为高亮行",
          LyricsCleaning.scrollAnchorIndex(lines, positionMs: 4_900, leadMs: 0) == 0)
    check("空歌词返回 -1",
          LyricsCleaning.scrollAnchorIndex([], positionMs: 4_900, leadMs: 220) == -1)
    check("负数提前量按 0 处理",
          LyricsCleaning.scrollAnchorIndex(lines, positionMs: 4_900, leadMs: -500) == 0)

    // ② 下拽关闭：比上一版（110 / 280）灵敏，但轻点、上滑、横滑都不关
    check("阈值 56 / 170",
          PlayerDismissRules.dismissDistance == 56 && PlayerDismissRules.dismissPredictedDistance == 170)
    check("拖到 60pt 就关", PlayerDismissRules.shouldDismiss(translation: 60, predicted: 90))
    check("拖 90pt 随便预测都关",
          PlayerDismissRules.shouldDismiss(translation: 90, predicted: 90))
    check("只拖 20pt 不关", !PlayerDismissRules.shouldDismiss(translation: 20, predicted: 40))
    check("轻扫（预测 180）也关",
          PlayerDismissRules.shouldDismiss(translation: 30, predicted: 180))
    check("上滑不关", !PlayerDismissRules.shouldDismiss(translation: -80, predicted: -200))
    check("NaN 不崩也不关",
          !PlayerDismissRules.shouldDismiss(translation: .nan, predicted: .nan))
}

// MARK: - 版式规则（P5 打磨）

section("版式规则：iPad 限宽 / 宽屏判定")

do {
    check("iPhone 竖屏 393 原样", LayoutRules.contentWidth(available: 393) == 393)
    check("iPad 竖屏 1024 截到 700", LayoutRules.contentWidth(available: 1024) == 700)
    check("横屏 852 截到 700", LayoutRules.contentWidth(available: 852) == 700)
    check("恰好 700 不变", LayoutRules.contentWidth(available: 700) == 700)
    check("宽度未知给上限", LayoutRules.contentWidth(available: 0) == 700)
    check("负数给上限", LayoutRules.contentWidth(available: -10) == 700)
    check("NaN 给上限", LayoutRules.contentWidth(available: .nan) == 700)
    check("768 算宽屏", LayoutRules.isWide(768))
    check("393 不算宽屏", !LayoutRules.isWide(393))
    check("自定义上限生效", LayoutRules.contentWidth(available: 900, max: 600) == 600)
}

// MARK: - 文本清洗 + 跨平台去重（v2.2 老板反馈 ⑦）

section("文本清洗：接口里的字面量转义与 HTML 实体")

do {
    check("字面量 \\u0026 还原成 &（真机录屏里「周杰伦\\u0026Lara」的根因）",
          TextClean.text("周杰伦\\u0026Lara梁心颐") == "周杰伦&Lara梁心颐",
          TextClean.text("周杰伦\\u0026Lara梁心颐"))
    check("中文转义也能还原", TextClean.text("\\u6674\\u5929") == "晴天", TextClean.text("\\u6674\\u5929"))
    check("&nbsp; 变空格", TextClean.text("A&nbsp;B") == "A B")
    check("&amp; 变 &", TextClean.text("A&amp;B") == "A&B")
    check("零宽字符与 BOM 被清掉", TextClean.text("\u{200B}晴天\u{FEFF}") == "晴天")
    check("首尾空白被 trim", TextClean.text("  晴天  ") == "晴天")
    check("没有转义时原样返回", TextClean.text("晴天") == "晴天")

    let cleaned = Song.make(platform: .qq, platformID: "c1", name: "珊瑚海",
                            singer: "周杰伦\\u0026Lara梁心颐", album: "十一月的萧邦",
                            duration: 260, picURL: nil)
    check("Song.make 构造时就洗净（UI 层不再看到反斜杠）", cleaned.singer == "周杰伦&Lara梁心颐",
          cleaned.singer)
}

section("跨平台去重：同一首只留匹配度最高的一条（对齐 APK songDedupeKey）")

do {
    let qq = song(.qq, "晴天", "周杰伦", id: "q1")
    let netease = song(.netease, "晴天", "周杰伦", id: "n1")
    let kuwo = song(.kuwo, "晴天", "周杰伦", id: "k1")
    let merged = SearchRanker.dedupe([qq, netease, kuwo])
    check("四家同名同歌手只留 1 条", merged.count == 1, "count=\(merged.count)")
    check("留下的是输入顺序里第一条（= 排序后分数最高的那条）", merged.first?.platform == .qq,
          merged.first?.platform.rawValue ?? "nil")

    check("同一位歌手的另一首歌不合并",
          SearchRanker.dedupe([qq, song(.qq, "七里香", "周杰伦", id: "q2")]).count == 2)
    check("同名不同歌手不合并",
          SearchRanker.dedupe([qq, song(.netease, "晴天", "某翻唱", id: "n9")]).count == 2)
    check("不同版本（Live）不合并",
          SearchRanker.dedupe([qq, song(.qq, "晴天 (Live)", "周杰伦", id: "q3")]).count == 2)

    // 真机录屏里网易把《倔强》同一首歌吐了 5 条（ID 不同），这是最典型的那一类
    let jj = (0..<5).map { song(.netease, "倔强", "五月天", id: "j\($0)") }
    check("同平台同歌 5 条只留 1 条", SearchRanker.dedupe(jj).count == 1)

    // 歌手字段带字面量转义的合唱曲：洗完以后应当和另一平台的干净写法合并
    let dirty = song(.qq, "珊瑚海", "周杰伦\\u0026Lara梁心颐", id: "d1")
    let clean = song(.kuwo, "珊瑚海", "周杰伦&Lara梁心颐", id: "d2")
    check("脏歌手与干净歌手算同一首", SearchRanker.dedupe([dirty, clean]).count == 1)

    check("归一化键只留数字/字母/汉字（对齐 Android 正则）",
          SearchRanker.normalizedKey("Letting Go (Live)!") == "lettinggolive",
          SearchRanker.normalizedKey("Letting Go (Live)!"))
    check("归一化键保留汉字", SearchRanker.normalizedKey("晴天·周杰伦") == "晴天周杰伦")
}

// MARK: - 第二轮整改：歌词时间轴 + 下载实测档位

section("歌词切行时间点（第三轮：与 APK `indexAt` 逐字一致）")

do {
    // APK 的口径就一句：`line.timeMs <= positionMs` 就切。逐字时间只用来做行内染色，不参与切行。
    let lines = [
        LyricLine(timeMs: 1000, text: "第一句"),
        LyricLine(timeMs: 5000, text: "第二句", words: [
            LyricWord(text: "第", startMs: 5300, durMs: 200),
        ]),
        LyricLine(timeMs: 9000, text: "第三句"),
    ]

    check("999ms 还没到第一句", LyricsCleaning.indexAt(lines, positionMs: 999) == -1)
    check("1000ms 切到第一句", LyricsCleaning.indexAt(lines, positionMs: 1000) == 0)
    check("5000ms 就切到第二句（按行时间，不等第一个字 5300）",
          LyricsCleaning.indexAt(lines, positionMs: 5000) == 1,
          "\(LyricsCleaning.indexAt(lines, positionMs: 5000))")
    check("4999ms 仍停在第一句", LyricsCleaning.indexAt(lines, positionMs: 4999) == 0)
    check("9000ms 切到第三句", LyricsCleaning.indexAt(lines, positionMs: 9000) == 2)
    check("空歌词返回 -1", LyricsCleaning.indexAt([], positionMs: 1000) == -1)

    // 用户偏移（±600ms）由调用方加在 positionMs 上：+200 提前、-200 延后
    check("偏移 +200ms：4800 的位置按 5000 算，已切到第二句",
          LyricsCleaning.indexAt(lines, positionMs: 4800 + 200) == 1)
    check("偏移 -200ms：5000 的位置按 4800 算，仍停在第一句",
          LyricsCleaning.indexAt(lines, positionMs: 5000 - 200) == 0)
}

section("第四轮：播放页宽度钉死 + 点歌词跳转口径")

do {
    // 老板第四轮录屏：播放页整页横向溢出，左右两头的按钮全跑到屏幕外。
    // 修法是把内容宽度先钉到屏幕上，这里把口径钉成断言。
    check("iPhone 393：原样用",
          LayoutRules.playerWidth(available: 393, screen: 393) == 393,
          "\(LayoutRules.playerWidth(available: 393, screen: 393))")
    check("外层给到 1200（比屏幕还宽）→ 钉回 393",
          LayoutRules.playerWidth(available: 1200, screen: 393) == 393,
          "\(LayoutRules.playerWidth(available: 1200, screen: 393))")
    check("外层给到 0 / NaN → 退回屏幕宽",
          LayoutRules.playerWidth(available: 0, screen: 393) == 393
          && LayoutRules.playerWidth(available: .nan, screen: 393) == 393)
    check("iPad 1024 → 限 700（与其它页面 readableWidth 同口径）",
          LayoutRules.playerWidth(available: 1024, screen: 1024) == 700,
          "\(LayoutRules.playerWidth(available: 1024, screen: 1024))")

    check("LRC 头部 [offset:+500] 解析成 +500",
          LyricsCleaning.lrcOffsetMs("[offset:+500]\n[00:01.00]第一句") == 500,
          "\(LyricsCleaning.lrcOffsetMs("[offset:+500]\n[00:01.00]第一句"))")
    check("没有 offset 标签 → 0",
          LyricsCleaning.lrcOffsetMs("[00:01.00]第一句") == 0)

    let shifted = LyricsCleaning.parseLrc("[offset:+500]\n[00:01.00]第一句\n[00:02.00]第二句")
    check("offset +500 → 行时间整体提前 500ms（1000 → 500）",
          shifted.first?.timeMs == 500,
          "\(shifted.first?.timeMs ?? -1)")
    let negativeShift = LyricsCleaning.parseLrc("[offset:-500]\n[00:01.00]第一句")
    check("offset −500 → 行时间整体延后（1000 → 1500）",
          negativeShift.first?.timeMs == 1500,
          "\(negativeShift.first?.timeMs ?? -1)")
    let clampedShift = LyricsCleaning.parseLrc("[offset:+3000]\n[00:01.00]第一句")
    check("offset 比行时间还大 → 夹到 0，不出负时间",
          clampedShift.first?.timeMs == 0,
          "\(clampedShift.first?.timeMs ?? -1)")

    check("点 5000ms 那句、用户偏移 +200 → 跳到 4800ms",
          LyricsCleaning.seekTargetMs(lineMs: 5000, userOffsetMs: 200) == 4800,
          "\(LyricsCleaning.seekTargetMs(lineMs: 5000, userOffsetMs: 200))")
    check("点 5000ms 那句、用户偏移 -200 → 跳到 5200ms",
          LyricsCleaning.seekTargetMs(lineMs: 5000, userOffsetMs: -200) == 5200)
    let seekLines = [LyricLine(timeMs: 1000, text: "第一句"), LyricLine(timeMs: 5000, text: "第二句")]
    check("跳完以后被点的那一句就是当前行（高亮不串行）",
          LyricsCleaning.indexAt(
            seekLines,
            positionMs: LyricsCleaning.seekTargetMs(lineMs: 5000, userOffsetMs: 200) + 200) == 1)
}

section("下载落盘后的实测档位（老板反馈 ⑥：找到无损却下成 320k）")

do {
    // 真实文件头：FLAC "fLaC" / MP3 "ID3"
    let flacMagic: [UInt8] = [0x66, 0x4C, 0x61, 0x43, 0, 0, 0, 34] + Array(repeating: 0, count: 8)
    let mp3Magic: [UInt8] = [0x49, 0x44, 0x33] + Array(repeating: 0, count: 13)

    let flac = DownloadGuard.verdict(prefix: flacMagic, size: 30_000_000, durationSec: 260)
    check("FLAC 头 → 无损", flac.quality == .lossless, flac.quality.rawValue)
    check("FLAC 头 → 后缀 flac", flac.extensionName == "flac")

    // 320k mp3：260 秒 × 320kbps ≈ 10.4 MB
    let mp3High = DownloadGuard.verdict(prefix: mp3Magic, size: 10_400_000, durationSec: 260)
    check("300+ kbps 的 mp3 → 高品", mp3High.quality == .high, "kbps=\(mp3High.kbps)")
    check("mp3 头 → 后缀 mp3", mp3High.extensionName == "mp3")

    // 128k mp3：260 秒 × 128kbps ≈ 4.2 MB
    let mp3Std = DownloadGuard.verdict(prefix: mp3Magic, size: 4_160_000, durationSec: 260)
    check("128k 的 mp3 → 标准", mp3Std.quality == .standard, "kbps=\(mp3Std.kbps)")

    check("标着无损但实测 320k → 有一句人话",
          DownloadGuard.downgradeNote(mp3High, requested: .lossless) != nil)
    check("实测就是无损 → 不啰嗦",
          DownloadGuard.downgradeNote(flac, requested: .lossless) == nil)
    check("标着无损但实测 320k 的说明里带实测码率",
          (DownloadGuard.downgradeNote(mp3High, requested: .lossless) ?? "").contains("kbps"))
}

section("第五轮：播放页留白 / 歌词浏览手感（老板反馈 ①⑤⑥⑦）")

do {
    // ⑥ 老板 r63：整列铺满，间距只做下限（富余由 Spacer 均分），不再出现"上边留白 + 下面一大截空"
    check("iPhone 844：间距下限落在 12~24pt（富余由 Spacer 均分，不再吞成一大块）",
          LayoutRules.playerGap(availableHeight: 844) > 12
          && LayoutRules.playerGap(availableHeight: 844) < 24,
          "\(LayoutRules.playerGap(availableHeight: 844))")
    check("小屏 400：间距压到下限 12pt（不会挤成一团也不铺张）",
          LayoutRules.playerGap(availableHeight: 400) == 12,
          "\(LayoutRules.playerGap(availableHeight: 400))")
    check("超大屏 2000：间距封顶 24pt（富余交给封面吃掉）",
          LayoutRules.playerGap(availableHeight: 2000) == 24,
          "\(LayoutRules.playerGap(availableHeight: 2000))")
    check("屏高未知（0 / NaN）→ 给一个安全的 16pt",
          LayoutRules.playerGap(availableHeight: 0) == 16
          && LayoutRules.playerGap(availableHeight: .nan) == 16)

    // ⑤ 滑歌词后停留 4 秒才回当前行
    check("停留时长 4 秒", LyricsUXRules.dwellSeconds == 4)
    check("停 4 秒 → 该回到当前行", LyricsUXRules.shouldResumeFollowing(secondsSinceInteraction: 4))
    check("才停 3.9 秒 → 不回去（还没来得及点，别弹走）",
          !LyricsUXRules.shouldResumeFollowing(secondsSinceInteraction: 3.9))
    check("NaN 当作「立刻回」（宁可跟随，不要卡在不跟随）",
          LyricsUXRules.shouldResumeFollowing(secondsSinceInteraction: .nan))

    // ⑥ 点击判定：只认"几乎没动、也没按太久"
    check("手指没动、0.2 秒 → 算点击", LyricsUXRules.isTap(moved: 3, duration: 0.2))
    check("扫了 20pt → 不算点击（滑动时不跳歌）",
          !LyricsUXRules.isTap(moved: 20, duration: 0.2))
    check("按了 0.9 秒 → 不算点击",
          !LyricsUXRules.isTap(moved: 3, duration: 0.9))
    check("滑动刚结束 0.1 秒内的触摸只当刹车",
          LyricsUXRules.isTapCoolingDown(secondsSinceScrollEnd: 0.1))
    check("滑动结束 0.5 秒后恢复正常点击",
          !LyricsUXRules.isTapCoolingDown(secondsSinceScrollEnd: 0.5))
}

section("第五轮：歌词取词判版本（文件头时长 / 版本标签 / 排序）")

do {
    // 老板反馈 ③：七里香取到的总是 live 版，逐行时间对不上。
    // 修法是不动 LDDC 主评分公式，另加"歌词文件头验收 + 版本标签惩罚 + 时长差排序"。
    let krcMeta = LyricsCleaning.meta(
        "[total:261000]\n[ti:七里香 - 周杰伦]\n[ar:周杰伦]\n[al:七里香]\n")
    check("KRC 头 [total:] 解析成毫秒", krcMeta.durationMs == 261000, "\(krcMeta.durationMs)")
    check("头里 [ti:七里香 - 周杰伦] 剥掉歌手后缀", krcMeta.title == "七里香", krcMeta.title)
    check("头里 [ar:]/[al:] 原样带出",
          krcMeta.artist == "周杰伦" && krcMeta.album == "七里香")
    check("有头部信息 → hasHeader", krcMeta.hasHeader)

    // 三种时长写法：LRC 的 mm:ss、纯毫秒、纯秒
    check("[length:04:21] → 261000ms",
          LyricsCleaning.meta("[length:04:21]").durationMs == 261000,
          "\(LyricsCleaning.meta("[length:04:21]").durationMs)")
    check("[length:261000] → 261000ms",
          LyricsCleaning.meta("[length:261000]").durationMs == 261000)
    check("[duration:261] 纯数字 ≤10000 → 当秒，261000ms",
          LyricsCleaning.meta("[duration:261]").durationMs == 261000)
    check("[length:abc] / 空串 → 0，不崩",
          LyricsCleaning.meta("[length:abc]").durationMs == 0
          && LyricsCleaning.meta("").durationMs == 0)
    check("KRC 行 [29900,1000]<0,...> 不会被误当成头部标签",
          LyricsCleaning.meta("[29900,1000]<0,1000,0>故事的小黄花").hasHeader == false)
    check("[offset:+500] 从头部带出", LyricsCleaning.meta("[offset:+500]").offsetMs == 500)

    // 版本标签惩罚：候选是 live/现场/翻唱/伴奏，而查询不是 → 扣 35 分
    check("七里香 vs 七里香 (Live) → 扣 35",
          LddcMatch.versionPenalty(queryTitle: "七里香", candidateTitle: "七里香 (Live)") == 35)
    check("全角括号的「现场版」同样认得",
          LddcMatch.versionPenalty(queryTitle: "七里香", candidateTitle: "七里香（现场版）") == 35)
    check("候选项只是「- 周杰伦」这种署名 → 不扣",
          LddcMatch.versionPenalty(queryTitle: "七里香", candidateTitle: "七里香 - 周杰伦") == 0)
    check("查询自己就是 Live → 不扣",
          LddcMatch.versionPenalty(queryTitle: "七里香 (Live)", candidateTitle: "七里香（现场版）") == 0)
    check("伴奏/纯音乐/Cover 都算另一个版本",
          LddcMatch.versionPenalty(queryTitle: "晴天", candidateTitle: "晴天 - 伴奏") == 35
          && LddcMatch.versionPenalty(queryTitle: "晴天", candidateTitle: "晴天（纯音乐）") == 35
          && LddcMatch.versionPenalty(queryTitle: "晴天", candidateTitle: "晴天 (Cover)") == 35)
    check("Olive 这种带 live 字样的普通歌名不误判",
          LddcMatch.versionPenalty(queryTitle: "Olive", candidateTitle: "Olive") == 0)
    // 这条是主评分拦不住的：标题分 57 > 50，只有版本标签这一层能拦
    check("富士山下（Live）→ 扣 35",
          LddcMatch.versionPenalty(queryTitle: "富士山下", candidateTitle: "富士山下（Live）") == 35)

    // 扣完必须掉到及格线以下（七里香 live 原本 73 分就能过）
    let liveScore = LddcMatch.score(title: "七里香", candidateTitle: "七里香 (Live)",
                                    artist: "周杰伦", candidateArtist: "周杰伦")
    check("七里香 Live 原本能过线（说明公式本身拦不住）",
          liveScore > LddcMatch.minScore, "\(liveScore)")
    check("扣掉版本分以后就过不了线",
          liveScore - LddcMatch.versionPenalty(queryTitle: "七里香",
                                              candidateTitle: "七里香 (Live)") < LddcMatch.minScore)

    // 排序：分数降序 → 时长差升序（r72：`rank` 就是 LDDC 的口径，不再有"源优先/兜底档"）
    let cands = [
        LddcLyrics.Candidate(source: "kg", title: "七里香", artist: "周杰伦", durationSec: 299),
        LddcLyrics.Candidate(source: "kg", title: "七里香 (Live)", artist: "周杰伦", durationSec: 302),
        LddcLyrics.Candidate(source: "kg", title: "夜曲", artist: "周杰伦", durationSec: 226),
    ]
    let ranked = LddcLyrics.rank(cands, title: "七里香", artist: "周杰伦", targetSec: 299)
    check("排序：原版第一（标题满分）",
          ranked.first?.candidate.title == "七里香", "\(ranked.first?.candidate.title ?? "nil")")
    // r74：Live 不再"排第二等兜底"——版本类不同，直接被身份闸挡掉
    check("排序：Live 不进池（版本类不同，身份闸挡掉）",
          !ranked.contains { $0.candidate.title.contains("(Live)") },
          "\(ranked.map(\.candidate.title))")
    check("排序：别的歌（夜曲）进不来（分数不到 55）",
          !ranked.contains { $0.candidate.title == "夜曲" }, "\(ranked.map(\.candidate.title))")
    check("排名里每条都过 55 分", ranked.allSatisfy { $0.score > LddcMatch.minScore })
    check("有合格候选时，时长差 >4s 的不进池",
          LddcLyrics.rank([LddcLyrics.Candidate(source: "kg", title: "七里香", artist: "周杰伦",
                                                durationSec: 299),
                           LddcLyrics.Candidate(source: "kg", title: "七里香", artist: "周杰伦",
                                                durationSec: 320)],
                          title: "七里香", artist: "周杰伦", targetSec: 299).count == 1)
    check("时长门槛不再放宽（差 >4s 一律不进池，宁可空着也不贴另一版）",
          LddcLyrics.rank([LddcLyrics.Candidate(source: "kg", title: "七里香", artist: "周杰伦",
                                                durationSec: 320)],
                          title: "七里香", artist: "周杰伦", targetSec: 299).isEmpty)
    check("时长未知不放行也不误杀（只按分数）",
          !LddcLyrics.rank([LddcLyrics.Candidate(source: "kg", title: "七里香", artist: "周杰伦",
                                                 durationSec: 0)],
                           title: "七里香", artist: "周杰伦", targetSec: 299).isEmpty)
    // 歌名自己带 Live：带 Live 的候选要排到前面（老板要的"歌名带 live 就优先 live 词"）
    let liveRanked = LddcLyrics.rank([
        LddcLyrics.Candidate(source: "kg", title: "七里香", artist: "周杰伦", durationSec: 302),
        LddcLyrics.Candidate(source: "kg", title: "七里香 (Live)", artist: "周杰伦", durationSec: 302),
    ], title: "七里香 (Live)", artist: "周杰伦", targetSec: 302)
    check("歌名带 Live → 带 Live 的候选排第一",
          liveRanked.first?.candidate.title == "七里香 (Live)",
          "\(liveRanked.map(\.candidate.title))")

    // 时长硬门槛（LDDC 的 4000ms）
    check("时长差 4s 以内放行", LddcMatch.durationOK(targetSec: 300, candidateSec: 304))
    check("时长差 5s 丢掉", !LddcMatch.durationOK(targetSec: 300, candidateSec: 305))
    check("时长未知放行", LddcMatch.durationOK(targetSec: 300, candidateSec: 0))

    // 真实酷狗 KRC 回归：头部只有 ti/ar/al，没有 [total:] → 不能因为"缺时长"把整批词丢掉
    if let data = Data(base64Encoded: LyricsFixtures.realKrcBase64),
       let plain = LddcCrypto.krcDecrypt([UInt8](data)) {
        let realMeta = LyricsCleaning.meta(plain)
        check("真实 KRC 头部能认出歌名", realMeta.title.contains("晴天"), realMeta.title)
        check("真实 KRC 头部能认出歌手", realMeta.artist.contains("周杰伦"), realMeta.artist)
        check("真实 KRC 头部没有 [total:]（缺失时 durationMs = 0）",
              realMeta.durationMs == 0, "\(realMeta.durationMs)")
    } else {
        check("真实 KRC 样本能解密", false)
    }
}

section("第六轮：播放页铺满 / 队列口径 / 歌词兜底 / 悬浮条严丝合缝（老板 r63）")

do {
    // ① 播放页「封面撑满型」：封面吃掉富余高度，整列铺满屏高
    let phone = LayoutRules.playerCoverSide(width: 393, height: 852)
    check("iPhone 393×852：封面 ≈ 340pt（吃掉富余高度）", phone > 320 && phone < 360, "\(phone)")
    let se = LayoutRules.playerCoverSide(width: 375, height: 667)
    check("小屏 375×667：封面收到 200 上下（其余块不被挤出屏幕）",
          se > 180 && se < 230, "\(se)")
    check("封面永远不超过「屏宽 − 56」",
          LayoutRules.playerCoverSide(width: 393, height: 852) <= 393 - 56)
    check("封面有下限 140（再小的屏也不至于看不见）",
          LayoutRules.playerCoverSide(width: 120, height: 300) == 140,
          "\(LayoutRules.playerCoverSide(width: 120, height: 300))")
    check("屏宽/屏高未知 → 按 393×852 估",
          LayoutRules.playerCoverSide(width: 0, height: 0) == phone)

    // ⑦ 悬浮条严丝合缝：占位 = 条子本体 64，没播歌时 24
    check("在播歌：列表末尾让出 64（= 条子 56 + 上下各 4）",
          MiniPlayerMetrics.listBottomInset(playing: true) == 64,
          "\(MiniPlayerMetrics.listBottomInset(playing: true))")
    check("没在播歌：只让 24（页面底部呼吸）",
          MiniPlayerMetrics.listBottomInset(playing: false) == 24)
    check("让出高度正好等于条子高度（上一版 72+32 多空了 40pt）",
          MiniPlayerMetrics.listBottomInset(playing: true) == MiniPlayerMetrics.barHeight)

    // ⑤ 同一首歌再点：不重新请求、不重头播
    check("同一首 + 已装上播放项 + 无错误 → 复用当前播放",
          PlaybackRules.shouldReuseCurrentSong(currentID: "qq_1", targetID: "qq_1",
                                               hasLoadedItem: true, hasError: false))
    check("上次解析失败（无播放项）→ 允许重试",
          !PlaybackRules.shouldReuseCurrentSong(currentID: "qq_1", targetID: "qq_1",
                                                hasLoadedItem: false, hasError: true))
    check("换了一首歌 → 正常起播",
          !PlaybackRules.shouldReuseCurrentSong(currentID: "qq_1", targetID: "qq_2",
                                                hasLoadedItem: true, hasError: false))
    check("没有当前曲（首次播放）→ 正常起播",
          !PlaybackRules.shouldReuseCurrentSong(currentID: nil, targetID: "qq_1",
                                                hasLoadedItem: true, hasError: false))

    // ⑧ r72：取词候选的分数**只用 LDDC 公式**（标题 0.5 + 歌手 0.5），
    //    不再有"版本标记 −35 / 时长差 −40 / 三档四档兜底"——那几档会把本来能用的歌压到线下。
    let qili = song(.qq, "七里香", "周杰伦", dur: 299, id: "q777")
    let zunxiangLines = [LyricLine(timeMs: 0, text: "发如雪（醇享版）- 周杰伦 (Jay Chou)"),
                         LyricLine(timeMs: 5_000, text: "狼牙月 伊人憔悴")]
    check("正文首行写着醇享版 → 判为另一版（酷我/网易云/LRCLIB 都走这条）",
          LyricsCleaning.contentVersionRejection(lines: zunxiangLines, queryTitle: "发如雪") != nil)
    let plainLines = [LyricLine(timeMs: 0, text: "发如雪 - 周杰伦"),
                      LyricLine(timeMs: 5_000, text: "狼牙月 伊人憔悴")]
    check("普通正文首行 → 不拦",
          LyricsCleaning.contentVersionRejection(lines: plainLines, queryTitle: "发如雪") == nil)
    check("正文首行带 live → 判为另一版",
          LyricsCleaning.contentVersionRejection(
            lines: [LyricLine(timeMs: 0, text: "发如雪 (Live) - 周杰伦")],
            queryTitle: "发如雪") != nil)
    // 《七里香》那次错的正是这一条：歌名干净，词却是演唱会的
    check("演唱会版正文 → 判为另一版（老板《七里香》那次就错在这里）",
          LyricsCleaning.contentVersionRejection(
            lines: [LyricLine(timeMs: 0, text: "七里香 (2024 嘉年华世界巡回演唱会台北站) - 周杰伦")],
            queryTitle: "七里香") != nil)

    // ⑨ r72：LRCLIB 源的选源口径（纯函数）
    let tracks = [
        LrclibLyrics.Track(title: "七里香 (Live)", artist: "周杰伦", durationSec: 302,
                           syncedLyrics: "[00:01.00]x", instrumental: false),
        LrclibLyrics.Track(title: "七里香", artist: "周杰伦", durationSec: 297,
                           syncedLyrics: "[00:27.38]窗外的麻雀", instrumental: false),
        LrclibLyrics.Track(title: "七里香", artist: "周杰伦", durationSec: 299,
                           syncedLyrics: nil, instrumental: false),
    ]
    check("LRCLIB：原版（带时间轴）胜出",
          LrclibLyrics.pickBest(tracks, queryTitle: "七里香", queryArtist: "周杰伦",
                                targetSec: 299)?.durationSec == 297)
    check("LRCLIB：没有时间轴的（纯文本）不收",
          LrclibLyrics.pickBest([tracks[2]], queryTitle: "七里香", queryArtist: "周杰伦",
                                targetSec: 299) == nil)
    check("LRCLIB：时长差 >4s 的不收",
          LrclibLyrics.pickBest([LrclibLyrics.Track(title: "七里香", artist: "周杰伦",
                                                   durationSec: 320,
                                                   syncedLyrics: "[00:01.00]x",
                                                   instrumental: false)],
                                queryTitle: "七里香", queryArtist: "周杰伦", targetSec: 299) == nil)
    check("LRCLIB：纯音乐不收",
          LrclibLyrics.pickBest([LrclibLyrics.Track(title: "七里香", artist: "周杰伦",
                                                   durationSec: 299,
                                                   syncedLyrics: "[00:01.00]x",
                                                   instrumental: true)],
                                queryTitle: "七里香", queryArtist: "周杰伦", targetSec: 299) == nil)
    check("LRCLIB：歌名/歌手对不上的不收",
          LrclibLyrics.pickBest([LrclibLyrics.Track(title: "夜曲", artist: "蔡健雅",
                                                   durationSec: 299,
                                                   syncedLyrics: "[00:01.00]x",
                                                   instrumental: false)],
                                queryTitle: "七里香", queryArtist: "周杰伦", targetSec: 299) == nil)
    check("LRCLIB：同分时选时长更接近的那条（0 秒那条不能靠运气赢）",
          LrclibLyrics.pickBest([
            LrclibLyrics.Track(title: "七里香", artist: "周杰伦", durationSec: 0,
                               syncedLyrics: "[00:01.00]x", instrumental: false),
            LrclibLyrics.Track(title: "七里香", artist: "周杰伦", durationSec: 297,
                               syncedLyrics: "[00:01.00]x", instrumental: false),
          ], queryTitle: "七里香", queryArtist: "周杰伦", targetSec: 299)?.durationSec == 297)

    // ⑩ r73：原版优先 / 变体垫底 —— 老板《发如雪》51 行错词的正解
    //
    // 实测（2026-11-17）酷我里周杰伦《发如雪》只有 伴奏 / DJ版 / 拍摄花絮 / 现场版，**没有正片**；
    // 而「发如雪 拍摄花絮」的标题分 54.5 + 歌手 100 = 77 分，比及格线还高 22 分，
    // 它的"歌词"其实是「本字幕由QQ音乐独家AI字幕技术生成」的专辑介绍口播。
    check("「拍摄花絮」被认成变体标记",
          LddcMatch.extraVariantTags(queryTitle: "发如雪",
                                     candidateTitle: "发如雪 拍摄花絮") == ["花絮"])
    check("变体标记不参与打分（公式仍与 LDDC 一致，花絮候选照样 77 分过线）",
          LddcMatch.score(title: "发如雪", candidateTitle: "发如雪 拍摄花絮",
                          artist: "周杰伦", candidateArtist: "周杰伦") > LddcMatch.minScore)
    let variantRanked = LddcLyrics.rank([
        LddcLyrics.Candidate(source: "kg", title: "发如雪 拍摄花絮", artist: "周杰伦", durationSec: 299),
        LddcLyrics.Candidate(source: "kg", title: "发如雪", artist: "周杰伦", durationSec: 299),
    ], title: "发如雪", artist: "周杰伦", targetSec: 299)
    check("花絮候选被身份闸挡掉，池里只剩原版",
          variantRanked.count == 1 && variantRanked.first?.candidate.title == "发如雪",
          "\(variantRanked.map(\.candidate.title))")
    check("只有变体时**空着**（老板口径：宁可不给，也不拿 Live 词糊弄）",
          LddcLyrics.rank([LddcLyrics.Candidate(source: "kg", title: "发如雪 (Live)",
                                                artist: "周杰伦", durationSec: 299)],
                          title: "发如雪", artist: "周杰伦", targetSec: 299).isEmpty)

    // 正文是字幕/文案 → 一律不收（《发如雪》51 行「酷我」那条就是这种）
    let subtitleLines = [LyricLine(timeMs: 0, text: "本字幕由QQ音乐独家AI字幕技术生成"),
                         LyricLine(timeMs: 1_230, text: "周杰伦的11月的萧邦推出也有一段时间")]
    check("字幕文案被判成「不是歌词」", LyricsCleaning.commentaryReason(lines: subtitleLines) != nil)
    check("正文闸门拦下字幕文案",
          LyricsCleaning.foreignVersionReason(lines: subtitleLines, queryTitle: "发如雪") != nil)
    check("正常歌词不被正文闸门误杀",
          LyricsCleaning.foreignVersionReason(
            lines: [LyricLine(timeMs: 0, text: "狼牙月"), LyricLine(timeMs: 3_000, text: "伊人憔悴")],
            queryTitle: "发如雪") == nil)

    // LRCLIB / 网易云这类"按歌名搜"的源：查原版时**不收** Live 那条（r73 起与 LDDC 同口径）
    check("LRCLIB：查 Live 时优先 Live 那条",
          LrclibLyrics.pickBest([
            LrclibLyrics.Track(title: "七里香", artist: "周杰伦", durationSec: 302,
                               syncedLyrics: "[00:01.00]x", instrumental: false),
            LrclibLyrics.Track(title: "七里香 (Live)", artist: "周杰伦", durationSec: 302,
                               syncedLyrics: "[00:01.00]x", instrumental: false),
          ], queryTitle: "七里香 (Live)", queryArtist: "周杰伦", targetSec: 302)?.title == "七里香 (Live)")
    check("LRCLIB：查原版时不收 Live 那条（宁可没词，也不贴另一版）",
          LrclibLyrics.pickBest([
            LrclibLyrics.Track(title: "七里香 (Live)", artist: "周杰伦", durationSec: 299,
                               syncedLyrics: "[00:01.00]x", instrumental: false),
          ], queryTitle: "七里香", queryArtist: "周杰伦", targetSec: 299) == nil)
    check("LRCLIB：查原版时不收「拍摄花絮」那条",
          LrclibLyrics.pickBest([
            LrclibLyrics.Track(title: "发如雪 拍摄花絮", artist: "周杰伦", durationSec: 299,
                               syncedLyrics: "[00:01.00]x", instrumental: false),
          ], queryTitle: "发如雪", queryArtist: "周杰伦", targetSec: 299) == nil)

    // ③ 时间轴对齐（r66 根因修复）：**只有歌词自己写了总长才允许拉伸**
    //
    // 老板三轮都说"歌词晚了一些"，真因就在这一条：酷我官方词没有总长字段，旧口径拿
    // 「最后一行 + 3 秒」当总长，于是每首正常歌都被当成"另一个剪辑"拉长：
    // 《那天下雨了》208s+3s=211s、元数据 224s → ×1.06 → 200 秒处晚 12 秒。
    let shortLyric = [LyricLine(timeMs: 0, text: "a"), LyricLine(timeMs: 270_000, text: "z")]
    check("没写总长的词一律不拉伸（这条就是歌词越唱越晚的根因）",
          LyricsCleaning.alignedToAudio(shortLyric, declaredMs: 0, audioSec: 362).ratio == 1)
    check("没写总长 + 音源更长也不拉（尾奏不是另一个剪辑）",
          LyricsCleaning.alignedToAudio(shortLyric, declaredMs: 0, audioSec: 224).ratio == 1)

    // ④ 行数同一版判定（r68：能不能用逐字那份词替换行级那份）
    check("55 行 vs 55 行 = 同一版", LyricsCleaning.lineCountsCompatible(55, 55))
    check("55 行 vs 62 行 = 同一版（+13%）", LyricsCleaning.lineCountsCompatible(55, 62))
    check("46 行 vs 55 行 也能接受（+20%）", LyricsCleaning.lineCountsCompatible(46, 55))
    check("55 行 vs 30 行 = 不是同一版", !LyricsCleaning.lineCountsCompatible(55, 30))
    check("55 行 vs 90 行 = 不是同一版", !LyricsCleaning.lineCountsCompatible(55, 90))
    check("0 行直接否掉", !LyricsCleaning.lineCountsCompatible(0, 40))

    // 文件头真写了总长时，才按比例对齐（KRC/QRC 才可能带）
    let headLyric = [LyricLine(timeMs: 0, text: "a"), LyricLine(timeMs: 190_000, text: "z")]
    // r74：老板口径「时间戳就是唯一依据」→ 一律不拉伸
    let scaled = LyricsCleaning.alignedToAudio(headLyric, declaredMs: 200_000, audioSec: 218)
    check("文件头 200s × 音源 218s 也不再拉伸（r74 去掉 ±12% 缩放）",
          scaled.ratio == 1, "\(scaled.ratio)")
    check("不拉伸时最后一行时间戳原样保留",
          scaled.lines.last?.timeMs == 190_000, "\(scaled.lines.last?.timeMs ?? 0)")
    check("偏差 >12% 不猜（更可能是另一首歌）",
          LyricsCleaning.alignedToAudio(headLyric, declaredMs: 200_000, audioSec: 240).ratio == 1)
    check("偏差 <3% 不动",
          LyricsCleaning.alignedToAudio(headLyric, declaredMs: 200_000, audioSec: 202).ratio == 1)
    check("音源时长未知 → 原样返回",
          LyricsCleaning.alignedToAudio(shortLyric, declaredMs: 200_000, audioSec: 0).ratio == 1)
    check("文件头总长与音源一致 → 不动",
          LyricsCleaning.alignedToAudio([LyricLine(timeMs: 0, text: "a")],
                                        declaredMs: 100_000, audioSec: 100).ratio == 1)
}

section("第五轮：下载把歌词和封面一起带走（老板反馈 ⑧ / 第四十轮补丁 3 分目录）")

do {
    // 第四十轮补丁 3（老板："歌曲 / 歌词 / 封面各放一个文件夹"）：
    // 音频在 `Download/Music`，旁车分别在 `Download/Lyrics`、`Download/Cover`，基名一致。
    let audio = URL(fileURLWithPath: "/m/Music/A - B [QQ_cyapi].m4a")
    let lyricsDir = URL(fileURLWithPath: "/m/Lyrics")
    let coverDir = URL(fileURLWithPath: "/m/Cover")
    let base = DownloadCompanion.baseName(for: audio)
    check("基名只去掉最后一段扩展名", base == "A - B [QQ_cyapi]", base)
    check("歌词旁车落在 Lyrics 目录、同基名 .lrc",
          DownloadCompanion.lyricsURL(in: lyricsDir, baseName: base).path
            == "/m/Lyrics/A - B [QQ_cyapi].lrc",
          DownloadCompanion.lyricsURL(in: lyricsDir, baseName: base).path)
    check("封面旁车落在 Cover 目录、同基名 .jpg",
          DownloadCompanion.coverURL(in: coverDir, baseName: base).path
            == "/m/Cover/A - B [QQ_cyapi].jpg",
          DownloadCompanion.coverURL(in: coverDir, baseName: base).path)
    check("多段扩展名只去掉最后一段",
          DownloadCompanion.baseName(for: URL(fileURLWithPath: "/m/x.y.z.mp3")) == "x.y.z")

    // LRC 文本：头部 + 行级时间（逐字不落 LRC），空行跳过
    let lrcLines = [LyricLine(timeMs: 0, text: "第一行"),
                    LyricLine(timeMs: 12_340, text: "第二行"),
                    LyricLine(timeMs: 61_000, text: "   ")]
    let lrc = DownloadCompanion.lrcText(from: lrcLines, title: "晴天",
                                        artist: "周杰伦", durationSec: 269)
    check("LRC 头部（ti/ar/al/length）",
          lrc.hasPrefix("[ti:晴天]\n[ar:周杰伦]\n[al:]\n[length:04:29]\n"), lrc.prefix(40).description)
    check("行级时间按百分秒写", lrc.contains("[00:12.34]第二行"), lrc)
    check("空文本行不写时间戳", !lrc.contains("[01:01.00]"))

    // 写旁车 → 读回来 → 删干净（真实文件 IO，用临时目录）
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("jz-companion-\(UUID().uuidString)", isDirectory: true)
    let musicDir = root.appendingPathComponent("Music", isDirectory: true)
    let lyrics = root.appendingPathComponent("Lyrics", isDirectory: true)
    let covers = root.appendingPathComponent("Cover", isDirectory: true)
    for dir in [musicDir, lyrics, covers] {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    let audioFile = musicDir.appendingPathComponent("A - B [QQ_cyapi].m4a")
    try? Data("fake-audio".utf8).write(to: audioFile)
    let coverBytes = Data([0xFF, 0xD8, 0xFF, 0x11, 0x22])
    let written = DownloadCompanion.writeSidecars(audio: audioFile, lyricsText: lrc,
                                                  coverData: coverBytes,
                                                  lyricsDirectory: lyrics,
                                                  coverDirectory: covers)
    check("旁车写成功（歌词 + 封面）",
          written.lyricsURL != nil && written.coverURL != nil)
    check("歌词写进 Lyrics 而不是音频旁边",
          written.lyricsURL?.deletingLastPathComponent().lastPathComponent == "Lyrics",
          written.lyricsURL?.path ?? "nil")
    check("封面写进 Cover 而不是音频旁边",
          written.coverURL?.deletingLastPathComponent().lastPathComponent == "Cover",
          written.coverURL?.path ?? "nil")
    check("音频目录里没有多出 .lrc/.jpg",
          !FileManager.default.fileExists(atPath:
            audioFile.deletingPathExtension().appendingPathExtension("lrc").path)
          && !FileManager.default.fileExists(atPath:
            audioFile.deletingPathExtension().appendingPathExtension("jpg").path))
    let readBack = DownloadCompanion.readLyrics(from: audioFile, in: [lyrics])
    check("读回 2 行（空行已被跳过）", readBack?.count == 2, "\(readBack?.count ?? -1)")
    check("读回的行时间对得上", readBack?.map { $0.timeMs } == [0, 12_340],
          "\(readBack?.map { $0.timeMs } ?? [])")
    check("读回封面字节一致", DownloadCompanion.readCover(from: audioFile, in: [covers]) == coverBytes)

    // 旧版布局（旁车与音频同目录）仍要能读回来，升级后老下载不能突然没词没图
    let legacyLrc = audioFile.deletingPathExtension().appendingPathExtension("lrc")
    try? Data(lrc.utf8).write(to: legacyLrc)
    check("旧版同目录旁车仍能读回",
          DownloadCompanion.readLyrics(from: audioFile, in: [])?.count == 2)

    DownloadCompanion.removeSidecars(audio: audioFile, lyricsDirectory: lyrics, coverDirectory: covers)
    check("删旁车后歌词/封面都读不到（新旧位置一起清）",
          DownloadCompanion.readLyrics(from: audioFile, in: [lyrics]) == nil
          && DownloadCompanion.readCover(from: audioFile, in: [covers]) == nil
          && !FileManager.default.fileExists(atPath: legacyLrc.path))

    check("不可写目录只返回 nil，不抛错",
          DownloadCompanion.writeSidecars(audio: URL(fileURLWithPath: "/no/such/dir/a.m4a"),
                                          lyricsText: lrc, coverData: coverBytes,
                                          lyricsDirectory: URL(fileURLWithPath: "/no/such/dir/Lyrics"),
                                          coverDirectory: URL(fileURLWithPath: "/no/such/dir/Cover")
          ).lyricsURL == nil)
    try? FileManager.default.removeItem(at: root)

    // ID3v2.4：mp3 内嵌（字节布局逐项钉住）
    func syncsafeValue(_ bytes: [UInt8]) -> Int {
        var value = 0
        for b in bytes.prefix(4) { value = (value << 7) | Int(b & 0x7F) }
        return value
    }
    func frameIDs(_ tag: [UInt8]) -> [String] {
        var ids: [String] = []
        var cursor = 10
        while cursor + 10 <= tag.count {
            ids.append(String(bytes: tag[cursor..<(cursor + 4)], encoding: .ascii) ?? "")
            let size = syncsafeValue(Array(tag[(cursor + 4)..<(cursor + 8)]))
            cursor += 10 + size
        }
        return ids
    }

    let tag = [UInt8](DownloadCompanion.id3Tag(title: "晴天", artist: "周杰伦", album: "叶惠美",
                                              coverData: coverBytes, coverMime: "IMAGE/JPEG",
                                              lyrics: "故事的小黄花"))
    check("ID3 头是 \"ID3\"", Array(tag.prefix(3)) == [0x49, 0x44, 0x33])
    check("ID3v2.4 + 无标志位", Array(tag[3..<6]) == [0x04, 0x00, 0x00])
    check("头部帧区长度 = 总长 − 10", syncsafeValue(Array(tag[6..<10])) == tag.count - 10,
          "\(syncsafeValue(Array(tag[6..<10]))) / \(tag.count - 10)")
    check("帧顺序 TIT2/TPE1/TALB/APIC/USLT",
          frameIDs(tag) == ["TIT2", "TPE1", "TALB", "APIC", "USLT"], "\(frameIDs(tag))")
    let tit2Payload = Array(tag[20..<20 + syncsafeValue(Array(tag[14..<18]))])
    check("TIT2 用 UTF-8 编码 + 标题",
          tit2Payload.first == 0x03
          && String(bytes: tit2Payload.dropFirst(), encoding: .utf8) == "晴天")
    check("空值跳帧：只给标题时只剩 TIT2 且总长 22",
          [UInt8](DownloadCompanion.id3Tag(title: "t", artist: "", album: "",
                                           coverData: nil, coverMime: "", lyrics: "")).count == 22
          && frameIDs([UInt8](DownloadCompanion.id3Tag(title: "t", artist: "", album: "",
                                                      coverData: nil, coverMime: "", lyrics: ""))) == ["TIT2"])
    check("全空 → 只有 10 字节头",
          [UInt8](DownloadCompanion.id3Tag(title: "", artist: "", album: "",
                                           coverData: nil, coverMime: "", lyrics: "")).count == 10)

    check("能内嵌的容器：m4a/mp3/MP4/.mp3",
          DownloadCompanion.canEmbed(extension: "m4a")
          && DownloadCompanion.canEmbed(extension: "mp3")
          && DownloadCompanion.canEmbed(extension: "MP4")
          && DownloadCompanion.canEmbed(extension: ".mp3"))
    check("只能写旁车的容器：flac/ogg/wav",
          !DownloadCompanion.canEmbed(extension: "flac")
          && !DownloadCompanion.canEmbed(extension: "ogg")
          && !DownloadCompanion.canEmbed(extension: "wav"))

    // 旧下载记录（downloads.json 没有 companionsNote 键）必须仍能解码
    let qili = song(.qq, "七里香", "周杰伦", dur: 299, id: "q777")
    let legacyItem = DownloadItem(song: qili, streamURL: "https://x", backendName: "b",
                                  quality: .high, status: .completed,
                                  companionsNote: "已内嵌歌词+封面")
    if let encoded = try? JSONEncoder().encode(legacyItem),
       var obj = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] {
        obj.removeValue(forKey: "companionsNote")
        if let legacyData = try? JSONSerialization.data(withJSONObject: obj),
           let decoded = try? JSONDecoder().decode(DownloadItem.self, from: legacyData) {
            check("旧 downloads.json 没有 companionsNote 也能解码",
                  decoded.companionsNote == nil && decoded.song.id == qili.id)
        } else {
            check("旧 downloads.json 能解码", false)
        }
    } else {
        check("DownloadItem 能编码", false)
    }

    try? FileManager.default.removeItem(at: root)
}

// MARK: - 第十二轮：单曲偏移 / 换曲先暂停 / 取词第二轮 / 酷狗第二条通道

section("单曲歌词偏移（r71：调一首不该推走别的歌）")
do {
    // 没有单曲覆盖值 → 用默认值
    check("默认值生效", LyricOffsetRules.effective(global: 220, perSong: [:], songID: "kugou_a") == 220)
    // 有覆盖值 → 覆盖值优先
    check("单曲覆盖值优先", LyricOffsetRules.effective(global: 0, perSong: ["kugou_a": -400],
                                                    songID: "kugou_a") == -400)
    // 别的歌不受影响（这就是老板说的"调一首，别的歌也被推走"）
    check("别的歌仍是默认值",
          LyricOffsetRules.effective(global: 0, perSong: ["kugou_a": -400], songID: "kugou_b") == 0)
    // 微调从"当前生效值"往上加，不是在默认值上加
    check("微调基于当前生效值",
          LyricOffsetRules.adjusted(global: 0, perSong: ["kugou_a": -400],
                                    songID: "kugou_a", byMs: 200) == -200)
    check("微调步进 200ms", LyricOffsetRules.stepMs == 200)
    // 夹在 ±2000
    check("上下限 ±2000",
          LyricOffsetRules.clamp(9999) == 2000 && LyricOffsetRules.clamp(-9999) == -2000
          && LyricOffsetRules.effective(global: 0, perSong: ["x": 5000], songID: "x") == 2000)
    // 单曲值 0 = "这首就是要对齐"（默认值非 0 时也照样生效）
    check("0 也是单曲值（归零要用它）",
          LyricOffsetRules.effective(global: 200, perSong: ["k": 0], songID: "k") == 0)
    check("没有单曲值时吃默认",
          LyricOffsetRules.effective(global: 200, perSong: ["k": 0], songID: "other") == 200)
}

section("换曲先暂停（r71）")
do {
    check("已装上播放项 → 换曲前暂停", PlaybackRules.shouldPauseBeforeSwitch(hasLoadedItem: true))
    check("没有播放项 → 不用暂停", !PlaybackRules.shouldPauseBeforeSwitch(hasLoadedItem: false))
}

section("取词口径（r72：只剩 LDDC 那一套）")
do {
    // 分数就是 LDDC 公式，**不额外扣版本/时长**——这两条是 r69 自造的，会把能用的歌压到线下
    let zunxiang = LddcMatch.score(title: "发如雪", candidateTitle: "发如雪（醇享版）",
                                   artist: "周杰伦", candidateArtist: "周杰伦")
    check("醇享版的标题分被 tag 拖低（不再靠自造的 −35 惩罚）",
          zunxiang < 100 && zunxiang > LddcMatch.minScore, "\(zunxiang)")
    let yuanban = LddcMatch.score(title: "发如雪", candidateTitle: "发如雪",
                                  artist: "周杰伦", candidateArtist: "周杰伦")
    check("原版 100 分，排第一", yuanban == 100)
    check("分数只由标题/歌手决定（同一对名字永远是同一个分）",
          LddcMatch.score(title: "晴天", candidateTitle: "晴天",
                          artist: "周杰伦", candidateArtist: "周杰伦") == 100)
    // 歌名自带版本标签时，同标签候选不吃亏
    let liveQuery = LddcMatch.score(title: "晴天 (Live)", candidateTitle: "晴天 (Live)",
                                    artist: "周杰伦", candidateArtist: "周杰伦")
    check("歌名带 Live 时同版本文本分仍满分", liveQuery == 100)
    // krcs 老接口的查询串（不带签名）：只是普通参数拼接 + 百分号编码
    let q = LddcLyrics.plainQuery([("ver", "1"), ("keyword", "发如雪 - 周杰伦")])
    check("krcs 查询串带百分号编码", q.hasPrefix("ver=1&keyword=") && !q.contains("发如雪")
          && !q.contains("signature"), q)
}

// MARK: - 第十五轮（r74）：身份闸、严格时间轴、8 秒超时

section("第十五轮：身份闸（歌手/版本类/词自报）/ 严格时间轴 / 8 秒超时")

do {
    // ① 版本类：原版 / Live / 翻唱 / 伴奏 / Remix / 其它非原版
    check("原版 → plain", LddcMatch.versionClass("七里香") == .plain)
    check("(Live) → live", LddcMatch.versionClass("七里香 (Live)") == .live)
    check("现场版 → live", LddcMatch.versionClass("七里香（现场版）") == .live)
    check("Cover → cover", LddcMatch.versionClass("晴天 (Cover)") == .cover)
    check("伴奏 → instrumental", LddcMatch.versionClass("晴天 - 伴奏") == .instrumental)
    check("(粤语版) → other（非原版）", LddcMatch.versionClass("发如雪 (粤语版)") == .other)
    check("拍摄花絮 → other", LddcMatch.versionClass("发如雪 拍摄花絮") == .other)

    // ② 身份闸：歌手 ≥90 + 版本类一致 + 时长 ≤4s
    let chang = LddcMatch.identityRejection(queryTitle: "发如雪", queryArtist: "周杰伦",
                                            candidateTitle: "发如雪", candidateArtist: "常颖杰",
                                            targetSec: 299, candidateSec: 299)
    check("同名不同人（常颖杰）→ 判废", chang != nil, chang ?? "nil")
    check("原版候选（周杰伦 299s）→ 通过",
          LddcMatch.identityRejection(queryTitle: "发如雪", queryArtist: "周杰伦",
                                      candidateTitle: "发如雪", candidateArtist: "周杰伦",
                                      targetSec: 299, candidateSec: 299) == nil)
    let liveForPlain = LddcMatch.identityRejection(queryTitle: "七里香", queryArtist: "周杰伦",
                                                   candidateTitle: "七里香 (Live)",
                                                   candidateArtist: "周杰伦",
                                                   targetSec: 299, candidateSec: 302)
    check("播原唱配 Live 词 → 判废", liveForPlain != nil, liveForPlain ?? "nil")
    check("播 Live 配 Live 词 → 通过",
          LddcMatch.identityRejection(queryTitle: "七里香 (Live)", queryArtist: "周杰伦",
                                      candidateTitle: "七里香 (Live)", candidateArtist: "周杰伦",
                                      targetSec: 302, candidateSec: 302) == nil)
    let longDelta = LddcMatch.identityRejection(queryTitle: "发如雪", queryArtist: "周杰伦",
                                                candidateTitle: "发如雪", candidateArtist: "周杰伦",
                                                targetSec: 299, candidateSec: 331)
    check("时长差 32s → 判废", longDelta != nil, longDelta ?? "nil")

    // ③ 用真实候选（2026-11-17 酷狗实测）跑 rank：只剩原版
    let real = [
        LddcLyrics.Candidate(source: "kg", title: "发如雪", artist: "周杰伦", durationSec: 299),
        LddcLyrics.Candidate(source: "kg", title: "发如雪", artist: "常颖杰", durationSec: 299),
        LddcLyrics.Candidate(source: "kg", title: "发如雪 (粤语版)", artist: "常颖杰", durationSec: 304),
        LddcLyrics.Candidate(source: "kg", title: "发如雪 (Live)", artist: "周杰伦", durationSec: 366),
        LddcLyrics.Candidate(source: "kg", title: "发如雪 (纯音乐)", artist: "周杰伦", durationSec: 322),
    ]
    let kept = LddcLyrics.rank(real, title: "发如雪", artist: "周杰伦", targetSec: 299)
    check("真实候选池里只剩原版一条", kept.count == 1, "\(kept.map(\.candidate.title))")
    check("留下的是周杰伦原版", kept.first?.candidate.artist == "周杰伦"
          && kept.first?.candidate.title == "发如雪")

    // ④ 词自报身份：KRC 头 / 首行
    let changMeta = LyricsMeta(title: "发如雪", artist: "常颖杰", album: "", durationMs: 0, offsetMs: 0)
    let changReport = LyricsCleaning.selfReportReason(meta: changMeta,
                                                      firstLine: "发如雪 (粤语版) - 常颖杰",
                                                      songTitle: "发如雪", songArtist: "周杰伦")
    check("词头 [ar:常颖杰] → 判废", changReport != nil, changReport ?? "nil")
    let okMeta = LyricsMeta(title: "发如雪", artist: "周杰伦", album: "十一月的萧邦",
                            durationMs: 0, offsetMs: 0)
    check("词头 [ti:发如雪][ar:周杰伦] → 通过",
          LyricsCleaning.selfReportReason(meta: okMeta, firstLine: "周杰伦 - 发如雪 词：方文山",
                                          songTitle: "发如雪", songArtist: "周杰伦") == nil)
    let liveMeta = LyricsMeta(title: "七里香 (Live)", artist: "周杰伦", album: "", durationMs: 0, offsetMs: 0)
    let liveReport = LyricsCleaning.selfReportReason(meta: liveMeta, firstLine: nil,
                                                     songTitle: "七里香", songArtist: "周杰伦")
    check("词头 [ti:七里香 (Live)] 配原唱 → 判废", liveReport != nil, liveReport ?? "nil")
    // 没有头部标签时看首行（酷我官方词就是这种）
    let noMeta = LyricsMeta()
    check("酷我式首行「七里香 - 周杰伦 (Jay Chou)」→ 通过",
          LyricsCleaning.selfReportReason(meta: noMeta, firstLine: "七里香 - 周杰伦 (Jay Chou)",
                                          songTitle: "七里香", songArtist: "周杰伦") == nil)
    let cantoneseLine = LyricsCleaning.selfReportReason(meta: noMeta,
                                                        firstLine: "发如雪 (粤语版) - 常颖杰",
                                                        songTitle: "发如雪", songArtist: "周杰伦")
    check("首行「发如雪 (粤语版) - 常颖杰」→ 判废", cantoneseLine != nil, cantoneseLine ?? "nil")
    // 括注处理：`七里香 (Live)` 的括注是关键版本词；`富士山下 (《爱情转移》粤语版)` 的括注是注记
    let fujiMeta = LyricsMeta(title: "富士山下 (《爱情转移》粤语版)", artist: "陈奕迅",
                              album: "", durationMs: 0, offsetMs: 0)
    check("词头括注是歌名注记 → 通过（不误杀富士山下）",
          LyricsCleaning.selfReportReason(meta: fujiMeta, firstLine: "富士山下 - 陈奕迅",
                                          songTitle: "富士山下", songArtist: "陈奕迅") == nil)
    let liveQueryMeta = LyricsMeta(title: "七里香 (Live)", artist: "周杰伦",
                                   album: "", durationMs: 0, offsetMs: 0)
    check("播 Live 时 [ti:七里香 (Live)] → 通过",
          LyricsCleaning.selfReportReason(meta: liveQueryMeta, firstLine: nil,
                                          songTitle: "七里香 (Live)", songArtist: "周杰伦") == nil)
    check("剥括注 coreTitle", LyricsCleaning.coreTitle("七里香 (Live)") == "七里香"
          && LyricsCleaning.coreTitle("富士山下 (《爱情转移》粤语版)") == "富士山下")

    check("首行是正文（狼牙月）→ 照常通过",
          LyricsCleaning.selfReportReason(meta: noMeta, firstLine: "狼牙月",
                                          songTitle: "发如雪", songArtist: "周杰伦") == nil)

    // ⑤ 8 秒硬超时：到点必须放弃，而不是继续等
    let slow = await LddcLyrics.withDeadline(seconds: 0.15) {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        return 42
    }
    check("超时到点放弃（1.5s 的活 / 0.15s 上限 → nil）", slow == nil)
    let fast = await LddcLyrics.withDeadline(seconds: 2) { 7 }
    check("没超时就拿到值", fast == 7)

    // ⑥ 逐句高亮打点（模拟时钟）：高亮时刻 = 该句时间戳，偏差 ≤ 40ms（远小于 0.3s 验收线）
    //
    // 老板口径：LRC 中括号里的时间戳就是该句出现的时刻。这里用 40ms 的 ticker（播放器实际频率）
    // 扫一遍，记录每句第一次亮起的时刻，与句首时间戳对比。
    let lines = [
        LyricLine(timeMs: 22_020, text: "狼牙月"),
        LyricLine(timeMs: 24_180, text: "伊人憔悴"),
        LyricLine(timeMs: 26_150, text: "我举杯"),
        LyricLine(timeMs: 70_140, text: "你发如雪"),
        LyricLine(timeMs: 121_110, text: "狼牙月（二段）"),
    ]
    var firstLit = [Int](repeating: -1, count: lines.count)
    var t = 0
    let end = 130_000
    while t <= end {
        let idx = LyricsCleaning.indexAt(lines, positionMs: t)
        if idx >= 0, firstLit[idx] < 0 { firstLit[idx] = t }
        t += 40
    }
    var worst = 0
    for (i, line) in lines.enumerated() {
        let dev = abs(firstLit[i] - line.timeMs)
        worst = max(worst, dev)
        check("第 \(i + 1) 句高亮偏差 \(dev)ms ≤ 300ms",
              firstLit[i] >= line.timeMs && dev <= 300,
              "lineMs=\(line.timeMs) litAt=\(firstLit[i])")
    }
    check("最坏偏差 ≤ 40ms（ticker 粒度）", worst <= 40, "\(worst)")
}

// MARK: - 第十六轮（r77）：seek 保护窗 / 取词链预算

section("第十六轮：seek 撞上旧位置不许改高亮 / 取词链各档预算")

do {
    // ① 老板 r85（9 分钟录屏）：位置 0:49 时歌词高亮显示的是 1:36 那一行（《黄昏》51 行 · 酷我）。
    //    实锤了旧口径的问题：`seek` 的完成回调**提前返回**（回调说完成了，但 `currentTime()` 还是旧值），
    //    旧实现一看到回调就解保护，40ms 的 ticker 立刻拿**旧位置**重算高亮 → 直接跳到几十秒外那一行，
    //    而且会一直错到播放头追上那一行为止。
    //
    //    新口径：seek 之后有 1.5 秒"乐观窗口"，窗口内用**目标位置**推歌词；播放头落在目标
    //    ±1.2 秒内（真落地）或窗口到期，才切回真实位置。**任何时刻都给出一个位置，绝不 return 冻住。**
    check("播放头还报旧位置（45s）且窗口未到期 → 用目标位置（不再拿旧位置算）",
          LyricsUXRules.seekClockSource(positionMs: 45_000, targetMs: 120_000,
                                        optimisticExpired: false) == .useTarget)
    check("播放头已落到目标附近（差 200ms）→ 用真实位置",
          LyricsUXRules.seekClockSource(positionMs: 119_800, targetMs: 120_000,
                                        optimisticExpired: false) == .usePosition)
    check("窗口到期、位置还是旧的 → 也必须切回真实位置（宁可跳一下，绝不冻住 10 秒）",
          LyricsUXRules.seekClockSource(positionMs: 45_000, targetMs: 120_000,
                                        optimisticExpired: true) == .usePosition)
    check("落地容差边界（1.2 秒整）→ 用真实位置",
          LyricsUXRules.seekClockSource(positionMs: 120_000 - LyricsUXRules.seekLandToleranceMs,
                                        targetMs: 120_000,
                                        optimisticExpired: false) == .usePosition)
    check("乐观窗口 8 秒：真机 seek 落地常要 2~4 秒，窗口太短会先跳到错误一行再弹回来",
          LyricsUXRules.seekOptimisticMaxSeconds == 8.0)
    check("落地容差 1.2 秒", LyricsUXRules.seekLandToleranceMs == 1200)

    // ② 取词链预算：单条酷狗通道 3 秒、酷狗整段 4.5 秒——必须给 ③④ 留出时间，
    //    否则"网易云明明有词却显示没词"（老板截图里那首《你好，再见》就是这条）。
    check("单条酷狗通道封顶 3.5 秒（内部还含 https→http 两试）",
          LddcLyrics.kgChannelDeadline == 3.5, "\(LddcLyrics.kgChannelDeadline)")
    check("单个酷狗请求只给 2.5 秒", LddcLyrics.kgAttemptTimeout == 2.5,
          "\(LddcLyrics.kgAttemptTimeout)")
    check("只有快速失败（<1.2s）才换 http 再试", LddcLyrics.kgFastFailureSeconds == 1.2,
          "\(LddcLyrics.kgFastFailureSeconds)")
    check("酷狗搜索只给 3 秒", LddcLyrics.kgSearchTimeout == 3,
          "\(LddcLyrics.kgSearchTimeout)")
    check("酷狗在整条链里只占 5.5 秒", LddcLyrics.chainBudgetSeconds == 5.5,
          "\(LddcLyrics.chainBudgetSeconds)")
    check("酷狗预算之后还给 ③④ 留 2 秒以上",
          8 - LddcLyrics.chainBudgetSeconds >= 2,
          "\(8 - LddcLyrics.chainBudgetSeconds)")
}

// MARK: - 第十七轮（r78）：酷狗 krcs 通道的身份闸 / 空态分类

section("第十七轮：krcs 通道不许把「同名不同人」的词贴上来")

do {
    // 实锤：《你好，再见 / 常力俊 / 244s》在酷狗只有一条《你好再见 / Butter / 244s》，
    // 那份 KRC 词头明写 `[ti:你好再见][ar:Butter]`，词是另一首歌。
    let ts = LddcMatch.titleScore("你好，再见", "你好再见")
    let as_ = LddcMatch.artistScore("常力俊", "Butter")
    check("标题 80~95 分（标点不敏感但不满分）", ts >= 80 && ts < 95, "\(ts)")
    check("歌手 0 分（Butter 不是常力俊）", as_ == 0, "\(as_)")
    check("旧口径 44.4 < 50：这一首本来就会被挡掉（差一点就贴错）",
          ts * 0.5 + as_ * 0.5 < 50, "\(ts * 0.5 + as_ * 0.5)")
    check("新口径（歌手 ≥ artistGateScore）挡得住", as_ < LddcMatch.artistGateScore,
          "\(as_) < \(LddcMatch.artistGateScore)")
    check("身份闸本身也拒收",
          LddcMatch.identityRejection(queryTitle: "你好，再见", queryArtist: "常力俊",
                                      candidateTitle: "你好再见", candidateArtist: "Butter",
                                      targetSec: 244, candidateSec: 244) != nil)

    // 空态分类：老板看到的文案要能分清"没有原唱词"和"我们没取到"
    check("MissKind.none 是空串", LddcLyrics.MissKind.none.rawValue.isEmpty)
    check("rejectedIdentity 文案写明「只有别的版本」",
          LddcLyrics.MissKind.rejectedIdentity.rawValue.contains("别的版本"),
          LddcLyrics.MissKind.rejectedIdentity.rawValue)
    check("fetchFailed 文案写明「没返回」",
          LddcLyrics.MissKind.fetchFailed.rawValue.contains("没返回"),
          LddcLyrics.MissKind.fetchFailed.rawValue)
}

// MARK: - 第十八轮（r79）：发现页榜单模块（酷我 bang/list + ksong.s）

section("榜单歌曲解析（酷我官方榜）")

// 真响应裁成三条：一条完整的、一条数字型字段 + 空歌手、一条缺 rid（必须被丢掉）。
// 其中第一条特意让 `duration`(4) 与 `song_duration`(189) 不一致——这就是线上真实形态，
// 断言钉死"取 song_duration"，否则时长闸门会拿 4s 当期望值，把真歌全判成坏源。
let chartFixture: [String: Any] = [
    "name": "酷我热歌榜",
    "pub": "2026-11-17",
    "num": "100",
    "musiclist": [
        [
            "id": "668801544",
            "name": "慌啥子嘛 (赵本山版)",
            "artist": "赵本山",
            "album": "慌啥子嘛（赵本山版）",
            "duration": "4",
            "song_duration": "189",
            "score100": "89"
        ],
        [
            "id": 669608403,
            "name": "阴天也会有烦恼吗",
            "artist": "",
            "album": "",
            "duration": 272
        ],
        [
            "name": "没有 rid 的歌",
            "artist": "某人"
        ]
    ] as [[String: Any]]
]

if let chart = KuwoChart.parsePage(chartFixture) {
    check("榜名取接口给的", chart.name == "酷我热歌榜", chart.name)
    check("更新日期取 pub", chart.publishedDate == "2026-11-17", chart.publishedDate)
    check("缺 rid 的那条被丢掉", chart.songs.count == 2, "\(chart.songs.count)")
    check("曲长取 song_duration 而不是 duration", chart.songs.first?.durationSec == 189,
          "\(String(describing: chart.songs.first?.durationSec))")
    check("rid 进 platformID", chart.songs.first?.platformID == "668801544",
          chart.songs.first?.platformID ?? "nil")
    check("榜单曲没有封面字段 → 交给封面链兜底", chart.songs.first?.picURL == nil)
    check("数字型 id / duration 也能解",
          chart.songs.last?.platformID == "669608403" && chart.songs.last?.durationSec == 272,
          "\(String(describing: chart.songs.last?.platformID)) / \(String(describing: chart.songs.last?.durationSec))")
    check("空歌手不报错", chart.songs.last?.singer == "", chart.songs.last?.singer ?? "nil")
} else {
    check("榜单解析", false, "parsePage 返回 nil")
}

check("空 musiclist 判失败（不显示一个 0 首的“正常”页）",
      KuwoChart.parsePage(["name": "空榜", "musiclist": []]) == nil)
check("两级 id 都留着：web 489927 / mobile 16",
      KuwoChart.Chart.hot.webId == "489927" && KuwoChart.Chart.hot.mobileId == "16",
      "\(KuwoChart.Chart.hot.webId)/\(KuwoChart.Chart.hot.mobileId)")

// MARK: - 第二十九轮（r96）：发现页「最新单曲」（酷我歌单 playListInfo）

section("最新单曲：酷我歌单解析 / 排序 / 日期缓存")

// 真响应裁成五条（2026-11-18 实测字段名）：
//   · 第 2 条 `duration`=4 但 `songTimeMinutes`=03:09 —— 就是 ksong.s 里踩过的那种脏值，
//     解析必须认 mm:ss（189s），否则播放侧的 ±25s 时长闸门会把真歌全判成坏源；
//   · 第 3 条与第 1 条同 rid（接口脏数据）→ 只留第一次出现；
//   · 第 4 条 rid=0 → 丢掉；
//   · 第 5 条没有 releaseDate → 排最后，但仍然保留（新歌单里偶有缺日期的老条目）。
let newSongsFixture: [String: Any] = [
    "code": 200,
    "data": [
        "name": "每日最新单曲推荐",
        "total": "653",
        "musicList": [
            [
                "rid": 670149467,
                "name": "涌泉相报",
                "artist": "刘惜君",
                "album": "涌泉相报",
                "duration": 267,
                "songTimeMinutes": "04:27",
                "pic": "https://img4.kuwo.cn/star/albumcover/500/s4s43/68/2072169166.jpg",
                "releaseDate": "2026-11-18"
            ],
            [
                "rid": "670146452",
                "name": "宝珠",
                "artist": "李佳薇",
                "album": "",
                "duration": "4",
                "songTimeMinutes": "03:09",
                "pic": "https://img4.kuwo.cn/a.jpg",
                "releaseDate": "2026-11-17"
            ],
            [
                "rid": 670149467,
                "name": "涌泉相报（重复条目）",
                "artist": "刘惜君",
                "album": "涌泉相报",
                "duration": 267,
                "releaseDate": "2026-11-18"
            ],
            [
                "rid": 0,
                "name": "没有身份证的歌",
                "artist": "某人",
                "duration": 200,
                "releaseDate": "2026-11-16"
            ],
            [
                "rid": 668382564,
                "name": "Pixel Slide (Carousel)",
                "artist": "云顶之弈",
                "album": "Pixel Slide",
                "duration": 52,
                "releaseDate": ""
            ]
        ] as [[String: Any]]
    ] as [String: Any]
]

if let releases = KuwoPlaylist.parse(newSongsFixture) {
    check("解析出 3 条（重复 rid / rid=0 被丢掉）", releases.count == 3, "\(releases.count)")
    check("按发行日倒序（11-18 → 11-17 → 无日期最后）",
          releases.map(\.releaseDate) == ["2026-11-18", "2026-11-17", ""],
          "\(releases.map(\.releaseDate))")
    check("rid 进 platformID、平台是酷我",
          releases.first?.song.platformID == "670149467" && releases.first?.song.platform == .kuwo,
          "\(String(describing: releases.first?.song.platformID))")
    check("曲长认 mm:ss（duration=4 的脏值被 03:09 盖掉）",
          releases.first(where: { $0.song.platformID == "670146452" })?.song.durationSec == 189,
          "\(String(describing: releases.first(where: { $0.song.platformID == "670146452" })?.song.durationSec))")
    check("曲长正常时保持秒数", releases.first?.song.durationSec == 267,
          "\(String(describing: releases.first?.song.durationSec))")
    check("封面取 pic（https）",
          releases.first?.song.picURL == "https://img4.kuwo.cn/star/albumcover/500/s4s43/68/2072169166.jpg")
    check("收录于《专辑》有专辑就写、空专辑不写",
          releases.first?.albumLine == "收录于《涌泉相报》"
            && releases.first(where: { $0.song.platformID == "670146452" })?.albumLine == "",
          "\(String(describing: releases.first?.albumLine))")
    check("短日期 2026-11-18 → 11-18", releases.first?.shortDate == "11-18",
          releases.first?.shortDate ?? "nil")
    check("无日期的条目排在最后", releases.last?.releaseDate == "",
          "\(String(describing: releases.last?.releaseDate))")
} else {
    check("最新单曲解析", false, "parse 返回 nil")
}

check("空 musicList 判失败", KuwoPlaylist.parse(["code": 200, "data": ["musicList": []]]) == nil)
check("code 非 200 判失败",
      KuwoPlaylist.parse(["code": 500, "data": ["musicList": [["rid": 1, "name": "x"]]]]) == nil)
check("请求串带 pid / pn / rn",
      KuwoPlaylist.url(pid: "1082685104").contains("pid=1082685104")
        && KuwoPlaylist.url(pid: "1082685104").contains("pn=0")
        && KuwoPlaylist.url(pid: "1082685104").contains("rn=100"),
      KuwoPlaylist.url(pid: "1082685104"))
check("模块只露 12 张卡，整页是一页 100 首", KuwoPlaylist.moduleCards == 12,
      "\(KuwoPlaylist.moduleCards)")

do {
    // 当天缓存：同一天命中、隔天失效（老板："加载一次当天不再加载，除非第二天刷新"）
    let testPlaylist = KuwoPlaylist.Playlist(pid: "selftest_new_songs", name: "测试歌单")
    let releases = KuwoPlaylist.parse(newSongsFixture) ?? []
    KuwoPlaylist.save(releases, for: testPlaylist, day: 20_000)
    check("当天缓存命中", KuwoPlaylist.cached(testPlaylist, day: 20_000)?.count == releases.count,
          "\(String(describing: KuwoPlaylist.cached(testPlaylist, day: 20_000)?.count))")
    check("隔天缓存失效", KuwoPlaylist.cached(testPlaylist, day: 20_001) == nil)
    check("不问日期时任何一天的缓存都能先铺界面",
          KuwoPlaylist.cachedAnyDay(testPlaylist)?.count == releases.count)
    UserDefaults.standard.removeObject(forKey: "kw_playlist_cache_v1_selftest_new_songs")
}

// MARK: - 第三十轮（r97）：歌单广场 + 歌手大全

section("歌单广场：列表 / 详情 / 数字缩写 / 当天缓存")

let squareFixture: [String: Any] = [
    "code": 200,
    "data": [
        "total": "1754",
        "data": [
            [
                "id": 3678617986,
                "name": "古风戏腔丨一曲舞霓裳清影醉红颜",
                "img": "http://img1.kuwo.cn/star/userpl2015/40/22/a.jpg",
                "uname": "给票认真画",
                "total": "104",
                "listencnt": "912116"
            ],
            [
                "id": "3575766446",
                "name": "短视频DJ热门歌曲｜网红BGM",
                "img": "https://img1.kuwo.cn/star/userpl2015/25/94/b.jpg",
                "uname": "诗情画意",
                "total": "41",
                "listencnt": 4743590
            ],
            [
                "name": "没有 id 的那条"
            ]
        ] as [[String: Any]]
    ] as [String: Any]
]

if let page = KuwoPlaylist.parseSquare(squareFixture) {
    check("广场一页解析出 2 张（缺 id 的被丢掉）", page.items.count == 2, "\(page.items.count)")
    check("广场 total 取接口给的 1754", page.total == 1754, "\(page.total)")
    check("歌单 id 转字符串", page.items.first?.id == "3678617986",
          page.items.first?.id ?? "nil")
    check("歌单封面 http 升 https", page.items.first?.cover == "https://img1.kuwo.cn/star/userpl2015/40/22/a.jpg",
          page.items.first?.cover ?? "nil")
    check("创建者 / 首数 / 播放量都取对",
          page.items.first?.creator == "给票认真画"
            && page.items.first?.songCount == 104
            && page.items.first?.playCount == 912116,
          "\(String(describing: page.items.first))")
    check("数字型 listencnt 也能解", page.items.last?.playCount == 4743590,
          "\(String(describing: page.items.last?.playCount))")
} else {
    check("歌单广场解析", false, "parseSquare 返回 nil")
}

check("广场空列表判失败", KuwoPlaylist.parseSquare(["code": 200, "data": ["data": []]]) == nil)
check("广场请求串带 order 与 pn",
      KuwoPlaylist.squareURL(sort: .hot, page: 2).contains("order=hot")
        && KuwoPlaylist.squareURL(sort: .hot, page: 2).contains("pn=2")
        && KuwoPlaylist.squareURL(sort: .new).contains("order=new"),
      KuwoPlaylist.squareURL(sort: .new))

let detailFixture: [String: Any] = [
    "code": 200,
    "data": [
        "id": "3678617986",
        "name": "古风戏腔丨一曲舞霓裳清影醉红颜",
        "img": "https://img1.kuwo.cn/star/userpl2015/40/22/a.jpg",
        "uname": "kw2427722717",
        "userName": "给票认真画",
        "total": "104",
        "listencnt": "912116",
        "musicList": [
            ["rid": 228908, "name": "牵丝戏", "artist": "银临&Aki阿杰", "album": "牵丝戏",
             "duration": 239, "pic": "https://img4.kuwo.cn/a.jpg", "releaseDate": "2015-01-01"],
            ["rid": 670146452, "name": "唐人恋曲", "artist": "小唐人", "album": "唐人恋曲",
             "duration": 212, "pic": "https://img4.kuwo.cn/b.jpg", "releaseDate": "2020-08-18"]
        ] as [[String: Any]]
    ] as [String: Any]
]

if let detail = KuwoPlaylist.parseDetail(detailFixture) {
    check("详情带 2 首", detail.releases.count == 2, "\(detail.releases.count)")
    check("详情创建者取 userName（不是登录名 kw 开头）",
          detail.summary.creator == "给票认真画", detail.summary.creator)
    check("详情保持歌单原顺序（不按发行日重排）",
          detail.releases.map(\.song.name) == ["牵丝戏", "唐人恋曲"],
          "\(detail.releases.map(\.song.name))")
    check("详情 meta 取总首数与播放量",
          detail.summary.songCount == 104 && detail.summary.playCount == 912116,
          "\(detail.summary.songCount)/\(detail.summary.playCount)")
} else {
    check("歌单详情解析", false, "parseDetail 返回 nil")
}

check("数字缩写：不足一万原样", CountFormat.short(8849) == "8849", CountFormat.short(8849))
check("数字缩写：万", CountFormat.short(912116) == "91.2万", CountFormat.short(912116))
check("数字缩写：整万去掉 .0", CountFormat.short(47435) == "4.7万" && CountFormat.short(10000) == "1万",
      "\(CountFormat.short(47435))/\(CountFormat.short(10000))")
check("数字缩写：亿", CountFormat.short(106793500) == "1.1亿", CountFormat.short(106793500))
check("数字缩写：0", CountFormat.short(0) == "0", CountFormat.short(0))

do {
    let page = KuwoPlaylist.parseSquare(squareFixture) ?? KuwoPlaylist.SquarePage(total: 0, items: [])
    KuwoPlaylist.saveSquare(page, sort: .hot, day: 20_000)
    check("广场当天缓存命中", KuwoPlaylist.cachedSquare(.hot, day: 20_000)?.items.count == page.items.count)
    check("广场隔天缓存失效", KuwoPlaylist.cachedSquare(.hot, day: 20_001) == nil)
    KuwoPlaylist.storeNewestID("3678617986")
    check("最新歌单 id 记下来了", KuwoPlaylist.storedNewestID() == "3678617986")
    UserDefaults.standard.removeObject(forKey: "kw_square_v1_hot")
    UserDefaults.standard.removeObject(forKey: "kw_square_newest_id_v1")
}

section("歌手大全：列表 / 歌曲 / 分类 / 当天缓存")

let artistFixture: [String: Any] = [
    "code": 200,
    "data": [
        "total": "8849",
        "artistList": [
            ["id": 336, "name": "周杰伦", "aartist": "Jay Chou",
             "pic300": "http://img1.kuwo.cn/star/starheads/300/a.jpg",
             "artistFans": 1664361, "musicNum": 1707, "albumNum": 45],
            ["id": "5371", "name": "G.E.M.邓紫棋", "pic120": "https://img4.kuwo.cn/star/starheads/120/b.jpg",
             "artistFans": "957941", "musicNum": 958, "albumNum": 20],
            ["name": "没有 id 的歌手"]
        ] as [[String: Any]]
    ] as [String: Any]
]

if let page = KuwoArtist.parseDirectory(artistFixture) {
    check("歌手一页解析出 2 位（缺 id 的丢掉）", page.items.count == 2, "\(page.items.count)")
    check("歌手 total 8849", page.total == 8849, "\(page.total)")
    check("歌手 id 转字符串", page.items.first?.id == "336", page.items.first?.id ?? "nil")
    check("歌手外文名取 aartist", page.items.first?.alias == "Jay Chou", page.items.first?.alias ?? "nil")
    check("歌手头像 http 升 https",
          page.items.first?.picURL == "https://img1.kuwo.cn/star/starheads/300/a.jpg",
          page.items.first?.picURL ?? "nil")
    check("粉丝 / 歌曲数 / 专辑数", page.items.first?.fans == 1664361
            && page.items.first?.songCount == 1707 && page.items.first?.albumCount == 45,
          "\(String(describing: page.items.first))")
    check("缺图用首字占位", page.items.first?.initial == "周" && page.items.last?.initial == "G",
          "\(page.items.map(\.initial))")
} else {
    check("歌手列表解析", false, "parseDirectory 返回 nil")
}

let artistSongsFixture: [String: Any] = [
    "code": 200,
    "data": [
        "total": "1707",
        "list": [
            ["rid": 228908, "name": "晴天", "artist": "周杰伦", "album": "叶惠美",
             "duration": 269, "songTimeMinutes": "04:29",
             "pic": "https://img4.kuwo.cn/a.jpg", "releasedate": "2003-07-31"],
            ["rid": 440613, "name": "稻香", "artist": "周杰伦", "album": "魔杰座",
             "duration": 223, "pic": "https://img4.kuwo.cn/b.jpg"]
        ] as [[String: Any]]
    ] as [String: Any]
]

if let songs = KuwoArtist.parseSongs(artistSongsFixture) {
    check("歌手歌曲解析出 2 首", songs.count == 2, "\(songs.count)")
    check("歌手歌曲的 releasedate（全小写）也认",
          songs.first?.releaseDate == "2003-07-31", songs.first?.releaseDate ?? "nil")
    check("歌手歌曲时长取对", songs.first?.song.durationSec == 269,
          "\(String(describing: songs.first?.song.durationSec))")
    check("歌手歌曲 rid 进 platformID", songs.first?.song.platformID == "228908")
} else {
    check("歌手歌曲解析", false, "parseSongs 返回 nil")
}

check("歌手分类 id 与实测一致",
      KuwoArtist.categories.map(\.id) == [0, 11, 13, 12, 4, 5, 6],
      "\(KuwoArtist.categories.map(\.id))")
check("字母条：热门 + A–Z", KuwoArtist.letters.count == 27 && KuwoArtist.letters.first == "热门",
      "\(KuwoArtist.letters.count)")

do {
    let page = KuwoArtist.parseDirectory(artistFixture)
        ?? KuwoArtist.Page(total: 0, items: [])
    KuwoArtist.save(page, category: 999, day: 20_000)
    check("歌手当天缓存命中", KuwoArtist.cached(category: 999, day: 20_000)?.items.count == page.items.count)
    check("歌手隔天缓存失效", KuwoArtist.cached(category: 999, day: 20_001) == nil)
    UserDefaults.standard.removeObject(forKey: "kw_artists_v1_999")
}

section("酷我封面（rid_pic 同平台兜底）")

check("http 升 https，且 kwcdn 换成 kuwo.cn",
      CoverResolver.ridPicURL(fromBody: "http://img1.kwcdn.kuwo.cn/star/albumcover/320/s3s94/93/211513640.jpg")
        == "https://img1.kuwo.cn/star/albumcover/320/s3s94/93/211513640.jpg",
      CoverResolver.ridPicURL(fromBody: "http://img1.kwcdn.kuwo.cn/star/albumcover/320/s3s94/93/211513640.jpg") ?? "nil")
check("已经是 https 的原样保留",
      CoverResolver.ridPicURL(fromBody: "https://img4.kuwo.cn/star/albumcover/320/a/b/1.jpg")
        == "https://img4.kuwo.cn/star/albumcover/320/a/b/1.jpg")
check("歌手头像不算专辑封面（宁可没图也别贴错）",
      CoverResolver.ridPicURL(fromBody: "http://img1.kuwo.cn/star/starheads/320/s4s56/58/291211030.jpg") == nil)
check("不是 URL 就不猜",
      CoverResolver.ridPicURL(fromBody: "") == nil
        && CoverResolver.ridPicURL(fromBody: "{\"code\":500}") == nil)
check("前后空行只取第一行",
      CoverResolver.ridPicURL(fromBody: "\n\nhttps://img1.kuwo.cn/a.jpg\n\n") == "https://img1.kuwo.cn/a.jpg")

let kuwoRidSong = song(.kuwo, "晴天", "周杰伦", id: "228908")
check("酷我数字 rid 才走 rid_pic", CoverResolver.kuwoRid(kuwoRidSong) == "228908")
check("非数字 platformID 不当 rid",
      CoverResolver.kuwoRid(song(.kuwo, "晴天", "周杰伦", id: "abc")) == nil)
check("别的平台不走 rid_pic",
      CoverResolver.kuwoRid(song(.qq, "晴天", "周杰伦", id: "228908")) == nil)

// MARK: - 第二十轮：热门音乐改成「榜单优先、搜索兜底」

section("热门音乐：榜单优先 / 搜索兜底")

// 25 首假榜（名次就是数组顺序），验证模块只取前 21 且**不重排**
let chartPool25 = (0..<25).map { song(.kuwo, "曲\($0)", "歌手", id: "\($0)") }
let hotModule = DiscoverRules.hotModuleSongs(chartPool25)
check("热门模块页数不变：只取前 21 首", hotModule?.count == DiscoverRules.hotModuleLimit,
      "\(hotModule?.count ?? -1) / \(DiscoverRules.hotModuleLimit)")
check("热门模块保持官方名次顺序（不重排、不筛原版）",
      hotModule?.first?.platformID == "0" && hotModule?.last?.platformID == "20",
      "\(hotModule?.first?.platformID ?? "nil")…\(hotModule?.last?.platformID ?? "nil")")
check("不足 21 首时全量返回",
      DiscoverRules.hotModuleSongs(Array(chartPool25.prefix(5)))?.count == 5)
check("空榜返回 nil → 调用方走种子词兜底（不显示空页）",
      DiscoverRules.hotModuleSongs([]) == nil)

// MARK: - 第二十一轮：点歌词跳转的定位 / 打开即用的缓存口径

section("歌词：点歌词跳转后的「等它唱到」窗口")

// 真机现象（老板反复提）：点歌词跳过去，高亮和滚动闪一下又退回上一句，从此不对。
// 根因：seek 常落到目标之前几百毫秒，而 indexAt 的口径是「行时间 ≤ 位置」——早 1ms 就推成上一句。
let holdTolerance = LyricsUXRules.lyricSeekHoldToleranceMs
check("落点比目标早 300ms：继续钉住被点的那一行",
      LyricsCleaning.lyricSeekHoldDecision(positionMs: 9_700, lineMs: 10_000,
                                           toleranceMs: holdTolerance) == .hold)
check("正好唱到这一行：交还正常推导",
      LyricsCleaning.lyricSeekHoldDecision(positionMs: 10_000, lineMs: 10_000,
                                           toleranceMs: holdTolerance) == .release)
check("已经唱过去了：交还正常推导",
      LyricsCleaning.lyricSeekHoldDecision(positionMs: 10_400, lineMs: 10_000,
                                           toleranceMs: holdTolerance) == .release)
check("落点早 4 秒（超出容差，多半是拖了进度条）：不钉住，跟音频走",
      LyricsCleaning.lyricSeekHoldDecision(positionMs: 6_000, lineMs: 10_000,
                                           toleranceMs: holdTolerance) == .release)
check("容差边界：刚好等于容差仍算 hold",
      LyricsCleaning.lyricSeekHoldDecision(positionMs: 10_000 - holdTolerance, lineMs: 10_000,
                                           toleranceMs: holdTolerance) == .hold)

section("打开即用：缓存口径")

check("猜你喜欢指纹只看最近播放前 3 首",
      DiscoverRules.guessSignature([
        song(.kuwo, "A", "x", id: "a"), song(.qq, "B", "y", id: "b"),
        song(.netease, "C", "z", id: "c"), song(.kugou, "D", "w", id: "d")
      ]) == "kuwo_a,qq_b,netease_c",
      DiscoverRules.guessSignature([
        song(.kuwo, "A", "x", id: "a"), song(.qq, "B", "y", id: "b"),
        song(.netease, "C", "z", id: "c"), song(.kugou, "D", "w", id: "d")
      ]))
check("没有最近播放时指纹为空", DiscoverRules.guessSignature([]) == "")

let cacheChart = KuwoChart.Chart(webId: "1", mobileId: "99999", name: "测试榜")
let cachePage = KuwoChart.Page(name: "测试榜", publishedDate: "2026-11-18",
                               songs: [song(.kuwo, "晴天", "周杰伦", id: "228908")])
KuwoChart.save(cachePage, for: cacheChart, day: 20_000)
check("缓存能读回（不按我们这边的日期判断）",
      KuwoChart.cachedPageAnyDay(cacheChart)?.songs.count == 1)
check("服务端 pub 没变 → 命中缓存，不重取整页",
      KuwoChart.cachedPage(cacheChart, publishedDate: "2026-11-18") != nil)
check("服务端 pub 变了 → 视为未命中，要重取",
      KuwoChart.cachedPage(cacheChart, publishedDate: "2026-11-19") == nil)

section("第二十四轮：本地日 / 播放页时钟")

// ① "今天"必须按本地日历天切（老板 11-18：白天还显示前一天缓存，因为旧实现用 UTC 日，
//    澳大利亚 UTC+10:30 要到本地上午 ~10:30 才翻页）
let utcDay = Int(Date().timeIntervalSince1970 / 86_400)
check("本地日与 UTC 日最多差 1 天（跨时区不会错很久）",
      abs(DiscoverRules.today - utcDay) <= 1, "\(DiscoverRules.today) vs \(utcDay)")
check("同一天内两次取值一致（不会因为时刻不同跳变）",
      DiscoverRules.today == DiscoverRules.today)

section("第二十七轮：封面兜底（iTunes 公共兜底 + 坏地址拉黑）")

// iTunes Search：无需 key、https，作为 QQ 严格匹配之后的最后一级
let itunesURL = ITunesCover.searchURL(title: "青花瓷", artist: "周杰伦")
check("iTunes 搜索 URL 走 https 且带 entity=song",
      itunesURL.hasPrefix("https://itunes.apple.com/search?") && itunesURL.contains("entity=song"),
      itunesURL)
check("歌名/歌手里的空格与 & 被正确编码",
      !ITunesCover.searchURL(title: "A & B", artist: "C D").contains("A & B"))
check("artwork 100x100bb → 600x600bb",
      ITunesCover.largeArtwork("https://is1-ssl.mzstatic.com/image/thumb/x/100x100bb.jpg")
        == "https://is1-ssl.mzstatic.com/image/thumb/x/600x600bb.jpg")
check("artwork 100x100 → 600x600（无 bb 后缀）",
      ITunesCover.largeArtwork("https://a/b/100x100.jpg") == "https://a/b/600x600.jpg")
check("http 的 artwork 升 https",
      ITunesCover.largeArtwork("http://a/b/100x100bb.jpg") == "https://a/b/600x600bb.jpg")
check("不是 URL 就不认", ITunesCover.largeArtwork("not-a-url") == nil)

// 严格匹配：iTunes 对华语歌相关性很差（搜"青花瓷 周杰伦"首条是《屋顶》），
// 只认歌名核心名 + 歌手片段都对得上的，宁可不给图。
let itunesPayload: [String: Any] = ["results": [
    ["trackName": "屋顶", "artistName": "Landy Wen & Jay Chou", "artworkUrl100": "https://is1.mzstatic.com/wrong/100x100bb.jpg"],
    ["trackName": "青花瓷", "artistName": "周杰伦", "artworkUrl100": "https://is1.mzstatic.com/right/100x100bb.jpg"]
]]
check("跳过名字不符的（屋顶不能当青花瓷的封面）",
      ITunesCover.parse(itunesPayload, title: "青花瓷", artist: "周杰伦")
        == "https://is1.mzstatic.com/right/600x600bb.jpg")
check("歌手对不上的也不收",
      ITunesCover.parse(["results": [["trackName": "青花瓷", "artistName": "吴英仔",
                                      "artworkUrl100": "https://a/100x100bb.jpg"]]],
                        title: "青花瓷", artist: "周杰伦") == nil)
check("版本后缀不影响匹配（歌名是中文）",
      ITunesCover.parse(["results": [["trackName": "凉凉 (with 張碧晨)", "artistName": "杨宗纬",
                                      "artworkUrl100": "https://a/100x100bb.jpg"]]],
                        title: "凉凉", artist: "杨宗纬") != nil)
// 罗马音歌手（Aska Yang 之于杨宗纬）按字符串比不出来——这是这套严格匹配的已知边界：
// 宁可返回 nil 落占位图，也不把别的专辑封面贴上来。
check("罗马音歌手不硬凑（已知边界：宁缺毋滥）",
      ITunesCover.parse(["results": [["trackName": "凉凉 (with 張碧晨)", "artistName": "Aska Yang",
                                      "artworkUrl100": "https://a/100x100bb.jpg"]]],
                        title: "凉凉", artist: "杨宗纬") == nil)
check("没有结果时返回 nil",
      ITunesCover.parse(["results": []], title: "青花瓷", artist: "周杰伦") == nil)

// MARK: - 开屏动画时间轴（SplashTimeline）
//
// 开屏是冷的：没人会为了它写回归测试，但它一旦"顺序错了"——比如声波先响、耳罩还没戴，
// 或者退场比落笔还早——看起来就是幻灯片，而且只在真机冷启动那一秒出现，极难复现。
// 所以把每一拍的先后关系都钉在这里。

section("开屏动画时间轴")

check("头梁先落笔，耳罩才开始戴",
      SplashTimeline.bandDraw.start < SplashTimeline.cupLeft.start)
check("两只耳罩错开 0.06s（同时落会像“啪”一下）",
      abs(SplashTimeline.cupRight.start - SplashTimeline.cupLeft.start - 0.06) < 0.001)
check("两只耳罩都在声波之前开始",
      SplashTimeline.cupLeft.start < SplashTimeline.sound.start
        && SplashTimeline.cupRight.start < SplashTimeline.sound.start)
check("声波开始时头梁已经画完",
      SplashTimeline.bandDraw.end <= SplashTimeline.sound.start)
check("图标轻顶落在声波窗口内",
      SplashTimeline.thump.start >= SplashTimeline.sound.start
        && SplashTimeline.thump.end <= SplashTimeline.sound.end)
check("耳罩彻底落位之后才退场",
      SplashTimeline.cupLeft.end <= SplashTimeline.exit.start
        && SplashTimeline.cupRight.end <= SplashTimeline.exit.start)
check("图标比纸底先走（不留一枚淡影压在新出现的封面上）",
      SplashTimeline.markFade.end <= SplashTimeline.exit.end)
check("首页与退场交叉淡入，不是等黑屏再出来",
      SplashTimeline.contentIn.start < SplashTimeline.exit.end
        && SplashTimeline.contentIn.end >= SplashTimeline.exit.end - 0.0001)
check("全片时长 = 退场结束，且压在 1.9s 以内",
      abs(SplashTimeline.total - SplashTimeline.exit.end) < 0.0001
        && SplashTimeline.total < 1.9,
      "total=\(SplashTimeline.total)")
check("每一拍都落在 0…total 之间",
      [SplashTimeline.bandDraw, SplashTimeline.cupLeft, SplashTimeline.cupRight,
       SplashTimeline.sound, SplashTimeline.thump, SplashTimeline.exit,
       SplashTimeline.markFade, SplashTimeline.contentIn]
        .allSatisfy { $0.start >= 0 && $0.end <= SplashTimeline.total + 0.0001 })
check("进度两端夹紧（不许越界，也不许倒流）",
      SplashTimeline.bandDraw.progress(at: -1) == 0
        && SplashTimeline.bandDraw.progress(at: 99) == 1
        && SplashTimeline.bandDraw.progress(at: SplashTimeline.bandDraw.start + 0.1)
             < SplashTimeline.bandDraw.progress(at: SplashTimeline.bandDraw.start + 0.4))
check("减弱动效的总时长不到正常版的一半",
      SplashTimeline.reduceMotionTotal < SplashTimeline.total / 2,
      "reduce=\(SplashTimeline.reduceMotionTotal)")
check("图标透明度：开场不透明、结束为 0",
      SplashTimeline.markOpacity(at: 0, reduceMotion: false) == 1
        && SplashTimeline.markOpacity(at: SplashTimeline.total, reduceMotion: false) == 0)
check("减弱动效：先完整停住，再淡出",
      SplashTimeline.markOpacity(at: SplashTimeline.reduceMotionHold - 0.01, reduceMotion: true) == 1
        && SplashTimeline.markOpacity(at: SplashTimeline.reduceMotionTotal, reduceMotion: true) < 1e-9)
check("结束判定：差一点点不结束、到点就结束",
      !SplashTimeline.isFinished(at: SplashTimeline.total - 0.01, reduceMotion: false)
        && SplashTimeline.isFinished(at: SplashTimeline.total, reduceMotion: false)
        && SplashTimeline.isFinished(at: SplashTimeline.reduceMotionTotal, reduceMotion: true))

// MARK: - 识曲舞台动效口径（RecognizeMotion）
//
// 第三十二轮：老板说"点击识曲是渐变，太丑且不符合功能"。新舞台全部由这几个纯函数驱动，
// 这里把"声波几秒一圈、透明度上限、倒计时夹紧、抖动不越界、同心圆顺序"钉死——
// 以后调手感只能改常量，不能改出"外圈跑出舞台"或"频谱压在倒计时环上"这种画面事故。

section("识曲舞台动效口径（RecognizeMotion）")

do {
    let samples = stride(from: 0.0, through: 12.0, by: 0.017).map { $0 }
    check("声波进度恒在 0…1（含长时间运行）",
          samples.allSatisfy { t in
              (0..<RecognizeMotion.rippleCount).allSatisfy { index in
                  let p = RecognizeMotion.rippleProgress(elapsed: t + 10_000, index: index)
                  return p >= 0 && p < 1
              }
          })
    check("声波错峰：三圈不同时出生",
          RecognizeMotion.rippleProgress(elapsed: 0, index: 0) == 0
            && RecognizeMotion.rippleProgress(elapsed: 0, index: 1) > 0.5,
          "i1=\(RecognizeMotion.rippleProgress(elapsed: 0, index: 1))")
    check("声波缩放 1 → 1.55，且单调外扩",
          abs(RecognizeMotion.rippleScale(progress: 0) - 1) < 1e-9
            && abs(RecognizeMotion.rippleScale(progress: 1) - RecognizeMotion.rippleMaxScale) < 1e-9
            && RecognizeMotion.rippleScale(progress: 0.4) < RecognizeMotion.rippleScale(progress: 0.8))
    check("声波透明度：峰值 0.42 → 0，且随距离递减",
          abs(RecognizeMotion.rippleOpacity(progress: 0) - RecognizeMotion.ripplePeakOpacity) < 1e-9
            && RecognizeMotion.rippleOpacity(progress: 1) == 0
            && RecognizeMotion.rippleOpacity(progress: 0.5) < RecognizeMotion.rippleOpacity(progress: 0.2))
    check("声波外圈不会跑出舞台",
          RecognizeMotion.coreDiameter * RecognizeMotion.rippleMaxScale <= RecognizeMotion.stageHeight,
          "outer=\(RecognizeMotion.coreDiameter * RecognizeMotion.rippleMaxScale)")
    check("电平条：静音留 3pt、满电平不超过 18pt、不为 NaN",
          (0..<RecognizeMotion.barCount).allSatisfy { index in
              let quiet = RecognizeMotion.barLength(index: index, level: 0, elapsed: 1.23)
              let loud = RecognizeMotion.barLength(index: index, level: 1, elapsed: 1.23)
              return abs(quiet - RecognizeMotion.barBaseLength) < 1e-9
                  && loud >= RecognizeMotion.barBaseLength
                  && loud <= RecognizeMotion.barMaxLength + 1e-9
                  && loud.isFinite
          })
    check("电平条透明度有上下界",
          (0...10).allSatisfy { step in
              let value = RecognizeMotion.barOpacity(level: Double(step) / 10)
              return value >= 0 && value <= RecognizeMotion.barPeakOpacity + 1e-9
          })
    check("倒计时环：听满为 1、刚开始为 0、越界夹紧",
          RecognizeMotion.countdownProgress(remaining: 0, total: 12) == 1
            && RecognizeMotion.countdownProgress(remaining: 12, total: 12) == 0
            && RecognizeMotion.countdownProgress(remaining: 20, total: 12) == 0
            && RecognizeMotion.countdownProgress(remaining: -3, total: 12) == 1
            && RecognizeMotion.countdownProgress(remaining: 5, total: 0) == 0)
    check("雷达弧：1.1s 一圈，进度循环",
          RecognizeMotion.scanRotation(elapsed: 0) == 0
            && abs(RecognizeMotion.scanRotation(elapsed: RecognizeMotion.scanCycle / 2) - 0.5) < 1e-6
            && abs(RecognizeMotion.scanRotation(elapsed: RecognizeMotion.scanCycle)) < 1e-9
            && RecognizeMotion.scanRotation(elapsed: 9.9) < 1)
    check("成功脉冲：0.55s 扩到 1.55，透明度归零",
          abs(RecognizeMotion.burstScale(elapsed: 0) - 1) < 1e-9
            && abs(RecognizeMotion.burstScale(elapsed: RecognizeMotion.burstCycle) - RecognizeMotion.burstMaxScale) < 1e-9
            && RecognizeMotion.burstOpacity(elapsed: RecognizeMotion.burstCycle) == 0
            && RecognizeMotion.burstOpacity(elapsed: RecognizeMotion.burstCycle / 2) < 0.55)
    check("失败抖动：起止为 0，全程不超出 ±6pt",
          RecognizeMotion.shakeOffset(elapsed: 0) == 0
            && RecognizeMotion.shakeOffset(elapsed: RecognizeMotion.shakeDuration) == 0
            && (0...36).allSatisfy { step in
                abs(RecognizeMotion.shakeOffset(elapsed: Double(step) / 100))
                    <= RecognizeMotion.shakeAmplitude + 1e-9
            },
          "peak=\(RecognizeMotion.shakeOffset(elapsed: 0.18))")
    check("同心圆顺序：底盘 < 光晕 < 倒计时环，且都在舞台高度内",
          RecognizeMotion.coreDiameter < RecognizeMotion.haloDiameter
            && RecognizeMotion.haloDiameter < RecognizeMotion.countdownDiameter
            && RecognizeMotion.countdownDiameter <= RecognizeMotion.stageHeight)
    check("频谱整圈在倒计时环以内（不压环）",
          RecognizeMotion.barRadius + RecognizeMotion.barMaxLength < RecognizeMotion.countdownDiameter / 2,
          "barOuter=\(RecognizeMotion.barRadius + RecognizeMotion.barMaxLength)")
    check("减弱动效的淡变不超过 0.2s",
          RecognizeMotion.reduceFade > 0 && RecognizeMotion.reduceFade <= 0.2)
}

// MARK: - 按压反馈最短可见时长（PressTiming）
//
// 第三十七轮：短按的 isPressed 可能同一帧 true→false，0.14s 下压动画来不及起帧；
// 这里把"补齐到最短可见时长"的算法钉死。
// 第三十八轮（老板：短按也要**完整铺满整条**高亮，只是比长按快）：
// 补上 ripplePlan 的口径——短按松手后换 0.16s 快速高亮接着铺满，长按走 0.55s 慢速。

section("按压反馈最短可见时长（PressTiming）")

do {
    check("短按 50ms：还要补 110ms（总可见 160ms）",
          abs(PressTiming.holdAfterRelease(elapsed: 0.05,
                                           minVisible: PressTiming.minVisible) - 0.11) < 1e-9)
    check("长按 300ms：已经够久，不需要补",
          PressTiming.holdAfterRelease(elapsed: 0.30,
                                       minVisible: PressTiming.minVisible) == 0)
    check("刚按下：补满整个最短时长",
          PressTiming.holdAfterRelease(elapsed: 0,
                                       minVisible: PressTiming.minVisible) == PressTiming.minVisible)
    check("短按阈值比普通按钮最短时长长",
          PressTiming.quickTapThreshold > PressTiming.minVisible,
          "threshold=\(PressTiming.quickTapThreshold) button=\(PressTiming.minVisible)")
    check("脏数据不产生负补时",
          PressTiming.holdAfterRelease(elapsed: Double.nan, minVisible: 0.16) == 0)
    check("比较常见的 80ms 快速点按也要补到 160ms",
          PressTiming.holdAfterRelease(elapsed: 0.08,
                                       minVisible: PressTiming.minVisible) > 0.07)

    let quick = PressTiming.ripplePlan(elapsed: 0.06)
    check("短按 60ms：松手后换 0.12s 快速高亮铺满",
          quick.restart && abs(quick.duration - PressTiming.fastRipple) < 1e-9,
          "\(quick)")
    check("短按从当前进度接着长，不回到 0",
          quick.startProgress > 0 && quick.startProgress < 0.1,
          "start=\(quick.startProgress)")
    check("短按也要等铺满 + 0.10s 再淡出",
          abs(quick.waitBeforeFade
              - (PressTiming.fastRipple + PressTiming.holdBeforeFade)) < 1e-9,
          "wait=\(quick.waitBeforeFade)")
    check("点歌条动作延迟覆盖铺满 + 停留（悬浮栏/播放页不会打断高亮）",
          PressTiming.rowActionDelay >= PressTiming.fastRipple + PressTiming.holdBeforeFade,
          "delay=\(PressTiming.rowActionDelay)")

    let medium = PressTiming.ripplePlan(elapsed: 0.30)
    check("300ms 按：不重启，让慢速高亮自己走完",
          !medium.restart
            && abs(medium.waitBeforeFade
                   - ((PressTiming.slowRipple - 0.30) + PressTiming.holdBeforeFade)) < 1e-9,
          "\(medium)")

    let long = PressTiming.ripplePlan(elapsed: 0.60)
    check("600ms 长按：已经铺满，只等 0.10s",
          !long.restart && long.waitBeforeFade == PressTiming.holdBeforeFade,
          "\(long)")

    let late = PressTiming.ripplePlan(elapsed: 0.20)
    check("200ms 松手：从约 29% 进度快速铺满，不闪回",
          late.restart && late.startProgress > 0.20 && late.startProgress < 0.40,
          "start=\(late.startProgress)")
}

// MARK: - 第四十轮：设置页瘦身 + 车载自动播放

// 这一轮把九个"只能这么办"的设置项收回到代码里。断言钉三件事：
//   ① 车载只在"车机 / 蓝牙 + 开关开 + 没在播"时才自动起播（连 USB 声卡、连着耳机不抢）；
//   ② 续播只认"真的听到一半"（开头 3 秒内、离结尾 8 秒内都不续，交给热门兜底）；
//   ③ 歌词缓存上限怎么填都是合法值（0/负数回默认、超界夹住、步进对齐区间）。

section("车载自动播放（CarAudioRules）")

do {
    check("车机端口 + 开关开 + 没在播 → 自动起播",
          CarAudioRules.shouldAutoplay(enabled: true, isPlaying: false, kind: .carAudio))
    check("车载蓝牙同样算（老板说的就是「连接车载蓝牙之后」）",
          CarAudioRules.shouldAutoplay(enabled: true, isPlaying: false, kind: .bluetooth))
    check("USB 声卡不算车载（电脑上插个声卡不该自己放歌）",
          !CarAudioRules.shouldAutoplay(enabled: true, isPlaying: false, kind: .usb))
    check("外放 / 有线耳机不算",
          !CarAudioRules.shouldAutoplay(enabled: true, isPlaying: false, kind: .other))
    check("开关关掉就一律不动",
          !CarAudioRules.shouldAutoplay(enabled: false, isPlaying: false, kind: .carAudio))
    check("正在播时连上车机不重头播（只是换了个输出）",
          !CarAudioRules.shouldAutoplay(enabled: true, isPlaying: true, kind: .bluetooth))
    check("端口名带车厂关键词能认出来（只用于文案）",
          CarAudioRules.looksLikeCarName("BYD Han") && CarAudioRules.looksLikeCarName("我的车"))
    check("普通耳机名不会被认成车",
          !CarAudioRules.looksLikeCarName("AirPods Pro"))
}

section("上次没播完 → 接着放（PlaybackRestoreRules）")

do {
    check("听到一半：续播", PlaybackRestoreRules.shouldResume(positionSec: 90, durationSec: 269))
    check("刚开头 1 秒：不续，重头放更自然",
          !PlaybackRestoreRules.shouldResume(positionSec: 1, durationSec: 269))
    check("刚好到最小位置：续播",
          PlaybackRestoreRules.shouldResume(positionSec: PlaybackRestoreRules.minResumePositionSec,
                                            durationSec: 269))
    check("只剩 5 秒：当上一轮听完了，不续",
          !PlaybackRestoreRules.shouldResume(positionSec: 264, durationSec: 269))
    check("时长未知（0）：不续，走热门兜底",
          !PlaybackRestoreRules.shouldResume(positionSec: 30, durationSec: 0))
    check("脏数据（NaN / 负数）不崩也不续",
          !PlaybackRestoreRules.shouldResume(positionSec: .nan, durationSec: 269)
            && !PlaybackRestoreRules.shouldResume(positionSec: -5, durationSec: 269))
    check("播放位置超过时长（容器时长偏短）：不续",
          !PlaybackRestoreRules.shouldResume(positionSec: 300, durationSec: 269))
}

section("歌词缓存上限可配（LyricsCacheRules）")

do {
    check("没设置过（0）→ 默认 200 首", LyricsCacheRules.clamp(0) == 200)
    check("负数同样回默认", LyricsCacheRules.clamp(-30) == 200)
    check("低于下限夹到 50", LyricsCacheRules.clamp(10) == LyricsCacheRules.minLimit)
    check("高于上限夹到 1000", LyricsCacheRules.clamp(9999) == LyricsCacheRules.maxLimit)
    check("区间内原样保留（设置页步进 50）", LyricsCacheRules.clamp(350) == 350)
    check("上下限之间容得下 20 档",
          (LyricsCacheRules.maxLimit - LyricsCacheRules.minLimit) / LyricsCacheRules.step == 19)
}

section("下载保存位置的路径文案（DownloadPathRules）")

do {
    let home = "/var/mobile/Containers/Data/Application/ABC"
    check("默认位置给的是整条面包屑，根目录是 Download",
          DownloadPathRules.defaultPathText == "文件 › JZ 音乐 › Download",
          DownloadPathRules.defaultPathText)
    check("三个子目录固定为 Music / Lyrics / Cover",
          DownloadPathRules.musicSubfolder == "Music"
            && DownloadPathRules.lyricsSubfolder == "Lyrics"
            && DownloadPathRules.coverSubfolder == "Cover")
    check("子目录说明文案", DownloadPathRules.foldersSummary == "Music · Lyrics · Cover",
          DownloadPathRules.foldersSummary)
    check("App 容器里的子目录 → 文件 › JZ 音乐 › 子目录",
          DownloadPathRules.breadcrumb(path: home + "/Documents/我的歌", home: home)
            == "文件 › JZ 音乐 › 我的歌",
          DownloadPathRules.breadcrumb(path: home + "/Documents/我的歌", home: home))
    check("两层子目录要一路展开",
          DownloadPathRules.breadcrumb(path: home + "/Documents/2026/冬天", home: home)
            == "文件 › JZ 音乐 › 2026 › 冬天")
    check("Documents 本身 → 就是默认位置文案",
          DownloadPathRules.breadcrumb(path: home + "/Documents", home: home)
            == DownloadPathRules.defaultPathText)
    check("iCloud Drive 里的文件夹 → iCloud Drive › …",
          DownloadPathRules.breadcrumb(
            path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs/我的音乐",
            home: home) == "iCloud Drive › 我的音乐")
    check("iCloud Drive 根目录 → iCloud Drive",
          DownloadPathRules.breadcrumb(
            path: "/private/var/mobile/Library/Mobile Documents/com~apple~CloudDocs",
            home: home) == "iCloud Drive")
    check("别的 App 的容器 → 末两级（不给一长串哈希）",
          DownloadPathRules.breadcrumb(
            path: "/private/var/mobile/Containers/Shared/AppGroup/XYZ/我的音乐",
            home: home) == "文件 › XYZ › 我的音乐")
    check("末尾多一个斜杠不会出现空段",
          DownloadPathRules.breadcrumb(path: home + "/Documents/我的歌/", home: home)
            == "文件 › JZ 音乐 › 我的歌",
          DownloadPathRules.breadcrumb(path: home + "/Documents/我的歌/", home: home))
    check("新建文件夹：普通名字原样",
          DownloadPathRules.sanitizedFolderName("  车载音乐 ") == "车载音乐")
    check("新建文件夹：带斜杠换成下划线",
          DownloadPathRules.sanitizedFolderName("2026/冬天") == "2026_冬天")
    check("新建文件夹：空 / 点 / 双点都拒掉",
          DownloadPathRules.sanitizedFolderName("   ") == nil
            && DownloadPathRules.sanitizedFolderName(".") == nil
            && DownloadPathRules.sanitizedFolderName("..") == nil)
}

// MARK: - 汇总

print("\n================ 结果 ================")
print("通过 \(passed) / 失败 \(failed)")
if failed > 0 {
    print("有断言失败")
    exit(1)
}
print("全部通过")
exit(0)
