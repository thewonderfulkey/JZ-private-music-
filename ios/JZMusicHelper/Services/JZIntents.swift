import AppIntents
import Foundation

// MARK: - 快捷指令 / Siri / 聚焦（App Intents）
//
// 这一版只给三个"一句话就能用"的动作，且全部是 `openAppWhenRun = true`：
//   · 播放我的收藏
//   · 听歌识曲
//   · 搜索歌曲（带一个关键词参数）
//
// 为什么不做 AppShortcutsProvider（Siri 固定短语）：那套 API 的短语插值类型很挑编译器，
// 而这三个 Intent 只要出现在「快捷指令」App 里就已经可用（也能被聚焦/自动化调用）。
// 等装机验证过 Intent 真的能跑，再补短语层——顺序反过来会是"短语注册好了但动作不通"。
//
// 动作本身不在这里执行：Intent 只往 `IntentInbox` 投递一条请求，视图层回前台时消费
// （见 Services/IntentInbox.swift 的说明）。

struct PlayFavoritesIntent: AppIntent {
    static var title: LocalizedStringResource = "播放我的收藏"
    static var description: IntentDescription? = IntentDescription("从收藏里随机起播一首")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        IntentInbox.shared.post(.playFavorites)
        return .result()
    }
}

struct StartRecognitionIntent: AppIntent {
    static var title: LocalizedStringResource = "听歌识曲"
    static var description: IntentDescription? = IntentDescription("打开识曲页并开始听环境里的歌")
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        IntentInbox.shared.post(.startRecognition)
        return .result()
    }
}

struct SearchMusicIntent: AppIntent {
    static var title: LocalizedStringResource = "搜索歌曲"
    static var description: IntentDescription? = IntentDescription("在 JZ 音乐里搜一首歌")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "关键词")
    var keyword: String

    init() {}

    init(keyword: String) {
        self.keyword = keyword
    }

    func perform() async throws -> some IntentResult {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .result() }
        IntentInbox.shared.post(.search(trimmed))
        return .result()
    }
}
