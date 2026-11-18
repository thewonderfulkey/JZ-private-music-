import Foundation

// MARK: - 发现页目录（Widget「每日三首」的 4 类池子 + 热门种子词）
//
// 第三十轮起，App 里的「编辑精选」已经下线（换成歌单广场 + 歌手大全）；
// 这里剩下的 4 类池子只有**主屏幕 Widget「今日精选」**在用（每天轮一类、取 3 首歌名）——
// 老板决定 Widget 维持现状，所以数据留着，但 App 界面不再读它。
// 热门音乐的种子词兜底（`hotSeedWords`）也还在用。
//
// 这个文件只放数据，不引 SwiftUI：`accentHex` 是十六进制，转 Color 的事在 View 层做，
// 这样它也能被 CI 的 logic-tests（只有 Foundation）编译。
enum DiscoverCatalog {

    /// 池子里的一首歌：只有「歌名 + 歌手」，平台 ID 要等用户点开时再去搜（与 Android 一致）
    struct Seed: Hashable {
        let name: String
        let singer: String
    }

    struct Playlist: Identifiable {
        let title: String
        /// 类别主题色（卡片描边用）；0xRRGGBB
        let accentHex: UInt32
        let seeds: [Seed]
        var id: String { title }
    }

    // MARK: 编辑精选（4 类 × 30 首）

    static let playlists: [Playlist] = [
        Playlist(title: "华语经典", accentHex: 0xF0B45A, seeds: chineseClassics),
        Playlist(title: "粤语金曲", accentHex: 0x5A7DF0, seeds: cantoneseGold),
        Playlist(title: "影视 OST", accentHex: 0xE0608E, seeds: filmOST),
        Playlist(title: "欧美热单", accentHex: 0x3EC6A8, seeds: westernHits),
    ]

    private static let chineseClassics: [Seed] = [
        Seed(name: "晴天", singer: "周杰伦"),
        Seed(name: "七里香", singer: "周杰伦"),
        Seed(name: "青花瓷", singer: "周杰伦"),
        Seed(name: "告白气球", singer: "周杰伦"),
        Seed(name: "稻香", singer: "周杰伦"),
        Seed(name: "夜曲", singer: "周杰伦"),
        Seed(name: "安静", singer: "周杰伦"),
        Seed(name: "演员", singer: "薛之谦"),
        Seed(name: "丑八怪", singer: "薛之谦"),
        Seed(name: "动物世界", singer: "薛之谦"),
        Seed(name: "后来", singer: "刘若英"),
        Seed(name: "成都", singer: "赵雷"),
        Seed(name: "理想", singer: "赵雷"),
        Seed(name: "光年之外", singer: "邓紫棋"),
        Seed(name: "泡沫", singer: "邓紫棋"),
        Seed(name: "小幸运", singer: "田馥甄"),
        Seed(name: "平凡之路", singer: "朴树"),
        Seed(name: "江南", singer: "林俊杰"),
        Seed(name: "曹操", singer: "林俊杰"),
        Seed(name: "童话", singer: "光良"),
        Seed(name: "隐形的翅膀", singer: "张韶涵"),
        Seed(name: "勇气", singer: "梁静茹"),
        Seed(name: "听海", singer: "张惠妹"),
        Seed(name: "红豆", singer: "王菲"),
        Seed(name: "十年", singer: "陈奕迅"),
        Seed(name: "好久不见", singer: "陈奕迅"),
        Seed(name: "模特", singer: "李荣浩"),
        Seed(name: "年少有为", singer: "李荣浩"),
        Seed(name: "消愁", singer: "毛不易"),
        Seed(name: "像我这样的人", singer: "毛不易"),
    ]

    private static let cantoneseGold: [Seed] = [
        Seed(name: "光辉岁月", singer: "Beyond"),
        Seed(name: "海阔天空", singer: "Beyond"),
        Seed(name: "喜欢你", singer: "Beyond"),
        Seed(name: "真的爱你", singer: "Beyond"),
        Seed(name: "不再犹豫", singer: "Beyond"),
        Seed(name: "灰色轨迹", singer: "Beyond"),
        Seed(name: "冷雨夜", singer: "Beyond"),
        Seed(name: "Amani", singer: "Beyond"),
        Seed(name: "富士山下", singer: "陈奕迅"),
        Seed(name: "浮夸", singer: "陈奕迅"),
        Seed(name: "单车", singer: "陈奕迅"),
        Seed(name: "明年今日", singer: "陈奕迅"),
        Seed(name: "K歌之王", singer: "陈奕迅"),
        Seed(name: "Shall We Talk", singer: "陈奕迅"),
        Seed(name: "红日", singer: "李克勤"),
        Seed(name: "月半小夜曲", singer: "李克勤"),
        Seed(name: "千千阙歌", singer: "陈慧娴"),
        Seed(name: "处处吻", singer: "杨千嬅"),
        Seed(name: "遥远的她", singer: "张学友"),
        Seed(name: "每天爱你多一些", singer: "张学友"),
        Seed(name: "只想一生跟你走", singer: "张学友"),
        Seed(name: "暗涌", singer: "王菲"),
        Seed(name: "约定", singer: "王菲"),
        Seed(name: "一生所爱", singer: "卢冠廷"),
        Seed(name: "上海滩", singer: "叶丽仪"),
        Seed(name: "万水千山总是情", singer: "汪明荃"),
        Seed(name: "沧海一声笑", singer: "许冠杰"),
        Seed(name: "倩女幽魂", singer: "张国荣"),
        Seed(name: "风继续吹", singer: "张国荣"),
        Seed(name: "沉默是金", singer: "张国荣"),
    ]

