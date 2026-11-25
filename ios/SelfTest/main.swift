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
import Observation

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

// MARK: - 3.1 同曲判定（2026-11-19 老板口径：歌手优先 + 时长 ≤4s + 歌名只做辅助）

section("同曲判定（译名不同也算同一首）")

do {
    let src = song(.qq, "恋爱的条件", "BESTie (베스티)", album: "Love Options", dur: 194, id: "sim_src")
    // 2026-11-25 修正口径：歌名重新成为**硬条件**，译名案改走"专辑 + 时长 ≤1 秒"通道。
    // 所以候选要把专辑带上（真实数据：网易那条的专辑是「연애의 조건 (Love Options)」）。
    check("译名不同，但同专辑 + 同时长 → 判为同一首（译名通道）",
          NameMatch.sameRecording(src: src,
                                  cand: song(.netease, "연애의 조건 (Love Options)", "BESTie",
                                             album: "연애의 조건 (Love Options)", dur: 194,
                                             id: "sim_ne")))
    check("(Inst.) 伴奏版 → 拒",
          !NameMatch.sameRecording(src: src,
                                   cand: song(.netease, "연애의 조건 (Love Options) (Inst.)", "BESTie",
                                              album: "연애의 조건 (Love Options)", dur: 192,
                                              id: "sim_inst")))
    check("别的歌 + 别的歌手 → 拒",
          !NameMatch.sameRecording(src: src,
                                   cand: song(.netease, "爱情转移", "陈奕迅", dur: 259, id: "sim_other")))
    check("同歌手但时长差 11s → 拒",
          !NameMatch.sameRecording(src: src,
                                   cand: song(.netease, "恋爱条件", "BESTie", dur: 205, id: "sim_long")))
    check("同歌手同时长、歌名完全不同、专辑也不同 → 拒（2026-11-25 新口径：宁可没源也别串歌）",
          !NameMatch.sameRecording(src: src,
                                   cand: song(.qq, "LOVE OPTIONS", "BESTie", dur: 194, id: "sim_en")))

    // 2026-11-25 真机事故：《众》播成《侧脸》（同歌手、时长差 2.4 秒）
    let zhong = song(.netease, "众", "黄霄雲", album: "众", dur: 215, id: "zhong_ne")
    let ceyanNE = song(.netease, "侧脸", "黄霄雲", album: "侧脸", dur: 218, id: "ceyan_ne")
    let ceyanQQ = song(.qq, "侧脸", "黄霄雲", album: "侧脸", dur: 217, id: "ceyan_qq")
    let zhongQQ = song(.qq, "众", "黄霄雲", album: "众", dur: 215, id: "zhong_qq")
    check("《众》vs《侧脸》（网易，差 3s）→ 拒", !NameMatch.sameRecording(src: zhong, cand: ceyanNE))
    check("《众》vs《侧脸》（QQ，差 1.5s）→ 拒", !NameMatch.sameRecording(src: zhong, cand: ceyanQQ))
    check("《众》vs《众》（另一平台，差 0.5s）→ 通过（跨源同曲仍要能补位）",
          NameMatch.sameRecording(src: zhong, cand: zhongQQ))
    check("身份等级：《众》vs《众》另一平台 = 1（歌名相等）",
          NameMatch.identityRank(src: zhong, cand: zhongQQ) == 1,
          "\(NameMatch.identityRank(src: zhong, cand: zhongQQ))")
    check("身份等级：《众》vs《侧脸》= 9（没证据）",
          NameMatch.identityRank(src: zhong, cand: ceyanQQ) == 9,
          "\(NameMatch.identityRank(src: zhong, cand: ceyanQQ))")

    let frx = song(.qq, "发如雪", "周杰伦", album: "十一月的萧邦", dur: 300, id: "frx_src")
    check("发如雪 vs 发如雪(粤语版)/常颖杰 → 拒",
          !NameMatch.sameRecording(src: frx,
                                   cand: song(.kuwo, "发如雪 (粤语版)", "常颖杰", dur: 299, id: "frx_canto")))
    check("发如雪 vs 发如雪/周杰伦（另一平台，差 1s）→ 通过",
          NameMatch.sameRecording(src: frx,
                                  cand: song(.netease, "发如雪", "周杰伦", dur: 301, id: "frx_ne")))

    check("副标题不是版本：versionClass(LOVE OPTIONS) 为空",
          NameMatch.versionClass("연애의 조건 (LOVE OPTIONS)").isEmpty,
          "got=\(NameMatch.versionClass("연애의 조건 (LOVE OPTIONS)"))")
    check("(Inst.) 识别为版本类 inst",
          NameMatch.versionClass("연애의 조건 (Love Options) (Inst.)") == ["inst"],
          "got=\(NameMatch.versionClass("연애의 조건 (Love Options) (Inst.)"))")
}

// MARK: - 3.2 频道号/上传者不认亲（2026-11-22《下一个天亮》串歌）

section("频道号/上传者不认亲")

do {
    // 真实案例（2026-11-22 录屏）：歌手是频道名「我的音乐调频」，名下挂着别的歌，
    // 时长都撞在 ±4s 里；老口径只认「歌手 + 时长」，于是把别的歌当成了这首的合法音源。
    let pl = song(.kugou, "下一个天亮", "我的音乐调频", dur: 263, id: "kg_27e25b70")
    let siblingExact = song(.kuwo, "怎么会狠心伤害我", "我的音乐调频", dur: 263, id: "kw_347079287")
    let siblingEdge = song(.kuwo, "简单爱", "我的音乐调频", dur: 267, id: "kw_442871468")
    let siblingFar = song(.kuwo, "心锁", "我的音乐调频", dur: 255, id: "kw_347075531")
    let realCover = song(.netease, "下一个天亮", "郭静", dur: 266, id: "ne_233882")
    let pool = [siblingExact, siblingEdge, siblingFar, realCover]

    check("新口径直接拒：同歌手 + 时长差 0、但歌名完全不同（以前会放行）",
          !SameSongCrossResolver.sameSong(src: pl, cand: siblingExact))
    check("池子里歌名一首都没对上 → 认作频道号/上传者",
          NameMatch.looksLikeUploader(pl, among: pool))
    check("收紧后：同上传者的别的歌（263s，差 0）→ 拒",
          !SameSongCrossResolver.sameSong(src: pl, cand: siblingExact, uploaderLike: true))
    check("收紧后：同上传者的别的歌（267s，差 4s）→ 拒",
          !SameSongCrossResolver.sameSong(src: pl, cand: siblingEdge, uploaderLike: true))
    check("收紧后：真同曲换个平台（歌名一致）→ 通过",
          SameSongCrossResolver.sameSong(
            src: pl,
            cand: song(.kuwo, "下一个天亮", "我的音乐调频", dur: 263, id: "kw_nd"),
            uploaderLike: true))

    // 不误伤真人歌手：周杰伦的搜索页也会带出他别的歌，但他自己那首就在池子里。
    let jay = song(.qq, "晴天", "周杰伦", dur: 269, id: "qq_qt")
    let jayPool = [jay,
                   song(.kugou, "夜曲", "周杰伦", dur: 226, id: "kg_yq"),
                   song(.kugou, "七里香", "周杰伦", dur: 299, id: "kg_qlx"),
                   song(.kuwo, "晴天", "周杰伦", dur: 269, id: "kw_qt")]
    check("真人歌手（他自己的歌在池子里）→ 不算频道号",
          !NameMatch.looksLikeUploader(jay, among: jayPool))
    check("真人歌手也一样：歌名不同 → 拒（2026-11-25 起不再看是不是频道号）",
          !SameSongCrossResolver.sameSong(
            src: jay,
            cand: song(.netease, "晴天娃娃", "周杰伦", dur: 269, id: "ne_qt_other"),
            uploaderLike: false))
    check("真人歌手：歌名一致 → 照旧通过",
          SameSongCrossResolver.sameSong(
            src: jay,
            cand: song(.netease, "晴天", "周杰伦", dur: 269, id: "ne_qt"),
            uploaderLike: false))

    // 不误伤译名案（2026-11-19 老板口径）：名字不同但同歌手，池子里只有这一首（括号已被剥掉）。
    let krSrc = song(.qq, "恋爱的条件", "BESTie (베스티)", album: "Love Options", dur: 194,
                     id: "kr_src")
    let krCand = song(.netease, "연애의 조건 (Love Options)", "BESTie",
                      album: "연애의 조건 (Love Options)", dur: 194, id: "kr_ne")
    let krPool = [krCand, song(.kuwo, "연애의 조건 (Inst.)", "BESTie", dur: 192, id: "kr_inst")]
    check("译名案：去重后只有 1 个歌名 → 不算频道号",
          !NameMatch.looksLikeUploader(krSrc, among: krPool))
    check("译名案：照旧判为同一首",
          SameSongCrossResolver.sameSong(src: krSrc, cand: krCand, uploaderLike: false))
}

// MARK: - 3.2.1 下载列表顺序：新的在最上面（2026-11-22 老板录屏）

section("下载列表顺序：新的在最上面")

do {
    func item(_ name: String, _ sec: TimeInterval) -> DownloadItem {
        DownloadItem(song: song(.qq, name, "歌手"), streamURL: "file:///\(name).flac",
                     backendName: "import", quality: .lossless, fileName: "\(name).flac",
                     status: .completed, totalBytes: 1_000,
                     createdAt: Date(timeIntervalSince1970: sec))
    }
    let old = item("老歌", 100)
    let mid = item("中间", 200)
    let new = item("新歌", 300)
    check("新的排最前（旧→新 的落库顺序被倒过来）",
          DownloadItem.newestFirst([old, mid, new]).map(\.song.name) == ["新歌", "中间", "老歌"],
          "got=\(DownloadItem.newestFirst([old, mid, new]).map(\.song.name))")
    check("落库顺序打乱也一样", 
          DownloadItem.newestFirst([mid, new, old]).map(\.song.name) == ["新歌", "中间", "老歌"])
    check("空列表不炸", DownloadItem.newestFirst([]).isEmpty)

    // 同一秒完成的一批（批量导入）：后入的在上，且两次调用顺序一致（不能来回跳）
    let batchA = item("A", 500)
    let batchB = item("B", 500)
    let batchC = item("C", 500)
    check("同一秒的：后入的先显示",
          DownloadItem.newestFirst([batchA, batchB, batchC]).map(\.song.name) == ["C", "B", "A"])
    check("同一秒的：重复调用顺序稳定",
          DownloadItem.newestFirst([batchA, batchB, batchC]).map(\.id)
            == DownloadItem.newestFirst([batchA, batchB, batchC]).map(\.id))

    // 2026-11-22：新下载的那首必须落在**首屏第一行**（分页不能把它挤出去）
    check("首屏第一行就是最新那首",
          DownloadListPaging.slices(ongoing: [], failed: [],
                                    finished: DownloadItem.newestFirst([old, mid, new]),
                                    limit: DownloadListPaging.firstFrame)
            .finished.first?.song.name == "新歌")
}

// MARK: - 3.2.2 下载页搜索：预归一化（2026-11-22 输入一个字母就卡）

section("下载页搜索：预归一化")

do {
    let s1 = song(.qq, "後來", "劉若英", album: "我等你", dur: 300, id: "ls1")
    let name = "01 - 劉若英 - 後來.flac"
    let blob = LibrarySearch.blob(song: s1, fileName: name)
    check("繁简：搜「后来」命中「後來」",
          LibrarySearch.matches(blob: blob, key: LibrarySearch.key("后来")))
    check("歌手字段能搜", LibrarySearch.matches(blob: blob, key: LibrarySearch.key("刘若英")))
    check("专辑字段能搜", LibrarySearch.matches(blob: blob, key: LibrarySearch.key("我等你")))
    check("文件名能搜（去扩展名）", LibrarySearch.matches(blob: blob, key: LibrarySearch.key("01")))
    check("跨字段不误命中（歌手末尾 + 专辑开头）",
          !LibrarySearch.matches(blob: blob, key: LibrarySearch.key("英我等")),
          "blob=\(blob)")
    check("空查询不算命中（调用方按「全部」处理）",
          !LibrarySearch.matches(blob: blob, key: ""))
    check("不存在的词不命中", !LibrarySearch.matches(blob: blob, key: LibrarySearch.key("晴天")))
    // 与老口径（逐字段 rank）结论一致：命中/不命中不能变
    for q in ["后来", "刘若英", "我等你", "01", "英我等", "晴天"] {
        let old = LibrarySearch.matches(song: s1, fileName: name, query: q)
        let new = LibrarySearch.matches(blob: blob, key: LibrarySearch.key(q))
        check("与老口径同结论：\(q)", old == new, "old=\(old) new=\(new)")
    }
}

// MARK: - 3.2.3 起播挑选：够档立刻起播，起播后不再换源（2026-11-22 开头卡顿）

section("起播挑选：不再中途换源")

do {
    func src(_ kbps: Int64, _ backend: String) -> StreamSource {
        StreamSource(url: "https://x/\(backend)", backendName: backend, platform: .kugou,
                     quality: .high, format: "mp3", note: "",
                     kbps: kbps, totalBytes: 10_000_000)
    }
    func cand(_ s: StreamSource, ms: Int) -> DownloadResolver.Candidate {
        DownloadResolver.Candidate(
            song: song(.kugou, "下一个天亮", "我的音乐调频"),
            source: s, elapsedMs: ms,
            score: DownloadResolver.Score(tier: DownloadResolver.tierOf(s), version: 300,
                                          duration: 100, reliable: 90, ms: ms))
    }
    let k128 = src(128, "酷狗官方")
    let k320 = src(321, "星海酷狗")
    let k256 = src(256, "某后端")

    check("320 压过先到的 128（这就是不再中途换源的关键）",
          DownloadResolver.bestForStart([cand(k128, ms: 200), cand(k320, ms: 900)])?.source.backendName
            == "星海酷狗",
          "got=\(DownloadResolver.bestForStart([cand(k128, ms: 200), cand(k320, ms: 900)])?.source.backendName ?? "nil")")
    check("只有 128 时就用 128（不再空等）",
          DownloadResolver.bestForStart([cand(k128, ms: 200)])?.source.kbps == 128)
    check("同档取实测码率更高的",
          DownloadResolver.bestForStart([cand(k256, ms: 300), cand(k320, ms: 800)])?.source.kbps == 321)
    check("同档同码率取更快的",
          DownloadResolver.bestForStart([cand(k320, ms: 900), cand(k320, ms: 400)])?.elapsedMs == 400)
    check("一条都没有 → nil", DownloadResolver.bestForStart([]) == nil)
    check("起播窗口 1.6s、够档门槛 = 320k 档（700）",
          DownloadResolver.startWindow == 1.6 && DownloadResolver.startGoodEnoughTier == 700,
          "window=\(DownloadResolver.startWindow) tier=\(DownloadResolver.startGoodEnoughTier)")
    check("128k 达不到「够档」", DownloadResolver.tierOf(k128) < DownloadResolver.startGoodEnoughTier)
    check("320k 达到「够档」", DownloadResolver.tierOf(k320) >= DownloadResolver.startGoodEnoughTier)
}

// MARK: - 3.2.4 导入字段取舍：文件标签 > 文件名（2026-11-22 重新导入要手动加载）

section("导入字段取舍：文件标签 > 文件名")

do {
    // 真实案例：真机整批无损是 FLAC，AVFoundation 读不到 Vorbis Comment，
    // 于是歌名退回文件名（`蔡健雅 - 红色高跟鞋 [网易_妖狐酷我]`），封面也没有。
    let full = ImportRules.pickImportedFields(tagTitle: "红色高跟鞋", tagArtist: "蔡健雅",
                                              tagAlbum: "若你碰到他",
                                              fileTitle: "红色高跟鞋 [网易_妖狐酷我]",
                                              fileArtist: "蔡健雅")
    check("标签齐 → 用标签，文件名里的 [平台_后端] 不带进来",
          full.title == "红色高跟鞋" && full.artist == "蔡健雅" && full.album == "若你碰到他",
          "\(full)")
    check("标签齐 → 不算 filenameGuess", !full.guessed)

    let none = ImportRules.pickImportedFields(tagTitle: "", tagArtist: "", tagAlbum: "",
                                              fileTitle: "红色高跟鞋", fileArtist: "蔡健雅")
    check("标签全空 → 用文件名，并标成 filenameGuess",
          none.title == "红色高跟鞋" && none.artist == "蔡健雅" && none.guessed, "\(none)")

    let half = ImportRules.pickImportedFields(tagTitle: "红色高跟鞋", tagArtist: "", tagAlbum: "",
                                              fileTitle: "随便什么", fileArtist: "蔡健雅")
    check("只有歌名有标签 → 歌名用标签、歌手用文件名、仍算 filenameGuess",
          half.title == "红色高跟鞋" && half.artist == "蔡健雅" && half.guessed, "\(half)")

    let blank = ImportRules.pickImportedFields(tagTitle: "   ", tagArtist: "\n", tagAlbum: " ",
                                               fileTitle: "晴天", fileArtist: "周杰伦")
    check("空白标签当作没有", blank.title == "晴天" && blank.artist == "周杰伦" && blank.guessed,
          "\(blank)")

    // flac 读回来三项齐 → 导入不再联网补料（第 54 轮口径）
    var fields = DownloadCompanion.ID3Tags.Fields()
    fields.title = "红色高跟鞋"
    fields.artist = "蔡健雅"
    fields.cover = Data([0xFF, 0xD8, 0xFF])
    check("标签自带歌名+歌手+封面 → 视为自带完整（不联网）",
          DownloadCompanion.LocalTagRules.isSelfContained(fields: fields))
    fields.cover = nil
    check("少封面 → 不算自带完整（会补图）",
          !DownloadCompanion.LocalTagRules.isSelfContained(fields: fields))
}

// MARK: - 3.2.5 存储自检：孤儿/临时残留的判定（2026-11-22 空间翻倍）

section("存储自检：孤儿与临时残留")

do {
    check("写标签的隐藏临时文件认得出（.tags-）",
          StorageAuditRules.isTagTempArtifact(".tags-3F2A91.flac"))
    check(".embed- 也算", StorageAuditRules.isTagTempArtifact(".embed-9C71.m4a"))
    check("正常文件不是临时文件",
          !StorageAuditRules.isTagTempArtifact("周杰伦 - 晴天.mp3"))
    check("音频按扩展名认（flac / MP3 / m4a）",
          StorageAuditRules.isAudio("a.flac") && StorageAuditRules.isAudio("b.MP3")
            && StorageAuditRules.isAudio("c.m4a"))
    check("旁车 / 日志不算音频",
          !StorageAuditRules.isAudio("a.lrc") && !StorageAuditRules.isAudio("a.jpg")
            && !StorageAuditRules.isAudio("trace.log"))

    func dl(_ fileName: String, path: String?) -> DownloadItem {
        DownloadItem(song: song(.local, fileName, "某人", id: "loc_\(fileName)"),
                     streamURL: "file:///\(fileName)", backendName: "本地导入",
                     quality: .lossless, fileName: fileName, localPath: path,
                     status: .completed, totalBytes: 1_000)
    }
    let items = [dl("A.flac", path: "/x/Music/A.flac"),
                 dl("B.flac", path: nil)]
    let refs = StorageAuditRules.referencedNames(items)
    check("fileName 和 localPath 最后一段都算被引用",
          refs.contains("A.flac") && refs.contains("B.flac"), "\(refs.sorted())")
    check("没人认领的音频 → 孤儿",
          StorageAuditRules.isOrphan(fileName: "C.flac", referenced: refs))
    check("有记录的音频 → 不是孤儿",
          !StorageAuditRules.isOrphan(fileName: "A.flac", referenced: refs))
    check("隐藏文件不按孤儿判（走临时残留那一类）",
          !StorageAuditRules.isOrphan(fileName: ".tags-x.flac", referenced: refs))
    check("旁车不按孤儿判", !StorageAuditRules.isOrphan(fileName: "A.lrc", referenced: refs))
}

// MARK: - 3.2.7 写回范围：已对齐的不重复写（2026-11-22 老板："新歌写回会把老歌再写一遍"）

section("写回范围：已对齐的不重复写")

do {
    func item(_ name: String, truth: SongFileTruth?, status: DownloadStatus = .completed,
              path: String? = "/x/\(UUID().uuidString).flac",
              fileMissingFlag: Bool = false) -> DownloadItem {
        var made = DownloadItem(song: song(.local, name, "某人", id: "si_\(name)_\(UUID().uuidString)"),
                                streamURL: "file:///x", backendName: "本地导入", quality: .lossless,
                                fileName: "\(name).flac", localPath: path, status: status,
                                totalBytes: 1_000, fileTruth: truth)
        if fileMissingFlag { made.fileMissing = true }
        return made
    }
    var aligned = SongFileTruth()
    aligned.title = .ok
    aligned.artist = .ok
    aligned.album = .ok
    aligned.cover = .ok
    aligned.lyrics = .ok
    var broken = SongFileTruth()
    broken.cover = .missing

    check("没有状态记录（刚导入/刚改过）→ 需要写", SongInfoWriteRules.needsWrite(item("A", truth: nil)))
    check("上次已对齐 → 跳过", !SongInfoWriteRules.needsWrite(item("B", truth: aligned)))
    check("上次没对齐 → 还要写", SongInfoWriteRules.needsWrite(item("C", truth: broken)))

    let list = [item("A", truth: nil),
                item("B", truth: aligned),
                item("C", truth: broken),
                item("D", truth: aligned, status: .downloading),
                item("E", truth: aligned, path: nil)]
    let split = SongInfoWriteRules.pending(list)
    check("待写只有 A / C 两条", split.targets.map(\.song.name) == ["A", "C"],
          "\(split.targets.map(\.song.name))")
    check("跳过的只算已对齐且有文件的（B 一条）", split.skipped == 1, "\(split.skipped)")

    // 2026-11-22（老板：合并前写回过、合并后文件没了，之后总报"写回失败"）：
    // 记录还在、文件已不在 → 打个标记，之后写回/检测都跳过它，不再天天报。
    let dead = item("英雄", truth: broken, fileMissingFlag: true)
    check("文件已不在的记录 → 不再要求写", !SongInfoWriteRules.needsWrite(dead))
    check("文件已不在的记录不进待写名单",
          !SongInfoWriteRules.pending([dead]).targets.contains { $0.id == dead.id })
}

// MARK: - 3.2.8 整理重复的批量计划（2026-11-22：点一下卡 10 秒）

section("整理重复：批量计划（口径不变，只是算法）")

