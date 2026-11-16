"""把 probe_lyrics.py 产出的 fixture + LDDC 评分参考值转成 Swift 常量文件。

为什么不在测试里读文件：CI 里 swiftc 编的是一个裸命令行程序，运行目录不固定；
把向量直接编成常量最省事，也保证"测试用的样本"和"仓库里的样本"是同一份。

用法：
    python tools/ios/probe_lyrics.py        # 先产出 .build/lyrics-fixtures/
    python tools/ios/gen_lyrics_fixtures.py
输出：
    ios/SelfTest/LyricsFixtures.swift
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import ref_match  # noqa: E402  同目录的 LDDC 评分参考实现

SRC = Path(".build/lyrics-fixtures")
DST = Path("ios/SelfTest/LyricsFixtures.swift")

# LDDC 评分的对照样例：(标题, 候选标题, 歌手, 候选歌手)
MATCH_PAIRS = [
    ("晴天", "晴天", "周杰伦", "周杰伦"),
    ("晴天", "晴天 (Live)", "周杰伦", "周杰伦"),
    ("晴天", "晴天 (钢琴版)", "周杰伦", "纯音乐"),
    ("晴天", "晴天 - 伴奏", "周杰伦", "周杰伦"),
    ("龙文", "龙文 (Live)", "谭晶", "谭晶"),
    ("龙文", "龙文", "谭晶", "谭晶/陈奕迅"),
    ("富士山下", "富士山下（Live）", "陈奕迅", "陈奕迅"),
    ("起风了", "起风了 (原唱 周杰伦)", "买辣椒也用券", "RyaVocal"),
    ("IVORY TOWER", "IVORY", "MYTH & ROID", "MYTH & ROID"),
    ("可惜不是你", "可惜不是你 (Cover)", "梁静茹", "某翻唱"),
    ("因为爱情", "因为爱情", "陈奕迅/王菲", "王菲/陈奕迅"),
]


def read(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8").strip()


def main() -> int:
    required = ["krc.b64", "krc.synth.b64", "krc.synth.expect", "qrc.synth.hex",
                "qrc.synth.expect", "des-vectors.json", "kg-sign.json", "_meta"]
    missing = [n for n in required if not (SRC / n).exists()]
    if missing:
        print(f"❌ 缺少 fixture：{missing}\n先跑 python tools/ios/probe_lyrics.py")
        return 1

    meta = json.loads(read("_meta"))
    krc_synth = json.loads(read("krc.synth.expect"))
    qrc_synth = json.loads(read("qrc.synth.expect"))
    vectors = [(v["plainHex"], v["cipherHex"]) for v in json.loads(read("des-vectors.json"))]

    des_lines = "\n".join(f'        ("{p}", "{c}"),' for p, c in vectors)

    match_lines = []
    for title, cand_title, artist, cand_artist in MATCH_PAIRS:
        ts = ref_match.title_score(title, cand_title)
        asc = ref_match.artist_score(artist, cand_artist)
        total = ref_match.score(title, cand_title, artist, cand_artist)
        match_lines.append(
            f'        ("{title}", "{cand_title}", "{artist}", "{cand_artist}", '
            f"{ts:.3f}, {asc:.3f}, {total:.3f}),"
        )
    match_block = "\n".join(match_lines)

    body = f'''// 歌词/评分测试向量 —— 由 tools/ios/gen_lyrics_fixtures.py 生成，**不要手改**。
//
// 来源：
//   · realKrcBase64：2026-11-16 从酷狗真实接口（complexsearch → lyrics.kugou.com → download）
//     拉到的《{meta["title"]}》KRC 密文，Python 参考实现解出 63 行逐字歌词；
//   · synth*：Python 参考实现「加密」出来的合成样本（KRC / QRC 各一份），给 Swift 做往返断言；
//   · desVectors：6 组 3DES 单块向量，双向验证 Swift 的 DES 移植；
//   · matchVectors：LDDC 评分对照（期望值由 tools/ios/ref_match.py 独立实现算出）。
enum LyricsFixtures {{

    /// 真实酷狗 KRC（base64，4192 字节密文）
    static let realKrcBase64 = "{read('krc.b64')}"

    static let realKrcContains = "{meta["title"]}"
    static let realKrcMinLines = 40

    /// 合成 KRC（base64）
    static let synthKrcBase64 = "{read('krc.synth.b64')}"
    static let synthKrcExpectedLines = {krc_synth["lines"]}
    static let synthKrcExpectedFirstText = "{krc_synth["firstText"]}"
    static let synthKrcExpectedFirstTimeMs = {krc_synth["firstTimeMs"]}
    static let synthKrcExpectedFirstWords = {krc_synth["firstWords"]}

    /// 合成 QRC（hex）
    static let synthQrcHex = "{read('qrc.synth.hex')}"
    static let synthQrcExpectedLines = {qrc_synth["lines"]}
    static let synthQrcExpectedFirstText = "{qrc_synth["firstText"]}"
    static let synthQrcExpectedFirstTimeMs = {qrc_synth["firstTimeMs"]}
    static let synthQrcExpectedFirstWords = {qrc_synth["firstWords"]}

    /// zlib 压缩的 "hello world"（hex）——单独验证解压底座
    static let zlibHelloHex = "789ccb48cdc9c95728cf2fca4901001a0b045d"

    /// 裸 deflate 的 "hello world"（hex）
    static let rawDeflateHelloHex = "cb48cdc9c95728cf2fca490100"

    /// LDDC 评分对照：(标题, 候选标题, 歌手, 候选歌手, 标题分, 歌手分, 总分)
    static let matchVectors: [(title: String, candidateTitle: String, artist: String,
                               candidateArtist: String, titleScore: Double,
                               artistScore: Double, total: Double)] = [
{match_block}
    ]

    /// 酷狗签名的期望 query（固定 mid/clienttime，由 tools/ios/gen_kg_signature.py 算出）
    static let kgSearchSongQuery = "{read("kg-sign.json") and __import__("json").loads(read("kg-sign.json"))["searchSong"]}"
    static let kgLyricQuery = "{read("kg-sign.json") and __import__("json").loads(read("kg-sign.json"))["lyric"]}"

    /// 3DES 单块向量：(明文 hex, 密文 hex)
    static let desVectors: [(plain: String, cipher: String)] = [
{des_lines}
    ]
}}
'''
    DST.write_text(body, encoding="utf-8")
    print(f"✓ 写入 {DST}（{len(body)} 字节，{len(vectors)} 组 DES / {len(MATCH_PAIRS)} 组评分向量）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
