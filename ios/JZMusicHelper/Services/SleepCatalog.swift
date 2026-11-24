import Foundation

// MARK: - 助眠模式的声音目录
//
// 84 条全部来自 Moodist（https://github.com/remvze/moodist，代码 MIT；
// 音频为 Pixabay Content License / CC0 混放，**未逐文件标注**，商用前需逐条回溯）。
//
// 这一版**不打包任何音频**：清单内置，声音按 URL 取。
// 路径相对 `SleepSound.baseURL`，换成自建 CDN 只改一个常量。
//
// 分类顺序 = 页面上分类栏的顺序；`nature` 放最前，因为助眠用得最多。
struct SleepSound: Identifiable, Hashable, Sendable {

    let id: String
    /// 中文名
    let name: String
    /// 英文原名（搜索 / 无障碍用）
    let english: String
    let category: String
    let symbol: String
    /// 相对路径，形如 `/sounds/nature/river.mp3`
    let path: String

    /// 声音服务器。以后搬到自己 CDN 只改这一行。
    static let baseURL = "https://moodist.mvze.net"

    var url: URL? { URL(string: Self.baseURL + path) }

    static let all: [SleepSound] = [
        // MARK: 自然
        SleepSound(id: "river", name: "河流", english: "River", category: "nature",
                   symbol: "water.waves", path: "/sounds/nature/river.mp3"),
        SleepSound(id: "waves", name: "海浪", english: "Waves", category: "nature",
                   symbol: "water.waves", path: "/sounds/nature/waves.mp3"),
        SleepSound(id: "campfire", name: "篝火", english: "Campfire", category: "nature",
                   symbol: "flame.fill", path: "/sounds/nature/campfire.mp3"),
        SleepSound(id: "wind", name: "风", english: "Wind", category: "nature",
                   symbol: "wind", path: "/sounds/nature/wind.mp3"),
        SleepSound(id: "howling-wind", name: "呼啸的风", english: "Howling Wind", category: "nature",
                   symbol: "wind", path: "/sounds/nature/howling-wind.mp3"),
        SleepSound(id: "wind-in-trees", name: "树林风声", english: "Wind in Trees", category: "nature",
                   symbol: "leaf.fill", path: "/sounds/nature/wind-in-trees.mp3"),
        SleepSound(id: "waterfall", name: "瀑布", english: "Waterfall", category: "nature",
                   symbol: "drop.fill", path: "/sounds/nature/waterfall.mp3"),
        SleepSound(id: "walk-in-snow", name: "踏雪", english: "Walk in Snow", category: "nature",
                   symbol: "snowflake", path: "/sounds/nature/walk-in-snow.mp3"),
        SleepSound(id: "walk-on-leaves", name: "踩落叶", english: "Walk on Leaves", category: "nature",
                   symbol: "leaf.fill", path: "/sounds/nature/walk-on-leaves.mp3"),
        SleepSound(id: "walk-on-gravel", name: "碎石路", english: "Walk on Gravel", category: "nature",
                   symbol: "circle.grid.2x2.fill", path: "/sounds/nature/walk-on-gravel.mp3"),
        SleepSound(id: "droplets", name: "水滴", english: "Droplets", category: "nature",
                   symbol: "drop.fill", path: "/sounds/nature/droplets.mp3"),
        SleepSound(id: "jungle", name: "丛林", english: "Jungle", category: "nature",
                   symbol: "tree.fill", path: "/sounds/nature/jungle.mp3"),
        // MARK: 雨
        SleepSound(id: "light-rain", name: "细雨", english: "Light Rain", category: "rain",
                   symbol: "cloud.drizzle.fill", path: "/sounds/rain/light-rain.mp3"),
        SleepSound(id: "heavy-rain", name: "大雨", english: "Heavy Rain", category: "rain",
                   symbol: "cloud.heavyrain.fill", path: "/sounds/rain/heavy-rain.mp3"),
        SleepSound(id: "thunder", name: "雷声", english: "Thunder", category: "rain",
                   symbol: "cloud.bolt.fill", path: "/sounds/rain/thunder.mp3"),
        SleepSound(id: "rain-on-window", name: "雨打窗", english: "Rain on Window", category: "rain",
                   symbol: "rectangle.portrait", path: "/sounds/rain/rain-on-window.mp3"),
        SleepSound(id: "rain-on-car-roof", name: "雨打车顶", english: "Rain on Car Roof", category: "rain",
                   symbol: "car.fill", path: "/sounds/rain/rain-on-car-roof.mp3"),
        SleepSound(id: "rain-on-umbrella", name: "雨打伞", english: "Rain on Umbrella", category: "rain",
                   symbol: "umbrella.fill", path: "/sounds/rain/rain-on-umbrella.mp3"),
        SleepSound(id: "rain-on-tent", name: "雨打帐篷", english: "Rain on Tent", category: "rain",
                   symbol: "tent.fill", path: "/sounds/rain/rain-on-tent.mp3"),
        SleepSound(id: "rain-on-leaves", name: "雨打树叶", english: "Rain on Leaves", category: "rain",
                   symbol: "leaf.fill", path: "/sounds/rain/rain-on-leaves.mp3"),
        // MARK: 动物
        SleepSound(id: "birds", name: "鸟鸣", english: "Birds", category: "animals",
                   symbol: "bird.fill", path: "/sounds/animals/birds.mp3"),
        SleepSound(id: "seagulls", name: "海鸥", english: "Seagulls", category: "animals",
                   symbol: "bird.fill", path: "/sounds/animals/seagulls.mp3"),
        SleepSound(id: "crickets", name: "蟋蟀", english: "Crickets", category: "animals",
                   symbol: "ant.fill", path: "/sounds/animals/crickets.mp3"),
        SleepSound(id: "wolf", name: "狼嚎", english: "Wolf", category: "animals",
                   symbol: "pawprint.fill", path: "/sounds/animals/wolf.mp3"),
        SleepSound(id: "owl", name: "猫头鹰", english: "Owl", category: "animals",
                   symbol: "bird.fill", path: "/sounds/animals/owl.mp3"),
        SleepSound(id: "frog", name: "青蛙", english: "Frog", category: "animals",
                   symbol: "pawprint.fill", path: "/sounds/animals/frog.mp3"),
        SleepSound(id: "dog-barking", name: "狗叫", english: "Dog Barking", category: "animals",
                   symbol: "dog.fill", path: "/sounds/animals/dog-barking.mp3"),
        SleepSound(id: "horse-gallop", name: "马蹄", english: "Horse Gallop", category: "animals",
                   symbol: "pawprint.fill", path: "/sounds/animals/horse-gallop.mp3"),
        SleepSound(id: "cat-purring", name: "猫咪呼噜", english: "Cat Purring", category: "animals",
                   symbol: "cat.fill", path: "/sounds/animals/cat-purring.mp3"),
        SleepSound(id: "crows", name: "乌鸦", english: "Crows", category: "animals",
                   symbol: "bird.fill", path: "/sounds/animals/crows.mp3"),
        SleepSound(id: "whale", name: "鲸歌", english: "Whale", category: "animals",
                   symbol: "fish.fill", path: "/sounds/animals/whale.mp3"),
        SleepSound(id: "beehive", name: "蜂巢", english: "Beehive", category: "animals",
                   symbol: "hexagon.fill", path: "/sounds/animals/beehive.mp3"),
        SleepSound(id: "woodpecker", name: "啄木鸟", english: "Woodpecker", category: "animals",
                   symbol: "bird.fill", path: "/sounds/animals/woodpecker.mp3"),
        SleepSound(id: "chickens", name: "鸡群", english: "Chickens", category: "animals",
                   symbol: "bird.fill", path: "/sounds/animals/chickens.mp3"),
        SleepSound(id: "cows", name: "牛群", english: "Cows", category: "animals",
                   symbol: "pawprint.fill", path: "/sounds/animals/cows.mp3"),
        SleepSound(id: "sheep", name: "羊群", english: "Sheep", category: "animals",
                   symbol: "pawprint.fill", path: "/sounds/animals/sheep.mp3"),
        // MARK: 城市
        SleepSound(id: "highway", name: "高速公路", english: "Highway", category: "urban",
                   symbol: "road.lanes", path: "/sounds/urban/highway.mp3"),
        SleepSound(id: "road", name: "马路", english: "Road", category: "urban",
                   symbol: "road.lanes", path: "/sounds/urban/road.mp3"),
        SleepSound(id: "ambulance-siren", name: "救护车", english: "Ambulance Siren", category: "urban",
                   symbol: "cross.case.fill", path: "/sounds/urban/ambulance-siren.mp3"),
        SleepSound(id: "busy-street", name: "闹市", english: "Busy Street", category: "urban",
                   symbol: "building.2.fill", path: "/sounds/urban/busy-street.mp3"),
        SleepSound(id: "crowd", name: "人群", english: "Crowd", category: "urban",
                   symbol: "person.3.fill", path: "/sounds/urban/crowd.mp3"),
        SleepSound(id: "traffic", name: "车流", english: "Traffic", category: "urban",
                   symbol: "car.fill", path: "/sounds/urban/traffic.mp3"),
        SleepSound(id: "fireworks", name: "烟花", english: "Fireworks", category: "urban",
                   symbol: "sparkles", path: "/sounds/urban/fireworks.mp3"),
        // MARK: 场所
        SleepSound(id: "cafe", name: "咖啡馆", english: "Cafe", category: "places",
                   symbol: "cup.and.saucer.fill", path: "/sounds/places/cafe.mp3"),
        SleepSound(id: "airport", name: "机场", english: "Airport", category: "places",
                   symbol: "airplane", path: "/sounds/places/airport.mp3"),
        SleepSound(id: "church", name: "教堂", english: "Church", category: "places",
                   symbol: "building.columns.fill", path: "/sounds/places/church.mp3"),
        SleepSound(id: "temple", name: "寺庙", english: "Temple", category: "places",
                   symbol: "building.columns.fill", path: "/sounds/places/temple.mp3"),
        SleepSound(id: "construction-site", name: "工地", english: "Construction Site", category: "places",
                   symbol: "hammer.fill", path: "/sounds/places/construction-site.mp3"),
        SleepSound(id: "underwater", name: "水下", english: "Underwater", category: "places",
                   symbol: "water.waves", path: "/sounds/places/underwater.mp3"),
        SleepSound(id: "crowded-bar", name: "酒吧", english: "Crowded Bar", category: "places",
                   symbol: "wineglass.fill", path: "/sounds/places/crowded-bar.mp3"),
        SleepSound(id: "night-village", name: "夜里的村子", english: "Night Village", category: "places",
                   symbol: "moon.stars.fill", path: "/sounds/places/night-village.mp3"),
        SleepSound(id: "subway-station", name: "地铁站", english: "Subway Station", category: "places",
                   symbol: "tram.fill", path: "/sounds/places/subway-station.mp3"),
        SleepSound(id: "office", name: "办公室", english: "Office", category: "places",
                   symbol: "building.2.fill", path: "/sounds/places/office.mp3"),
        SleepSound(id: "supermarket", name: "超市", english: "Supermarket", category: "places",
                   symbol: "cart.fill", path: "/sounds/places/supermarket.mp3"),
        SleepSound(id: "carousel", name: "旋转木马", english: "Carousel", category: "places",
                   symbol: "circle.circle.fill", path: "/sounds/places/carousel.mp3"),
        SleepSound(id: "laboratory", name: "实验室", english: "Laboratory", category: "places",
                   symbol: "flask.fill", path: "/sounds/places/laboratory.mp3"),
        SleepSound(id: "laundry-room", name: "洗衣房", english: "Laundry Room", category: "places",
                   symbol: "washer.fill", path: "/sounds/places/laundry-room.mp3"),
        SleepSound(id: "restaurant", name: "餐厅", english: "Restaurant", category: "places",
                   symbol: "fork.knife", path: "/sounds/places/restaurant.mp3"),
        SleepSound(id: "library", name: "图书馆", english: "Library", category: "places",
                   symbol: "books.vertical.fill", path: "/sounds/places/library.mp3"),
        // MARK: 交通
        SleepSound(id: "train", name: "火车", english: "Train", category: "transport",
                   symbol: "tram.fill", path: "/sounds/transport/train.mp3"),
        SleepSound(id: "inside-a-train", name: "车厢里", english: "Inside a Train", category: "transport",
                   symbol: "tram.fill", path: "/sounds/transport/inside-a-train.mp3"),
        SleepSound(id: "airplane", name: "飞机", english: "Airplane", category: "transport",
                   symbol: "airplane", path: "/sounds/transport/airplane.mp3"),
        SleepSound(id: "submarine", name: "潜艇", english: "Submarine", category: "transport",
                   symbol: "water.waves", path: "/sounds/transport/submarine.mp3"),
        SleepSound(id: "sailboat", name: "帆船", english: "Sailboat", category: "transport",
                   symbol: "sailboat.fill", path: "/sounds/transport/sailboat.mp3"),
        SleepSound(id: "rowing-boat", name: "划船", english: "Rowing Boat", category: "transport",
                   symbol: "oar.2.crossed", path: "/sounds/transport/rowing-boat.mp3"),
        // MARK: 器物
        SleepSound(id: "keyboard", name: "键盘", english: "Keyboard", category: "things",
                   symbol: "keyboard.fill", path: "/sounds/things/keyboard.mp3"),
        SleepSound(id: "typewriter", name: "打字机", english: "Typewriter", category: "things",
                   symbol: "keyboard.fill", path: "/sounds/things/typewriter.mp3"),
        SleepSound(id: "paper", name: "纸张", english: "Paper", category: "things",
                   symbol: "doc.fill", path: "/sounds/things/paper.mp3"),
        SleepSound(id: "clock", name: "时钟", english: "Clock", category: "things",
                   symbol: "clock.fill", path: "/sounds/things/clock.mp3"),
        SleepSound(id: "wind-chimes", name: "风铃", english: "Wind Chimes", category: "things",
                   symbol: "music.note", path: "/sounds/things/wind-chimes.mp3"),
        SleepSound(id: "singing-bowl", name: "颂钵", english: "Singing Bowl", category: "things",
                   symbol: "circle.hexagongrid.fill", path: "/sounds/things/singing-bowl.mp3"),
        SleepSound(id: "ceiling-fan", name: "吊扇", english: "Ceiling Fan", category: "things",
                   symbol: "fan.fill", path: "/sounds/things/ceiling-fan.mp3"),
        SleepSound(id: "dryer", name: "烘干机", english: "Dryer", category: "things",
                   symbol: "wind", path: "/sounds/things/dryer.mp3"),
        SleepSound(id: "slide-projector", name: "幻灯机", english: "Slide Projector", category: "things",
                   symbol: "projector.fill", path: "/sounds/things/slide-projector.mp3"),
        SleepSound(id: "boiling-water", name: "烧水", english: "Boiling Water", category: "things",
                   symbol: "cup.and.saucer.fill", path: "/sounds/things/boiling-water.mp3"),
        SleepSound(id: "bubbles", name: "气泡", english: "Bubbles", category: "things",
                   symbol: "circle.grid.3x3.fill", path: "/sounds/things/bubbles.mp3"),
        SleepSound(id: "tuning-radio", name: "调台", english: "Tuning Radio", category: "things",
                   symbol: "radio.fill", path: "/sounds/things/tuning-radio.mp3"),
        SleepSound(id: "morse-code", name: "摩斯电码", english: "Morse Code", category: "things",
                   symbol: "dot.radiowaves.left.and.right", path: "/sounds/things/morse-code.mp3"),
        SleepSound(id: "washing-machine", name: "洗衣机", english: "Washing Machine", category: "things",
                   symbol: "washer.fill", path: "/sounds/things/washing-machine.mp3"),
        SleepSound(id: "vinyl-effect", name: "黑胶", english: "Vinyl Effect", category: "things",
                   symbol: "opticaldisc.fill", path: "/sounds/things/vinyl-effect.mp3"),
        SleepSound(id: "windshield-wipers", name: "雨刷", english: "Windshield Wipers", category: "things",
                   symbol: "rectangle.dashed", path: "/sounds/things/windshield-wipers.mp3"),
        // MARK: 噪声
        SleepSound(id: "white-noise", name: "白噪声", english: "White Noise", category: "noise",
                   symbol: "waveform", path: "/sounds/noise/white-noise.wav"),
        SleepSound(id: "pink-noise", name: "粉噪声", english: "Pink Noise", category: "noise",
                   symbol: "waveform", path: "/sounds/noise/pink-noise.wav"),
        SleepSound(id: "brown-noise", name: "棕噪声", english: "Brown Noise", category: "noise",
                   symbol: "waveform", path: "/sounds/noise/brown-noise.wav"),
    ]