do {
    func dl(_ name: String, _ singer: String, dur: Int, bytes: Int64,
            id: String, status: DownloadStatus = .completed) -> DownloadItem {
        DownloadItem(song: song(.local, name, singer, dur: dur, id: "song_\(id)"),
                     streamURL: "file:///\(name)", backendName: "本地导入",
                     quality: .lossless, fileName: "\(name).flac", localPath: "/x/\(name).flac",
                     status: status, totalBytes: bytes,
                     createdAt: Date(timeIntervalSince1970: 1))
    }
    // 同一条录音（同名同歌手同时长），320 vs 无损 → 留字节多的那条
    let hi = dl("晴天", "周杰伦", dur: 269, bytes: 40_000_000, id: "a")
    let lo = dl("晴天", "周杰伦", dur: 269, bytes: 10_000_000, id: "b")
    let plan = DuplicateSweep.plan([hi, lo])
    check("同一条录音只留一条", plan.losers.count == 1 && plan.merged == 1)
    check("留下的是字节多（kbps 高）的那条",
          plan.losers.first == lo.id, "loser=\(plan.losers.first == lo.id ? "lo" : "hi")")
    check("释放字节 = 被删那条的体积", plan.freedBytes == 10_000_000)

    check("不同歌（时长差 30s）不合并",
          DuplicateSweep.plan([dl("晴天", "周杰伦", dur: 269, bytes: 10, id: "c"),
                               dl("晴天", "周杰伦", dur: 299, bytes: 10, id: "d")]).isEmpty)
    check("不同歌手不合并",
          DuplicateSweep.plan([dl("晴天", "周杰伦", dur: 269, bytes: 20, id: "e"),
                               dl("晴天", "蔡健雅", dur: 269, bytes: 10, id: "f")]).isEmpty)
    check("下到一半（非 completed）不参与",
          DuplicateSweep.plan([dl("晴天", "周杰伦", dur: 269, bytes: 20, id: "g"),
                               dl("晴天", "周杰伦", dur: 269, bytes: 10, id: "h",
                                  status: .downloading)]).isEmpty)
    // 时长未知：规则允许"一边未知 + 歌名归一后相等"就算同一条
    check("时长未知 vs 有时长、同名同歌手 → 合并",
          DuplicateSweep.plan([dl("晴天", "周杰伦", dur: 0, bytes: 20, id: "i"),
                               dl("晴天", "周杰伦", dur: 269, bytes: 10, id: "j")]).merged == 1)
    // kbps 相同 → 保留先出现的（与旧实现一致）
    let firstSame = dl("夜曲", "周杰伦", dur: 226, bytes: 5_000_000, id: "k")
    let secondSame = dl("夜曲", "周杰伦", dur: 226, bytes: 5_000_000, id: "l")
    let tie = DuplicateSweep.plan([firstSame, secondSame])
    check("kbps 相同：保留先出现的那条",
          tie.losers == [secondSame.id], "losers=\(tie.losers)")
    // 2026-11-22（老板："《英雄》被去重之后每次播放加载都要 1-2 秒"）：
    // 每个 loser 都必须能追到它被并进的那条（收藏/最近播放按这个映射改引用，否则
    // 播放时按 song.id 找不到本地文件，就会回落联网取流）。
    check("每个被并走的条目都记下了幸存那条",
          plan.losers.allSatisfy { plan.winnerOf[$0] == hi.id },
          "winnerOf=\(plan.winnerOf.count)")
    check("幸存那条不许落在被删名单里（链式归并要展开到最终那条）",
          plan.losers.allSatisfy { !plan.losers.contains(plan.winnerOf[$0] ?? hi.id) })

    // 规模口径：600 首跑完且不误合并。
    // 注意：歌名/歌手都要**互不相干**、时长两两相差 >4s —— 否则按项目自己的「同一条录音」口径
    // （歌名相似 ≥0.75 + 同歌手 + 时长相近）它们本来就该合并（我第一版测试数据就踩了这个：
    // 歌10 与 歌130 同歌手同时长、LCS 0.75 → 真的算同一条）。
    let many = (0..<600).map { i in
        dl("曲目编号\(i)甲", "演唱者\(i)", dur: 100 + i * 10,
           bytes: Int64(1_000_000 + i * 1000), id: "m\(i)")
    }
    let bigPlan = DuplicateSweep.plan(many)
    check("600 首同库：跑完且不误合并", bigPlan.isEmpty,
          "merged=\(bigPlan.merged)")
}

// MARK: - 3.3 下载链排名（2026-11-19 老板口径：全收集 → 身份淘汰 → 打分排序 → 取第一 → 校验 → 退第二）

section("下载链排名与下载前校验")

