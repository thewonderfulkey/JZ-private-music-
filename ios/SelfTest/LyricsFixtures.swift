// 歌词/评分测试向量 —— 由 tools/ios/gen_lyrics_fixtures.py 生成，**不要手改**。
//
// 来源：
//   · realKrcBase64：2026-11-16 从酷狗真实接口（complexsearch → lyrics.kugou.com → download）
//     拉到的《晴天》KRC 密文，Python 参考实现解出 63 行逐字歌词；
//   · synth*：Python 参考实现「加密」出来的合成样本（KRC / QRC 各一份），给 Swift 做往返断言；
//   · desVectors：6 组 3DES 单块向量，双向验证 Swift 的 DES 移植；
//   · matchVectors：LDDC 评分对照（期望值由 tools/ios/ref_match.py 独立实现算出）。
enum LyricsFixtures {

    /// 真实酷狗 KRC（base64，4192 字节密文）
    static let realKrcBase64 = "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"

    static let realKrcContains = "晴天"
    static let realKrcMinLines = 40

    /// 合成 KRC（base64）
    static let synthKrcBase64 = "AAAAADidPOYFfLYHRbDulsTEPvopwnfl1ykdm1qHmQ0nV0Zgl+9IX9O7WVZyIqHgAn8hB4F0fKOYpT2IpQnu1AHtYLvNXSOQRttiBWsMUu7bT6sxVuCkMruW9ly50QbA4wpaTPtgrEaTKEDc+29YaCyvgy8YUeyIrBj4lhBr+UD7eREg8ml+wjYokJzHjmhPNaVAsLqfYc4ALvT9n87sULDDv6TK4apLRMIdFCIaapdmRd+VJUl7t1Td5Xgmn9a7fitGOZj9E4vE4LdSCAHIVQtUQATnmy6eOpNNSgXESvHoDq4lmraJSz6hxbvP8w3jRK569/U8OREs9kewHIpO7awuWHsJWFvvgSOVGSI6kqUB+J2gemSacCAq/KNC2vKDrp7Qr18YByOumd5LplOQ28NwZKE8"
    static let synthKrcExpectedLines = 6
    static let synthKrcExpectedFirstText = "晴天 - 周杰伦"
    static let synthKrcExpectedFirstTimeMs = 0
    static let synthKrcExpectedFirstWords = 3

    /// 合成 QRC（hex）
    static let synthQrcHex = "220fcb8b68a1b45186748dfc9260ab087eaea2d46b924b4c31418cfbea1fa9842e5f723b2c230d551a68421946e5a2d0e201c492b56d0d09a11f37c319face6a882826018596db76d8ee965de80e6c75332e7f77a08e5882857fa5908adf9d9351e52b7b3762b280eee194d29697513754e062801c06c339a38b67c225b71c79af7f0680a4fc754c894de749c0df213eede9a7cfedb586538af08f645f77c5fa03113b4f9193de35a2ff3cc43b6f2a4b66b6ce13ca7b5ab8bc62f39a6b8ab8e09b1b6a774f0406e404411835cff354f3c22bb03f517a2d404a368eec636d7ae56a37b6ec3d5c3552acd5563238316f323b15fd265380d6d9bf86d0dd4ca2923627ff071655fb4ed68f80c51cf27547dadc0a880403f47dadc81634237bcb212281bee1d0c13ea4f39d9783cc7e8c0d251736d613ca8806d0650e0a39de19768e3cd6e9957d5708b5c14a6347eafc6b73b1572b98c4d8992c7089730c75867d53a891a5f1e127e1034ac924ec61c711158888bbd3917219ffa6d39b280cfc098d36aed11c1059e375163694ef8fbfb6f8bcb2cfd8a549234b5b0e0db6abc029f75c27edf7b2ad26c3e1162acfb490af75cd330044feb9dc8931cf20bf10c70eed1ff88a72d08a40de373ce260ceabb119adedb2b305778bc5e978b388f19de20eec0d55f4ce184e99653897f35baa49c40d2ccbb98f1ff96e86b35f92bed8f3df8b13b6e0efb73301"
    static let synthQrcExpectedLines = 8
    static let synthQrcExpectedFirstText = "晴天 - 周杰伦"
    static let synthQrcExpectedFirstTimeMs = 0
    static let synthQrcExpectedFirstWords = 3

