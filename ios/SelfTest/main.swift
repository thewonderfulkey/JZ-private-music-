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
    // 时长防线：差 >5s 才算"不是同一份音频"
    check("时长一致不拦", !PlaybackRules.durationMismatch(actual: 269, expected: 269))
    check("差 4s 不拦", !PlaybackRules.durationMismatch(actual: 273, expected: 269))
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

// MARK: - 发现页口径（编辑精选 / 热门榜单 / 猜你喜欢）

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
    check("编辑精选 4 类", DiscoverCatalog.playlists.count == 4)
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

// MARK: - 收尾口径（可配置跳过上限 / 编辑精选按新旧轮换）

section("收尾口径：可配置跳过上限 / 编辑精选按新旧轮换")

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

    // ② 编辑精选「最久没展示优先」
    let pool = ["A", "B", "C", "D"]
    let none: [String: Int] = [:]
    check("没展示过的按池子顺序",
          DiscoverRules.pickByRecency(pool, key: { $0 }, lastShown: none, day: 1, take: 2) == ["A", "B"])
    let shown = ["A": 5, "B": 5, "C": 1, "D": 1]
    check("最久没展示的优先",
          DiscoverRules.pickByRecency(pool, key: { $0 }, lastShown: shown, day: 6, take: 2) == ["C", "D"],
          "\(DiscoverRules.pickByRecency(pool, key: { $0 }, lastShown: shown, day: 6, take: 2))")
    check("take 超过池子按池子长度",
          DiscoverRules.pickByRecency(pool, key: { $0 }, lastShown: none, day: 1, take: 99).count == 4)
    check("空池子返回空",
          DiscoverRules.pickByRecency([String](), key: { $0 }, lastShown: none, day: 1, take: 3).isEmpty)
    check("换一批会换一组",
          DiscoverRules.pickByRecency(pool, key: { $0 }, lastShown: none, day: 1, take: 2, offset: 1) == ["B", "C"],
          "\(DiscoverRules.pickByRecency(pool, key: { $0 }, lastShown: none, day: 1, take: 2, offset: 1))")
    check("30 首池子取 20 首",
          DiscoverRules.pickByRecency(DiscoverCatalog.playlists[0].seeds,
                                      key: { $0.name }, lastShown: none, day: 1, take: 20).count == 20)
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

// MARK: - 锁屏歌词 / 灵动岛（P4 第三段）

section("锁屏活动：进度 / 歌词截断 / 刷新节流")

do {
    // ① 进度
    check("一半时长 = 0.5", PlaybackActivityRules.progress(current: 135, duration: 270) == 0.5)
    check("超出时长夹到 1", PlaybackActivityRules.progress(current: 300, duration: 270) == 1.0)
    check("负数夹到 0", PlaybackActivityRules.progress(current: -5, duration: 270) == 0.0)
    check("时长未知给 0", PlaybackActivityRules.progress(current: 30, duration: 0) == 0)

    // ② 歌词截断（锁屏只有一行）
    check("短句原样", PlaybackActivityRules.shorten("晴天") == "晴天")
    let longLine = "故事的小黄花从出生那年就飘着童年的荡秋千随记忆一直晃到现在"
    let shortened = PlaybackActivityRules.shorten(longLine)
    check("长句截断到上限", shortened.count == PlaybackActivityRules.maxLyricLength, "\(shortened.count)")
    check("截断以省略号结尾", shortened.hasSuffix("…"))
    check("前后空白被去掉", PlaybackActivityRules.shorten("  晴天  ") == "晴天")

    // ③ 刷新节流
    let now = Date()
    let base = PlaybackActivitySnapshot(title: "晴天", artist: "周杰伦", lyricLine: "A",
                                        progress: 0.1, isPlaying: true, updatedAt: now)
    check("第一次一定刷新",
          PlaybackActivityRules.shouldRefresh(previous: nil, next: base,
                                              lastUpdate: now.addingTimeInterval(-100), now: now))
    let sameContent = PlaybackActivitySnapshot(title: "晴天", artist: "周杰伦", lyricLine: "A",
                                               progress: 0.11, isPlaying: true, updatedAt: now)
    check("内容没变 1 秒内不刷",
          !PlaybackActivityRules.shouldRefresh(previous: base, next: sameContent,
                                               lastUpdate: now.addingTimeInterval(-1), now: now))
    check("内容没变 6 秒后刷（进度条要对齐）",
          PlaybackActivityRules.shouldRefresh(previous: base, next: sameContent,
                                              lastUpdate: now.addingTimeInterval(-7), now: now))
    let nextLine = PlaybackActivitySnapshot(title: "晴天", artist: "周杰伦", lyricLine: "B",
                                            progress: 0.2, isPlaying: true, updatedAt: now)
    check("换歌词行 0.6 秒后立刻刷",
          PlaybackActivityRules.shouldRefresh(previous: base, next: nextLine,
                                              lastUpdate: now.addingTimeInterval(-0.6), now: now))
    check("换歌词行 0.2 秒内仍节流",
          !PlaybackActivityRules.shouldRefresh(previous: base, next: nextLine,
                                               lastUpdate: now.addingTimeInterval(-0.2), now: now))

    // ④ 过期时间：App 被杀后锁屏不该永远显示旧歌
    check("staleDate 是 2 分钟后",
          abs(PlaybackActivityRules.staleDate(from: now).timeIntervalSince(now) - 120) < 0.001)
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

// MARK: - 汇总

print("\n================ 结果 ================")
print("通过 \(passed) / 失败 \(failed)")
if failed > 0 {
    print("有断言失败")
    exit(1)
}
print("全部通过")
exit(0)