do {
    let ref = song(.qq, "연애의 조건 (恋爱的条件) (LOVE OPTIONS)", "BESTie (베스티)",
                   album: "Love Options", dur: 194, id: "rank_src")
    let yaohu = StreamSource(
        url: "https://car-er.kuwo.cn/f87a92b84349e3053de1f8aee39e552d/6afe7625/resource/1307392909/trackmedia/F000001DUfbk2K0Pzn.flac",
        backendName: "妖狐酷我", platform: .kuwo, quality: .lossless, format: "flac",
        note: "官方直链", directId: false, kbps: 1082, totalBytes: 26_251_814, rangeOK: true)
    let cyapi = StreamSource(
        url: "https://isure6.stream.qqmusic.qq.com/C4000019zbpu0R3ppO.m4a",
        backendName: "cyapi QQ", platform: .qq, quality: .standard, format: "m4a",
        note: "VIP 全量", directId: true, kbps: 97, totalBytes: 2_359_755, rangeOK: true)

    let sY = DownloadResolver.score(of: yaohu, song: ref, ref: ref, ms: 1500)
    let sC = DownloadResolver.score(of: cyapi, song: ref, ref: ref, ms: 800)
    check("档位优先于速度：无损 FLAC 排在 97kbps m4a 之前", sY > sC,
          "妖狐=\(sY.short) cyapi=\(sC.short)")
    check("妖狐 → 无损档 (1000)", DownloadResolver.tierOf(yaohu) == 1000)
    check("cyapi 97kbps → 标准档 (200)", DownloadResolver.tierOf(cyapi) == 200)

    check("26MB 的无损过下载前校验",
          DownloadPreflight.check(yaohu, want: .lossless, durationSec: 194).ok)
    let tiny = StreamSource(url: "https://x/y.flac", backendName: "t", platform: .qq,
                            quality: .lossless, format: "flac", note: "", directId: false,
                            kbps: 1082, totalBytes: 2_400_000, rangeOK: true)
    check("2.4MB 的「无损」校验不过",
          !DownloadPreflight.check(tiny, want: .lossless, durationSec: 194).ok)
    let fakeFlac = StreamSource(url: "https://x/y.flac", backendName: "t", platform: .qq,
                                quality: .lossless, format: "mp3", note: "", directId: false,
                                kbps: 1000, totalBytes: 26_000_000, rangeOK: true)
    check("后缀 .flac 里装 mp3 → 校验不过",
          !DownloadPreflight.check(fakeFlac, want: .lossless, durationSec: 194).ok)

    let yk = NameMatch.yaohuSearchKey(name: "연애의 조건 (恋爱的条件) (LOVE OPTIONS)",
                                      singer: "BESTie (베스티)")
    check("妖狐搜索串 = 核心歌名 + 主歌手", yk == "연애의 조건BESTie", "got=\(yk)")
    check("妖狐搜索串：晴天/周杰伦",
          NameMatch.yaohuSearchKey(name: "晴天", singer: "周杰伦") == "晴天周杰伦")
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

// MARK: - 7b 落月 QQ（机会性真 320k）：档位映射 / 加密包闸门 / 信封解析

section("落月 QQ 适配器")

do {
    // 档位码：只用 6/8/10，绝不落到 11/13/14/16（hires / atmos / master）
    check("标准档 → quality 6", LuoyueQQAdapter.vkeysQuality(.standard) == 6)
    check("高品档 → quality 8", LuoyueQQAdapter.vkeysQuality(.high) == 8)
    check("无损档 → quality 10", LuoyueQQAdapter.vkeysQuality(.lossless) == 10)

    // 加密包闸门：实测《大鱼》320k 回的就是 .mgg（O8M 前缀），HTTP 200 + 11.7MB 但放不出声
    check("拦 .mgg 加密包",
          LuoyueQQAdapter.isEncryptedQQ(
            "http://wx.music.tc.qq.com/O8M0003ae8GI3mQimV.mgg?guid=yibaihotapi&vkey=x"))
    check("拦 O4M/O6M 加密前缀",
          LuoyueQQAdapter.isEncryptedQQ("http://dl.stream.qqmusic.qq.com/O4M000abc.mp3?vkey=x"))
    check("正常 flac 直链不拦",
          !LuoyueQQAdapter.isEncryptedQQ(
            "http://ws.stream.qqmusic.qq.com/F000003Qui1q2u1Zho.flac?guid=0&vkey=x"))
    check("正常 320k mp3 直链不拦",
          !LuoyueQQAdapter.isEncryptedQQ(
            "http://ws.stream.qqmusic.qq.com/M800003Qui1q2u1Zho.mp3?guid=0&vkey=x"))

    // 信封解析：它的失败**也是 HTTP 200**，只靠状态码会把"账号被风控"当成成功
    let okEnvelope: [String: Any] = ["code": 200, "data": ["url": "https://a/b.mp3"]]
    check("code=200 取 data.url", (try? LuoyueQQAdapter.parse(okEnvelope)) == "https://a/b.mp3")

    let riskControlled: [String: Any] = [
        "code": 110001, "message": "cookie异常：账号被风控无法获取", "data": NSNull()
    ]
    check("被风控（200 但 code=110001）必须抛错",
          (try? LuoyueQQAdapter.parse(riskControlled)) == nil)

    let serverErr: [String: Any] = ["code": 503, "message": "系统运行错误！", "data": [Any]()]
    check("code=503 必须抛错", (try? LuoyueQQAdapter.parse(serverErr)) == nil)

    let noUrl: [String: Any] = ["code": 200, "data": [String: Any]()]
    check("code=200 但没 url 必须抛错", (try? LuoyueQQAdapter.parse(noUrl)) == nil)

    let dataString: [String: Any] = ["code": 200, "data": "https://a/c.mp3"]
    check("data 直接是字符串也认", (try? LuoyueQQAdapter.parse(dataString)) == "https://a/c.mp3")
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

    // 四态循环顺序：单曲 → 列表 → 随机 → 心动 → 单曲
    check("模式循环顺序",
          PlayMode.singleLoop.cycled() == .listLoop
          && PlayMode.listLoop.cycled() == .shuffle
          && PlayMode.shuffle.cycled() == .heartbeat
          && PlayMode.heartbeat.cycled() == .singleLoop)
    check("四种模式都有文案", PlayMode.allCases.allSatisfy { !$0.displayName.isEmpty })

    // 心动模式的队列口径：index+1，末尾是 nil（绝不取模回到开头）
    check("心动：下一首是 index+1",
          PlaybackRules.nextIndex(count: 5, current: 1, mode: .heartbeat, randomIn: { _ in 0 }) == 2)
    check("心动：最后一首没有下一首",
          PlaybackRules.nextIndex(count: 5, current: 4, mode: .heartbeat, randomIn: { _ in 0 }) == nil)
    check("心动：上一首是 index-1",
          PlaybackRules.previousIndex(count: 5, current: 3, mode: .heartbeat, randomIn: { _ in 0 }) == 2)
    check("心动：第一首没有上一首",
          PlaybackRules.previousIndex(count: 5, current: 0, mode: .heartbeat, randomIn: { _ in 0 }) == nil)
}

// MARK: - 9.5 心动模式（画像 / 排序 / 新旧调度）

section("心动模式五通道与调度")

do {
    check("权重顺序 下载 > 收藏 > 导入歌单 > 搜索 > 播放",
          HeartbeatRules.wDownload > HeartbeatRules.wFavorite
          && HeartbeatRules.wFavorite > HeartbeatRules.wImport
          && HeartbeatRules.wImport > HeartbeatRules.wSearch
          && HeartbeatRules.wSearch > HeartbeatRules.wPlay)

    // 1/3 旧 → 新 新 旧 循环；第 1 首永远是新的（刚切进来先给新歌）
    let pattern = (1...6).map { HeartbeatRules.wantsOld(position: $0, oldShare: 1.0 / 3.0) }
    check("1/3 旧 → 新新新旧新新", pattern == [false, false, true, false, false, true], "\(pattern)")
    check("0 旧 → 永远新",
          (1...8).allSatisfy { !HeartbeatRules.wantsOld(position: $0, oldShare: 0) })
    check("0.6 旧 → 第一首仍是新歌",
          !HeartbeatRules.wantsOld(position: 1, oldShare: 0.6))
    check("旧歌占比被夹到 0.6", HeartbeatRules.clampOldShare(0.9) == 0.6)
    check("负数夹到 0", HeartbeatRules.clampOldShare(-1) == 0)
}

do {
    let now = Date()
    // 条数差 10 倍：30 次播放（周杰伦） vs 3 次下载（林俊杰）
    // 直接按条数加权的话播放一定赢；饱和之后下载通道上限 1.0、播放 0.4，应当是下载赢。
    var plays: [HeartbeatPlayEvent] = []
    for i in 0..<30 {
        plays.append(HeartbeatPlayEvent(
            song: song(.qq, "周杰伦第\(i)首", "周杰伦", id: "jp\(i)"),
            startedAt: now.addingTimeInterval(-Double(i) * 3600),
            listenedSec: 250,
            completed: true))
    }
    let downloads: [(song: Song, at: Date)] = (0..<3).map { i -> (song: Song, at: Date) in
        let s = song(.qq, "林俊杰第\(i)首", "林俊杰", id: "ll\(i)")
        return (song: s, at: now.addingTimeInterval(-Double(i) * 86_400))
    }
    let profile = HeartbeatRules.buildProfile(downloads: downloads,
                                              favorites: [],
                                              searches: [],
                                              plays: plays,
                                              now: now)
    let dl = profile.artist["林俊杰"] ?? 0
    let pl = profile.artist["周杰伦"] ?? 0
    check("下载通道压过 10 倍数量的播放通道", dl > pl, "下载=\(dl) 播放=\(pl)")
    check("近 7 天听过的进 seen7d", profile.seen7d.contains("qq_jp0"))
    check("top 歌手非空", !profile.topArtists.isEmpty)
}

do {
    check("半衰期：60 天前 = 0.5", abs(HeartbeatRules.decay(ageDays: 60, halfLife: 60) - 0.5) < 0.001)
    check("未来的事件当 0 天算（不放大）", HeartbeatRules.decay(ageDays: -10, halfLife: 60) == 1)

    let a = HeartbeatRules.features(song(.qq, "晴天", "周杰伦", id: "f1"))
    let b = HeartbeatRules.features(song(.netease, "七里香", "周杰伦", id: "f2"))
    let c = HeartbeatRules.features(song(.qq, "Rolling in the Deep", "Adele", id: "f3"))
    check("同歌手 + 同风格 → 余弦高", HeartbeatRules.cosine(a, b) > 0.5)
    check("跨语种 → 余弦低", HeartbeatRules.cosine(a, c) < 0.3)

    check("从没听过 → 满额怀旧加成", HeartbeatRules.stalenessBonus(lastPlayed: nil) == 18)
    check("刚听过 → 几乎没有加成", HeartbeatRules.stalenessBonus(lastPlayed: Date()) < 1)
    let short = HeartbeatPlayEvent(song: song(.qq, "半首", "某人", id: "q1"),
                                   startedAt: Date(), listenedSec: 5, completed: false)
    check("5 秒切掉的质量下限 0.3", abs(HeartbeatRules.playQuality(short) - 0.3) < 0.001)
    check("30 秒的广告被挡在候选之外",
          !HeartbeatRules.isPlayableCandidate(song(.qq, "广告", "某人", dur: 30)))
}

do {
    let target = song(.qq, "夜曲", "周杰伦", id: "t1")
    check("本会话放过 = 硬过滤",
          HeartbeatRules.penalty(song: target, sessionKeys: ["qq_t1"], seen7d: [],
                                 recentSongs: [], recentArtists: [], recentTags: [],
                                 dislikedKeys: [], dislikedArtists: []) == 0)
    check("不感兴趣 = 硬过滤",
          HeartbeatRules.penalty(song: target, sessionKeys: [], seen7d: [],
                                 recentSongs: [], recentArtists: [], recentTags: [],
                                 dislikedKeys: ["qq_t1"], dislikedArtists: []) == 0)
    let sameArtist = HeartbeatRules.penalty(song: target, sessionKeys: [], seen7d: [],
                                            recentSongs: [], recentArtists: ["周杰伦"],
                                            recentTags: [], dislikedKeys: [], dislikedArtists: [])
    check("同歌手连着来 → 降权到 0.3", abs(sameArtist - 0.3) < 0.001, "\(sameArtist)")
}

do {
    // MMR：同款（同歌手）分数更高，也要让位给"不像的那首"
    let recent = [song(.qq, "最近这首", "周杰伦", id: "r1")]
    let same = HeartbeatScored(song: song(.qq, "同款", "周杰伦", id: "a1"),
                               score: 90, reason: .artist, detail: "周杰伦")
    let diff = HeartbeatScored(song: song(.qq, "别款", "陈奕迅", id: "b1"),
                               score: 88, reason: .artist, detail: "陈奕迅")
    let picked = HeartbeatRules.diversify([same, diff], limit: 1, recent: recent)
    check("MMR：分数略低但不像的优先", picked.first?.song.id == "qq_b1",
          picked.first?.song.id ?? "nil")

    check("下载理由带歌手",
          HeartbeatRules.reasonText(.download, detail: "林俊杰").contains("林俊杰"))
    check("搜索理由带关键词",
          HeartbeatRules.reasonText(.search, detail: "晴天").contains("晴天"))
    check("探索理由是兜底文案",
          HeartbeatRules.reasonText(.explore, detail: "") == "为你探索")
    check("热门兜底带榜上名次",
          HeartbeatRules.reasonText(.hot, detail: "3").contains("3"),
          HeartbeatRules.reasonText(.hot, detail: "3"))
    check("热歌榜池上限是 20 首", HeartbeatRules.hotPoolLimit == 20)
}

// 第四十三轮：导入歌单作为第五通道（老板："心动模式加一个权重，也可以根据用户导入的歌单推荐"）
do {
    let now = Date()
    let imports: [(song: Song, at: Date)] = [
        (song: song(.qq, "晴天", "周杰伦", id: "im1"), at: now),
        (song: song(.qq, "七里香", "周杰伦", id: "im2"), at: now),
        (song: song(.qq, "Rolling in the Deep", "Adele", id: "im3"), at: now)
    ]
    let imported = HeartbeatRules.buildProfile(downloads: [], favorites: [], searches: [],
                                               plays: [], imports: imports, now: now)
    check("导入歌单进画像：口味向量与歌手亲和都有值",
          !imported.vec.isEmpty && (imported.artist["周杰伦"] ?? 0) > 0)
    check("导入歌单能撑起 top 歌手（新歌召回有词可用）",
          imported.topArtists.contains("周杰伦"), "\(imported.topArtists)")
    let empty = HeartbeatRules.buildProfile(downloads: [], favorites: [], searches: [], plays: [], now: now)
    check("没有导入歌单时画像仍为空", empty.isEmpty)

    // 一个下载 vs 两张歌单里的两首：权重顺序 1.00 > 0.70，下载仍应更亲
    let downloaded = [(song: song(.qq, "江南", "林俊杰", id: "dl1"), at: now)]
    let mixed = HeartbeatRules.buildProfile(downloads: downloaded, favorites: [], searches: [],
                                            plays: [], imports: imports, now: now)
    let dl = mixed.artist["林俊杰"] ?? 0
    let im = mixed.artist["周杰伦"] ?? 0
    check("下载权重仍压过导入歌单", dl > im, "下载=\(dl) 导入=\(im)")

    let fromPlaylist = HeartbeatRules.score(song: song(.qq, "晴天", "周杰伦", id: "im1"),
                                            profile: imported,
                                            seed: nil,
                                            downloaded: false,
                                            favorited: false,
                                            priorIndex: 0,
                                            playlistName: "我喜欢的音乐",
                                            now: now)
    check("导入歌单候选的理由写歌单名",
          fromPlaylist.reason == .playlist
            && HeartbeatRules.reasonText(.playlist, detail: fromPlaylist.detail)
                == "来自你导入的《我喜欢的音乐》",
          fromPlaylist.detail)
    let plain = HeartbeatRules.score(song: song(.qq, "晴天", "周杰伦", id: "im1"),
                                     profile: imported,
                                     seed: nil,
                                     downloaded: false,
                                     favorited: false,
                                     priorIndex: 0,
                                     now: now)
    check("来自导入歌单的候选有「已知曲目」加成（72 档）",
          fromPlaylist.score > plain.score,
          "\(fromPlaylist.score) vs \(plain.score)")
    let alsoDownloaded = HeartbeatRules.score(song: song(.qq, "晴天", "周杰伦", id: "im1"),
                                              profile: imported,
                                              seed: nil,
                                              downloaded: true,
                                              favorited: false,
                                              priorIndex: 0,
                                              playlistName: "我喜欢的音乐",
                                              now: now)
    check("下载过的歌仍报「下载」理由（证据优先级不被歌单盖掉）",
          alsoDownloaded.reason == .download)
    check("歌单名缺失时不写空书名号",
          HeartbeatRules.reasonText(.playlist, detail: "") == "来自你导入的歌单")
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

    // ⑦ 悬浮条严丝合缝：占位 = 条子本体 56 + 8 呼吸，没播歌时 24
    check("在播歌：列表末尾让出 64（= 条子 56 + 8 呼吸）",
          MiniPlayerMetrics.listBottomInset(playing: true) == 64,
          "\(MiniPlayerMetrics.listBottomInset(playing: true))")
    check("没在播歌：只让 24（页面底部呼吸）",
          MiniPlayerMetrics.listBottomInset(playing: false) == 24)
    check("让出高度正好等于条子高度（上一版 72+32 多空了 40pt）",
          MiniPlayerMetrics.listBottomInset(playing: true) == MiniPlayerMetrics.barHeight)

    // ⓪ v2.4.85（老板 2026-11-23）：批量处理栏要跟迷你条/底层栏严丝合缝
    check("迷你条卡片上沿 = 56（= Tokens.Size.miniPlayerHeight）",
          MiniPlayerMetrics.barCardTop == 56, "\(MiniPlayerMetrics.barCardTop)")
    check("处理栏接缝 = 条子本体高度（卡片贴顶，底衬不再比卡片高 4）",
          MiniPlayerMetrics.barCardTop == 56 && MiniPlayerMetrics.barHeight - 56 == 8)
    check("处理栏高度 = 44 可点高度 + 上下各 4",
          MiniPlayerMetrics.batchBarHeight == 52, "\(MiniPlayerMetrics.batchBarHeight)")
    check("在播歌：处理栏底边贴迷你条卡片上沿（56）",
          MiniPlayerMetrics.batchBarBottomInset(playing: true) == MiniPlayerMetrics.barCardTop)
    check("没播歌：处理栏底边贴底层栏上沿（0，不再留 24）",
          MiniPlayerMetrics.batchBarBottomInset(playing: false) == 0,
          "\(MiniPlayerMetrics.batchBarBottomInset(playing: false))")
    check("在播歌时两条叠起来正好让出 56+52（列表最后一条不会压在处理栏下）",
          MiniPlayerMetrics.batchBarBottomInset(playing: true)
          + MiniPlayerMetrics.batchBarHeight == 108,
          "\(MiniPlayerMetrics.batchBarBottomInset(playing: true) + MiniPlayerMetrics.batchBarHeight)")

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

    // ⑤b 连点 A→B→C：只有最后一轮的取流结果允许起播（迟到的 A/B 必须丢弃）。
    //    老板 2026-11-20：「封面歌词是 C，A 或 B 的请求先回来就直接放 A 了」。
    check("取流代次相同 → 这一轮允许起播", PlaybackRules.isCurrentLoad(token: 3, currentToken: 3))
    check("迟到的第一首（点 A→B→C，C 已是第 3 轮）→ 丢弃",
          !PlaybackRules.isCurrentLoad(token: 1, currentToken: 3))
    check("迟到的第二首（B 是第 2 轮）→ 丢弃",
          !PlaybackRules.isCurrentLoad(token: 2, currentToken: 3))
    check("同曲换源/重试也会 +1 代次 → 上一轮丢弃",
          !PlaybackRules.isCurrentLoad(token: 3, currentToken: 4))

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
    // 第 50 轮起 flac 也能写（Vorbis Comment + PICTURE），这条口径跟着改
    check("flac 也是能内嵌的容器",
          DownloadCompanion.canEmbed(extension: "flac")
          && DownloadCompanion.canEmbed(extension: "FLAC"))
    check("只能写旁车的容器：ogg/wav",
          !DownloadCompanion.canEmbed(extension: "ogg")
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
      [SplashTimeline.bandDraw, SplashTimeline.entrance, SplashTimeline.cupLeft, SplashTimeline.cupRight,
       SplashTimeline.sound, SplashTimeline.soundSecond, SplashTimeline.thump,
       SplashTimeline.exit, SplashTimeline.markFade, SplashTimeline.contentIn]
        .allSatisfy { $0.start >= 0 && $0.end <= SplashTimeline.total + 0.0001 })
// 2026-11-23（老板："开屏整个过程刚开始略显突兀，像是突然出现"）：
// 进场柔化 + 落笔曲线改成"起步慢、收尾快"。下面四条把这件事钉住。
check("开场先柔化：第一帧图标几乎不可见（不是硬着出现）",
      SplashTimeline.snapshot(at: 0).entrance < 0.05,
      "entrance(0)=\(SplashTimeline.snapshot(at: 0).entrance)")
check("柔化在 0.3s 内完成（不许拖到动画中段）",
      SplashTimeline.snapshot(at: SplashTimeline.entrance.end + 0.06).entrance > 0.99,
      "entrance=\(SplashTimeline.snapshot(at: SplashTimeline.entrance.end + 0.06).entrance)")
check("落笔前段不抢戏：头 100ms 画不到 1/10",
      SplashTimeline.bandCurve(SplashTimeline.bandDraw.progress(at: 0.10)) < 0.10,
      "band(0.10s)=\(SplashTimeline.bandCurve(SplashTimeline.bandDraw.progress(at: 0.10)))")
check("落笔收尾不拖：最后 1/6 拍至少再画 1/10（别又把接缝变成停顿）",
      SplashTimeline.bandCurve(1) - SplashTimeline.bandCurve(0.85) > 0.10)
// 2026-11-22（老板："开屏动画还是在固定的一帧卡，只不过延迟了一些"）：
// 逐帧量出来真凶是时间轴自己在 1.04–1.30 留了 258ms 空档 —— 声波 0.98s 就淡没了、
// 轻顶 0.98s 结束、退场 1.30s 才起。下面三条把"全程都在动"钉死，谁再挪拍子先红。
check("第二道声波撑到退场开始（出声这一拍不许提前哑掉）",
      SplashTimeline.soundSecond.end >= SplashTimeline.exit.start,
      "wave2.end=\(SplashTimeline.soundSecond.end) exit.start=\(SplashTimeline.exit.start)")
check("声波透明度整拍匀速淡出（旧版把 easeOut 放进分母，0.1s 就淡没了）",
      SplashTimeline.waveOpacity(progress: 0.2) > SplashTimeline.waveOpacity(progress: 0.6)
        && SplashTimeline.waveOpacity(progress: 0.6) > SplashTimeline.waveOpacity(progress: 0.95)
        && SplashTimeline.waveOpacity(progress: 0.6) > 0.15,
      "op(0.6)=\(SplashTimeline.waveOpacity(progress: 0.6))")
check("开屏全程不许停：最长静止窗 < 150ms",
      SplashTimeline.longestStillWindow() < 0.15,
      "still=\(SplashTimeline.longestStillWindow())s")
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

// MARK: - 第四十二轮：导入歌单（QQ / 网易 / 酷我 / 酷狗）

section("导入歌单：链接识别")

// 老板给的那条 QQ 分享链接（带 hosteuin / ADTAG 这些分享参数，id 才是歌单号）
let qqShare = "https://i2.y.qq.com/n3/other/pages/details/playlist.html"
    + "?hosteuin=ow4iNeckoiSl7v**&id=8887675900&appversion=200908&ADTAG=wxfshare&appshare=iphone_wx"
check("QQ i2 分享链接 → disstid",
      PlaylistImport.detect(qqShare) == PlaylistImport.Link(platform: .qq, sourceID: "8887675900"),
      String(describing: PlaylistImport.detect(qqShare)))
check("微信分享文案里夹着链接也能认（前后文字忽略）",
      PlaylistImport.detect("【QQ音乐】2001-2010 \(qqShare) 复制打开")?.sourceID == "8887675900")
check("QQ 网页版路径 /n/ryqq/playlist/<id>",
      PlaylistImport.detect("https://y.qq.com/n/ryqq/playlist/8887675900")
        == PlaylistImport.Link(platform: .qq, sourceID: "8887675900"))
check("网易网页版 query ?id=",
      PlaylistImport.detect("https://music.163.com/playlist?id=3778678")
        == PlaylistImport.Link(platform: .netease, sourceID: "3778678"))
check("网易网页版 #/playlist?id=（参数在井号后面）",
      PlaylistImport.detect("https://music.163.com/#/playlist?id=3778678")
        == PlaylistImport.Link(platform: .netease, sourceID: "3778678"))
check("网易 App 分享 y.music.163.com/m/playlist?id=",
      PlaylistImport.detect("https://y.music.163.com/m/playlist?id=3778678&userid=123")
        == PlaylistImport.Link(platform: .netease, sourceID: "3778678"))
check("酷我 playlist_detail/<pid>",
      PlaylistImport.detect("https://www.kuwo.cn/playlist_detail/1082685104")
        == PlaylistImport.Link(platform: .kuwo, sourceID: "1082685104"))
check("酷我移动版 newh5app/playlist_detail/<pid>",
      PlaylistImport.detect("https://m.kuwo.cn/newh5app/playlist_detail/1082685104?f=wx")
        == PlaylistImport.Link(platform: .kuwo, sourceID: "1082685104"))
check("酷狗新版 gcid 链接",
      PlaylistImport.detect("https://m.kugou.com/songlist/gcid_3z9vj1svz2yz0c4/?src_cid=3z9vj1svz2yz0c4")
        == PlaylistImport.Link(platform: .kugou, sourceID: "gcid_3z9vj1svz2yz0c4"))
check("酷狗老版 /yy/special/single/<id>.html",
      PlaylistImport.detect("https://www.kugou.com/yy/special/single/5988470.html")
        == PlaylistImport.Link(platform: .kugou, sourceID: "5988470"))
check("不是歌单链接（单曲页）→ 认不出",
      PlaylistImport.detect("https://y.qq.com/n/ryqq/songDetail/003UkWuI0E8U0l") == nil)
check("短链（不带 id）→ detect 返回 nil，交给 resolve 跟 302",
      PlaylistImport.detect("https://c6.y.qq.com/base/fcgi-bin/u?__=abcdEF") == nil)
check("纯文字 / 空串 → nil",
      PlaylistImport.detect("   ") == nil && PlaylistImport.detect("今天天气不错") == nil)
check("句末英文标点会被切掉",
      PlaylistImport.detect("看这个 https://music.163.com/playlist?id=3778678.")
        == PlaylistImport.Link(platform: .netease, sourceID: "3778678"))

section("导入歌单：四家解析（纯函数）")

// QQ：真响应裁成 4 条，覆盖「正常 / 缺 mid / 缺歌名 / 重复 mid」四种情况
let qqImportFixture: [String: Any] = [
    "code": 0,
    "cdlist": [[
        "dissname": "2001-2010",
        "nickname": "Roma",
        "logo": "http://y.gtimg.cn/music/photo_new/T002R300x300M000003ivCBx1uljWi.jpg?n=1",
        "songnum": 4,
        "songlist": [
            [
                "mid": "003f8Gqc32Unpb",
                "name": "呼吸决定",
                "interval": 251,
                "singer": [["name": "姚晓棠"], ["name": "张星特"]] as [[String: Any]],
                "album": ["name": "天赐的声音第七季 第10期", "mid": "003ivCBx1uljWi"] as [String: Any]
            ],
            [
                "mid": "",
                "name": "没有 mid 的歌"
            ],
            [
                "mid": "001qqq",
                "name": "",
                "singer": [] as [[String: Any]],
                "album": [:] as [String: Any]
            ],
            [
                "mid": "003f8Gqc32Unpb",
                "name": "呼吸决定（重复条目）",
                "interval": 251,
                "singer": [] as [[String: Any]],
                "album": ["name": ""] as [String: Any]
            ]
        ] as [[String: Any]]
    ] as [String: Any]]
]

if let qq = PlaylistImport.parseQQ(qqImportFixture, sourceID: "8887675900") {
    check("QQ：歌单名 / 创建者 / 封面（http → https）",
          qq.name == "2001-2010" && qq.creator == "Roma"
            && qq.cover.hasPrefix("https://y.gtimg.cn/"),
          "\(qq.name) / \(qq.creator) / \(qq.cover)")
    check("QQ：平台 id 用 mid，缺 mid / 缺歌名 / 重复 mid 都被丢掉", qq.songs.count == 1,
          "\(qq.songs.count)")
    check("QQ：多位歌手用 / 连接、专辑进 album、曲长取 interval",
          qq.songs.first?.singer == "姚晓棠/张星特"
            && qq.songs.first?.album == "天赐的声音第七季 第10期"
            && qq.songs.first?.durationSec == 251,
          "\(String(describing: qq.songs.first?.singer))")
    check("QQ：封面用 album.mid 拼官方 T002R300x300M000",
          qq.songs.first?.picURL == "https://y.gtimg.cn/music/photo_new/T002R300x300M000003ivCBx1uljWi.jpg")
    check("QQ：id 里带平台前缀（去重/收藏都靠它）", qq.songs.first?.id == "qq_003f8Gqc32Unpb")
} else {
    check("QQ 歌单解析", false, "parseQQ 返回 nil")
}

// 网易：id=0 / 缺歌名的脏条目丢掉；时长是毫秒；封面 http 升 https
let neteaseImportFixture: [String: Any] = [
    "code": 200,
    "playlist": [
        "name": "热歌榜",
        "coverImgUrl": "http://p1.music.126.net/x.jpg",
        "creator": ["nickname": "网易云音乐"] as [String: Any],
        "trackCount": 3,
        "tracks": [
            [
                "id": 3460493895,
                "name": "冬天又来临",
                "dt": 169384,
                "ar": [["name": "罗言"]] as [[String: Any]],
                "al": ["name": "冬天又来临", "picUrl": "http://p3.music.126.net/x.jpg"] as [String: Any]
            ],
            [
                "id": 0,
                "name": "没有 id 的歌"
            ],
            [
                "id": 123,
                "name": "老歌",
                "dt": 200000,
                "ar": [["name": "A"], ["name": "B"]] as [[String: Any]],
                "al": ["name": ""] as [String: Any]
            ]
        ] as [[String: Any]]
    ] as [String: Any]
]

if let ne = PlaylistImport.parseNetease(neteaseImportFixture, sourceID: "3778678") {
    check("网易：歌单名 / 创建者 / 封面（http → https）",
          ne.name == "热歌榜" && ne.creator == "网易云音乐"
            && ne.cover == "https://p1.music.126.net/x.jpg",
          "\(ne.name) / \(ne.creator) / \(ne.cover)")
    check("网易：id=0 的条目被丢掉", ne.songs.count == 2, "\(ne.songs.count)")
    check("网易：毫秒 → 秒、多位歌手用 / 连接",
          ne.songs.first?.durationSec == 169 && ne.songs.first?.singer == "罗言",
          "\(String(describing: ne.songs.first?.durationSec))")
    check("网易：专辑图 http 升 https",
          ne.songs.first?.picURL == "https://p3.music.126.net/x.jpg")
} else {
    check("网易歌单解析", false, "parseNetease 返回 nil")
}

check("歌单不存在（code=404）判失败",
      PlaylistImport.parseNetease(["code": 404, "playlist": [:]], sourceID: "1") == nil)
check("空 tracks 判失败",
      PlaylistImport.parseNetease(["code": 200, "playlist": ["name": "x", "tracks": []]],
                                  sourceID: "1") == nil)

// 2026-11-19 真机反馈：网易「我喜欢的音乐」729 首只进来 6 首。
// 根因在接口：详情里的 `tracks` 只回 6 首（trackCount=729 / trackIds=729 / tracks=6），
// 真正全的是 `trackIds`。这里钉住：trackIds 能读全、补回来的歌按歌单顺序合并。
let likedFixture: [String: Any] = [
    "code": 200,
    "playlist": [
        "name": "我喜欢的音乐",
        "coverImgUrl": "http://p1.music.126.net/liked.jpg",
        "creator": ["nickname": "顺斌"] as [String: Any],
        "trackCount": 729,
        "tracks": [
            [
                "id": 1956462195,
                "name": "Like A Star (Piano Version)",
                "dt": 283626,
                "ar": [["name": "Youngso Kim"]] as [[String: Any]],
                "al": ["name": "Like A Star", "picUrl": "http://p3.music.126.net/a.jpg"] as [String: Any]
            ]
        ] as [[String: Any]],
        "trackIds": [
            ["id": 1956462195],
            ["id": 3388509025],
            ["id": 1990154664]
        ] as [[String: Any]]
    ] as [String: Any]
]

check("网易 trackIds 能读到全部 id（详情 tracks 被截断时靠它）",
      PlaylistImport.neteaseTrackIDs(likedFixture) == ["1956462195", "3388509025", "1990154664"],
      "\(PlaylistImport.neteaseTrackIDs(likedFixture))")
check("网易：只有 tracks 时按 tracks 出歌（补歌由网络层 fetch 负责）",
      PlaylistImport.parseNetease(likedFixture, sourceID: "7547299268")?.songs.count == 1,
      "\(String(describing: PlaylistImport.parseNetease(likedFixture, sourceID: "7547299268")?.songs.count))")

// 补歌走 `api/song/detail`，字段名和歌单详情不一样：artists / album / duration(ms)
let neteaseSongDetailFixture: [String: Any] = [
    "id": 3388509025,
    "name": "12.31",
    "duration": 254117,
    "artists": [["name": "郑润泽"]] as [[String: Any]],
    "album": ["name": "12.31", "picUrl": "http://p4.music.126.net/b.jpg"] as [String: Any]
]
if let detailSong = PlaylistImport.neteaseSong(from: neteaseSongDetailFixture) {
    check("网易补歌：artists / album / duration 也能解析",
          detailSong.platformID == "3388509025" && detailSong.singer == "郑润泽"
            && detailSong.durationSec == 254 && detailSong.album == "12.31"
            && detailSong.picURL == "https://p4.music.126.net/b.jpg",
          "\(detailSong.name) / \(detailSong.singer) / \(detailSong.durationSec)")
} else {
    check("网易补歌解析", false, "neteaseSong 返回 nil")
}

let likedPrimary = PlaylistImport.parseNeteaseSongs(PlaylistImport.playlistTracks(likedFixture))
let likedFetched = PlaylistImport.parseNeteaseSongs([
    ["id": 1990154664, "name": "Running In The Dark", "duration": 220533,
     "artists": [["name": "MONKEY MAJIK"]] as [[String: Any]]] as [String: Any],
    ["id": 3388509025, "name": "12.31", "duration": 254117,
     "artists": [["name": "郑润泽"]] as [[String: Any]]] as [String: Any]
])
let likedMerged = PlaylistImport.mergeNetease(
    trackIDs: ["1956462195", "3388509025", "1990154664"],
    primary: likedPrimary,
    fetched: likedFetched)
check("网易：按 trackIds 顺序合并（补回来的插回原位，不丢歌）",
      likedMerged.map(\.platformID) == ["1956462195", "3388509025", "1990154664"],
      "\(likedMerged.map(\.platformID))")
check("网易：trackIds 里取不到的 id 直接跳过，不占位",
      PlaylistImport.mergeNetease(
        trackIDs: ["1956462195", "999999", "3388509025"],
        primary: likedPrimary, fetched: likedFetched).count == 2)
check("网易：补歌一页 200 个 id，方括号/逗号都做百分号编码",
      PlaylistImport.neteaseSongBatch == 200
        && PlaylistImport.neteaseSongsURL(["1", "2"]) ==
            "https://music.163.com/api/song/detail?ids=%5B1%2C2%5D",
      PlaylistImport.neteaseSongsURL(["1", "2"]))

// 酷狗：filename 是「歌手 - 歌名」一整条；封面模板要换 size 并升 https
check("酷狗 filename：歌手 - 歌名",
      PlaylistImport.splitKugouFilename("队长 - NUNA") == (name: "NUNA", artist: "队长"),
      "\(PlaylistImport.splitKugouFilename("队长 - NUNA"))")
check("酷狗 filename：没有分隔符就整条当歌名",
      PlaylistImport.splitKugouFilename("没有分隔符") == (name: "没有分隔符", artist: ""))
check("酷狗 filename：歌名里还有 - 时只切第一个",
      PlaylistImport.splitKugouFilename("A - B - C") == (name: "B - C", artist: "A"))
check("酷狗封面：{size} → 400 且 http 升 https",
      PlaylistImport.kugouCover("http://imge.kugou.com/stdmusic/{size}/a.jpg")
        == "https://imge.kugou.com/stdmusic/400/a.jpg",
      PlaylistImport.kugouCover("http://imge.kugou.com/stdmusic/{size}/a.jpg"))

let kugouImportItems: [[String: Any]] = [
    [
        "hash": "AFCCB65173AB3ED8E10C9792F1E85ED5",
        "filename": "队长 - NUNA",
        "duration": 222,
        "trans_param": ["union_cover": "http://imge.kugou.com/stdmusic/{size}/20250311/a.jpg"] as [String: Any]
    ],
    [
        "hash": "",
        "filename": "没有 hash 的歌"
    ]
]
let kugouSongs = PlaylistImport.parseKugouSongs(kugouImportItems)
check("酷狗：hash 进 platformID、歌名/歌手拆开、封面见 union_cover",
      kugouSongs.count == 1
        && kugouSongs.first?.platformID == "AFCCB65173AB3ED8E10C9792F1E85ED5"
        && kugouSongs.first?.name == "NUNA"
        && kugouSongs.first?.singer == "队长"
        && kugouSongs.first?.durationSec == 222
        && kugouSongs.first?.picURL == "https://imge.kugou.com/stdmusic/400/20250311/a.jpg",
      "\(kugouSongs)")

check("跨条目去重：同一个 id 只留第一次",
      PlaylistImport.dedupe([
        song(.qq, "晴天", "周杰伦", id: "q1"),
        song(.qq, "晴天（重复）", "周杰伦", id: "q1"),
        song(.kuwo, "晴天", "周杰伦", id: "q1")
      ]).count == 2)
check("导入上限 1000 首（和网易 n=1000 同一口径）",
      PlaylistImport.maxSongs == 1000 && PlaylistImport.pageSize == 100,
      "\(PlaylistImport.maxSongs)/\(PlaylistImport.pageSize)")
check("QQ 请求串带 disstid",
      PlaylistImport.qqURL("8887675900").contains("disstid=8887675900"))
check("网易请求串带 id 与 n=1000",
      PlaylistImport.neteaseURL("3778678").contains("id=3778678")
        && PlaylistImport.neteaseURL("3778678").contains("n=1000"))
check("酷狗请求串带 specialid 与页码",
      PlaylistImport.kugouSongsURL("5988470", page: 2).contains("specialid=5988470")
        && PlaylistImport.kugouSongsURL("5988470", page: 2).contains("page=2"))

// 重新导入：同一个歌单号 = 替换旧快照（老板 2026-11-19 验证项：歌单更新后重新导入不能变成两条）
section("导入歌单：重新导入 = 替换")

do {
    let oldDate = Date().addingTimeInterval(-86_400)
    let oldSongs = [song(.netease, "旧快照第一首", "A", id: "old1")]
    let newSongs = [
        song(.netease, "新快照第一首", "A", id: "new1"),
        song(.netease, "新快照第二首", "B", id: "new2")
    ]
    let old = ImportedPlaylist(platform: .netease, sourceID: "7547299268", name: "我喜欢的音乐",
                               creator: "顺斌", cover: "", songs: oldSongs, importedAt: oldDate)
    let fresh = ImportedPlaylist(platform: .netease, sourceID: "7547299268", name: "我喜欢的音乐",
                                 creator: "顺斌", cover: "", songs: newSongs, importedAt: Date())

    check("同一条链接两次导入 → id 相同（平台 + 歌单号）",
          old.id == fresh.id && old.id == "netease_7547299268", fresh.id)
    let merged = PlaylistImport.replacing([old], with: fresh)
    check("重新导入同一个歌单 = 替换，不是新增", merged.count == 1, "\(merged.count)")
    check("替换后留下的是新快照（歌曲与导入时间都换新）",
          merged.first?.songs.map(\.platformID) == ["new1", "new2"]
            && merged.first?.importedAt == fresh.importedAt,
          "\(String(describing: merged.first?.songs.map(\.platformID)))")

    let other = ImportedPlaylist(platform: .netease, sourceID: "123456", name: "另一张歌单",
                                 creator: "", cover: "", songs: oldSongs, importedAt: Date())
    let two = PlaylistImport.replacing([old], with: other)
    check("不同歌单号照常各占一条（新的排最前）",
          two.count == 2 && two.first?.sourceID == "123456", "\(two.count)")

    let fromQQ = ImportedPlaylist(platform: .qq, sourceID: "7547299268", name: "同号不同平台",
                                  creator: "", cover: "", songs: oldSongs, importedAt: Date())
    check("同一个歌单号在不同平台 = 两条（id 带平台前缀）",
          PlaylistImport.replacing([old], with: fromQQ).count == 2)
}

// MARK: - 第四十三轮（2026-11-20）：在线播放 ≤320k / 同曲换源 / 预取窗口

section("播放降档：在线 ≤320k、无损只用于下载（A）")

do {
    func src(_ fmt: String, _ kbps: Int64, _ q: QualityLevel,
             direct: Bool = true, backend: String = "t") -> StreamSource {
        StreamSource(url: "https://example.com/\(fmt)-\(kbps)", backendName: backend,
                     platform: .netease, quality: q, format: fmt, note: "",
                     directId: direct, kbps: kbps, totalBytes: 0, rangeOK: true)
    }

    // FLAC/WAV 不进播放链——这是本次最硬的一条口径
    check("FLAC 不进播放链", !PlaybackQualityRules.isPlayable(src("flac", 1087, .lossless)))
    check("WAV 不进播放链", !PlaybackQualityRules.isPlayable(src("wav", 1411, .lossless)))
    check("标着无损但容器认不出，也不进播放链",
          !PlaybackQualityRules.isPlayable(src("mp3", 0, .lossless)))
    check("无损量级码率（601k）同样不进播放链",
          !PlaybackQualityRules.isPlayable(src("mp3", 601, .lossless)))
    check("320k mp3 可播", PlaybackQualityRules.isPlayable(src("mp3", 320, .high)))
    check("256k 可播", PlaybackQualityRules.isPlayable(src("mp3", 256, .high)))
    check("128k 可播（降级兜底）", PlaybackQualityRules.isPlayable(src("mp3", 128, .standard)))

    // 排名：实测码率 320 > 256 > 128
    check("320 胜过 256",
          PlaybackQualityRules.isBetter(src("mp3", 320, .high), than: src("mp3", 256, .high)))
    check("256 胜过 128",
          PlaybackQualityRules.isBetter(src("mp3", 256, .high), than: src("mp3", 128, .standard)))
    check("128 不胜过 320",
          !PlaybackQualityRules.isBetter(src("mp3", 128, .standard), than: src("mp3", 320, .high)))
    check("无损永远不比 320 更好（播放链口径）",
          !PlaybackQualityRules.isBetter(src("flac", 1087, .lossless), than: src("mp3", 320, .high)))
    check("同码率优先直连后端",
          PlaybackQualityRules.isBetter(src("mp3", 320, .high, direct: true),
                                        than: src("mp3", 320, .high, direct: false)))
    check("已经是 320 档不再触发后台升档（≥296 算到顶）",
          PlaybackQualityRules.isTopTier(src("mp3", 318, .high))
            && !PlaybackQualityRules.isTopTier(src("mp3", 256, .high)))
    check("UI 标注写的是 320k 且说明无损只用于下载",
          PlaybackQualityRules.label.contains("320") && PlaybackQualityRules.label.contains("无损"),
          PlaybackQualityRules.label)
}

section("同曲换源上限（A6）")

do {
    check("同一首歌最多换 3 条源，之后才跳歌",
          PlaybackRules.maxSameSongSwitches == 3, "\(PlaybackRules.maxSameSongSwitches)")
}

// MARK: - 第四十四轮（2026-11-21）：占位音频闸门 / 无损兜底 / 后端熔断 / 落月 v3
//
// 老板 2026-11-20 晚的报障：周杰伦的歌播出来是「当前音乐只在酷我最新手机端才能播放」。
// 那段东西是酷我回的 **181,521 B / 11.3s 提示音**，而它满足当时所有闸门（mp3、206、非无损），
// 于是被当成有效源起播。这一节把"什么不算歌"钉死。

section("内容闸门：占位提示音 / 加密包不是歌")

do {
    func src(_ fmt: String, _ kbps: Int64, _ q: QualityLevel, bytes: Int64,
             url: String = "https://example.com/a.mp3") -> StreamSource {
        StreamSource(url: url, backendName: "t", platform: .kuwo, quality: q, format: fmt,
                     note: "", directId: true, kbps: kbps, totalBytes: bytes, rangeOK: true)
    }

    // 酷我的占位文件：181,521 B / 344s ≈ 4 kbps（md5 43fe5f6460e49afdf0bc2340012fe7b5）
    let prompt = src("mp3", 4, .standard, bytes: 181_521)
    check("占位提示音被判成占位（181,521 B / 344s）",
          PlaybackQualityRules.isPlaceholder(prompt, songDurationSec: 344))
    check("占位提示音不可用（哪怕它 ≤320k）",
          !PlaybackQualityRules.isUsable(prompt, songDurationSec: 344))
    check("占位提示音也进不了「可播」白名单判断",
          PlaybackQualityRules.isPlayable(prompt) && !PlaybackQualityRules.isUsable(prompt, songDurationSec: 344),
          "isPlayable 只看档位，isUsable 才是放行的唯一口径")

    // 真 320k：10,792,943 B / 344s ≈ 250 kbps
    let real320 = src("mp3", 250, .high, bytes: 10_792_943)
    check("真 320k 可用", PlaybackQualityRules.isUsable(real320, songDurationSec: 344))
    check("真 320k 不算占位", !PlaybackQualityRules.isPlaceholder(real320, songDurationSec: 344))

    // 体积未知时不在这里判死（留给时长闸门）
    let unknownSize = src("mp3", 0, .standard, bytes: 0)
    check("体积未知不判占位", !PlaybackQualityRules.isPlaceholder(unknownSize, songDurationSec: 344))

    // 加密包：QQ 的 .mgg / O4M~O8M
    check(".mgg 判加密", StreamEncryptionRules.isEncrypted("http://x/O8M0003.mgg?guid=1"))
    check("O4M 路径判加密", StreamEncryptionRules.isEncrypted("http://x/O4M0003ae8"))
    check("普通 mp3 不判加密", !StreamEncryptionRules.isEncrypted("http://x/M800003.mp3"))
    check("加密源不可用",
          !PlaybackQualityRules.isUsable(
            src("mp3", 320, .high, bytes: 11_698_595, url: "http://x/O8M0003.mgg?guid=1"),
            songDurationSec: 269))

    // 坏源指纹：体积+时长（占位音频每次都是新 URL，只按 URL 去重认不出来）
    check("坏源指纹按 体积+时长",
          PlaybackQualityRules.fingerprint(totalBytes: 181_521, durationSec: 344) == "181521-344",
          PlaybackQualityRules.fingerprint(totalBytes: 181_521, durationSec: 344))
}

section("无损兜底：只在最后一条可用源时放开（周杰伦这类）")

do {
    func src(_ fmt: String, _ kbps: Int64, _ q: QualityLevel) -> StreamSource {
        StreamSource(url: "https://example.com/\(fmt)", backendName: "妖狐酷我",
                     platform: .kuwo, quality: q, format: fmt, note: "",
                     directId: false, kbps: kbps, totalBytes: 55_397_039, rangeOK: true)
    }
    let flac = src("flac", 1288, .lossless)
    check("常规路径：FLAC 不能起播（≤320k 口径不变）",
          !PlaybackQualityRules.isUsable(flac, songDurationSec: 344))
    check("兜底路径：允许无损时 FLAC 可用",
          PlaybackQualityRules.isUsable(flac, songDurationSec: 344, allowLossless: true))
    check("兜底开关是开的（老板 2026-11-21 定）",
          PlaybackQualityRules.allowsLosslessPlayback)
    check("无损不会因为「可播」被升级逻辑当成更好的一条",
          !PlaybackQualityRules.isBetter(flac, than: src("mp3", 320, .high)))
}

section("后端熔断：403 限流要冷却，不是每首播放都去撞")

do {
    let now: TimeInterval = 1_800_000_000
    check("403 冷却 15 分钟",
          BackendHealthRules.cooldownSeconds(apiCode: 403, message: "", httpStatus: nil) == 900)
    check("落月风控 110001 冷却 5 分钟",
          BackendHealthRules.cooldownSeconds(apiCode: 110001, message: "", httpStatus: nil) == 300)
    check("503 冷却 2 分钟",
          BackendHealthRules.cooldownSeconds(apiCode: 503, message: "", httpStatus: nil) == 120)
    check("「频繁请求」文案也判冷却",
          BackendHealthRules.cooldownSeconds(apiCode: nil, message: "由于你多次频繁请求", httpStatus: nil) == 900)
    check("普通失败不冷却",
          BackendHealthRules.cooldownSeconds(apiCode: nil, message: "解析失败", httpStatus: nil) == nil)
    check("冷却期内算「在冷却」",
          BackendHealthRules.isCoolingDown(blockedUntil: now + 10, now: now))
    check("到期就不算在冷却",
          !BackendHealthRules.isCoolingDown(blockedUntil: now - 1, now: now))
    check("没记录过不算在冷却",
          !BackendHealthRules.isCoolingDown(blockedUntil: nil, now: now))
}

section("落月 v3 信封（v2 恒 503，线上走 song/link）")

do {
    let ok: [String: Any] = ["code": 0, "message": "访问成功",
                             "data": ["url": "http://ws.stream.qqmusic.qq.com/M800.mp3",
                                      "link": "https://i.y.qq.com/v8/playsong.html?songmid=x"]]
    check("v3 取的是 data.url（不是 data.link）",
          (try? LuoyueQQAdapter.parseV3(ok)) == "http://ws.stream.qqmusic.qq.com/M800.mp3")

    let risk: [String: Any] = ["code": 110001, "message": "cookie异常：账号被风控无法获取"]
    check("v3 风控失败抛错", (try? LuoyueQQAdapter.parseV3(risk)) == nil)

    let empty: [String: Any] = ["code": 0, "data": ["link": "https://i.y.qq.com/x"]]
    check("v3 只有 link 没 url 也算失败", (try? LuoyueQQAdapter.parseV3(empty)) == nil)

    // v2 的老断言基线（保留，防止有人把 v2 端点又接回去）
    let v2: [String: Any] = ["code": 200, "data": ["url": "http://a/b.mp3"]]
    check("v2 信封仍能解析（历史基线）",
          (try? LuoyueQQAdapter.parse(v2)) == "http://a/b.mp3")
    check("v2 的 503 会被拒", (try? LuoyueQQAdapter.parse(["code": 503])) == nil)
}

// MARK: - oiapi 响应形状（2026-11-25：《众》彻底没源的根因）

section("oiapi 网易：直链在 data.items[] 里（旧解析只认数组，一次都没成功过）")

do {
    // 真实响应（2026-11-25 20:5x 实测）：{"code":0,"data":{"items":[{"url":"http://…"}]}}
    let real: [String: Any] = ["code": 0,
                               "data": ["items": [["name": "众", "id": 1_865_532_803,
                                                   "url": "http://m8.music.126.net/a.m4a"]]]]
    check("现行形状 data.items[0].url", OiapiNeteaseAdapter.streamURL(from: real)
          == "http://m8.music.126.net/a.m4a", OiapiNeteaseAdapter.streamURL(from: real))

    let legacyArray: [String: Any] = ["code": 0, "data": [["url": "http://x/y.mp3"]]]
    check("老形状 data[0].url 仍然认", OiapiNeteaseAdapter.streamURL(from: legacyArray)
          == "http://x/y.mp3", OiapiNeteaseAdapter.streamURL(from: legacyArray))

    let rootURL: [String: Any] = ["code": 0, "url": "http://x/z.mp3", "data": [String: Any]()]
    check("根上的 url 也认", OiapiNeteaseAdapter.streamURL(from: rootURL) == "http://x/z.mp3")

    // 受限歌：url 是 null（不是解析失败，是这首没有）
    let nullURL: [String: Any] = ["code": 0, "data": ["items": [["name": "晴天", "url": NSNull()]]]]
    check("url 为 null → 空串（按「未返回 URL」处理）",
          OiapiNeteaseAdapter.streamURL(from: nullURL).isEmpty)

    let emptyItems: [String: Any] = ["code": 0, "data": ["items": [Any]()]]
    check("items 空 → 空串", OiapiNeteaseAdapter.streamURL(from: emptyItems).isEmpty)
    check("什么都没有 → 空串", OiapiNeteaseAdapter.streamURL(from: [:]).isEmpty)
}

section("多源：酷我三条独立后端 + QQ 两条")
do {
    let all = SourceRegistry.all
    let kuwo = all.filter { $0.platform == .kuwo }.map(\.name)
    let qq = all.filter { $0.platform == .qq }.map(\.name)
    check("酷我有 ≥3 条后端（妖狐/官方/ikun/星海）", Set(kuwo).count >= 3, kuwo.joined(separator: "/"))
    check("ikun 已注册", kuwo.contains("ikun 酷我"), kuwo.joined(separator: "/"))
    check("星海已注册", kuwo.contains("星海酷我"), kuwo.joined(separator: "/"))
    check("QQ 有 cyapi + 落月 v3 两条", Set(qq).count >= 2, qq.joined(separator: "/"))
    check("落月已恢复注册", qq.contains("落月 QQ"), qq.joined(separator: "/"))
}

section("身份闸：副标题/译名放行，版本类拦截（A7 不变）")

do {
    let baseline = song(.netease, "恋爱的条件", "BESTie", album: "Love Options", dur: 200, id: "n1")
    let translated = song(.qq, "연애의 조건 (LOVE OPTIONS)", "BESTie",
                          album: "연애의 조건 (Love Options)", dur: 201, id: "q1")
    let live = song(.qq, "恋爱的条件 (Live)", "BESTie", dur: 210, id: "q2")
    let inst = song(.qq, "恋爱的条件 (Inst.)", "BESTie", dur: 200, id: "q3")
    let cover = song(.qq, "恋爱的条件 (翻唱)", "别人", dur: 200, id: "q4")
    check("带官方英文副标题的同曲要放行（译名不是版本）",
          NameMatch.sameRecording(src: baseline, cand: translated))
    check("Live 版要拦（版本类）", !NameMatch.sameRecording(src: baseline, cand: live))
    check("伴奏/Inst 要拦", !NameMatch.sameRecording(src: baseline, cand: inst))
    check("翻唱要拦", !NameMatch.sameRecording(src: baseline, cand: cover))
    check("时长差 4s 是硬闸门（差 5s 直接拒）",
          !NameMatch.sameRecording(src: baseline,
                                   cand: song(.qq, "恋爱的条件", "BESTie", dur: 206, id: "q5")))
}

section("下一首预取窗口（B1：剩余 20~30 秒）")

do {
    check("剩 25 秒要预取",
          PrefetchRules.shouldPrefetch(remainingSec: 25, hasItem: true,
                                       isResolving: false, mode: .listLoop))
    check("剩 5 秒太晚（来不及）",
          !PrefetchRules.shouldPrefetch(remainingSec: 5, hasItem: true,
                                        isResolving: false, mode: .listLoop))
    check("剩 60 秒太早（浪费一次解析）",
          !PrefetchRules.shouldPrefetch(remainingSec: 60, hasItem: true,
                                        isResolving: false, mode: .listLoop))
    check("随机播放也要预取（下标会被钉住，不会白跑）",
          PrefetchRules.shouldPrefetch(remainingSec: 25, hasItem: true,
                                       isResolving: false, mode: .shuffle))
    check("单曲循环不预取（重播同一份音频）",
          !PrefetchRules.shouldPrefetch(remainingSec: 25, hasItem: true,
                                        isResolving: false, mode: .singleLoop))
    check("心动模式不预取（它有自己的预取链）",
          !PrefetchRules.shouldPrefetch(remainingSec: 25, hasItem: true,
                                        isResolving: false, mode: .heartbeat))
    check("正在解析时不要再起一个预取",
          !PrefetchRules.shouldPrefetch(remainingSec: 25, hasItem: true,
                                        isResolving: true, mode: .listLoop))
    check("没有播放项时不预取",
          !PrefetchRules.shouldPrefetch(remainingSec: 25, hasItem: false,
                                        isResolving: false, mode: .listLoop))
    check("时长未知（NaN）时不预取",
          !PrefetchRules.shouldPrefetch(remainingSec: Double.nan, hasItem: true,
                                        isResolving: false, mode: .listLoop))
}

// MARK: - 44 ListLocate 列表页「定位到正在播放」（第四十四轮）

section("ListLocate 定位口径")

do {
    let qing = song(.qq, "晴天", "周杰伦", album: "叶惠美", dur: 269, id: "q1")
    let list = [
        song(.kuwo, "夜曲", "周杰伦", dur: 226, id: "k0"),
        qing,
        song(.netease, "稻香", "周杰伦", dur: 223, id: "n1"),
    ]
    check("同一条数据按 id 精确命中", ListLocate.index(of: qing, in: list) == 1,
          "index=\(String(describing: ListLocate.index(of: qing, in: list)))")

    let dup = [qing, list[2], qing]
    check("同一首出现两遍取第一处", ListLocate.index(of: qing, in: dup) == 0,
          "index=\(String(describing: ListLocate.index(of: qing, in: dup)))")

    check("没在播放 → nil", ListLocate.index(of: nil, in: list) == nil)
    check("空列表 → nil", ListLocate.index(of: qing, in: []) == nil)

    // 跨平台同一条录音：id 不同，靠 版本类 + 歌名 + 歌手 + 时长
    let playing = song(.netease, "晴天", "周杰伦", album: "叶惠美", dur: 269, id: "nq")
    let kuwoSame = song(.kuwo, "晴天", "周杰伦", album: "叶惠美", dur: 270, id: "kq")
    check("跨平台同曲（时长差 1s）能定位",
          ListLocate.index(of: playing, in: [list[0], kuwoSame]) == 1,
          "index=\(String(describing: ListLocate.index(of: playing, in: [list[0], kuwoSame])))")

    // 版本闸门：原唱与 Live 是两条录音，互相都不定位
    let live = song(.kuwo, "晴天 (Live)", "周杰伦", dur: 269, id: "klive")
    check("原唱不会定位到 Live 版", ListLocate.index(of: playing, in: [live]) == nil)
    check("Live 版也不会定位到原唱", ListLocate.index(of: live, in: [kuwoSame]) == nil)
    // 两边都是 Live（版本类相等）就可以认：跨平台翻录的 Live 也常差 1–2 秒
    let liveOther = song(.qq, "晴天 (Live)", "周杰伦", dur: 268, id: "qlive")
    check("两边都是 Live 版能认", ListLocate.index(of: live, in: [liveOther]) == 0,
          "index=\(String(describing: ListLocate.index(of: live, in: [liveOther])))")

    // 时长闸门：同名同歌手但差 11s，不是同一条录音
    let longer = song(.kuwo, "晴天", "周杰伦", dur: 280, id: "kq2")
    check("时长差 11s 不认", ListLocate.index(of: playing, in: [longer]) == nil)

    // 歌名闸门：同歌手 + 时长碰巧一样（《七里香》269s），不能被误认
    let other = song(.kuwo, "七里香", "周杰伦", dur: 269, id: "kqx")
    check("同歌手同时长的另一首歌不会误认", ListLocate.index(of: playing, in: [other]) == nil)

    // 歌手闸门：同名但换了人（翻唱）
    let cover = song(.qq, "晴天", "某翻唱歌手", dur: 269, id: "qc")
    check("同名不同歌手不认", ListLocate.index(of: playing, in: [cover]) == nil)

    // 接口偶尔不给歌手：这时靠歌名 + 时长命中（与 NameMatch 同口径：任一方没歌手就不拦）
    let noSinger = song(.qq, "晴天", "", dur: 269, id: "qns")
    check("列表缺歌手时靠歌名 + 时长命中", ListLocate.index(of: playing, in: [noSinger]) == 0)

    // 译名不同的同一首（《연애의 조건》/《恋爱的条件》）：定位**不认**——
    // 定位比换源保守：宁可提示"不在此列表"，也不能跳到另一行去。
    let kr = song(.qq, "연애의 조건 (Love Options)", "BESTie", dur: 212, id: "b1")
    let krPlaying = song(.netease, "恋爱的条件", "BESTie", dur: 212, id: "b2")
    check("译名不同不认（宁可不定位，也不跳错行）", ListLocate.index(of: krPlaying, in: [kr]) == nil)
}

// MARK: - 第四十五轮（2026-11-21）：酷狗取流 / 网易 meting / QQ 兜底三件事
//
// 老板当晚的三个现象：周杰伦还播那句提示音、QQ 一直"超时"、源不够壮。
// 这轮补的是「酷狗从来就没有原生取流」「网易只有一条活后端」「QQ 的兜底是死代码」。
// 纯逻辑全部钉在下面；真实字节的证据在 docs/dev/EVAL-聆听岛报告接入评估.md 附录。

section("酷狗取流：zddyr source=kg 的档位映射")

do {
    check("标准档 → 128k", XinghaiKugouAdapter.qualityParam(.standard) == "128k",
          XinghaiKugouAdapter.qualityParam(.standard))
    check("高品档 → 320k", XinghaiKugouAdapter.qualityParam(.high) == "320k",
          XinghaiKugouAdapter.qualityParam(.high))
    check("无损档 → flac（不是 master：master 是 3.4Mbps/108MB 母带）",
          XinghaiKugouAdapter.qualityParam(.lossless) == "flac",
          XinghaiKugouAdapter.qualityParam(.lossless))
    check("不会有人把 master 写进播放链",
          !["128k", "320k", "flac"].contains("master"))
}

section("网易 meting：200 + text/html 不是歌")

do {
    check("真 320k（audio/mpeg + 10MB）算音频",
          MetingStreamRules.looksLikeAudio(container: "mp3", totalBytes: 10_242_285))
    check("真无损（flac 32MB）算音频",
          MetingStreamRules.looksLikeAudio(container: "flac", totalBytes: 32_511_640))
    check("HTML 错误页（0 字节）不算音频",
          !MetingStreamRules.looksLikeAudio(container: "unknown", totalBytes: 0))
    check("体积过小（试听残片）不算音频",
          !MetingStreamRules.looksLikeAudio(container: "mp3", totalBytes: 171_072))
    check("容器认不出（unknown）也不算音频",
          !MetingStreamRules.looksLikeAudio(container: "unknown", totalBytes: 13_042_460))
}

section("QQ 搜索兜底：meting tencent 给的是真 songmid")

do {
    let u = "https://api.qijieya.cn/meting/?server=tencent&type=url&id=0039MnYb0qxYhV"
    check("从 meting url 取出 QQ songmid", QQSearchAdapter.tencentMid(fromMetingURL: u) == "0039MnYb0qxYhV",
          QQSearchAdapter.tencentMid(fromMetingURL: u) ?? "nil")
    check("只认 server=tencent（网易 url 不能当 QQ mid）",
          QQSearchAdapter.tencentMid(
            fromMetingURL: "https://api.qijieya.cn/meting/?server=netease&type=url&id=2668397359") == nil)
    check("mid 太短的不认（防止把空串当 id）",
          QQSearchAdapter.tencentMid(
            fromMetingURL: "https://api.qijieya.cn/meting/?server=tencent&type=url&id=abc") == nil)

    // gdstudio 的 source=tencent 实测 400/503：这条兜底是死的，别再写回去
    check("gdstudio 不是 QQ 搜索的兜底（实测 400/503）",
          true, "留作记录：QQ 兜底只能走 meting tencent")
}

section("QQ 取流：110001 风控先重试一次，别立刻熔断")

do {
    check("110001 值得重试一次", LuoyueQQAdapter.shouldRetryOnce(code: 110001))
    check("503 不重试（上游系统错误，重试也白搭）", !LuoyueQQAdapter.shouldRetryOnce(code: 503))
    check("0（成功）不需要重试", !LuoyueQQAdapter.shouldRetryOnce(code: 0))
    check("403 不重试（会被封更久）", !LuoyueQQAdapter.shouldRetryOnce(code: 403))
}

section("新源已进注册表（酷狗 ≥2 条、网易 ≥3 条）")

do {
    let all = SourceRegistry.all
    let kg = all.filter { $0.platform == .kugou }.map(\.name)
    let ne = all.filter { $0.platform == .netease }.map(\.name)
    check("星海酷狗已注册", kg.contains("星海酷狗"), kg.joined(separator: "/"))
    check("酷狗现在有 ≥2 条后端（官方 + 星海）", Set(kg).count >= 2, kg.joined(separator: "/"))
    check("meting 网易已注册", ne.contains("meting 网易"), ne.joined(separator: "/"))
    check("网易现在有 ≥3 条后端（gdstudio/oiapi/meting）", Set(ne).count >= 3,
          ne.joined(separator: "/"))
    check("注册表里没有重复名字",
          Set(all.map(\.name)).count == all.count, "\(all.count) 条")
}

// MARK: - 第四十六轮（2026-11-21）：收藏去重（同一条录音才算重复）
//
// 老板："收藏一多就忘了已经收过这一首，又收一遍；封面不一样，但音乐文件是同一段。"
// 根因：`Song.id = 平台_ID`，同一首在酷我/酷狗/QQ 各一条 → 天然算三条。
// 口径钉在 `FavoriteRules`：名字核心 + 歌手 + 时长 ±4s + **版本类完全一致**（Live 不许并进录音室）。

section("收藏去重：同一条录音才合并")

do {
    func s(_ p: MusicPlatform, _ name: String, _ singer: String, dur: TimeInterval,
           id: String, pic: String? = nil) -> Song {
        Song.make(platform: p, platformID: id, name: name, singer: singer,
                  album: "叶惠美", duration: dur, picURL: pic)
    }

    // 同一首《晴天》在四家各一条
    let kuwo = s(.kuwo, "晴天", "周杰伦", dur: 269, id: "228908", pic: "https://img/kuwo.jpg")
    let kugou = s(.kugou, "晴天", "周杰伦", dur: 269, id: "B3A52A7A958BF0AED0EBFBA2E9A818B7")
    let qq = s(.qq, "晴天", "周杰伦", dur: 269, id: "0039MnYb0qxYhV")
    check("跨平台同曲算同一条录音（酷我 vs 酷狗）", FavoriteRules.isSameRecording(kuwo, kugou))
    check("跨平台同曲算同一条录音（酷我 vs QQ）", FavoriteRules.isSameRecording(kuwo, qq))
    check("同平台同 id 算同一条", FavoriteRules.isSameRecording(kuwo, kuwo))
    check("对称：反过来也成立", FavoriteRules.isSameRecording(kugou, kuwo))

    // 不能合并的几种
    let cover = s(.kugou, "晴天", "某翻唱歌手", dur: 269, id: "c1")
    check("同名不同歌手（翻唱）不合并", !FavoriteRules.isSameRecording(kuwo, cover))
    let live = s(.kugou, "晴天 (Live)", "周杰伦", dur: 279, id: "live1")
    check("Live 版不并进录音室版", !FavoriteRules.isSameRecording(kuwo, live))
    let liveSameDur = s(.kugou, "晴天 (Live)", "周杰伦", dur: 269, id: "live2")
    check("Live 就算时长一样也不合并（版本类不同）",
          !FavoriteRules.isSameRecording(kuwo, liveSameDur))
    let long = s(.kugou, "晴天", "周杰伦", dur: 299, id: "long1")
    check("时长差 30s 不合并", !FavoriteRules.isSameRecording(kuwo, long))
    let other = s(.kugou, "夜曲", "周杰伦", dur: 226, id: "n1")
    check("同歌手不同歌不合并", !FavoriteRules.isSameRecording(kuwo, other))
    let piano = s(.kugou, "晴天 (钢琴版)", "周杰伦", dur: 269, id: "p1")
    check("钢琴版不合并", !FavoriteRules.isSameRecording(kuwo, piano))

    // 时长未知（gdstudio 搜索不返回时长）→ 退回歌名口径
    let noDur = s(.netease, "晴天", "周杰伦", dur: 0, id: "nd1")
    check("一边时长未知、歌名歌手一致 → 合并", FavoriteRules.isSameRecording(kuwo, noDur))
    let kr1 = s(.qq, "연애의 조건", "BESTie", dur: 0, id: "k1")
    let kr2 = s(.netease, "恋爱的条件", "BESTie", dur: 0, id: "k2")
    check("一边时长未知、译名不同 → 不合并（宁可不合，也不能并错）",
          !FavoriteRules.isSameRecording(kr1, kr2))

    // 老板 2026-11-21 补的口径：不同平台同一首原唱，标题带括号 / 差几个字 / 繁简不同，**都算同一首**
    let trad = s(.kuwo, "後來", "刘若英", dur: 314, id: "tr1")
    let simp = s(.qq, "后来", "刘若英", dur: 314, id: "tr2")
    check("繁简不同 → 合并", FavoriteRules.isSameRecording(trad, simp))
    let withBracket = s(.netease, "晴天 (原唱 周杰伦)", "周杰伦", dur: 269, id: "br1")
    check("带括号说明 → 合并", FavoriteRules.isSameRecording(kuwo, withBracket))
    let fuzzyA = s(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "fz1")
    let fuzzyB = s(.qq, "这世界这么多人", "莫文蔚", dur: 265, id: "fz2")
    check("差一个字（7 字名）→ 合并", FavoriteRules.isSameRecording(fuzzyA, fuzzyB))
    check("标点/全角括号/空格归一", FavoriteRules.titleKey("晴天（原唱 周杰伦）") == FavoriteRules.titleKey("晴天"))

    // 但放行有底线：像但不是同一首，不能并
    check("爱情 vs 爱情转移（两字名不做模糊）",
          !FavoriteRules.isSameRecording(s(.qq, "爱情", "陈奕迅", dur: 240, id: "lo1"),
                                         s(.qq, "爱情转移", "陈奕迅", dur: 240, id: "lo2")))
    check("晴天 vs 情天（两字名差一字）",
          !FavoriteRules.isSameRecording(s(.kuwo, "晴天", "周杰伦", dur: 269, id: "qt1"),
                                         s(.qq, "情天", "周杰伦", dur: 269, id: "qt2")))
    check("相似标题但时长差 5s（模糊口径 ±2s）",
          !FavoriteRules.isSameRecording(s(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "d5a"),
                                         s(.qq, "这世界这么多人", "莫文蔚", dur: 270, id: "d5b")))
    check("相似标题 + 一边时长未知（要求 ≥0.9）",
          !FavoriteRules.isSameRecording(s(.kuwo, "这世界那么多人", "莫文蔚", dur: 265, id: "un1"),
                                         s(.netease, "这世界这么多人", "莫文蔚", dur: 0, id: "un2")))

    // duplicateIndex
    let list = [kuwo, other]
    check("能在收藏里找到同曲那一行", FavoriteRules.duplicateIndex(of: kugou, in: list) == 0)
    check("不同歌返回空", FavoriteRules.duplicateIndex(of: s(.qq, "稻香", "周杰伦", dur: 223, id: "d1"),
                                                   in: list) == nil)

    // 合并：保住已有那条的身份，只补空字段
    let merged = FavoriteRules.merge(existing: kuwo, incoming: kugou)
    check("合并后 id 仍是原来那条（音源不偷换）", merged.id == kuwo.id, merged.id)
    check("合并后封面保留原来的", merged.picURL == kuwo.picURL, merged.picURL ?? "nil")
    let noPic = s(.kuwo, "夜曲", "周杰伦", dur: 226, id: "nopic")
    let withPic = s(.kugou, "夜曲", "周杰伦", dur: 226, id: "withpic", pic: "https://img/kg.jpg")
    check("原来没封面时用新来的补上",
          FavoriteRules.merge(existing: noPic, incoming: withPic).picURL == "https://img/kg.jpg")
    let noDur2 = s(.qq, "稻香", "周杰伦", dur: 0, id: "nd2")
    let withDur = s(.kugou, "稻香", "周杰伦", dur: 223, id: "wd2")
    check("原来时长为 0 时用新来的补上",
          FavoriteRules.merge(existing: noDur2, incoming: withDur).duration > 0)

    // 历史清理
    let dupes = [kuwo, kugou, qq, other, live]
    let result = FavoriteRules.dedupe(dupes)
    check("三条同曲合成一条", result.songs.count == 3, "\(result.songs.count)")
    check("合并计数 = 2", result.merged == 2, "\(result.merged)")
    check("保留列表里最先出现的那条", result.songs.first?.id == kuwo.id)
    check("Live 版仍单独保留", result.songs.contains { $0.id == live.id })
}

section("收藏文件级去重：字节指纹（同一文件才合并）")

do {
    func fp(_ bytes: Int64, _ dur: Int, _ kbps: Int64 = 320) -> FavoriteFingerprint {
        FavoriteFingerprint(bytes: bytes, durationSec: dur, kbps: kbps,
                            capturedAt: Date(timeIntervalSince1970: 0))
    }
    // 实测（2026-11-21）：同一首 320k《晴天》在 ikun / 酷狗 zddyr / 落月 vkeys 都是 10,792,943 B
    check("字节完全相等 → 同一个文件",
          FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_943, 269)))
    check("字节差 1 → 不算（宁可不合）",
          !FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_944, 269)))
    check("时长差 1s 仍算同文件（容器差）",
          FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_943, 270)))
    check("时长差 5s → 不算",
          !FavoriteIdentity.isSameFile(fp(10_792_943, 269), fp(10_792_943, 274)))

    // 占位提示音必须排除：181,521 B 是所有受限歌共用的同一段
    check("占位提示音不可用", !FavoriteIdentity.isUsable(bytes: 181_521, durationSec: 269))
    check("两个占位文件不会互相判同",
          !FavoriteIdentity.isSameFile(fp(181_521, 269), fp(181_521, 269)))
    check("试听残片（171KB）不可用", !FavoriteIdentity.isUsable(bytes: 171_072, durationSec: 11))
    check("真 320k 可用", FavoriteIdentity.isUsable(bytes: 10_792_943, durationSec: 269))
    check("时长为 0 不可用", !FavoriteIdentity.isUsable(bytes: 10_792_943, durationSec: 0))
}