    static func find(_ id: String) -> SleepSound? { all.first { $0.id == id } }
    static func inCategory(_ cat: String) -> [SleepSound] { all.filter { $0.category == cat } }
}

// MARK: - 分类

struct SleepCategory: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String

    static let all: [SleepCategory] = [
        SleepCategory(id: "nature", name: "自然", symbol: "leaf.fill"),
        SleepCategory(id: "rain", name: "雨", symbol: "cloud.rain.fill"),
        SleepCategory(id: "animals", name: "动物", symbol: "pawprint.fill"),
        SleepCategory(id: "things", name: "器物", symbol: "clock.fill"),
        SleepCategory(id: "places", name: "场所", symbol: "building.2.fill"),
        SleepCategory(id: "transport", name: "交通", symbol: "tram.fill"),
        SleepCategory(id: "urban", name: "城市", symbol: "car.fill"),
        SleepCategory(id: "noise", name: "噪声", symbol: "waveform"),
    ]

    static func name(_ id: String) -> String {
        all.first { $0.id == id }?.name ?? id
    }
}

// MARK: - 内置的搭配组合
//
// 每条 = 若干 (声音 id, 音量)。用户也可以自己存，存的那部分见 SleepPresetStore。
struct SleepPreset: Identifiable {
    let id: String
    let name: String
    let caption: String
    /// (soundID, volume 0...1)
    let mix: [(String, Float)]

