"""把 probe_lyrics.py 产出的 fixture 转成 Swift 常量文件（给 ios/SelfTest 用）。

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
from pathlib import Path

SRC = Path(".build/lyrics-fixtures")
DST = Path("ios/SelfTest/LyricsFixtures.swift")


def read(name: str) -> str:
    return (SRC / name).read_text(encoding="utf-8").strip()


def two_tuples(raw: str) -> list[tuple[str, str]]:
    return [(v["plainHex"], v["cipherHex"]) for v in json.loads(raw)]


def main() -> int:
    required = ["krc.b64", "krc.synth.b64", "krc.synth.expect", "qrc.synth.hex",
                "qrc.synth.expect", "des-vectors.json", "_meta"]
    missing = [n for n in required if not (SRC / n).exists()]
    if missing:
        print(f"❌ 缺少 fixture：{missing}\n先跑 python tools/ios/probe_lyrics.py")
        return 1

    meta = json.loads(read("_meta"))
    krc_synth_expect = json.loads(read("krc.synth.expect"))
    qrc_synth_expect = json.loads(read("qrc.synth.expect"))
    vectors = two_tuples(read("des-vectors.json"))

    vec_lines = "\n".join(
        f'        ("{p}", "{c}"),' for p, c in vectors
    )

    body = f'''// 歌词解密测试向量 —— 由 tools/ios/gen_lyrics_fixtures.py 生成，**不要手改**。
//
// 来源分两类：
//   · realKrcBase64：2026-11-16 从酷狗真实接口（complexsearch → lyrics.kugou.com → download）
//     拉到的《{meta["title"]}》KRC 密文，经 Python 参考实现解密得到 63 行逐字歌词；
//   · synth*：用 Python 参考实现「加密」出来的合成样本（KRC / QRC 各一份），
//     给 Swift 侧做逐字节往返断言；
//   · desVectors：6 组 3DES 单块向量（Python 独立实现生成），双向验证 Swift 的 DES 移植。
enum LyricsFixtures {{

    /// 真实酷狗 KRC（base64，4192 字节密文）
    static let realKrcBase64 = "{read('krc.b64')}"

    /// 真实 KRC 解出来的明文应当包含这个关键词
    static let realKrcContains = "{meta["title"]}"

    /// 真实 KRC 的行数下限（实测 63 行；清洗可能丢极少数不可用行，所以给下限）
    static let realKrcMinLines = 40

    /// 合成 KRC（base64）
    static let synthKrcBase64 = "{read('krc.synth.b64')}"

    /// 合成 KRC 的明文逐字：
    static let synthKrcExpectedLines = {krc_synth_expect["lines"]}
    static let synthKrcExpectedFirstText = "{krc_synth_expect["firstText"]}"
    static let synthKrcExpectedFirstTimeMs = {krc_synth_expect["firstTimeMs"]}
    static let synthKrcExpectedFirstWords = {krc_synth_expect["firstWords"]}

    /// 合成 QRC（hex）
    static let synthQrcHex = "{read('qrc.synth.hex')}"

    static let synthQrcExpectedLines = {qrc_synth_expect["lines"]}
    static let synthQrcExpectedFirstText = "{qrc_synth_expect["firstText"]}"
    static let synthQrcExpectedFirstTimeMs = {qrc_synth_expect["firstTimeMs"]}
    static let synthQrcExpectedFirstWords = {qrc_synth_expect["firstWords"]}

    /// zlib 压缩的 "hello world"（hex）——用来单独验证解压底座
    static let zlibHelloHex = "789ccb48cdc9c95728cf2fca4901001a0b045d"

    /// 3DES 单块向量：(明文 hex, 密文 hex)
    static let desVectors: [(plain: String, cipher: String)] = [
{vec_lines}
    ]
}}
'''
    DST.write_text(body, encoding="utf-8")
    print(f"✓ 写入 {DST}（{len(body)} 字节，{len(vectors)} 组 DES 向量）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