    private static let filmOST: [Seed] = [
        Seed(name: "体面", singer: "于文文"),
        Seed(name: "后会无期", singer: "邓紫棋"),
        Seed(name: "年轮", singer: "张碧晨"),
        Seed(name: "大鱼", singer: "周深"),
        Seed(name: "凉凉", singer: "张碧晨 杨宗纬"),
        Seed(name: "时间煮雨", singer: "郁可唯"),
        Seed(name: "只要平凡", singer: "张杰 张碧晨"),
        Seed(name: "My Heart Will Go On", singer: "Celine Dion"),
        Seed(name: "爱如潮水", singer: "张信哲"),
        Seed(name: "匆匆那年", singer: "王菲"),
        Seed(name: "画心", singer: "张靓颖"),
        Seed(name: "默", singer: "那英"),
        Seed(name: "传奇", singer: "李健"),
        Seed(name: "贝加尔湖畔", singer: "李健"),
        Seed(name: "卷珠帘", singer: "霍尊"),
        Seed(name: "不将就", singer: "李荣浩"),
        Seed(name: "说散就散", singer: "袁娅维"),
        Seed(name: "卡路里", singer: "火箭少女101"),
        Seed(name: "追光者", singer: "岑宁儿"),
        Seed(name: "我们", singer: "陈奕迅"),
        Seed(name: "终于等到你", singer: "张靓颖"),
        Seed(name: "当爱已成往事", singer: "张国荣"),
        Seed(name: "滚滚红尘", singer: "陈淑桦"),
        Seed(name: "甜蜜蜜", singer: "邓丽君"),
        Seed(name: "新不了情", singer: "万芳"),
        Seed(name: "星语心愿", singer: "张柏芝"),
        Seed(name: "我愿意", singer: "王菲"),
        Seed(name: "人间", singer: "王菲"),
        Seed(name: "萱草花", singer: "张小斐"),
        Seed(name: "这世界那么多人", singer: "莫文蔚"),
    ]

    private static let westernHits: [Seed] = [
        Seed(name: "Shape of You", singer: "Ed Sheeran"),
        Seed(name: "Perfect", singer: "Ed Sheeran"),
        Seed(name: "Thinking Out Loud", singer: "Ed Sheeran"),
        Seed(name: "Photograph", singer: "Ed Sheeran"),
        Seed(name: "See You Again", singer: "Wiz Khalifa"),
        Seed(name: "Let It Go", singer: "Idina Menzel"),
        Seed(name: "Hello", singer: "Adele"),
        Seed(name: "Someone Like You", singer: "Adele"),
        Seed(name: "Rolling in the Deep", singer: "Adele"),
        Seed(name: "Counting Stars", singer: "OneRepublic"),
        Seed(name: "Secrets", singer: "OneRepublic"),
        Seed(name: "Sugar", singer: "Maroon 5"),
        Seed(name: "Memories", singer: "Maroon 5"),
        Seed(name: "Payphone", singer: "Maroon 5"),
        Seed(name: "Faded", singer: "Alan Walker"),
        Seed(name: "Alone", singer: "Alan Walker"),
        Seed(name: "Havana", singer: "Camila Cabello"),
        Seed(name: "Señorita", singer: "Camila Cabello  Shawn Mendes"),
        Seed(name: "Bad Guy", singer: "Billie Eilish"),
        Seed(name: "Happier", singer: "Marshmello"),
        Seed(name: "Thunder", singer: "Imagine Dragons"),
        Seed(name: "Believer", singer: "Imagine Dragons"),
        Seed(name: "Numb", singer: "Linkin Park"),
        Seed(name: "In the End", singer: "Linkin Park"),
        Seed(name: "Yellow", singer: "Coldplay"),
        Seed(name: "Viva La Vida", singer: "Coldplay"),
        Seed(name: "Uptown Funk", singer: "Bruno Mars"),
        Seed(name: "Just the Way You Are", singer: "Bruno Mars"),
        Seed(name: "Blinding Lights", singer: "The Weeknd"),
        Seed(name: "Shallow", singer: "Lady Gaga  Bradley Cooper"),
    ]

    // MARK: 热门种子词（24 个，与 Android HotMusic.SEED_WORDS 一字不差）

    static let hotSeedWords: [String] = [
        "晴天 周杰伦", "孤勇者 陈奕迅", "七里香 周杰伦", "海阔天空 Beyond",
        "演员 薛之谦", "光年之外 邓紫棋", "夜曲 周杰伦", "平凡之路 朴树",
        "后来 刘若英", "成都 赵雷",
        "江南 林俊杰", "红豆 王菲", "遇见 孙燕姿", "富士山下 陈奕迅",
        "千千阙歌 陈慧娴", "蓝莲花 许巍", "消愁 毛不易", "隐形的翅膀 张韶涵",
        "说谎 林宥嘉", "年少有为 李荣浩", "大鱼 周深", "漠河舞厅 柳爽",
        "万疆 李玉刚", "朋友 周华健",
    ]
}