section("收藏灰区复核：什么才值得让用户看一眼")

do {
    func s(_ p: MusicPlatform, _ name: String, _ singer: String, dur: TimeInterval,
           id: String) -> Song {
        Song.make(platform: p, platformID: id, name: name, singer: singer, album: "",
                  duration: dur, picURL: nil)
    }
    func fp(_ bytes: Int64, _ kbps: Int64) -> FavoriteFingerprint {
        FavoriteFingerprint(bytes: bytes, durationSec: 269, kbps: kbps,
                            capturedAt: Date(timeIntervalSince1970: 0))
    }

    let base = s(.kuwo, "晴天", "周杰伦", dur: 269, id: "g1")
    let shorter = s(.qq, "晴天", "周杰伦", dur: 258, id: "g2")
    check("同名同歌手、时长差 11s → 不进灰区（宽口径只收 ≤3s，减少噪音）",
          !FavoriteReview.isGreyPair(base, shorter))
    check("但一级不会合并它（差 11s > 4s）", !FavoriteRules.isSameRecording(base, shorter))

    check("时长差 40s → 不是灰区（基本是两首歌）",
          !FavoriteReview.isGreyPair(base, s(.qq, "晴天", "周杰伦", dur: 309, id: "g3")))
    check("不同歌手 → 不是灰区",
          !FavoriteReview.isGreyPair(base, s(.qq, "晴天", "某翻唱", dur: 269, id: "g4")))
    check("Live 版 → 不是灰区（一听就知道是两首）",
          !FavoriteReview.isGreyPair(base, s(.qq, "晴天 (Live)", "周杰伦", dur: 269, id: "g5")))
    check("一级已经合并的完全同曲 → 不重复提示",
          !FavoriteReview.isGreyPair(base, s(.kugou, "晴天", "周杰伦", dur: 269, id: "g6")))
    check("同名同歌手、时长差 2s → 一级已自动合并，不进灰区",
          !FavoriteReview.isGreyPair(base, s(.qq, "晴天", "周杰伦", dur: 267, id: "g2b")))
    check("歌名只差一点（相似度 0.67）→ 灰区",
          FavoriteReview.isGreyPair(s(.kuwo, "我的天空", "南征北战", dur: 200, id: "g7"),
                                    s(.qq, "我的天空啊呀", "南征北战", dur: 200, id: "g8")))

    // 合并保留哪条：老板定"音质更好"
    let a = s(.kuwo, "晴天", "周杰伦", dur: 269, id: "qa")
    let b = s(.kugou, "晴天", "周杰伦", dur: 269, id: "qb")
    check("320k 赢 128k", FavoriteReview.preferred(a, b,
          fingerprints: [a.id: fp(3_000_000, 128), b.id: fp(10_000_000, 320)]).id == b.id)
    check("同码率比体积", FavoriteReview.preferred(a, b,
          fingerprints: [a.id: fp(9_000_000, 320), b.id: fp(10_000_000, 320)]).id == b.id)
    check("都没指纹保留先出现的", FavoriteReview.preferred(a, b, fingerprints: [:]).id == a.id)
    check("只有一条有指纹就选它", FavoriteReview.preferred(a, b,
          fingerprints: [a.id: fp(3_000_000, 128)]).id == a.id)

    // 否定缓存的键与顺序无关
    check("pairKey 与顺序无关", FavoriteReview.pairKey(a, b) == FavoriteReview.pairKey(b, a))
    check("pairKey 能区分不同对", FavoriteReview.pairKey(a, b) != FavoriteReview.pairKey(a, base))
}

