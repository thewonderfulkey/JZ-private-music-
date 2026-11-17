import Foundation

// MARK: - 预置歌单的解析结果（**由脚本生成，别手改**）
//
// 老板 r85：「编辑精选里原来是文字，现在文字转歌曲，我希望一步到位，别每次点进去都等。」
// 这里就是写死的那一份：4 个预置歌单（歌名+歌手）→「酷我 rid / 专辑 / 时长 / 封面」。
// 生成脚本：`tools/ios/gen_baked_seeds.py`（走 search.kuwo.cn，多种参数合并候选，只收原版）。
// 生成时间：2026-11-18；命中 107/120 首（没命中的那几首照常走运行时搜索，行内会先显示占位）。
//
// 键与 `ResolvedSongCache.key` 完全同口径（歌名|歌手，小写去首尾空白）。
enum BakedSeedSongs {

    struct Item {
        let platformID: String
        let name: String
        let singer: String
        let album: String
        let duration: Int
        let pic: String
    }

    static let generatedAt = "2026-11-18"

    static let byKey: [String: Item] = [
"晴天|周杰伦": Item(platformID: "228908", name: "晴天", singer: "周杰伦", album: "叶惠美", duration: 269, pic: "https://img1.kuwo.cn/wmvpic/324/s4s75/52/1458871193.jpg"),
"七里香|周杰伦": Item(platformID: "94237", name: "七里香", singer: "周杰伦", album: "七里香", duration: 299, pic: "https://img1.kuwo.cn/wmvpic/324/21/22/2447167998.jpg"),
"青花瓷|周杰伦": Item(platformID: "23928868", name: "青花瓷", singer: "周杰伦\\&那英", album: "", duration: 290, pic: ""),
"告白气球|周杰伦": Item(platformID: "7149583", name: "告白气球", singer: "周杰伦", album: "周杰伦的床边故事", duration: 215, pic: "https://img1.kuwo.cn/wmvpic/324/62/99/2969335178.jpg"),
"稻香|周杰伦": Item(platformID: "440613", name: "稻香", singer: "周杰伦", album: "魔杰座", duration: 223, pic: "https://img1.kuwo.cn/wmvpic/324/s4s90/99/2794876793.jpg"),
"夜曲|周杰伦": Item(platformID: "345182154", name: "夜曲", singer: "周杰伦_", album: "范特西", duration: 214, pic: ""),
"安静|周杰伦": Item(platformID: "156518", name: "安静", singer: "周杰伦", album: "范特西", duration: 334, pic: "https://img1.kuwo.cn/wmvpic/324/s4s62/11/1498660881.jpg"),
"演员|薛之谦": Item(platformID: "6468891", name: "演员", singer: "薛之谦", album: "绅士", duration: 261, pic: "https://img1.kuwo.cn/wmvpic/324/1/82/2466107719.jpg"),
"动物世界|薛之谦": Item(platformID: "35712552", name: "动物世界", singer: "薛之谦", album: "渡 The Crossing", duration: 230, pic: "https://img1.kuwo.cn/wmvpic/324/63/21/589291717.jpg"),
"后来|刘若英": Item(platformID: "96765035", name: "后来", singer: "刘若英", album: "2020 刘若英陪你 献上录音专辑", duration: 309, pic: "https://img1.kuwo.cn/wmvpic/324/s4s46/9/2202523588.jpg"),
"成都|赵雷": Item(platformID: "345182170", name: "成都", singer: "赵雷", album: "成都", duration: 328, pic: ""),
"泡沫|邓紫棋": Item(platformID: "300085735", name: "泡沫", singer: "张新航\\&邓 紫 棋", album: "泡沫", duration: 259, pic: ""),
"小幸运|田馥甄": Item(platformID: "184037058", name: "小幸运", singer: "田馥甄", album: "", duration: 309, pic: ""),
"平凡之路|朴树": Item(platformID: "33849066", name: "平凡之路", singer: "朴树", album: "猎户星座实体CD版", duration: 301, pic: "https://img1.kuwo.cn/wmvpic/324/71/3/1166196902.jpg"),
"江南|林俊杰": Item(platformID: "1079171", name: "江南", singer: "林俊杰", album: "西界", duration: 260, pic: ""),
"曹操|林俊杰": Item(platformID: "125802", name: "曹操", singer: "林俊杰", album: "曹操", duration: 242, pic: "https://img1.kuwo.cn/wmvpic/324/25/85/1716576903.jpg"),
"童话|光良": Item(platformID: "126543", name: "童话", singer: "光良", album: "童话", duration: 244, pic: ""),
"勇气|梁静茹": Item(platformID: "164700", name: "勇气", singer: "梁静茹", album: "勇气", duration: 239, pic: "https://img1.kuwo.cn/wmvpic/324/s4s41/16/136348223.jpg"),
"听海|张惠妹": Item(platformID: "64462", name: "听海", singer: "张惠妹", album: "Bad Boy", duration: 318, pic: "https://img1.kuwo.cn/wmvpic/324/37/54/3227240435.jpg"),
"红豆|王菲": Item(platformID: "326890", name: "红豆", singer: "王菲", album: "Eyes On Me", duration: 260, pic: "https://img1.kuwo.cn/wmvpic/324/s4s17/51/1348496997.jpg"),
"十年|陈奕迅": Item(platformID: "326071801", name: "十年", singer: "陈奕迅", album: "人生有个真正朋友的确好极", duration: 205, pic: ""),
"好久不见|陈奕迅": Item(platformID: "303316116", name: "好久不见", singer: "聚来提\\&陈奕迅", album: "", duration: 224, pic: ""),
"模特|李荣浩": Item(platformID: "3514084", name: "模特", singer: "李荣浩", album: "模特", duration: 306, pic: "https://img1.kuwo.cn/wmvpic/324/s4s1/56/573126290.jpg"),
"年少有为|李荣浩": Item(platformID: "55724544", name: "年少有为", singer: "李荣浩", album: "耳朵", duration: 279, pic: "https://img1.kuwo.cn/wmvpic/324/s4s50/19/2460928507.jpg"),
"像我这样的人|毛不易": Item(platformID: "356022591", name: "像我这样的人", singer: "毛不易", album: "", duration: 176, pic: ""),
"光辉岁月|beyond": Item(platformID: "19534406", name: "光辉岁月", singer: "BEYOND", album: "命运派对", duration: 302, pic: ""),
"真的爱你|beyond": Item(platformID: "508098433", name: "真的爱你", singer: "BEYOND", album: "MULTIVERSE OF CINEPOLY 40TH ANNIVERSARY - Beyond", duration: 277, pic: ""),
"不再犹豫|beyond": Item(platformID: "68775533", name: "不再犹豫", singer: "BEYOND", album: "Beyond The Stage", duration: 261, pic: "https://img1.kuwo.cn/wmvpic/324/s4s91/8/645481433.jpg"),
"灰色轨迹|beyond": Item(platformID: "25251951", name: "灰色轨迹", singer: "BEYOND", album: "环球影音启示录-Beyond", duration: 327, pic: ""),
"冷雨夜|beyond": Item(platformID: "68775530", name: "冷雨夜", singer: "BEYOND", album: "Beyond The Stage", duration: 371, pic: "https://img1.kuwo.cn/wmvpic/324/47/5/772725014.jpg"),
"amani|beyond": Item(platformID: "995747", name: "Amani", singer: "BEYOND", album: "Beyond The Stage", duration: 288, pic: "https://img1.kuwo.cn/wmvpic/324/76/61/475430622.jpg"),
"富士山下|陈奕迅": Item(platformID: "28423286", name: "富士山下", singer: "陈奕迅", album: "What&apos;s Going On...?", duration: 259, pic: ""),
"浮夸|陈奕迅": Item(platformID: "110247", name: "浮夸", singer: "陈奕迅", album: "U 87", duration: 283, pic: "https://img1.kuwo.cn/wmvpic/324/39/92/2622545373.jpg"),
"单车|陈奕迅": Item(platformID: "320058", name: "单车", singer: "陈奕迅", album: "Shall We Dance? Shall We Talk!", duration: 211, pic: "https://img1.kuwo.cn/wmvpic/324/37/41/1636926231.jpg"),
"k歌之王|陈奕迅": Item(platformID: "125120", name: "K歌之王", singer: "陈奕迅", album: "打得火热", duration: 222, pic: "https://img1.kuwo.cn/wmvpic/324/60/74/66745326.jpg"),
"shall we talk|陈奕迅": Item(platformID: "320057", name: "Shall We Talk", singer: "陈奕迅", album: "Shall We Dance? Shall We Talk!", duration: 227, pic: "https://img1.kuwo.cn/wmvpic/324/47/79/4137158325.jpg"),
"红日|李克勤": Item(platformID: "192493408", name: "红日", singer: "李克勤", album: "宝丽金真开心精选 4", duration: 291, pic: ""),
"千千阙歌|陈慧娴": Item(platformID: "386146885", name: "千千阙歌", singer: "陈慧娴", album: "林振强 依然爱不完101", duration: 300, pic: ""),
"处处吻|杨千嬅": Item(platformID: "97878464", name: "处处吻", singer: "杨千嬅", album: "Simply Me", duration: 199, pic: ""),
"遥远的她|张学友": Item(platformID: "25251970", name: "遥远的她", singer: "张学友", album: "遥远的她•Amour", duration: 257, pic: "https://img1.kuwo.cn/wmvpic/324/33/77/3083583796.jpg"),
"每天爱你多一些|张学友": Item(platformID: "158288", name: "每天爱你多一些", singer: "张学友", album: "吻别", duration: 278, pic: "https://img1.kuwo.cn/wmvpic/324/s4s14/28/1695820981.jpg"),
"只想一生跟你走|张学友": Item(platformID: "54272", name: "只想一生跟你走", singer: "张学友", album: "传奇 - 我与你", duration: 311, pic: "https://img1.kuwo.cn/wmvpic/324/70/84/1801140980.jpg"),
"暗涌|王菲": Item(platformID: "627070057", name: "暗涌", singer: "王菲", album: "你不能没听过的粤语金曲", duration: 260, pic: ""),
"约定|王菲": Item(platformID: "169628", name: "约定", singer: "王菲", album: "玩具", duration: 267, pic: "https://img1.kuwo.cn/wmvpic/324/76/2/1064790451.jpg"),
"一生所爱|卢冠廷": Item(platformID: "233271928", name: "一生所爱", singer: "卢冠廷\\&莫文蔚", album: "武侠音乐精装特辑", duration: 273, pic: ""),
"上海滩|叶丽仪": Item(platformID: "41591290", name: "上海滩", singer: "叶丽仪", album: "叶丽仪48周年", duration: 199, pic: ""),
"万水千山总是情|汪明荃": Item(platformID: "19296051", name: "万水千山总是情", singer: "汪明荃", album: "港台影视怀旧金曲", duration: 181, pic: ""),
"倩女幽魂|张国荣": Item(platformID: "462355", name: "倩女幽魂", singer: "张国荣", album: "港台影视怀旧金曲", duration: 219, pic: "https://img1.kuwo.cn/wmvpic/324/33/46/57680087.jpg"),
"风继续吹|张国荣": Item(platformID: "319718", name: "风继续吹", singer: "张国荣", album: "常在心头", duration: 308, pic: ""),
"沉默是金|张国荣": Item(platformID: "154948", name: "沉默是金", singer: "许冠杰\\&张国荣", album: "跨世纪情歌典藏", duration: 246, pic: "https://img1.kuwo.cn/wmvpic/324/34/86/3759346838.jpg"),
"体面|于文文": Item(platformID: "56474696", name: "体面", singer: "于文文", album: "尚未界定Undefined", duration: 282, pic: "https://img1.kuwo.cn/wmvpic/324/37/84/3863141236.jpg"),
"后会无期|邓紫棋": Item(platformID: "204523711", name: "后会无期", singer: "G.E.M.邓紫棋", album: "后会无期", duration: 223, pic: ""),
"大鱼|周深": Item(platformID: "411833533", name: "大鱼", singer: "周深", album: "", duration: 270, pic: ""),
"凉凉|张碧晨 杨宗纬": Item(platformID: "188247793", name: "凉凉", singer: "杨宗纬\\&张碧晨", album: "", duration: 362, pic: ""),
"爱如潮水|张信哲": Item(platformID: "993948", name: "爱如潮水", singer: "张信哲", album: "爱情海", duration: 272, pic: "https://img1.kuwo.cn/wmvpic/324/70/98/3014653093.jpg"),
"匆匆那年|王菲": Item(platformID: "376534134", name: "匆匆那年", singer: "王菲", album: "匆匆那年 电影原声带", duration: 240, pic: ""),
"传奇|李健": Item(platformID: "150208", name: "传奇", singer: "李健", album: "似水流年", duration: 294, pic: "https://img1.kuwo.cn/wmvpic/324/76/82/579540919.jpg"),
"贝加尔湖畔|李健": Item(platformID: "330272362", name: "贝加尔湖畔", singer: "李健", album: "李健自选辑2", duration: 245, pic: ""),
"卷珠帘|霍尊": Item(platformID: "51564671", name: "卷珠帘", singer: "霍尊", album: "天韵·霍尊", duration: 272, pic: ""),
"不将就|李荣浩": Item(platformID: "206111213", name: "不将就", singer: "李荣浩", album: "不将就", duration: 312, pic: ""),
"说散就散|袁娅维": Item(platformID: "299056938", name: "说散就散", singer: "袁娅维TIA RAY", album: "", duration: 242, pic: ""),
"卡路里|火箭少女101": Item(platformID: "299984548", name: "卡路里", singer: "火箭少女101", album: "卡路里", duration: 232, pic: ""),
"追光者|岑宁儿": Item(platformID: "147341218", name: "追光者", singer: "岑宁儿\\&Joker one", album: "", duration: 238, pic: ""),
"终于等到你|张靓颖": Item(platformID: "308088122", name: "终于等到你", singer: "张靓颖", album: "咱们结婚吧 电视剧原声带", duration: 295, pic: ""),
"当爱已成往事|张国荣": Item(platformID: "28668074", name: "当爱已成往事", singer: "张国荣", album: "永远张国荣 最完整精选全纪录", duration: 302, pic: ""),
"滚滚红尘|陈淑桦": Item(platformID: "331664469", name: "滚滚红尘", singer: "罗大佑\\&陈淑桦", album: "港台怀旧影视金曲", duration: 186, pic: ""),
"甜蜜蜜|邓丽君": Item(platformID: "105819", name: "甜蜜蜜", singer: "邓丽君", album: "邓丽君金曲选03", duration: 212, pic: "https://img1.kuwo.cn/wmvpic/324/91/66/1604709073.jpg"),
"新不了情|万芳": Item(platformID: "29149094", name: "新不了情", singer: "万芳", album: "新不了情 电影原声带", duration: 267, pic: "https://img1.kuwo.cn/wmvpic/324/27/29/477851649.jpg"),
"星语心愿|张柏芝": Item(platformID: "40718468", name: "星语心愿", singer: "任贤齐\\&张柏芝", album: "", duration: 269, pic: ""),
"我愿意|王菲": Item(platformID: "109321", name: "我愿意", singer: "王菲", album: "王菲的故事", duration: 269, pic: "https://img1.kuwo.cn/wmvpic/192/38/37/2844811981.jpg"),
"人间|王菲": Item(platformID: "1033975", name: "人间", singer: "王菲", album: "你王菲所以我王菲", duration: 287, pic: ""),
"萱草花|张小斐": Item(platformID: "474373945", name: "萱草花", singer: "张小斐\\&赵允哲\\&DJ Wave", album: "", duration: 267, pic: ""),
"这世界那么多人|莫文蔚": Item(platformID: "488369845", name: "这世界那么多人", singer: "莫文蔚\\&月亮做证扒带编曲习", album: "", duration: 300, pic: ""),
"shape of you|ed sheeran": Item(platformID: "15240778", name: "Shape of You", singer: "Ed Sheeran", album: "Shape of You", duration: 233, pic: "https://img1.kuwo.cn/wmvpic/324/46/64/4268541486.jpg"),
"perfect|ed sheeran": Item(platformID: "21141303", name: "Perfect", singer: "Ed Sheeran", album: "÷ (Deluxe)", duration: 263, pic: "https://img1.kuwo.cn/wmvpic/324/71/68/3448202961.jpg"),
"thinking out loud|ed sheeran": Item(platformID: "6330457", name: "Thinking Out Loud", singer: "Ed Sheeran", album: "Brit Awards 2015", duration: 281, pic: "https://img1.kuwo.cn/wmvpic/324/74/65/476893863.jpg"),
"photograph|ed sheeran": Item(platformID: "4798769", name: "Photograph", singer: "Ed Sheeran", album: "x (Deluxe Edition)", duration: 258, pic: "https://img1.kuwo.cn/wmvpic/324/s4s26/58/4012579921.jpg"),
"let it go|idina menzel": Item(platformID: "495289321", name: "Let It Go", singer: "Idina Menzel", album: "冰雪奇缘 日版 OST", duration: 224, pic: ""),
"hello|adele": Item(platformID: "6686351", name: "Hello", singer: "Adele", album: "25", duration: 295, pic: ""),
"someone like you|adele": Item(platformID: "2238175", name: "Someone Like You", singer: "Adele", album: "Someone Like You", duration: 285, pic: ""),
"rolling in the deep|adele": Item(platformID: "152878892", name: "Rolling in the Deep", singer: "Adele、Biley Cyrus", album: "", duration: 371, pic: ""),
"counting stars|onerepublic": Item(platformID: "64992797", name: "Counting Stars", singer: "OneRepublic", album: "Native", duration: 257, pic: "https://img1.kuwo.cn/wmvpic/324/s4s79/86/2003199977.jpg"),
"secrets|onerepublic": Item(platformID: "146393063", name: "Secrets", singer: "OneRepublic", album: "Waking Up (Explicit)", duration: 224, pic: ""),
"sugar|maroon 5": Item(platformID: "30362042", name: "Sugar", singer: "Maroon 5", album: "Sugar", duration: 235, pic: "https://img1.kuwo.cn/wmvpic/324/78/77/1508151454.jpg"),
"memories|maroon 5": Item(platformID: "181165924", name: "Memories", singer: "Maroon 5", album: "JORDI (Deluxe)", duration: 189, pic: "https://img1.kuwo.cn/wmvpic/324/15/96/4002056112.jpg"),
"payphone|maroon 5": Item(platformID: "1870477", name: "Payphone", singer: "Maroon 5\\&Wiz Khalifa", album: "Payphone", duration: 231, pic: "https://img1.kuwo.cn/wmvpic/324/87/12/2616140710.jpg"),
"faded|alan walker": Item(platformID: "27879704", name: "Faded", singer: "Suby Cheng\\&周禹成\\&Alan Walker", album: "Suby Cheng单曲合集", duration: 175, pic: ""),
"alone|alan walker": Item(platformID: "12442905", name: "Alone", singer: "Alan Walker", album: "Alone", duration: 161, pic: "https://img1.kuwo.cn/wmvpic/324/s4s45/89/3561085252.jpg"),
"havana|camila cabello": Item(platformID: "40073245", name: "Havana", singer: "Camila Cabello\\&Young Thug", album: "Camila", duration: 217, pic: "https://img1.kuwo.cn/wmvpic/324/13/81/2253862454.jpg"),
"señorita|camila cabello  shawn mendes": Item(platformID: "83081023", name: "Señorita", singer: "Shawn Mendes\\&Camila Cabello", album: "Romance (Explicit)", duration: 190, pic: "https://img1.kuwo.cn/wmvpic/324/60/8/1333605070.jpg"),
"bad guy|billie eilish": Item(platformID: "86626563", name: "bad guy", singer: "Billie Eilish", album: "2020 GRAMMY® Nominees", duration: 192, pic: "https://img1.kuwo.cn/wmvpic/324/s4s31/41/3527115319.jpg"),
"happier|marshmello": Item(platformID: "52246042", name: "Happier", singer: "Marshmello\\&Bastille", album: "Happier", duration: 214, pic: "https://img1.kuwo.cn/wmvpic/324/s4s66/68/1332443670.jpg"),
"thunder|imagine dragons": Item(platformID: "41300915", name: "Thunder", singer: "Imagine Dragons", album: "Top 30 US (Explicit)", duration: 187, pic: ""),
"believer|imagine dragons": Item(platformID: "61922277", name: "Believer", singer: "Imagine Dragons\\&Lil Wayne", album: "Believer", duration: 219, pic: "https://img1.kuwo.cn/wmvpic/324/3/91/3275925093.jpg"),
"numb|linkin park": Item(platformID: "269467235", name: "Numb", singer: "Linkin Park", album: "Meteora 20th Anniversary Edition (Explicit)", duration: 187, pic: ""),
"in the end|linkin park": Item(platformID: "69322924", name: "In the End", singer: "Linkin Park", album: "Hybrid Theory (Bonus Edition)", duration: 216, pic: ""),
"yellow|coldplay": Item(platformID: "240945", name: "Yellow", singer: "Coldplay", album: "Yellow", duration: 266, pic: "https://img1.kuwo.cn/wmvpic/324/6/96/1919959724.jpg"),
"viva la vida|coldplay": Item(platformID: "18789354", name: "Viva La Vida", singer: "Coldplay", album: "Viva La Vida or Death and All His Friends", duration: 241, pic: "https://img1.kuwo.cn/wmvpic/324/20/69/1703576300.jpg"),
"uptown funk|bruno mars": Item(platformID: "5934888", name: "Uptown Funk", singer: "Mark Ronson\\&Bruno Mars", album: "Toggo Music 40", duration: 270, pic: "https://img1.kuwo.cn/wmvpic/324/14/47/1779042482.jpg"),
"just the way you are|bruno mars": Item(platformID: "839280", name: "Just the Way You Are", singer: "Bruno Mars", album: "Now That&apos;s What I Call Love Songs", duration: 218, pic: "https://img1.kuwo.cn/wmvpic/324/72/5/253242063.jpg"),
"blinding lights|the weeknd": Item(platformID: "82513606", name: "Blinding Lights", singer: "The Weeknd", album: "Blinding Lights", duration: 200, pic: "https://img1.kuwo.cn/wmvpic/324/59/46/511924220.jpg"),
"shallow|lady gaga  bradley cooper": Item(platformID: "63060538", name: "Shallow", singer: "Lady Gaga\\&Bradley Cooper", album: "2019 GRAMMY® Nominees", duration: 216, pic: "https://img1.kuwo.cn/wmvpic/324/5/18/3390476245.jpg"),
    ]

    /// 按键查（键与 `ResolvedSongCache.key` 同口径）
    static func song(name: String, singer: String) -> Song? {
        let key = ResolvedSongCache.key(name: name, singer: singer)
        guard let item = byKey[key] else { return nil }
        return Song(platform: .kuwo,
                    platformID: item.platformID,
                    name: item.name,
                    singer: item.singer,
                    album: item.album,
                    duration: TimeInterval(item.duration),
                    picURL: item.pic.isEmpty ? nil : item.pic)
    }
}