    static let builtIn: [SleepPreset] = [
        SleepPreset(id: "rainy-night", name: "雨夜", caption: "大雨 + 远雷 + 窗上的雨", mix: [
            ("heavy-rain", 0.70), ("thunder", 0.25), ("rain-on-window", 0.45)]),
        SleepPreset(id: "seaside", name: "海边", caption: "浪 + 风 + 远处海鸥", mix: [
            ("waves", 0.80), ("wind", 0.30), ("seagulls", 0.12)]),
        SleepPreset(id: "forest-night", name: "森林夜", caption: "虫鸣 + 树梢风 + 猫头鹰", mix: [
            ("crickets", 0.60), ("wind-in-trees", 0.45), ("owl", 0.18)]),
        SleepPreset(id: "fireplace", name: "壁炉", caption: "柴火 + 窗外风", mix: [
            ("campfire", 0.80), ("howling-wind", 0.20)]),
        SleepPreset(id: "journey", name: "旅途", caption: "车厢 + 车窗上的雨", mix: [
            ("train", 0.70), ("rain-on-window", 0.35)]),
        SleepPreset(id: "deep-sleep", name: "深睡", caption: "棕噪铺底 + 帐篷雨", mix: [
            ("brown-noise", 0.55), ("rain-on-tent", 0.40), ("campfire", 0.15)]),
    ]
}

// MARK: - 定时关闭
//
// 15 / 30 / 60 / 90 分钟，到点 **30 秒淡出**再停。
enum SleepTimerMinutes: Int, CaseIterable, Identifiable {
    case m15 = 15, m30 = 30, m60 = 60, m90 = 90

    var id: Int { rawValue }
    var title: String { "\(rawValue) 分钟" }

    static let fadeOutSeconds: Double = 30
}