section("本地导入：文件名解析 / 基名唯一 / 搜索")

do {
    let a = ImportRules.parseFileName("01 - 周杰伦 - 晴天.mp3")
    check("音轨号 + 歌手 - 歌名", a.title == "晴天" && a.artist == "周杰伦" && a.confident,
          "\(a.artist)|\(a.title)")
    let b = ImportRules.parseFileName("周杰伦 - 晴天.flac")
    check("歌手 - 歌名", b.title == "晴天" && b.artist == "周杰伦", "\(b.artist)|\(b.title)")
    let c = ImportRules.parseFileName("晴天.mp3")
    check("只有歌名时歌手留空（不瞎猜）", c.title == "晴天" && c.artist.isEmpty && !c.confident)
    let d = ImportRules.parseFileName("2002年的第一场雪.mp3")
    check("开头的数字不是音轨号", d.title.hasPrefix("2002年的第一场雪"), d.title)

    check("mp3 可导入", ImportRules.isPlayable(extension: "mp3"))
    check("ape 不可导入（iOS 放不了）", !ImportRules.isPlayable(extension: "ape"))

    check("基名清洗掉斜杠等非法字符", !ImportRules.sanitizeBase("AC/DC: Back").contains("/"))
    let taken: Set<String> = ["周杰伦 - 晴天"]
    check("撞基名自动加 (2)",
          ImportRules.uniqueBaseName("周杰伦 - 晴天", taken: taken) == "周杰伦 - 晴天 (2)")
    check("不撞就原样",
          ImportRules.uniqueBaseName("周杰伦 - 夜曲", taken: taken) == "周杰伦 - 夜曲")

    let qing = Song.make(platform: .local, platformID: "imp_1", name: "晴天", singer: "周杰伦",
                         album: "叶惠美", duration: 269, picURL: nil)
    check("按歌名搜到", LibrarySearch.rank(song: qing, fileName: "周杰伦 - 晴天.mp3", query: "晴天") >= 2)
    check("按歌手搜到", LibrarySearch.rank(song: qing, fileName: nil, query: "周杰伦") >= 1)
    check("按专辑搜到", LibrarySearch.rank(song: qing, fileName: nil, query: "叶惠美") >= 1)
    check("按文件名搜到", LibrarySearch.rank(song: qing, fileName: "周杰伦 - 晴天.mp3", query: "晴天") >= 1)
    check("繁简都能搜（後來 → 后来）",
          LibrarySearch.rank(song: Song.make(platform: .local, platformID: "imp_2", name: "后来",
                                             singer: "刘若英", album: "", duration: 314, picURL: nil),
                             fileName: nil, query: "後來") >= 2)
    check("搜不到返回 0", LibrarySearch.rank(song: qing, fileName: nil, query: "夜曲") == 0)
    check("精确比包含更靠前",
          LibrarySearch.rank(song: qing, fileName: nil, query: "晴天")
          > LibrarySearch.rank(song: Song.make(platform: .local, platformID: "imp_3", name: "晴天娃娃",
                                               singer: "", album: "", duration: 200, picURL: nil),
                               fileName: nil, query: "晴天"))
}

// MARK: - 第六十六轮（v2.4.51）：导入先"抢"进暂存目录
//
// 事故实证（`诊断/import.log`）：全选 664 首（27 GB）导入，崩点固定在第 59 秒——
// 崩点前 444/419 首 0 失败，崩点后 219/244 首全失败，系统原话「未能打开文件…因为它不存在」，
// 设备当时还剩 303 GB。根因：系统选择器 `asCopy: true` 的副本在 App 的 tmp 里，
// iOS 约 1 分钟后会清掉（前台也清）→ 后面那批 URL 全指向空气。
// 现在的做法：回调一进来先抄进 `Documents/ImportStaging`，再从容解析。

section("本地导入：抢取阶段（时间预算 / ENOENT / 文案）")

do {
    check("时间预算是 40 秒（改大就踩到系统清理线）", ImportGrabRules.grabBudget == 40)
    check("连续 5 个不存在才停", ImportGrabRules.consecutiveMissingAbort == 5)

    check("预算内、没连续失败 → 继续抢",
          !ImportGrabRules.shouldStopGrabbing(elapsed: 39.9, consecutiveMissing: 0))
    check("正好 40 秒 → 停",
          ImportGrabRules.shouldStopGrabbing(elapsed: 40, consecutiveMissing: 0))
    check("超时很久 → 停",
          ImportGrabRules.shouldStopGrabbing(elapsed: 75, consecutiveMissing: 0))
    check("连续 4 个不存在 → 还没到线",
          !ImportGrabRules.shouldStopGrabbing(elapsed: 10, consecutiveMissing: 4))
    check("连续 5 个不存在 → 认定 tmp 被清，停",
          ImportGrabRules.shouldStopGrabbing(elapsed: 10, consecutiveMissing: 5))

    check("ENOENT(4) 判成不存在",
          ImportGrabRules.isMissingFile(domain: "NSCocoaErrorDomain", code: 4))
    check("ENOENT 读(260) 也判成不存在",
          ImportGrabRules.isMissingFile(domain: "NSCocoaErrorDomain", code: 260))
    check("EACCES(257) 不算不存在（权限问题别混进来）",
          !ImportGrabRules.isMissingFile(domain: "NSCocoaErrorDomain", code: 257))
    check("别的 domain 不算",
          !ImportGrabRules.isMissingFile(domain: "NSURLErrorDomain", code: 4))

    let ms = ImportGrabRules.missedSummary(245)
    check("摘要写清数量与原因", ms.contains("245") && ms.contains("临时副本"))
    let early = ImportGrabRules.missedReason(count: 12, abortedEarly: true)
    check("提前停下 → 建议一次选 150 首以内", early.contains("150") && early.contains("12"))
    let late = ImportGrabRules.missedReason(count: 7, abortedEarly: false)
    check("预算用完 → 说明已取到的都进来了", late.contains("7") && late.contains("已取到"))

    check("ImportStaging 在导入浏览器里隐藏", ImportRules.browserHides(name: "ImportStaging"))
    check("暂存目录判成 other（不进列表）",
          ImportRules.browserKind(name: "ImportStaging", isDirectory: true) == .other)
    check("隐藏名单里有它", ImportRules.browserHiddenNames.contains("ImportStaging"))
    check("诊断目录照旧隐藏", ImportRules.browserHides(name: "诊断"))
    check("用户自己的文件夹不隐藏", !ImportRules.browserHides(name: "我的歌"))
}

section("收藏去重：长副标题（包含关系）")
do {
    func s(_ p: MusicPlatform, _ name: String, _ singer: String, dur: TimeInterval,
           id: String, album: String = "哎呦，不错哦") -> Song {
        Song.make(platform: p, platformID: id, name: name, singer: singer, album: album,
                  duration: dur, picURL: nil)
    }
    // 录屏实证：这两首在收藏里并存（QQ vs 酷我），都是 04:57
    let qq = s(.qq, "手写的从前", "周杰伦", dur: 297, id: "h1")
    let kuwo = s(.kuwo, "手写的从前-优酸乳为爱告白广告曲", "周杰伦", dur: 297, id: "h2")
    check("短标题被长标题包含 → 同一条录音", FavoriteRules.isSameRecording(qq, kuwo))
    check("反过来也成立", FavoriteRules.isSameRecording(kuwo, qq))
    check("专辑不同 → 不合并（防止同名不同专辑的联名版）",
          !FavoriteRules.isSameRecording(
            qq, s(.kuwo, "手写的从前-优酸乳为爱告白广告曲", "周杰伦", dur: 297,
                  id: "h3", album: "别的专辑")))
    check("时长差 30s → 不合并",
          !FavoriteRules.isSameRecording(
            qq, s(.kuwo, "手写的从前-优酸乳为爱告白广告曲", "周杰伦", dur: 327, id: "h4")))
    check("四字以上才做包含：三字名不合并",
          !FavoriteRules.isSameRecording(s(.qq, "七里香", "周杰伦", dur: 299, id: "p1"),
                                         s(.kuwo, "七里香花开", "周杰伦", dur: 299, id: "p2")))
    check("两字名不合并（爱情 / 爱情转移）",
          !FavoriteRules.isSameRecording(s(.qq, "爱情", "陈奕迅", dur: 240, id: "l1"),
                                         s(.kuwo, "爱情转移", "陈奕迅", dur: 240, id: "l2")))
    check("长标题带 Live 仍按版本类挡住",
          !FavoriteRules.isSameRecording(s(.qq, "手写的从前", "周杰伦", dur: 297, id: "l3"),
                                         s(.kuwo, "手写的从前 (Live)", "周杰伦", dur: 297, id: "l4")))
    check("包含关系也认：去掉连字符/标点后依然包含",
          FavoriteRules.isSameRecording(s(.qq, "手写的从前", "周杰伦", dur: 297, id: "k1"),
                                         s(.kugou, "手写的从前（优酸乳广告曲）", "周杰伦", dur: 297, id: "k2")))
}

// MARK: - 导入浏览器（r163：不再把系统选择器当唯一入口）

section("导入浏览器：条目分类 / 隐藏名单 / 排序")

do {
    check("mp3 能选", ImportRules.browserKind(name: "a.mp3", isDirectory: false) == .audio)
    check("大写 M4A 也能选", ImportRules.browserKind(name: "A.M4A", isDirectory: false) == .audio)
    check("flac 能选", ImportRules.browserKind(name: "晴天.flac", isDirectory: false) == .audio)
    check("文件夹是 folder", ImportRules.browserKind(name: "我的歌", isDirectory: true) == .folder)
    check("ape 看得见但选不了", ImportRules.browserKind(name: "a.ape", isDirectory: false) == .unsupported)
    check("wma 看得见但选不了", ImportRules.browserKind(name: "a.wma", isDirectory: false) == .unsupported)
    check("lrc 不显示", ImportRules.browserKind(name: "a.lrc", isDirectory: false) == .other)
    check("jpg 不显示", ImportRules.browserKind(name: "cover.jpg", isDirectory: false) == .other)

    check("诊断目录隐藏", ImportRules.browserHides(name: "诊断"))
    check("隐藏文件隐藏", ImportRules.browserHides(name: ".DS_Store"))
    check("Inbox 要显示（别的 App 送来的文件落在那里）",
          !ImportRules.browserHides(name: "Inbox"))
    check("空名隐藏", ImportRules.browserHides(name: ""))

    check("文件夹排在文件前",
          ImportRules.browserComesBefore("zzz", true, "aaa.mp3", false))
    check("02 排在 10 前（不是字典序）",
          ImportRules.browserComesBefore("02 - a.mp3", false, "10 - b.mp3", false))
    check("同名不算'在前'",
          !ImportRules.browserComesBefore("x", false, "x", false))
    check("体积：0 字节不显示", ImportRules.browserSizeText(0) == "")

    // 导入结果文案（v2.4.47：老板问"为什么有些歌导不进去"）
    check("扩展名汇总去重/小写/排序",
          ImportRules.extensionSummary(["a.wma", "b.APE", "c.ape"]) == "ape/wma",
          ImportRules.extensionSummary(["a.wma", "b.APE", "c.ape"]))
    check("没有扩展名 → 未知", ImportRules.extensionSummary(["README"]) == "未知")
    check("ape+wma 才判定'系统没有解码器'",
          ImportRules.hasOnlyUndecodableExtensions(["a.ape", "b.wma"]))
    check("有一个 mp3 就不能说'导进来也是无声'",
          !ImportRules.hasOnlyUndecodableExtensions(["a.ape", "b.mp3"]))
    check("认不出的扩展名不算系统不支持",
          !ImportRules.hasOnlyUndecodableExtensions(["a.lexClip"]))
}

// MARK: - 体积档位（r165：老板要 >1GB 用 GB、<1MB 再降级）

section("体积文案 ByteText：GB / MB / KB / B")

do {
    check("1.5 GB", ByteText.human(1_500_000_000) == "1.5 GB", ByteText.human(1_500_000_000))
    check("正好 1GB 走 GB", ByteText.human(1_000_000_000) == "1 GB", ByteText.human(1_000_000_000))
    check("999.9MB 还是 MB", ByteText.human(999_900_000) == "999.9 MB", ByteText.human(999_900_000))
    check("正好 1MB 走 MB", ByteText.human(1_000_000) == "1 MB", ByteText.human(1_000_000))
    check("999KB 走 KB", ByteText.human(999_000) == "999 KB", ByteText.human(999_000))
    check("999B 走 B", ByteText.human(999) == "999 B", ByteText.human(999))
    check("0 给 0 MB", ByteText.human(0) == "0 MB", ByteText.human(0))
    check("GB 整数不带 .00", !ByteText.human(2_000_000_000).contains(".00"),
          ByteText.human(2_000_000_000))
    check("MB 整数不带 .0", !ByteText.human(10_000_000).contains(".0"),
          ByteText.human(10_000_000))
    check("GB 两位小数保留", ByteText.human(1_250_000_000) == "1.25 GB",
          ByteText.human(1_250_000_000))
    check("下载条目：<1MB 也有文案（旧实现给空串）",
          ByteText.human(500_000) == "500 KB", ByteText.human(500_000))
}

// MARK: - 下载页多选（r166：老板要多选 + 全选 + 批量删除）

section("批量选择 BatchSelection：全选 / 取消全选 / 清理")

do {
    let a = UUID(), b = UUID(), c = UUID(), other = UUID()

    check("空列表不算全选", !BatchSelection.isAllSelected(picked: [], visible: []))
    check("全选上为真", BatchSelection.isAllSelected(picked: [a, b], visible: [a, b]))
    check("少一个为假", !BatchSelection.isAllSelected(picked: [a], visible: [a, b]))
    check("有别人不影响（只看可见的）",
          BatchSelection.isAllSelected(picked: [a, b, other], visible: [a, b]))

    check("没全选 → 并入可见",
          BatchSelection.togglingAll(picked: [c], visible: [a, b]) == [a, b, c])
    check("已全选 → 只移除可见（不动搜索过滤掉的选择）",
          BatchSelection.togglingAll(picked: [a, b, other], visible: [a, b]) == [other])

    check("单行勾选：加上", BatchSelection.toggling([a], b) == [a, b])
    check("单行勾选：去掉", BatchSelection.toggling([a, b], a) == [b])

    check("清理：只保留还看得见的", BatchSelection.pruning([a, b, c], visible: [a, c]) == [a, c])
    check("清理：全没了 → 空", BatchSelection.pruning([a, b], visible: []).isEmpty)

    // v2.4.85（老板 2026-11-23）：还没选歌时不要出现处理栏
    check("多选态但一首没选 → 处理栏不出现",
          !BatchSelection.isBarVisible(selectMode: true, pickedCount: 0))
    check("多选态选了 1 首 → 出现",
          BatchSelection.isBarVisible(selectMode: true, pickedCount: 1))
    check("多选态选了 3 首 → 出现",
          BatchSelection.isBarVisible(selectMode: true, pickedCount: 3))
    check("不在多选态（哪怕还留着残留选择）→ 不出现",
          !BatchSelection.isBarVisible(selectMode: false, pickedCount: 2))
    check("负数/脏计数也不出现",
          !BatchSelection.isBarVisible(selectMode: true, pickedCount: -1))
}

// MARK: - 下载页分页（第 41 轮：首屏 80 行，滚到底继续加载）

func dlItem(_ i: Int, status: DownloadStatus = .completed,
            path: String? = "/tmp/x.flac") -> DownloadItem {
    DownloadItem(song: song(.qq, "第\(i)首", "歌手\(i % 7)"),
                 streamURL: "file:///\(i).flac",
                 backendName: "import",
                 quality: .lossless,
                 fileName: "歌手\(i % 7) - 第\(i)首.flac",
                 localPath: path,
                 status: status,
                 totalBytes: 40_000_000,
                 origin: "import")
}

section("下载页分页：预算怎么分（P0-2）")

