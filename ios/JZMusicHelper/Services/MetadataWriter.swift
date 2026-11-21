import Foundation

// MARK: - 元数据写回的唯一通道（第 44 轮）
//
// 老板点名："`Song` 是 `let`，回填统一走**一条 `applyMetadata` 通道**，四处快照
// （downloads.json / 收藏 / 导入歌单 / 播放队列）+ 三处缓存（CoverImageCache、rowFacts、
// NowPlayingCenter 判重）必须一起刷，不许出现'列表改了、播放页还是旧的'。"
//
// 所以：**任何地方**要改一首歌的 name/singer/album/picURL/meta，都不许自己赋值，
// 一律 `await MetadataWriter.apply(song)`。这里按顺序刷四个持有者，再广播一次给播放期。
//
//   ① DownloadManager.items → downloads.json（顺带重建 rowFacts、作废封面内存缓存）
//   ② LibraryStore.favorites  → favorite_songs.json
//   ③ MyPlaylistStore.playlists → my_playlists.json
//   ④ 广播 `.songMetadataUpdated` → PlayerEngine（queue + currentSong + 锁屏 + 歌词）

extension Notification.Name {
    /// 元数据被改（自动匹配 / 手动编辑 / 换封面）。播放器靠它刷新当前队列与锁屏。
    static let songMetadataUpdated = Notification.Name("jz.songMetadataUpdated")
}

@MainActor
enum MetadataWriter {

    /// 写回一首歌的元数据（四处快照 + 三处缓存）
    static func apply(_ song: Song) {
        DownloadManager.shared.applySongMetadata(song)
        LibraryStore.shared.applySongMetadata(song)
        MyPlaylistStore.shared.applySongMetadata(song)
        NotificationCenter.default.post(name: .songMetadataUpdated, object: song)
        CrashReporter.logMetadata(
            "write | \(song.platformID) | \(song.meta?.logTag ?? "-") "
            + "| \(song.name) | \(song.singer) | \(song.album) "
            + "| locked=\(song.meta?.locked.map(\.rawValue).joined(separator: ",") ?? "-") "
            + "| cover r\(song.coverRevision)\(song.meta?.coverStale == true ? " stale" : "")")
    }

    /// 手动编辑：改字段 → 锁住改过的字段 → 写回 → 立刻用新值再匹配一次
    /// - Returns: 匹配结论（没匹配到就是 reject，UI 上标"仅手动信息"）
    @discardableResult
    static func applyManualEdit(to current: Song, name: String, singer: String, album: String,
                                coverPicked: Bool) async -> MatchOutcome {
        let edited = MetadataMatcher.applyingManualEdit(to: current, name: name, singer: singer,
                                                        album: album,
                                                        cover: coverPicked ? .cover : nil)
        apply(edited)
        return await rematch(edited, force: false)
    }

    /// 再匹配：只在"没锁的字段"上写；命中就补专辑/封面，封面没命中就沿兜底链取。
    /// - Parameter force: 用户点了「重新联网匹配」——连手选封面也允许被替换
    @discardableResult
    static func rematch(_ song: Song, force: Bool) async -> MatchOutcome {
        var working = song
        if force {
            var meta = working.meta ?? MetaProvenance()
            meta.unlock(.cover)
            working = working.with(meta: meta)
        }

        let outcome = await MetadataIQ.match(working)
        switch outcome.verdict {
        case .auto:
            if let best = outcome.best {
                let merged = MetadataMatcher.merge(into: working, matched: best)
                apply(merged)
                await DownloadManager.shared.fillCompanionsAfterMatch(song: merged,
                                                                      preferCoverURL: best.picURL)
                return outcome
            }
            return outcome
        case .confirm:
            // 0.6–0.85：**不写**，存成"待确认"，UI 里给一个「采用」
            if let best = outcome.best {
                let suggestion = working.with(name: best.name, singer: best.singer,
                                              album: best.album, picURL: best.picURL)
                await DownloadManager.shared.setMatchSuggestion(suggestion, for: working)
            }
            CrashReporter.logMetadata(
                "confirm | \(working.platformID) | \(outcome.query) | \(String(format: "%.2f", outcome.best?.score ?? 0)) | \(outcome.detail)")
            return outcome
        case .reject:
            CrashReporter.logMetadata(
                "unmatched | \(working.platformID) | \(outcome.query) | \(outcome.candidateCount) | \(outcome.detail)")
            return outcome
        }
    }

    /// 用待确认候选回填（用户点了「采用」）
    static func acceptSuggestion(_ suggestion: Song, for current: Song) {
        var meta = current.meta ?? MetaProvenance()
        meta.matchedID = suggestion.meta?.matchedID ?? meta.matchedID
        meta.matchedPlatform = suggestion.meta?.matchedPlatform ?? meta.matchedPlatform
        meta.score = suggestion.meta?.score ?? meta.score
        let merged = current.with(name: suggestion.name, singer: suggestion.singer,
                                  album: suggestion.album, picURL: suggestion.picURL, meta: meta)
        apply(merged)
    }

    /// 恢复自动：解锁全部 + 清命中，然后重匹配一次
    @discardableResult
    static func resetToAuto(_ song: Song) async -> MatchOutcome {
        let reset = MetadataMatcher.resettingToAuto(song)
        apply(reset)
        return await rematch(reset, force: true)
    }

    /// 换封面（用户自选图写完旁车之后调）：代次 +1，三处缓存一起失效
    static func coverChanged(_ song: Song, picURL: String?) -> Song {
        var meta = song.meta ?? MetaProvenance()
        meta.coverRevision += 1
        meta.coverStale = false
        meta.lock(.cover)
        if meta.source != .manual { meta.source = .manual }
        let next = song.with(picURL: picURL ?? song.picURL, meta: meta)
        apply(next)
        return next
    }
}