    /// zlib 压缩的 "hello world"（hex）——单独验证解压底座
    static let zlibHelloHex = "789ccb48cdc9c95728cf2fca4901001a0b045d"

    /// 裸 deflate 的 "hello world"（hex）
    static let rawDeflateHelloHex = "cb48cdc9c95728cf2fca490100"

    /// LDDC 评分对照：(标题, 候选标题, 歌手, 候选歌手, 标题分, 歌手分, 总分)
    static let matchVectors: [(title: String, candidateTitle: String, artist: String,
                               candidateArtist: String, titleScore: Double,
                               artistScore: Double, total: Double)] = [
        ("晴天", "晴天", "周杰伦", "周杰伦", 100.000, 100.000, 100.000),
        ("晴天", "晴天 (Live)", "周杰伦", "周杰伦", 36.364, 100.000, 68.182),
        ("晴天", "晴天 (钢琴版)", "周杰伦", "纯音乐", 40.000, 0.000, 20.000),
        ("晴天", "晴天 - 伴奏", "周杰伦", "周杰伦", 44.444, 100.000, 72.222),
        ("龙文", "龙文 (Live)", "谭晶", "谭晶", 36.364, 100.000, 68.182),
        ("龙文", "龙文", "谭晶", "谭晶/陈奕迅", 100.000, 57.143, 78.571),
        ("富士山下", "富士山下（Live）", "陈奕迅", "陈奕迅", 57.143, 100.000, 78.571),
        ("起风了", "起风了 (原唱 周杰伦)", "买辣椒也用券", "RyaVocal", 40.000, 0.000, 20.000),
        ("IVORY TOWER", "IVORY", "MYTH & ROID", "MYTH & ROID", 62.500, 100.000, 81.250),
        ("可惜不是你", "可惜不是你 (Cover)", "梁静茹", "某翻唱", 55.556, 0.000, 27.778),
        ("因为爱情", "因为爱情", "陈奕迅/王菲", "王菲/陈奕迅", 100.000, 100.000, 100.000),
    ]

    /// 酷狗签名的期望 query（固定 mid/clienttime，由 tools/ios/gen_kg_signature.py 算出）
    static let kgSearchSongQuery = "appid=3116&clienttime=1700000000&clientver=11070&dfid=-&iscorrection=1&keyword=%E6%99%B4%E5%A4%A9%20%E5%91%A8%E6%9D%B0%E4%BC%A6&mid=abcdef0123456789&page=1&pagesize=20&platform=AndroidFilter&sorttype=0&token=&userid=0&uuid=-&signature=cfeaa7ca4091ae75a4ca48e2517baa4f"
    static let kgLyricQuery = "album_audio_id=123456&appid=3116&clientver=11070&duration=269000&hash=abc123def456&keyword=%E5%91%A8%E6%9D%B0%E4%BC%A6%20-%20%E6%99%B4%E5%A4%A9&lrctxt=1&man=no&signature=64b79f297b3b5e6b86992ebbdd761310"

    /// 3DES 单块向量：(明文 hex, 密文 hex)
    static let desVectors: [(plain: String, cipher: String)] = [
        ("4a5a544553543031", "e6ba70094ac5bc6d"),
        ("4c59524943532121", "701266e48b23ca05"),
        ("3031323334353637", "2b97510549c4e97c"),
        ("4142434445464748", "fe1dd2e23bbba6e8"),
        ("e4b8ade69687e6ad", "306845985a5fb1d5"),
        ("6b72637172633132", "e5e1492b660c7581"),
    ]
}