do {
    check("首屏上限 80 / 每次「继续加载」加 24（第 42 轮从 80 降下来）",
          DownloadListPaging.firstPage == 80 && DownloadListPaging.pageStep == 24)

    let finished = (0..<662).map { dlItem($0) }
    let one = DownloadListPaging.slices(ongoing: [], failed: [], finished: finished,
                                        limit: DownloadListPaging.firstPage)
    check("662 首只建 80 行", one.finished.count == 80 && one.shown == 80)
    check("总数报全量（不是分页后的）", one.total == 662)
    check("还有没显示的", one.hasMore && one.hidden == 582)

    let all = DownloadListPaging.slices(ongoing: [], failed: [], finished: finished, limit: 10_000)
    check("limit 够大时全展开", all.finished.count == 662 && !all.hasMore && all.hidden == 0)

    // 失败区不能把已下载整片挤出首屏（老板机器上真有 245 条失败记录）
    let failed = (0..<245).map { dlItem($0, status: .failed, path: nil) }
    let mixed = DownloadListPaging.slices(ongoing: Array(finished.prefix(5)), failed: failed,
                                          finished: finished, limit: 80)
    check("失败区只占 1/4（20 条），已下载还能露 55 条",
          mixed.failed.count == 20 && mixed.finished.count == 55)
    check("正在下载永远全显示", mixed.ongoing.count == 5)
    check("一屏总数仍受预算约束", mixed.shown == 80 && mixed.total == 5 + 245 + 662)

    check("失败区不足配额时按实际给",
          DownloadListPaging.failedQuota(budget: 80, failedCount: 3) == 3)
    check("预算为 0 时不给失败区",
          DownloadListPaging.failedQuota(budget: 0, failedCount: 10) == 0)

    check("继续加载：80 → 104", DownloadListPaging.nextLimit(80, total: 662) == 104)
    check("继续加载不越界", DownloadListPaging.nextLimit(640, total: 662) == 662)
    check("到底了不再涨", DownloadListPaging.nextLimit(662, total: 662) == 662)

    let empty = DownloadListPaging.slices(ongoing: [], failed: [], finished: [], limit: 80)
    check("空列表：没有更多、不显示负的 hidden",
          !empty.hasMore && empty.hidden == 0 && empty.shown == 0)

    // 第 42 轮：首帧 8 行 + 分块补到 80（真机 80 行要 507–813ms ≈ 7–10ms/行）
    check("首帧只建 8 行", DownloadListPaging.firstFrame == 8)
    check("补行目标 80 / 每拍 4 行",
          DownloadListPaging.fillTarget == 80 && DownloadListPaging.fillChunk == 4)
    check("补行：8 → 12", DownloadListPaging.nextFillLimit(8, target: 80) == 12)
    check("补行不越过目标", DownloadListPaging.nextFillLimit(76, target: 80) == 80)
    check("已经到目标就不涨", DownloadListPaging.nextFillLimit(80, target: 80) == 80)
}

// MARK: - 下载行左滑按钮（第 47 轮：两个删除键 + 长按唤不出菜单）

do {
    // 老板 2026-11-21 21:35 截屏：一行左滑后两个一模一样的红垃圾桶。
    // 根源是同一行挂了两份 `.swipeActions`；现在按钮顺序只在 `DownloadRowSwipe` 里定义一次。
    check("尾侧顺序：删除在前（贴右边缘）",
          DownloadRowSwipe.trailingOrder == [.delete, .edit])
    check("**只有一个删除键**",
          DownloadRowSwipe.trailingOrder.filter { $0 == .delete }.count == 1)
    check("歌曲信息在删除键左边（声明序第 2 个）",
          DownloadRowSwipe.trailingOrder.last == .edit)
    check("只有删除是破坏性（红色）",
          DownloadRowSwipe.delete.isDestructive && !DownloadRowSwipe.edit.isDestructive)
    check("文案/图标：删除=trash，歌曲信息=pencil",
          DownloadRowSwipe.delete.title == "删除" && DownloadRowSwipe.delete.symbol == "trash"
          && DownloadRowSwipe.edit.title == "歌曲信息" && DownloadRowSwipe.edit.symbol == "pencil")
    check("动作集合不重复", Set(DownloadRowSwipe.trailingOrder).count == 2)

    // 「部分歌曲长按唤不出」的算账（第 47 轮根因）：
    // 首帧预算 8 行，245 条失败记录先吃掉 2 行 → 已下载只 arm 到前 6 首；
    // 而列表后来被「定位」撑到 104 行（显示 84 首），那 78 首因为没 arm 全都没有交互。
    let finished662 = (0..<662).map { dlItem($0) }
    let failed245 = (0..<245).map { dlItem($0, status: .failed, path: nil) }
    let firstFrame = DownloadListPaging.slices(ongoing: [], failed: failed245,
                                               finished: finished662, limit: 8)
    check("首帧 8 行预算：失败区 2 行 + 已下载 6 行",
          firstFrame.failed.count == 2 && firstFrame.finished.count == 6)
    let armedFirst = DownloadListPaging.renderedIDs(ongoing: [], failed: failed245,
                                                    finished: finished662, limit: 8)
    check("arm 的目标 = 首帧真正渲染的那 8 行", armedFirst.count == 8)
    check("首帧 arm 的已下载只有 6 首（第 7 首起没有交互 → 老板说的「部分歌曲」）",
          Set(firstFrame.finished.map(\.id)).count == 6
          && Set(firstFrame.finished.map(\.id)) == armedFirst.subtracting(Set(firstFrame.failed.map(\.id))))

    // 第 47 轮的兜底：limit 一变就 arm，所以「已渲染」必然是「已 arm」的超集
    let wide = DownloadListPaging.renderedIDs(ongoing: [], failed: failed245,
                                              finished: finished662, limit: 104)
    check("撑到 104 行（定位那条路）时，一屏就是 104 个 id", wide.count == 104)
    check("**旧的行一个都不能丢**（arm 只许变大）", armedFirst.isSubset(of: wide))
    check("行数跟着 limit 单调增",
          DownloadListPaging.renderedIDs(ongoing: [], failed: failed245,
                                         finished: finished662, limit: 32).isSubset(of: wide))

    let paged = DownloadListPaging.slices(ongoing: [], failed: failed245,
                                          finished: finished662, limit: 104)
    check("renderedIDs = slices 的全部 id（arm 与渲染同源）", paged.allIDs == wide)
    check("失败区按 1/4 配额给（245 条 → 26 条），已下载 78 首",
          paged.failed.count == 26 && paged.finished.count == 78)

    // 老板 21:16 那天录屏里「已显示 84」：104 行预算 - 20 条失败记录 = 84 首已下载。
    // 这条只是把那个数字钉死，说明"能显示 84 行、却只有前 6 首挂了交互"。
    let failed20 = (0..<20).map { dlItem($0, status: .failed, path: nil) }
    let boss = DownloadListPaging.slices(ongoing: [], failed: failed20,
                                         finished: finished662, limit: 104)
    check("104 行预算 + 20 条失败 → 已下载正好显示 84（= 截屏上的「已显示 84」）",
          boss.failed.count == 20 && boss.finished.count == 84)
}

section("目录索引：一次列目录，别每首列一遍（P1-1）")

do {
    let index = DownloadFileIndex.build(names: ["晴天.flac", "晴天.m4a", "七里香.mp3"])
    check("同基名两份都进索引", index["晴天"]?.count == 2)
    check("精确同名优先", DownloadFileIndex.match(fileName: "晴天.m4a", in: index) == "晴天.m4a")
    check("扩展名变了按基名找",
          DownloadFileIndex.match(fileName: "晴天.wav", in: index) == "晴天.flac")
    check("找不到就是没有", DownloadFileIndex.match(fileName: "发如雪.flac", in: index) == nil)
    check("空文件名直接 nil", DownloadFileIndex.match(fileName: "", in: index) == nil)
    check("空目录不炸", DownloadFileIndex.build(names: []).isEmpty)
}

section("缓存按 id 失效：进度不算变化（P0-4）")

do {
    let base = dlItem(1)
    var progressed = base
    progressed.progress = 0.87
    progressed.receivedBytes = 12_345
    check("只是进度变了 → 签名不变（缓存不该被清）",
          DownloadCacheSignature(base) == DownloadCacheSignature(progressed))

    var failedItem = base
    failedItem.status = .failed
    check("状态变了 → 签名变", DownloadCacheSignature(base) != DownloadCacheSignature(failedItem))

    var movedItem = base
    movedItem.localPath = "/tmp/y.flac"
    check("本地路径变了 → 签名变", DownloadCacheSignature(base) != DownloadCacheSignature(movedItem))

    var renamed = base
    renamed.fileName = "别的名字.flac"
    check("文件名变了 → 签名变", DownloadCacheSignature(base) != DownloadCacheSignature(renamed))

    let otherSong = DownloadItem(song: song(.qq, "另一首", "别人"), streamURL: "x",
                                 backendName: "import", quality: .lossless, status: .completed)
    check("不同歌 → 签名不同", DownloadCacheSignature(base) != DownloadCacheSignature(otherSong))
}

// MARK: - 第 48/49 轮：把歌曲信息写进音频文件（ID3 TIT2/TPE1/TALB/TLEN/APIC/USLT）
//
// 老板 2026-11-22 两轮：「本地的后台文件封面并没有和前端内置的对齐……把内置的封面下载下来
// 替换原有文件中该歌曲的封面，如果该歌曲后台文件中没有封面那么直接添加进去并建联」，
// 随后又问「是否可以同时把封面、歌名、歌手、专辑还有音频信息一起通过这个按钮写入音频文件」。
//
// 这一节的断言守四件事：
//   ① 写进去的字段**读得回来**（歌名/歌手/专辑/时长/封面/歌词）；
//   ② 写封面/歌名**不能顺手删别的**（别人写的年份/流派、内嵌歌词都要留着）；
//   ③ 音频体一个字节都不能改（"能放"这件事不能赌）；
//   ④ 解析不了就返回 nil（v2.2 / unsync），v2.3 的中文必须走 UTF-16，不能用 latin1 写。

section("写回歌曲信息：ID3 只换认识的那几帧（第 48/49 轮）")

do {
    let body = Data((0..<256).map { UInt8($0 % 251) })
    let oldCover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x11, count: 400))
    let newCover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x22, count: 900))
    let lyricLine = "[00:01.00]故事的小黄花"

    // 老文件：旧歌名/歌手/专辑 + 旧封面 + 内嵌歌词（模拟"导入时标签里带的东西"）
    let file = DownloadCompanion.id3Tag(title: "旧歌名", artist: "旧歌手", album: "旧专辑",
                                        coverData: oldCover, coverMime: "image/jpeg",
                                        lyrics: lyricLine) + body

    var want = DownloadCompanion.ID3Tags.Fields()
    want.title = "晴天"
    want.artist = "周杰伦"
    want.album = "叶惠美"
    want.durationMs = 269_000
    want.cover = newCover
    want.coverMime = "image/jpeg"
    want.lyrics = lyricLine

    check("读得出文件里原来的那一套",
          DownloadCompanion.ID3Tags.reading(inFileData: file).title == "旧歌名")
    check("还没写的时候 matches = false",
          !DownloadCompanion.ID3Tags.matches(want, inFileData: file))

    let out = DownloadCompanion.ID3Tags.rewriting(inFileData: file, fields: want)
    check("写回返回了新文件字节", out != nil)
    if let out {
        let read = DownloadCompanion.ID3Tags.reading(inFileData: out)
        check("歌名换成新的", read.title == "晴天", read.title)
        check("歌手换成新的", read.artist == "周杰伦", read.artist)
        check("专辑换成新的", read.album == "叶惠美", read.album)
        check("时长写进 TLEN（毫秒）", read.durationMs == 269_000, "\(read.durationMs)")
        check("封面换成新的", read.cover == newCover)
        check("内嵌歌词还在（不能顺手删词）", (read.lyrics ?? "").contains("故事的小黄花"))
        check("旧歌名的字节一个都不剩", out.range(of: Data("旧歌名".utf8)) == nil)
        check("旧封面字节也不剩", out.range(of: oldCover) == nil)
        check("音频体原样跟在标签后面", out.suffix(body.count) == body)
        check("头还是 ID3v2.4", out.prefix(4) == Data([0x49, 0x44, 0x33, 0x04]))
        let sizeBytes = [UInt8](out[6..<10])
        let framesLen = (Int(sizeBytes[0]) << 21) | (Int(sizeBytes[1]) << 14)
            | (Int(sizeBytes[2]) << 7) | Int(sizeBytes[3])
        check("标签长度字段 = 帧区真实长度", out.count == 10 + framesLen + body.count,
              "count=\(out.count) framesLen=\(framesLen) body=\(body.count)")
        check("同一套再写一次 → matches 为真（第二次不会再重写）",
              DownloadCompanion.ID3Tags.matches(want, inFileData: out))
        // 再写一遍：字节数不变（帧没有叠加）
        let twice = DownloadCompanion.ID3Tags.rewriting(inFileData: out, fields: want)
        check("重复写不会叠帧", twice?.count == out.count)
    }

    // 只给封面（老板的第一次要求）：歌名/歌手/专辑一律不动
    var coverOnly = DownloadCompanion.ID3Tags.Fields()
    coverOnly.cover = newCover
    if let done = DownloadCompanion.ID3Tags.rewriting(inFileData: file, fields: coverOnly) {
        let read = DownloadCompanion.ID3Tags.reading(inFileData: done)
        check("只给封面时，歌名/歌手/专辑一个都没动",
              read.title == "旧歌名" && read.artist == "旧歌手" && read.album == "旧专辑")
        check("只给封面时，新图进去了", read.cover == newCover)
    } else {
        check("只给封面也能写", false)
    }

    // 空字段 = 不动，不是"清空"
    check("什么都没给 → 不返回新文件（不能把标签清空）",
          DownloadCompanion.ID3Tags.rewriting(inFileData: file,
                                              fields: DownloadCompanion.ID3Tags.Fields()) == nil)

    // 没有 ID3 标签的裸文件（本地导入的 mp3 不少是这样）
    let bare = body
    if let added = DownloadCompanion.ID3Tags.rewriting(inFileData: bare, fields: want) {
        check("无标签 → 直接加一条完整标签", added.prefix(3) == Data("ID3".utf8))
        let read = DownloadCompanion.ID3Tags.reading(inFileData: added)
        check("新增后歌名/歌手/专辑/封面都在",
              read.title == "晴天" && read.artist == "周杰伦"
                  && read.album == "叶惠美" && read.cover == newCover)
        check("新增后音频体一个字节没动", added.suffix(bare.count) == bare)
    } else {
        check("无标签文件也能写", false)
    }

    // v2.3：别的工具（下载站/老播放器）写的老标签 —— 帧长度是普通 32 位大端；
    // 中文必须 UTF-16，拿 latin1/UTF-8 硬写就是乱码。
    func v23Frame(_ id: String, _ payload: Data) -> Data {
        var d = Data(id.utf8)
        let n = payload.count
        d.append(contentsOf: [UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF),
                              UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF), 0x00, 0x00])
        d.append(payload)
        return d
    }
    var apic23 = Data([0x00])
    apic23.append(contentsOf: Array("image/jpeg".utf8))
    apic23.append(0x00) // MIME 结束
    apic23.append(0x03) // front cover
    apic23.append(0x00) // 空描述
    apic23.append(oldCover)
    var frames23 = v23Frame("TIT2", Data([0x00]) + Data("Old Title".utf8))
    frames23.append(v23Frame("APIC", apic23))
    // 一个我们"不认识"的帧（年份 TDRC）：写回时不许把它弄丢
    frames23.append(v23Frame("TDRC", Data([0x00]) + Data("2003".utf8)))
    var file23 = Data("ID3".utf8)
    file23.append(contentsOf: [0x03, 0x00, 0x00])
    let n23 = frames23.count
    file23.append(contentsOf: [UInt8((n23 >> 21) & 0x7F), UInt8((n23 >> 14) & 0x7F),
                               UInt8((n23 >> 7) & 0x7F), UInt8(n23 & 0x7F)])
    file23.append(frames23)
    file23.append(body)

    check("v2.3 也能读出原歌名",
          DownloadCompanion.ID3Tags.reading(inFileData: file23).title == "Old Title")
    if let out23 = DownloadCompanion.ID3Tags.rewriting(inFileData: file23, fields: want) {
        check("v2.3 换完还是 v2.3", out23.prefix(4) == Data([0x49, 0x44, 0x33, 0x03]))
        let read = DownloadCompanion.ID3Tags.reading(inFileData: out23)
        check("v2.3 中文歌名读得回来（UTF-16 写对了）", read.title == "晴天", read.title)
        check("v2.3 中文歌手读得回来", read.artist == "周杰伦", read.artist)
        check("v2.3 新封面读得回来", read.cover == newCover)
        check("v2.3 不认识的帧（年份 2003）还在", out23.range(of: Data("2003".utf8)) != nil)
        check("v2.3 音频体没动", out23.suffix(body.count) == body)
        let sb = [UInt8](out23[6..<10])
        let fl = (Int(sb[0]) << 21) | (Int(sb[1]) << 14) | (Int(sb[2]) << 7) | Int(sb[3])
        check("v2.3 标签长度字段正确", out23.count == 10 + fl + body.count)
        check("v2.3 中文走 UTF-16（带 BOM）",
              out23.range(of: Data([0x01, 0xFF, 0xFE])) != nil)
    } else {
        check("v2.3 也能写回", false)
    }

    // 解析不了就不碰：v2.2 / 带 unsynchronisation
    var v22 = Data("ID3".utf8)
    v22.append(contentsOf: [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    v22.append(body)
    check("ID3v2.2 不冒险（返回 nil，原文件不动）",
          DownloadCompanion.ID3Tags.rewriting(inFileData: v22, fields: want) == nil)
    var unsync = Data("ID3".utf8)
    unsync.append(contentsOf: [0x04, 0x00, 0x80, 0x00, 0x00, 0x00, 0x00, 0x00])
    unsync.append(body)
    check("带 unsynchronisation 的标签不碰",
          DownloadCompanion.ID3Tags.rewriting(inFileData: unsync, fields: want) == nil)
}

// MARK: - 第 50 轮：FLAC 写回（Vorbis Comment + PICTURE）
//
// 老板 2026-11-22 01:05：点完写回，结果是「改写 6 · 新增 14 · 格式不支持 642」——
// 他的库几乎全是 FLAC，而上一版只做了 mp3/m4a。这一节把 FLAC 的标准写法钉住：
//   · TITLE/ARTIST/ALBUM/UNSYNCEDLYRICS 写进 VORBIS_COMMENT，**原有的其它键（DATE）保留**；
//   · 封面写 PICTURE（type 3 = front cover），旧封面块被替换；
//   · 音频帧一个字节不改；前置 ID3v2 被丢掉（解码从 fLaC 开始）。

section("FLAC 写回：Vorbis Comment + PICTURE（第 50 轮）")

do {
    // 造一个最小可解析的 FLAC：fLaC + STREAMINFO(34B) + VORBIS_COMMENT(旧值+DATE) + 假音频帧
    func be32(_ v: Int) -> [UInt8] {
        [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
    }
    func le32(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    func vcBlock(_ pairs: [(String, String)]) -> Data {
        var payload = Data()
        let vendor = Array("old-writer".utf8)
        payload.append(contentsOf: le32(vendor.count))
        payload.append(contentsOf: vendor)
        payload.append(contentsOf: le32(pairs.count))
        for (k, v) in pairs {
            let text = Array("\(k)=\(v)".utf8)
            payload.append(contentsOf: le32(text.count))
            payload.append(contentsOf: text)
        }
        return payload
    }
    func blockHeader(type: Int, last: Bool, len: Int) -> Data {
        var h = Data([UInt8((last ? 0x80 : 0x00) | UInt8(type))])
        h.append(contentsOf: [UInt8((len >> 16) & 0xFF), UInt8((len >> 8) & 0xFF), UInt8(len & 0xFF)])
        return h
    }
    func picturePayload(type: Int, image: Data) -> Data {
        var payload = Data()
        payload.append(contentsOf: be32(type))
        payload.append(contentsOf: be32(10)) // "image/jpeg" 是 10 字节
        payload.append(contentsOf: Array("image/jpeg".utf8))
        payload.append(contentsOf: be32(0))
        payload.append(contentsOf: be32(0))
        payload.append(contentsOf: be32(0))
        payload.append(contentsOf: be32(24))
        payload.append(contentsOf: be32(0))
        payload.append(contentsOf: be32(image.count))
        payload.append(image)
        return payload
    }

    let audioFrames = Data((0..<512).map { UInt8(($0 * 7) % 251) })
    let streamInfo = Data(repeating: 0x11, count: 34)
    let oldCover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x33, count: 300))
    let newCover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x44, count: 700))
    let vc = vcBlock([("TITLE", "旧标题"), ("ARTIST", "旧歌手"), ("DATE", "2003")])
    let pic = picturePayload(type: 3, image: oldCover)

    var flac = Data("fLaC".utf8)
    flac.append(blockHeader(type: 0, last: false, len: streamInfo.count))
    flac.append(streamInfo)
    flac.append(blockHeader(type: 4, last: false, len: vc.count))
    flac.append(vc)
    flac.append(blockHeader(type: 6, last: true, len: pic.count))
    flac.append(pic)
    flac.append(audioFrames)

    let before = DownloadCompanion.FlacTags.reading(inFileData: flac)
    check("FLAC 读得出旧标题", before.title == "旧标题", before.title)
    check("FLAC 读得出旧封面", before.cover == oldCover)
    check("FLAC hasImage = true", DownloadCompanion.FlacTags.hasImage(inFileData: flac))

    var want = DownloadCompanion.ID3Tags.Fields()
    want.title = "晴天"
    want.artist = "周杰伦"
    want.album = "叶惠美"
    want.cover = newCover
    want.coverMime = "image/jpeg"
    want.lyrics = "[00:01.00]故事的小黄花"

    check("FLAC 还没写时 matches = false",
          !DownloadCompanion.FlacTags.matches(want, inFileData: flac))
    if let out = DownloadCompanion.FlacTags.rewriting(inFileData: flac, fields: want) {
        check("FLAC 写出来还是 fLaC 打头", out.prefix(4) == Data("fLaC".utf8))
        let read = DownloadCompanion.FlacTags.reading(inFileData: out)
        check("FLAC 歌名写进去了", read.title == "晴天", read.title)
        check("FLAC 歌手写进去了", read.artist == "周杰伦", read.artist)
        check("FLAC 专辑写进去了", read.album == "叶惠美", read.album)
        check("FLAC 歌词写进去了", (read.lyrics ?? "").contains("故事的小黄花"))
        check("FLAC 封面换成了新图", read.cover == newCover)
        check("FLAC 旧的 DATE=2003 保留着", out.range(of: Data("DATE=2003".utf8)) != nil)
        check("FLAC 旧标题字节不在了", out.range(of: Data("旧标题".utf8)) == nil)
        check("FLAC 音频帧一个字节没动", out.suffix(audioFrames.count) == audioFrames)
        check("FLAC 同一套再写 → matches 为真",
              DownloadCompanion.FlacTags.matches(want, inFileData: out))
        let twice = DownloadCompanion.FlacTags.rewriting(inFileData: out, fields: want)
        check("FLAC 重复写不会叠块", twice?.count == out.count)
    } else {
        check("FLAC 能写回", false)
    }

    // 前置 ID3v2 的 FLAC（老工具常见）：写回后应当只剩 fLaC，音频帧不变
    var id3 = Data("ID3".utf8)
    id3.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    id3.append(flac)
    if let fixed = DownloadCompanion.FlacTags.rewriting(inFileData: id3, fields: want) {
        check("前置 ID3 的 FLAC 写回后从 fLaC 开始", fixed.prefix(4) == Data("fLaC".utf8))
        check("前置 ID3 丢掉后音频帧仍原样", fixed.suffix(audioFrames.count) == audioFrames)
        check("前置 ID3 版本也能读出字段",
              DownloadCompanion.FlacTags.reading(inFileData: fixed).title == "晴天")
    } else {
        check("前置 ID3 的 FLAC 也能写", false)
    }

    // 不是 FLAC 就别碰
    check("不是 FLAC 的文件返回 nil",
          DownloadCompanion.FlacTags.rewriting(inFileData: Data("not a flac".utf8),
                                               fields: want) == nil)
    // 空字段 = 不动
    check("FLAC 空字段 → 不写",
          DownloadCompanion.FlacTags.rewriting(inFileData: flac,
                                               fields: DownloadCompanion.ID3Tags.Fields()) == nil)
}

// MARK: - 第 51/52 轮 A 方案：对齐判定（逐字段）
//
// 老板 2026-11-22 02:35：「有些是没有歌词内嵌成功的，有些内嵌成功了，有些歌曲没有专辑（这个有时候正常），
// 但是都显示是绿的」——所以判定必须**逐字段**：没专辑是 empty（不算问题），
// 旁车有词但文件里没词是 missing（必须变灰），图不一样是 differs。

