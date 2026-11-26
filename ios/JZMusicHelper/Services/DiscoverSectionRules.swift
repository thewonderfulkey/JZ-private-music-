import Foundation

// MARK: - 发现页板块状态（2026-11-26）
//
// 老板口径：一个板块里两家的内容**都要出现**；一家挂了只少它那部分，其余照常。
// 这个文件只做"把若干家的结果合成一个板块"，不碰网络、不碰 UI，方便 CI 断言。

/// 一家在本次刷新里的结果
enum SourceResult: Sendable {
    case ok(DiscoverSource, [Song])
    case failed(DiscoverSource)
}

struct SourceState: Sendable, Equatable {
    let source: DiscoverSource
    let count: Int
    let failed: Bool
}

struct SectionData: Sendable, Equatable {
    let items: [Song]
    let sources: [SourceState]

    /// 0 条就整块不渲染（不留空壳/骨架）
    var isVisible: Bool { !items.isEmpty }

    /// 失败的源（板块标题旁显示「网易暂不可用」，不弹错）
    var failedSources: [DiscoverSource] { sources.filter(\.failed).map(\.source) }
}

enum DiscoverSectionRules {

    /// 把各源结果合成一个板块：合并去重（见 `DiscoverMergeRules`）+ 记录每源状态。
    ///
    /// 顺序固定按传入顺序（调用方按"主推在前"传），失败源也保留状态位——
    /// 这样 UI 才能在同一块里说清"哪家没来"，而不是整块消失。
    static func combine(_ results: [SourceResult]) -> SectionData {
        var groups: [(DiscoverSource, [Song])] = []
        var states: [SourceState] = []
        for result in results {
            switch result {
            case .ok(let source, let songs):
                groups.append((source, songs))
                states.append(SourceState(source: source, count: songs.count, failed: false))
            case .failed(let source):
                states.append(SourceState(source: source, count: 0, failed: true))
            }
        }
        let merged = DiscoverMergeRules.merge(groups)
        return SectionData(items: merged, sources: states)
    }
}