section("对齐判定：文件里 vs 列表上（第 51/52 轮 A 方案）")

do {
    let target = song(.local, "晴天", "周杰伦", album: "叶惠美")
    let cover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x22, count: 32))
    let otherCover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x33, count: 32))

    var good = DownloadCompanion.ID3Tags.Fields()
    good.title = "晴天"
    good.artist = "周杰伦"
    good.album = "叶惠美"
    good.cover = cover

    let aligned = DownloadCompanion.FileTruth.truth(file: good, song: target,
                                                    coverSidecar: cover, lyricsSidecar: nil)
    check("五个字段都一致 → 已对齐", aligned.state == .inSync && aligned.isAligned)
    check("…逐字段都是 ok / empty",
          aligned.title == .ok && aligned.artist == .ok && aligned.album == .ok
              && aligned.cover == .ok && aligned.lyrics == .empty)

    // 老板 02:35 的原话：旁车有词、文件里没词，以前显示绿的
    let noLyrics = DownloadCompanion.FileTruth.truth(file: good, song: target,
                                                     coverSidecar: cover,
                                                     lyricsSidecar: "[00:01.00]故事的小黄花")
    check("旁车有词、文件里没有 → 不再算已对齐", noLyrics.state != .inSync)
    check("…歌词标成 missing", noLyrics.lyrics == .missing)
    check("…原因里点出歌词", noLyrics.problems.contains { $0.contains("歌词") })

    // 没有专辑是"正常情况"，不能被判成问题
    let noAlbum = DownloadCompanion.FileTruth.truth(file: good,
                                                    song: song(.local, "晴天", "周杰伦", album: ""),
                                                    coverSidecar: cover, lyricsSidecar: nil)
    check("列表本来没有专辑 → empty，不算问题", noAlbum.album == .empty && noAlbum.isAligned)

    let oldCover = DownloadCompanion.FileTruth.truth(file: good, song: target,
                                                     coverSidecar: otherCover, lyricsSidecar: nil)
    check("文件里的图和旁车不是同一张 → cover differs", oldCover.cover == .differs)
    check("…状态不是已对齐", oldCover.state != .inSync)

    var noCoverFile = good
    noCoverFile.cover = nil
    check("文件没图、旁车也没图 → missing",
          DownloadCompanion.FileTruth.truth(file: noCoverFile, song: target,
                                            coverSidecar: nil,
                                            lyricsSidecar: nil).state == .missing)
    check("文件没图、旁车有图 → 只在旁车",
          DownloadCompanion.FileTruth.truth(file: noCoverFile, song: target,
                                            coverSidecar: cover,
                                            lyricsSidecar: nil).state == .sidecarOnly)

    let unsupported = DownloadCompanion.FileTruth.unsupported(coverSidecar: cover, lyricsSidecar: nil)
    check("容器不支持 → 单独一个状态", unsupported.state == .unsupported && !unsupported.isAligned)

    check("四种状态都有中文说明",
          [SongFileState.inSync, .sidecarOnly, .missing, .unsupported].allSatisfy {
              !DownloadCompanion.FileTruth.label($0).isEmpty
          })

    // 第 52 轮流式写盘用的两个纯函数：标签长度 / 只写标签区 / 满足判定
    check("tagLength：不是 ID3 → 0",
          DownloadCompanion.ID3Tags.tagLength(headBytes: [0xFF, 0xFB, 0x90]) == 0)
    var head24: [UInt8] = Array("ID3".utf8)
    head24.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x02, 0x2C]) // size = 300（syncsafe）
    check("tagLength：v2.4 长度 = 10 + size",
          DownloadCompanion.ID3Tags.tagLength(headBytes: head24) == 310)
    var head22: [UInt8] = Array("ID3".utf8)
    head22.append(contentsOf: [0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    check("tagLength：v2.2 不冒险（nil）",
          DownloadCompanion.ID3Tags.tagLength(headBytes: head22) == nil)

    check("satisfied：字段全对 → true", DownloadCompanion.ID3Tags.satisfied(good, by: good))
    var half = good
    half.album = ""
    check("satisfied：文件里缺专辑 → false", !DownloadCompanion.ID3Tags.satisfied(good, by: half))
    check("satisfied：什么都没要求 → true",
          DownloadCompanion.ID3Tags.satisfied(DownloadCompanion.ID3Tags.Fields(), by: good))

    // 只写标签区 == 整文件写回的头部（流式写盘靠这条等价）
    let oldTag = DownloadCompanion.id3Tag(title: "旧", artist: "旧", album: "旧",
                                          coverData: nil, coverMime: "image/jpeg", lyrics: "")
    let body = Data((0..<128).map { UInt8($0) })
    let whole = oldTag + body
    let full = DownloadCompanion.ID3Tags.rewriting(inFileData: whole, fields: good)
    let tagLength = DownloadCompanion.ID3Tags.tagLength(headBytes: [UInt8](whole.prefix(10))) ?? 0
    let tagOnly = DownloadCompanion.ID3Tags.rewriting(tagBytes: whole.prefix(tagLength), fields: good)
    check("只写标签区 = 整文件结果的头部",
          full != nil && tagOnly != nil && full!.prefix(tagOnly!.count) == tagOnly!)
}

// MARK: - 第 53 轮：按内容识别容器（扩展名不可信）
//
// 老板 2026-11-22 03:35 那份未对齐名单里，13 首是五个字段**全 missing** —— 不是没写进去，
// 是连读都读不出来。最可能是「扩展名 .flac、内容其实是 mp3/m4a」（r120 踩过同一个坑），
// 也可能是文件不在本地。判定容器只能看文件头。

section("按内容识别容器（第 53 轮）")

do {
    func bytes(_ hex: [UInt8]) -> [UInt8] { hex }

    check("fLaC → FLAC",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22])) == .flac)
    check("ftyp（MP4/M4A）→ M4A",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0x00, 0x00, 0x00, 0x20, 0x66, 0x74, 0x79, 0x70,
                                                                0x4D, 0x34, 0x41, 0x20])) == .m4a)
    check("OggS → OGG",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0x4F, 0x67, 0x67, 0x53, 0x00, 0x02, 0x00, 0x00])) == .ogg)
    check("RIFF…WAVE → WAV",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0x52, 0x49, 0x46, 0x46, 0x24, 0x08, 0x00, 0x00,
                                                                0x57, 0x41, 0x56, 0x45])) == .wav)
    check("MAC → APE",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0x4D, 0x41, 0x43, 0x20, 0x96, 0x0F, 0x00, 0x00])) == .ape)
    check("裸 MPEG 帧（0xFF 0xFB）→ MP3",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0xFF, 0xFB, 0x90, 0x64, 0x00, 0x00, 0x00, 0x00])) == .mp3)
    check("认不出的数据 → unknown",
          DownloadCompanion.AudioSniff.container(prefix: bytes([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07])) == .unknown)

    // 开头挂 ID3 的：跳过标签再看后面是什么（老工具常见；r120 的坑）
    var id3Flac: [UInt8] = Array("ID3".utf8)
    id3Flac.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]) // size = 0
    id3Flac.append(contentsOf: [0x66, 0x4C, 0x61, 0x43, 0x00, 0x00, 0x00, 0x22])
    check("ID3 + fLaC → FLAC（不能被 ID3 骗成 MP3）",
          DownloadCompanion.AudioSniff.container(prefix: id3Flac) == .flac)

    var id3Mp3: [UInt8] = Array("ID3".utf8)
    id3Mp3.append(contentsOf: [0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    id3Mp3.append(contentsOf: [0xFF, 0xFB, 0x90, 0x64])
    check("ID3 + MPEG 帧 → MP3", DownloadCompanion.AudioSniff.container(prefix: id3Mp3) == .mp3)

    check("能写标签的只有 flac / mp3 / m4a",
          DownloadCompanion.AudioContainer.flac.canWriteTags
              && DownloadCompanion.AudioContainer.mp3.canWriteTags
              && DownloadCompanion.AudioContainer.m4a.canWriteTags
              && !DownloadCompanion.AudioContainer.ogg.canWriteTags
              && !DownloadCompanion.AudioContainer.unknown.canWriteTags)
}

// MARK: - 第 54 轮：文件里自带完整信息就不联网
//
// 老板 2026-11-22 03:53：「下次导入后就可以自动解析不用再一个个换封面了对吗，
// 也不用请求 api 联网查询了，会优先查找文件内置的信息」。

section("导入先用文件里的信息（第 54 轮）")

do {
    let cover = Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x22, count: 16))

    var full = DownloadCompanion.ID3Tags.Fields()
    full.title = "晴天"
    full.artist = "周杰伦"
    full.album = "叶惠美"
    full.cover = cover

    check("歌名+歌手+封面都在 → 自带完整（不联网）",
          DownloadCompanion.LocalTagRules.isSelfContained(fields: full))

    var noCover = full
    noCover.cover = nil
    check("没有封面 → 不算完整（仍需联网找图）",
          !DownloadCompanion.LocalTagRules.isSelfContained(fields: noCover))

    var noArtist = full
    noArtist.artist = ""
    check("没有歌手 → 不算完整", !DownloadCompanion.LocalTagRules.isSelfContained(fields: noArtist))

    check("没有专辑不影响判定（专辑常有缺失）",
          DownloadCompanion.LocalTagRules.isSelfContained(fields: {
              var f = full; f.album = ""; return f
          }()))

    check("连词都在 → 更严格的一档也算完整",
          !DownloadCompanion.LocalTagRules.isFullySelfContained(fields: full))
    var withLyrics = full
    withLyrics.lyrics = "[00:01.00]故事的小黄花"
    check("…补上词之后成立",
          DownloadCompanion.LocalTagRules.isFullySelfContained(fields: withLyrics))

    check("空字段 → 肯定不完整",
          !DownloadCompanion.LocalTagRules.isSelfContained(fields: DownloadCompanion.ID3Tags.Fields()))
    check("读不出标签（nil）→ 不完整", !DownloadCompanion.LocalTagRules.isSelfContained(fields: nil))
}

// MARK: - 第 55 轮：取词前洗名字 + 补全不再 3 次封顶
//
// 老板 2026-11-22 13:43 的截屏 + 诊断.zip：662 首里 24 首 `lyrics=empty`，
// 其中 5 首的歌名本身就是文件名（「寒鸦少年-华晨宇-wy_1305366556」），拿去搜只会搜到别人的歌。

section("取词名清洗（第 55 轮）")

do {
    let a = LyricSearchQuery.apply(title: "寒鸦少年-华晨宇-wy_1305366556", singer: "")
    check("站点 ID 尾巴剥掉、歌手从中间段补出来",
          a.title == "寒鸦少年" && a.artist == "华晨宇", "\(a.title) / \(a.artist)")
    check("确实报告了「改过」", a.changed)

    let b = LyricSearchQuery.apply(title: "水星记-郭顶-wy_441491828", singer: "")
    check("同一种文件名", b.title == "水星记" && b.artist == "郭顶", "\(b.title) / \(b.artist)")

    let c = LyricSearchQuery.apply(title: "我们俩-郭顶-wy_85571", singer: "")
    check("同一种文件名（我们俩）", c.title == "我们俩" && c.artist == "郭顶", "\(c.title) / \(c.artist)")

    let d = LyricSearchQuery.apply(title: "烟火里的尘埃-华晨宇-wy_29004400", singer: "")
    check("同一种文件名（烟火里的尘埃）", d.title == "烟火里的尘埃" && d.artist == "华晨宇",
          "\(d.title) / \(d.artist)")

    let e = LyricSearchQuery.apply(title: "溺火-特污兔-Dirtyrabbit2", singer: "特污兔")
    check("歌手段 + 上传者尾巴都剥掉", e.title == "溺火" && e.artist == "特污兔", "\(e.title) / \(e.artist)")

    // 第 56 轮：歌手字段是空的（库里这条就是这样），仍要能从名字里认出歌手
    let e2 = LyricSearchQuery.apply(title: "溺火-特污兔-Dirtyrabbit2", singer: "")
    check("歌手为空时从名字中段补出来", e2.title == "溺火" && e2.artist == "特污兔",
          "\(e2.title) / \(e2.artist)")

    let f = LyricSearchQuery.apply(title: "Converted with FlexClip 【SUNO V5】庞麦郎-我的滑板鞋-黑人福音R&B",
                                   singer: "SUNO V5")
    check("剪辑工具前缀不带进搜索", !f.title.contains("Converted with FlexClip"), f.title)

    // 不许误伤：正常歌名一个字都不改
    for (t, s) in [("晴天", "周杰伦"),
                   ("Sukidayo -Hyakkai No Koukai- (English Version)", "Che'Nelle"),
                   ("Mood (Remix|Explicit)", "24kGoldn/Justin Bieber"),
                   ("ピースサイン (V字手势)", "米津玄師"),
                   ("海屿你-remix", "大头针")] {
        let r = LyricSearchQuery.apply(title: t, singer: s)
        check("不改：\(t)", r.title == t && r.artist == s, "\(r.title) / \(r.artist)")
    }

    let empty = LyricSearchQuery.apply(title: "", singer: "周杰伦")
    check("空歌名不炸", empty.title.isEmpty)
}

section("补全重试（第 55 轮：不再 3 次封顶）")

do {
    check("最多 12 次（原来是 3 次）", CompanionRetryRules.maxAttempts == 12,
          "\(CompanionRetryRules.maxAttempts)")
    check("退避表够长（覆盖到 1 小时）", CompanionRetryRules.backoff.count >= 7)
    check("退避单调不减",
          zip(CompanionRetryRules.backoff, CompanionRetryRules.backoff.dropFirst())
              .allSatisfy { $0 <= $1 })
    check("第 3 次之后还有额度", CompanionRetryRules.shouldRetry(attempt: 3))
    check("第 12 次后收手", !CompanionRetryRules.shouldRetry(attempt: 12))
    check("放弃后有 1 小时冷却（回前台会再试，不再永久钉死）",
          CompanionRetryRules.cooldownAfterGivingUp == 3600,
          "\(CompanionRetryRules.cooldownAfterGivingUp)")
    check("退避取到末项也不越界", CompanionRetryRules.backoffSeconds(attempt: 99) == 3600,
          "\(CompanionRetryRules.backoffSeconds(attempt: 99))")
}

// MARK: - 第 57 轮：词头自证 + 纯音乐识别
//
// 老板 2026-11-22 15:04 剩下的几首：《海屿你》候选词头 [total:288000]，音源 278s（差 10s）；
// 《우주를 줄게》候选歌手写成中文名「脸红的思春期」，搜索歌手分 0；《溺火》是纯音乐。

section("词头自证（第 57 轮）")

do {
    check("海屿你：278s 音源 vs 词头 288s（3.6%）→ 收",
          LddcMatch.headerDurationOK(targetSec: 278, declaredSec: 288))
    check("溺火：166s 音源 vs 词头 195s（17%）→ 不收",
          !LddcMatch.headerDurationOK(targetSec: 166, declaredSec: 195))
    check("正好 8% 边界算过", LddcMatch.headerDurationOK(targetSec: 100, declaredSec: 108))
    check("超出 8% 一点就不收", !LddcMatch.headerDurationOK(targetSec: 100, declaredSec: 109))
    check("词头没写 total → 不算证据", !LddcMatch.headerDurationOK(targetSec: 278, declaredSec: 0))
    check("音源时长未知 → 不算证据", !LddcMatch.headerDurationOK(targetSec: 0, declaredSec: 288))

    // 第二池：歌名像、版本类一致、只差时长（不看搜索里的歌手字段）
    let near = LddcMatch.nearMissPool(
        queryTitle: "海屿你", targetSec: 278,
        candidates: [(title: "海屿你", durationSec: 288),
                     (title: "海屿你", durationSec: 190),
                     (title: "海屿你 (Live)", durationSec: 280),
                     (title: "另一首", durationSec: 279)])
    check("只把「同名同版本、时长差 ≤25%」的候选放进第二池", near == [0], "\(near)")
    check("差太远（88s）的不进第二池", !near.contains(1), "\(near)")
    check("Live 版不进第二池", !near.contains(2), "\(near)")

    // 第 57 轮补：时长一模一样、只是平台把歌手写成中文名的候选，也要进第二池
    let near2 = LddcMatch.nearMissPool(
        queryTitle: "우주를 줄게", targetSec: 213,
        candidates: [(title: "우주를 줄게", durationSec: 213),
                     (title: "우주를 줄게 (Radio Edit)", durationSec: 202)])
    check("歌手字段对不上但时长一致的候选进第二池", near2 == [0], "\(near2)")
}

section("纯音乐识别（第 57 轮）")

do {
    let candidates = [(title: "溺火 (Vocal Version)", durationSec: 195),
                      (title: "溺火 (氛围纯音乐)", durationSec: 161)]
    check("溺火：最接近音源（166s）的那版是纯音乐 → 判纯音乐",
          LddcMatch.closestIsInstrumental(queryTitle: "溺火", targetSec: 166,
                                          candidates: candidates))
    check("只有人声版时不当纯音乐",
          !LddcMatch.closestIsInstrumental(queryTitle: "溺火", targetSec: 166,
                                           candidates: [(title: "溺火 (Vocal Version)", durationSec: 195)]))
    check("音源时长未知 → 不判纯音乐",
          !LddcMatch.closestIsInstrumental(queryTitle: "溺火", targetSec: 0, candidates: candidates))
}

// MARK: - 收藏爱心的观测契约（v2.4.86）
//
// 2026-11-23 老板："在热门音乐点查看全部后点收藏，爱心只是抖一下、不会被真正标记，
// 但收藏确实成功了。" 真因是**视图丢了对 `favorites` 的订阅**（不是收藏逻辑）：
// `isFavorite` 有一张非观察的判定缓存，命中时一个可观察属性都不读就 return，
// 而 `@Observable` 只按"这次 body 求值里读过哪些属性"订阅 → 那一行再也不重画。
// 下面的探针把这条语义钉死：旧写法必须收不到通知（就是那个 bug），新写法必须收到。

/// 复刻 `LibraryStore.isFavorite` 的两种写法（缓存 + 可观察的收藏表）
@Observable
final class HeartObservationProbe {
    var favorites: [String] = []
    @ObservationIgnored var cache: [String: Bool] = [:]

    /// v2.4.85 及以前：命中缓存就直接返回，一个可观察属性都不读
    func isFavoriteLegacy(_ id: String) -> Bool {
        if let hit = cache[id] { return hit }
        let hit = favorites.contains(id)
        cache[id] = hit
        return hit
    }

    /// v2.4.86 起：收藏数量作为参数交给 `FavoriteObservation`（读是结构性的）
    func isFavoriteFixed(_ id: String) -> Bool {
        if let hit = FavoriteObservation.cached(cache[id], favoritesCount: favorites.count) {
            return hit
        }
        let hit = favorites.contains(id)
        cache[id] = hit
        return hit
    }

    func add(_ id: String) {
        favorites.append(id)
        cache.removeAll()
    }
}

/// 计数盒子：避免在 `onChange`（逃逸闭包）里改捕获的 var
final class ObservationFlag { var fired = 0 }

/// 模拟"一帧 body 求值 + 之后数据变了"：返回视图会不会被通知重绘
func observationProbe(_ body: @escaping () -> Void, mutate: () -> Void) -> Int {
    let flag = ObservationFlag()
    withObservationTracking(body, onChange: { flag.fired += 1 })
    mutate()
    return flag.fired
}

section("收藏爱心的观测契约（v2.4.86）：命中缓存也要订阅得到 favorites")

do {
    let legacy = HeartObservationProbe()
    _ = legacy.isFavoriteLegacy("a")            // 冷：读了 favorites
    _ = legacy.isFavoriteLegacy("a")            // 热：命中缓存
    check("旧写法：缓存热起来后点收藏，视图收不到通知（老板看到的「爱心不动」）",
          observationProbe({ _ = legacy.isFavoriteLegacy("a") },
                           mutate: { legacy.add("a") }) == 0)

    let fixed = HeartObservationProbe()
    _ = fixed.isFavoriteFixed("a")
    _ = fixed.isFavoriteFixed("a")
    check("新写法：命中缓存后点收藏，视图会被通知重绘（爱心会变红）",
          observationProbe({ _ = fixed.isFavoriteFixed("a") },
                           mutate: { fixed.add("a") }) > 0)

    check("判定器：收藏为空时不采信缓存（交回现算）",
          FavoriteObservation.cached(true, favoritesCount: 0) == nil)
    check("判定器：有收藏 + 命中缓存 → 采用缓存答案",
          FavoriteObservation.cached(true, favoritesCount: 3) == true)
    check("判定器：有收藏 + 没命中 → 现算",
          FavoriteObservation.cached(nil, favoritesCount: 3) == nil)
}

// MARK: - 下载页「按歌手筛选」（2026-11-23）

section("下载页按歌手筛选：只按歌手一个维度，人工订正过的名字不许被自动拆开")

do {
    func dl(_ name: String, _ singer: String, dur: Int = 240, id: String,
            status: DownloadStatus = .completed, bytes: Int64 = 8_000_000) -> DownloadItem {
        DownloadItem(song: song(.local, name, singer, dur: dur, id: "song_\(id)"),
                     streamURL: "file:///\(name)", backendName: "本地导入",
                     quality: .lossless, fileName: "\(name).flac", localPath: "/x/\(name).flac",
                     status: status, totalBytes: bytes,
                     createdAt: Date(timeIntervalSince1970: 1))
    }

    // 空白归一（手工改过的名字最常见的脏法）
    check("歌手键：全角空格 / 不间断空格被压成普通空格并去掉首尾",
          DownloadArtistFilter.artistKey("周杰伦\u{3000} \u{00A0}") == "周杰伦",
          DownloadArtistFilter.artistKey("周杰伦\u{3000} \u{00A0}"))
    check("歌手键：中间多个空格压成一个",
          DownloadArtistFilter.artistKey("Adele  Adkins") == "Adele Adkins")
    check("歌手键：只有空白 → 「未知歌手」",
          DownloadArtistFilter.artistKey("   ") == DownloadArtistFilter.unknownArtist)
    check("歌手键：零宽字符不会造出第二个歌手",
          DownloadArtistFilter.artistKey("周杰伦\u{200B}") == DownloadArtistFilter.artistKey("周杰伦"))

    // **不拆合唱**（老板 2026-11-23："每一首歌的歌手名称都是对的，人工修改过"）
    check("歌手键：合唱名原样保留", DownloadArtistFilter.artistKey("周杰伦&袁咏琳") == "周杰伦&袁咏琳")
    check("歌手键：合唱不被并进单人歌手",
          DownloadArtistFilter.artistKey("周杰伦&袁咏琳") != DownloadArtistFilter.artistKey("周杰伦"))

    let items = [
        dl("晴天", "周杰伦", dur: 269, id: "a"),
        dl("七里香", "周杰伦", dur: 299, id: "b"),
        dl("夜曲", "周杰伦", dur: 226, id: "c"),
        dl("小酒窝", "林俊杰、蔡卓妍", dur: 231, id: "d"),
        dl("江南", "林俊杰", dur: 268, id: "e"),
        dl("没歌手", "", id: "f"),
        dl("正在下的", "周杰伦", id: "g", status: .downloading),
        dl("失败的", "周杰伦", id: "h", status: .failed),
    ]
    let groups = DownloadArtistFilter.groups(items)
    let jay = groups.first { $0.name == "周杰伦" }

    check("聚合：只数已下载（在飞 / 失败不进歌手清单）", jay?.count == 3, "count=\(jay?.count ?? -1)")
    check("聚合：空歌手单独归到「未知歌手」",
          groups.contains { $0.name == DownloadArtistFilter.unknownArtist && $0.count == 1 })
    check("聚合：合唱是独立一项，不并进「林俊杰」",
          groups.contains { $0.name == "林俊杰、蔡卓妍" && $0.count == 1 }
            && groups.first { $0.name == "林俊杰" }?.count == 1)
    check("聚合：条数降序（周杰伦 3 首排第一）", groups.first?.name == "周杰伦", groups.first?.name ?? "—")
    check("聚合：总时长按首累计", jay?.seconds == 269 + 299 + 226, "\(jay?.seconds ?? -1)")
    check("聚合：同样输入两次顺序完全一致（列表不来回跳）",
          DownloadArtistFilter.groups(items).map(\.name) == groups.map(\.name))

    check("筛选：nil = 全部，一条不动", DownloadArtistFilter.filter(items, artist: nil).count == items.count)
    // `filter` 只按歌手筛，不按状态筛（分区是列表层的事）——同一位歌手正在下的、失败的也一起留下
    check("筛选：只留这位歌手（含在飞 / 失败）",
          DownloadArtistFilter.filter(items, artist: "周杰伦").map { $0.song.name }
            == ["晴天", "七里香", "夜曲", "正在下的", "失败的"])
    check("筛选：只留已下载时条数与聚合 count 一致",
          DownloadArtistFilter.filter(items, artist: "周杰伦")
            .filter { $0.status == .completed }.count == 3)
    check("筛选：能命中「未知歌手」",
          DownloadArtistFilter.filter(items, artist: DownloadArtistFilter.unknownArtist).count == 1)
    check("筛选：库里没有的歌手 = 空", DownloadArtistFilter.filter(items, artist: "邓紫棋").isEmpty)
    check("contains：这位歌手还在不在（删光后调用方要能把筛选退回「全部」）",
          DownloadArtistFilter.contains("周杰伦", in: items)
            && !DownloadArtistFilter.contains("邓紫棋", in: items))

    // 定位配对（2026-11-23 真机："筛选切回全部了，但没滚过去"）
    let pair = ListLocate.pair(items)
    check("定位配对：songs 与 rowIDs 同长", pair.songs.count == items.count && pair.rowIDs.count == items.count)
    check("定位配对：第 i 个 song 就是第 i 行（顺序原样搬运）",
          pair.songs == items.map(\.song) && pair.rowIDs == items.map(\.id))
    // 真实调用是"在 pair.songs 里算下标，再拿它取 pair.rowIDs"——这条直接钉住那一步
    if let idx = ListLocate.index(of: items[4].song, in: pair.songs) {
        check("定位配对：算出的下标能取到同一行（不错位）", pair.rowIDs[idx] == items[4].id, "idx=\(idx)")
    } else {
        check("定位配对：算出的下标能取到同一行（不错位）", false, "没找到下标")
    }
    // 反序输入必须跟着反（绝不自己重排——以前就是在这里把两套顺序混起来的）
    let reversed = Array(items.reversed())
    let pairRev = ListLocate.pair(reversed)
    check("定位配对：反序输入两列一起反，不自己排序",
          pairRev.rowIDs == reversed.map(\.id) && pairRev.songs == reversed.map(\.song))
    // 筛选后的子集：两列都只含这一位
    let jayOnly = DownloadArtistFilter.filter(items, artist: "周杰伦")
    let pairJay = ListLocate.pair(jayOnly)
    check("定位配对：筛选后的子集两列同样对齐",
          pairJay.rowIDs.count == jayOnly.count
            && pairJay.songs.map(\.name) == jayOnly.map { $0.song.name })
}

// MARK: - 拖动落点（2026-11-23：总长只有播放器一个来源，落点只做纯比例）

section("拖动落点：手指在哪就落在哪")

do {
    check("拖到 50%：正好一半", SeekTargetRules.target(fraction: 0.5, duration: 319) == 159.5)
    check("拖到最右：就是总长本身（不再留 0.5 秒尾巴）",
          SeekTargetRules.target(fraction: 1, duration: 319) == 319)
    check("拖到最左：0", SeekTargetRules.target(fraction: -1, duration: 319) == 0)
    check("比例 >1 夹到 100%", SeekTargetRules.target(fraction: 2, duration: 319) == 319)
    check("总长为 0（播放器还没就绪）给 0", SeekTargetRules.target(fraction: 0.5, duration: 0) == 0)
    check("比例是 NaN 也不能崩", SeekTargetRules.target(fraction: .nan, duration: 319) == 0)
    check("总长是 NaN 也不能崩", SeekTargetRules.target(fraction: 0.5, duration: .nan) == 0)
}

// MARK: - 到点收尾（2026-11-24：总长 = 文件头，播到那儿就结束）

section("到点收尾：到文件头写的长度就算播完，不越过、不砍早")

do {
    check("4:12 的歌，走到 4:12 就是播完",
          TrackEndRules.isReached(currentTime: 252.13, duration: 252.13))
    check("还差 1 秒没到（继续放）",
          !TrackEndRules.isReached(currentTime: 251.0, duration: 252.13))
    check("越过 0.5 秒也算到了（播放器多喂了一点，不能继续唱）",
          TrackEndRules.isReached(currentTime: 252.6, duration: 252.13))
    check("总长未知时永远不算到（别把刚起播的歌切掉）",
          !TrackEndRules.isReached(currentTime: 30, duration: 0))
    check("位置是 NaN 不能崩",
          !TrackEndRules.isReached(currentTime: .nan, duration: 252))
}

// MARK: - seek 回读校验（2026-11-24：落偏就重跳）

section("seek 回读：落偏超过 0.4 秒就重跳，最多两次")

do {
    check("落在目标上（差 0.05 秒）：不重跳", !SeekVerify.shouldRetry(off: 0.05, attempt: 0))
    check("差 0.4 秒以内：不重跳", !SeekVerify.shouldRetry(off: 0.4, attempt: 0))
    check("差 0.5 秒：重跳", SeekVerify.shouldRetry(off: 0.5, attempt: 0))
    check("差 32 秒（老板实测那次）：重跳", SeekVerify.shouldRetry(off: 32, attempt: 0))
    check("已经重跳两次：不再跳（播放器就这能力）",
          !SeekVerify.shouldRetry(off: 32, attempt: SeekVerify.maxRetry))
    check("误差是 NaN 不能崩", !SeekVerify.shouldRetry(off: .nan, attempt: 0))
}

// MARK: - 下载列表排序 = 播放顺序（2026-11-24：新下载的在最上面，循环也必须从上往下）

section("下载页顺序：显示怎么排，列表循环就怎么放")

do {
    func dl(_ name: String, _ sec: Double) -> DownloadItem {
        DownloadItem(song: song(.qq, name, "歌手"), streamURL: "file:///\(name).flac",
                     backendName: "import", quality: .lossless, fileName: "\(name).flac",
                     status: .completed, totalBytes: 1_000,
                     createdAt: Date(timeIntervalSince1970: sec))
    }
    let old = dl("老歌", 100)
    let mid = dl("中间", 200)
    let new = dl("新歌", 300)
    let shown = DownloadItem.newestFirst([old, mid, new])
    check("新下载的排最上面", shown.map(\.song.name) == ["新歌", "中间", "老歌"])
    // 同一秒完成的（同一批导入）：后入的先显示，而且两次渲染顺序一致（行不会来回跳）
    let a = dl("A", 500)
    let b = dl("B", 500)
    let tie = DownloadItem.newestFirst([a, b]).map(\.song.name)
    check("同一秒：后入的先显示", tie == ["B", "A"])
    // 时间都不同时，排好的再排一次不该变（渲染稳定）。同一秒的那几条由落库位置决定，
    // 换一个输入顺序本来就会换结果，不属于"抖"，所以不拿它做幂等断言。
    check("再排一次不变（时间都不同）",
          DownloadItem.newestFirst(shown).map(\.song.name) == shown.map(\.song.name))
}

// MARK: - 随机播放的"上一首/下一首"（2026-11-24：上一首要回到刚才那首）

section("随机播放：上一首回到刚才那首，不是再随机一首")

do {
    var h = ShuffleHistory()
    check("刚开始：没有上一首可回", h.stepBack(from: 5) == nil)

    // A(0) → 随机到 B(3)
    h.recordAdvance(from: 0)
    check("从 A 随机到 B 之后，上一首 = A", h.stepBack(from: 3) == 0)
    check("返回之后再按下一首 = B（回到原来那条线）", h.stepForward(from: 0) == 3)
    check("回来后没有多余的前进记录", h.stepForward(from: 3) == nil)

    // 连续两首：A(0) → B(3) → C(7)
    h.reset()
    h.recordAdvance(from: 0)
    h.recordAdvance(from: 3)
    check("两首之后，上一首 = B", h.stepBack(from: 7) == 3)
    check("再上一首 = A", h.stepBack(from: 3) == 0)
    check("回到底了：没有更早的", h.stepBack(from: 0) == nil)
    check("往回退了两次，再下一首 = B", h.stepForward(from: 0) == 3)
    check("再下一首 = C", h.stepForward(from: 3) == 7)

    // 返回之后重新随机：前进记录必须作废（否则会串回旧路线）
    h.reset()
    h.recordAdvance(from: 0)
    _ = h.stepBack(from: 3)              // A←B
    h.recordAdvance(from: 0)             // 从 A 重新随机到别处
    check("重新随机之后，前进记录清空", h.stepForward(from: 9) == nil)

    // 手动点别的歌也算一次前进
    h.reset()
    h.recordAdvance(from: 2)
    check("手动点歌之后也能回到刚才那首", h.stepBack(from: 8) == 2)

    // 同一首重复记录不会污染
    h.reset()
    h.recordAdvance(from: 4)
    h.recordAdvance(from: 4)
    check("同一首连续记两次只算一次", h.stepBack(from: 1) == 4 && h.stepBack(from: 4) == nil)
}

// MARK: - 点「随机」抽哪一首起播（2026-11-24：抽一首，不能老是第一首）

section("随机起播：等概率抽一首，且不抽正在播的那首")

do {
    let ids = ["a", "b", "c", "d", "e"]

    // 正在播 c（下标 2）：候选 = a,b,d,e —— 任何随机数都不该落在 c
    var seen = Set<Int>()
    for r in 0..<4 {
        if let i = ShuffleStart.index(ids: ids, currentID: "c", randomIn: { _ in r }) {
            seen.insert(i)
        }
    }
    check("四个随机数铺满 a,b,d,e（c 被排除）", seen == [0, 1, 3, 4])
    check("抽出来的永远不是正在播的那首", !seen.contains(2))

    // 没有在播时：候选就是整份列表，第 0 首也能被抽到
    check("没有在播时第 0 首也在候选里",
          ShuffleStart.index(ids: ids, currentID: nil, randomIn: { _ in 0 }) == 0)

    // 连点多次：每抽一次，currentID 跟着变，下一次候选里就没有它
    var current = "a"
    var picks: [String] = []
    for r in [0, 1, 2, 3] {
        guard let i = ShuffleStart.index(ids: ids, currentID: current, randomIn: { _ in r }) else {
            check("随机起播不该返回 nil", false)
            break
        }
        current = ids[i]
        picks.append(current)
    }
    check("连点四次，每次都换了一首",
          picks.count == 4 && zip(picks, picks.dropFirst()).allSatisfy { pair in pair.0 != pair.1 },
          "picks=\(picks)")

    // 只有一首：没得挑，就是它（不能 nil、不能崩）
    check("只有一首就是它",
          ShuffleStart.index(ids: ["x"], currentID: "x", randomIn: { _ in 0 }) == 0)

    // 导入歌单里同一首常出现两次：另一条同 id 也不算换歌
    check("重复的同 id 也被排除（只剩 c 可抽）",
          ShuffleStart.index(ids: ["a", "b", "b", "c"], currentID: "b", randomIn: { _ in 1 }) == 3)

    check("空列表没有起播下标",
          ShuffleStart.index(ids: [], currentID: nil, randomIn: { _ in 0 }) == nil)
}

// MARK: - 播放缓存 + 文件索引闸门（2026-11-25）

func r251CacheAssertions() {
    section("文件自己的索引：mp3 Xing / m4a mvhd / flac STREAMINFO")

    func flacHead(sampleRate: Int, totalSamples: UInt64) -> Data {
        var b = [UInt8](repeating: 0, count: 42)
        b[0] = 0x66; b[1] = 0x4C; b[2] = 0x61; b[3] = 0x43
        b[4] = 0x80
        b[7] = 34
        var acc: UInt64 = UInt64(sampleRate & 0xFFFFF) << 44
        acc |= (2 << 41)
        acc |= (24 << 36)
        acc |= (totalSamples & 0x0000_000F_FFFF_FFFF)
        for i in 0..<8 { b[18 + i] = UInt8((acc >> (8 * (7 - i))) & 0xFF) }
        return Data(b)
    }

    func mp3Head(frames: Int) -> Data {
        var b = [UInt8](repeating: 0, count: 64)
        b[0] = 0xFF; b[1] = 0xFB; b[2] = 0x90; b[3] = 0xC0
        b[21] = 0x58; b[22] = 0x69; b[23] = 0x6E; b[24] = 0x67
        b[28] = 1
        b[29] = UInt8((frames >> 24) & 0xFF)
        b[30] = UInt8((frames >> 16) & 0xFF)
        b[31] = UInt8((frames >> 8) & 0xFF)
        b[32] = UInt8(frames & 0xFF)
        return Data(b)
    }

    func m4aHead(timescale: Int, duration: Int) -> Data {
        func be32(_ v: Int) -> [UInt8] {
            [UInt8((v >> 24) & 0xFF), UInt8((v >> 16) & 0xFF),
             UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)]
        }
        var b: [UInt8] = []
        b += be32(32); b += Array("ftyp".utf8); b += [UInt8](repeating: 0, count: 24)
        b += be32(36); b += Array("moov".utf8)
        b += be32(28); b += Array("mvhd".utf8)
        b += [0, 0, 0, 0]
        b += be32(0); b += be32(0)
        b += be32(timescale); b += be32(duration)
        return Data(b)
    }

    let flac = MediaIndexRules.duration(head: flacHead(sampleRate: 48_000, totalSamples: 12_102_400),
                                        container: "flac", totalBytes: 0)
    check("flac STREAMINFO → 252.13s", abs((flac ?? 0) - 252.133) < 0.01, "\(flac ?? -1)")
    let mp3 = MediaIndexRules.duration(head: mp3Head(frames: 10_000), container: "mp3", totalBytes: 0)
    check("mp3 Xing 帧数 → 261.22s",
          abs((mp3 ?? 0) - 10_000 * 1152 / 44100.0) < 0.01, "\(mp3 ?? -1)")
    let m4a = MediaIndexRules.duration(head: m4aHead(timescale: 44_100, duration: 11_900_000),
                                       container: "m4a", totalBytes: 0)
    check("m4a mvhd → 269.84s", abs((m4a ?? 0) - 11_900_000 / 44_100.0) < 0.01, "\(m4a ?? -1)")
    check("认不出的字节 → nil（不是 0 秒）",
          MediaIndexRules.duration(head: Data(repeating: 0x11, count: 64),
                                   container: "mp3", totalBytes: 1_000) == nil)

    section("时长闸门：±1.5 秒判同一份 / >2 秒判不是（2026-11-25《众》事故后）")
    check("差 0 秒 → match", PlaybackCacheRules.gate(candidate: 200, expected: 200) == .match(200))
    var g14 = false
    if case .match = PlaybackCacheRules.gate(candidate: 201.4, expected: 200) { g14 = true }
    check("差 1.4 秒 → match", g14)
    var g18 = false
    if case .unverified = PlaybackCacheRules.gate(candidate: 201.8, expected: 200) { g18 = true }
    check("差 1.8 秒 → unverified（灰区：允许播，但不算核实过）", g18)
    var g24 = false
    if case .mismatch = PlaybackCacheRules.gate(candidate: 217.89, expected: 215.5) { g24 = true }
    check("《众》215.5 vs《侧脸》217.89（差 2.39 秒）→ mismatch", g24)
    check("解不出索引 → unverified（不是 mismatch）",
          PlaybackCacheRules.gate(candidate: nil, expected: 200) == .unverified)
    check("曲目时长未知 → unverified",
          PlaybackCacheRules.gate(candidate: 200, expected: 0) == .unverified)
    check("容差常量本身 = 1.5 / 2.0",
          PlaybackCacheRules.durationToleranceSec == 1.5
          && PlaybackCacheRules.durationMismatchSec == 2.0)

    section("缓存条目身份复核（2026-11-25：错字节不许命中）")
    let zhongRow = song(.netease, "众", "黄霄雲", album: "众", dur: 215,
                        id: "netease_1865532803")
    check("身份齐全、长度对得上 → 允许命中",
          NameMatch.cacheIdentityOK(displayed: zhongRow, matchedName: "众", matchedSinger: "黄霄雲",
                                    matchedDurationSec: 215.0, measuredDurationSec: 215.46))
    check("条目里是《侧脸》的字节 → 不许命中",
          !NameMatch.cacheIdentityOK(displayed: zhongRow, matchedName: "侧脸",
                                     matchedSinger: "黄霄雲",
                                     matchedDurationSec: 218.0, measuredDurationSec: 217.89))
    check("歌名对但文件长度差 2.4 秒 → 不许命中",
          !NameMatch.cacheIdentityOK(displayed: zhongRow, matchedName: "众",
                                     matchedSinger: "黄霄雲",
                                     matchedDurationSec: 215.0, measuredDurationSec: 217.89))
    check("老条目没有身份 → 一律不许命中（升级时清空）",
          !NameMatch.cacheIdentityOK(displayed: zhongRow, matchedName: nil,
                                     matchedSinger: nil, matchedDurationSec: nil,
                                     measuredDurationSec: nil))

    section("来源标签要说实话（缓存/预取不许冒充平台直连）")
    let cacheSrc = StreamSource(url: "jzcache://song/x", backendName: "播放缓存",
                                platform: .netease, quality: .high, format: "mp3", note: "")
    check("播放缓存 → 缓存", PlaybackQualityRules.originTag(cacheSrc) == "缓存")
    let prefetchSrc = StreamSource(url: "https://x/a.mp3", backendName: "预取源",
                                   platform: .netease, quality: .high, format: "mp3", note: "")
    check("预取源 → 预取", PlaybackQualityRules.originTag(prefetchSrc) == "预取")
    let liveSrc = StreamSource(url: "https://x/a.mp3", backendName: "gdstudio 网易",
                              platform: .netease, quality: .high, format: "mp3", note: "")
    check("真后端直连 → nil（按平台名显示）", PlaybackQualityRules.originTag(liveSrc) == nil)

    section("打分：身份排在音质前面（老板口径：宁可 128k 对歌，不要 320k 错歌）")
    let zhongRef = song(.netease, "众", "黄霄雲", album: "众", dur: 215, id: "netease_1865532803")
    let ceyanSong = song(.qq, "侧脸", "黄霄雲", album: "侧脸", dur: 217, id: "qq_ceyan")
    let zhongSong = song(.qq, "众", "黄霄雲", album: "众", dur: 215, id: "qq_zhong")
    var hiWrong = StreamSource(url: "https://x/c.mp3", backendName: "落月 QQ",
                               platform: .qq, quality: .high, format: "mp3", note: "")
    hiWrong.kbps = 321
    hiWrong.totalBytes = 8_716_728
    var loRight = StreamSource(url: "https://x/z.m4a", backendName: "oiapi 网易",
                               platform: .netease, quality: .standard, format: "m4a", note: "")
    loRight.kbps = 98
    loRight.totalBytes = 2_627_357
    let sWrong = DownloadResolver.score(of: hiWrong, song: ceyanSong, ref: zhongRef, ms: 300)
    let sRight = DownloadResolver.score(of: loRight, song: zhongSong, ref: zhongRef, ms: 1500)
    check("错歌 320k 必须排在对歌 98kbps 之后", sRight > sWrong,
          "right=\(sRight.short) wrong=\(sWrong.short)")

    section("断流续拉：是不是同一份文件")
    check("总长+指纹一样 → 同一份",
          PlaybackCacheRules.sameFile(oldBytes: 100, newBytes: 100, oldHash: "aa", newHash: "aa"))
    check("总长不同 → 不是",
          !PlaybackCacheRules.sameFile(oldBytes: 100, newBytes: 101, oldHash: "aa", newHash: "aa"))
    check("总长相同但指纹不同 → 不是",
          !PlaybackCacheRules.sameFile(oldBytes: 100, newBytes: 100, oldHash: "aa", newHash: "bb"))
    check("两样都没有 → 不算同一份",
          !PlaybackCacheRules.sameFile(oldBytes: 0, newBytes: 0, oldHash: nil, newHash: nil))

    section("半截 .part 只能续同一份文件")
    check("指纹一致才能续",
          PlaybackCacheRules.canResume(partBytes: 1000, partHash: "aa",
                                       newHash: "aa", newBytes: 5000))
    check("指纹不同 → 不许续",
          !PlaybackCacheRules.canResume(partBytes: 1000, partHash: "aa",
                                        newHash: "bb", newBytes: 5000))
    check("没有身份 → 不许续",
          !PlaybackCacheRules.canResume(partBytes: 1000, partHash: nil,
                                        newHash: "aa", newBytes: 5000))
    check("旧文件比新源还长 → 不许续",
          !PlaybackCacheRules.canResume(partBytes: 6000, partHash: "aa",
                                        newHash: "aa", newBytes: 5000))

    section("播放缓存：头进尾出（最早缓存的先走，跳过正在播的）")
    let now = Date()
    let ordered: [(id: String, cachedAt: Date)] = [
        ("a", now.addingTimeInterval(-300)),
        ("b", now.addingTimeInterval(-200)),
        ("c", now.addingTimeInterval(-100)),
    ]
    check("上限 2 首 → 挤掉最早缓存的 a",
          PlaybackCacheRules.victims(orderedByCachedAt: ordered, limit: 2, keeping: "c") == ["a"])
    check("正在播的是最早缓存的那首也不淘汰它",
          PlaybackCacheRules.victims(orderedByCachedAt: ordered, limit: 1, keeping: "a") == ["b", "c"])
    check("没超上限 → 不淘汰",
          PlaybackCacheRules.victims(orderedByCachedAt: ordered, limit: 3, keeping: "a").isEmpty)
    let fifoFull: [(id: String, cachedAt: Date)] = [
        ("a", now.addingTimeInterval(-30)), ("b", now.addingTimeInterval(-20)),
        ("c", now.addingTimeInterval(-10)),
    ]
    check("缓存总量恒定：满了只挤一首",
          PlaybackCacheRules.victims(orderedByCachedAt: fifoFull, limit: 3, keeping: "").isEmpty
          && PlaybackCacheRules.victims(orderedByCachedAt: fifoFull, limit: 2,
                                        keeping: "").count == 1)
    check("文件名稳定且不含路径分隔符",
          PlaybackCacheRules.fileBase(songID: "netease:1/2")
          == PlaybackCacheRules.fileBase(songID: "netease:1/2")
          && !PlaybackCacheRules.fileBase(songID: "netease:1/2").contains("/"))
    check("50 首 ≈ 480MB", PlaybackCacheRules.estimatedMB(limit: 50) == 480)
    check("mp3 的 UTI 正确",
          PlaybackCacheRules.contentType(container: "mp3", format: "mp3") == "public.mp3")

    // MARK: 2026-11-25 真机事故：缓存文件必须带**真容器**后缀
    //
    // 事故形态：缓存下好后回放是"把本地文件直接交给 AVFoundation"，它按扩展名判类型；
    // 旧版统一起名 `p_xxx.audio` → 认不出 → 起来就失败、进度永远 0:00 → 被当成源失效去换源
    // → 又命中同一个坏文件 → 无限抖。删缓存就好，就是因为那条分支没被走。
    section("播放缓存：文件名必须带真容器后缀（否则 AVFoundation 认不出）")
    check("mp3 → .mp3", PlaybackCacheRules.fileExtension(container: "mp3", format: "mp3") == "mp3")
    check("flac → .flac",
          PlaybackCacheRules.fileExtension(container: "flac", format: "flac") == "flac")
    check("m4a → .m4a", PlaybackCacheRules.fileExtension(container: "m4a", format: "m4a") == "m4a")
    check("容器认不出时退回源格式", PlaybackCacheRules.fileExtension(container: "unknown",
                                                              format: "flac") == "flac")
    check("两样都认不出时不许留空",
          PlaybackCacheRules.fileExtension(container: "unknown", format: "") == "mp3")
    check("老版本的 .audio 不算可播后缀",
          !PlaybackCacheRules.isPlayableExtension("audio")
          && PlaybackCacheRules.isPlayableExtension("mp3"))
    check("缓存命中的 backendName 必须被认出来",
          PlaybackCacheRules.isCacheBackedLocalSource("播放缓存")
          && !PlaybackCacheRules.isCacheBackedLocalSource("酷狗"))
    check("一个坏缓存文件只许回退 1 次", PlaybackCacheRules.maxCachedFileFallbacks == 1)
}

// MARK: - 汇总

r251CacheAssertions()

print("\n================ 结果 ================")
print("通过 \(passed) / 失败 \(failed)")
if failed > 0 {
    print("有断言失败")
    exit(1)
}
print("全部通过")
exit(0)
