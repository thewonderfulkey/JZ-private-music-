import SwiftUI

// MARK: - 音源详情（设计稿 §3.5）
//
// 这是个**只读**的信息页：把"这条音源到底怎么来的、是不是真 320k"摊开给用户看。
// 数据全部来自 PlayerEngine 当前状态（不再自己发起解析），所以不会和播放页出现两个事实源。
struct SourceDetailView: View {

    @Environment(PlayerEngine.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let song = player.currentSong {
                    Section {
                        Text(song.name)
                            .font(.headline)
                        Text("\(song.singer)\(song.album.isEmpty ? "" : " · \(song.album)")")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                // 2026-11-25《众》播成《侧脸》：把"这条字节到底对应哪条候选"摊开。
                // 结论只有两种：同一条录音，或者"不是这首歌"（后者要被一眼看见，而不是靠用户听出来）。
                Section("匹配身份") {
                    if let song = player.currentSong, let source = player.source {
                        let matchedName = source.matchedName ?? ""
                        if matchedName.isEmpty {
                            Text("这条源没有身份记录（老数据/本地文件），无法核对")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            let played: Double? = player.duration > 1 ? player.duration : source.matchedDurationSec
                            let ok = NameMatch.cacheIdentityOK(
                                displayed: song, matchedName: matchedName,
                                matchedSinger: source.matchedSinger,
                                matchedDurationSec: source.matchedDurationSec,
                                measuredDurationSec: played)
                            LabeledContent("结论", value: ok ? "✅ 同一条录音" : "⚠️ 不是这首歌")
                            LabeledContent("实际匹配", value: "\(matchedName)"
                                           + (source.matchedSinger.map { " · \($0)" } ?? ""))
                            if let d = source.matchedDurationSec, d > 1 {
                                LabeledContent("候选时长", value: NowPlayingView.timeText(d))
                            }
                            if !ok {
                                Text("这份字节不是当前这首歌的（长度或歌名对不上）。已缓存的那首会在下次播放时作废并重新解析；如果反复出现，把这段截图发出来。")
                                    .font(.caption)
                                    .foregroundStyle(Tokens.Palette.vermilion)
                            }
                        }
                    } else {
                        Text("还没有音源信息").font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("当前播放") {
                    if let source = player.source {
                        LabeledContent("后端", value: source.backendName)
                        LabeledContent("真实码率", value: source.kbps > 0 ? "\(source.kbps) kbps" : "算不出")
                        LabeledContent("容器", value: source.format.uppercased())
                        LabeledContent("解析方式", value: source.directId ? "按平台 ID 直连" : "按歌名搜索取流")
                        LabeledContent("体积", value: source.totalBytes > 0
                                       ? String(format: "%.1f MB", Double(source.totalBytes) / 1_000_000)
                                       : "未知")
                        Text(source.note)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else if player.isResolving {
                        HStack(spacing: Tokens.Spacing.xs) {
                            ProgressView().scaleEffect(0.7)
                            Text("正在解析音源…").font(.footnote).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("还没有音源信息")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("歌词") {
                    LabeledContent("行数", value: "\(player.lyrics.count)")
                    LabeledContent("来源", value: player.lyricsSource.isEmpty ? "—" : player.lyricsSource)
                    LabeledContent("逐字", value: player.lyrics.first?.hasWordTiming == true ? "有" : "无")
                }

                // r66：时长是"歌词对不上、进度先到头"这一族问题的关键证据，
                // 摊开来给下一轮直接看（老板截图就能定位是元数据短了还是流本身更长）。
                Section("时长") {
                    LabeledContent("实际播放时长", value: player.duration > 0
                                   ? NowPlayingView.timeText(player.duration) : "未知")
                    LabeledContent("曲目元数据", value: player.currentSong.map {
                        $0.duration > 0 ? NowPlayingView.timeText($0.duration) : "未知"
                    } ?? "—")
                    if let song = player.currentSong, song.duration > 0, player.duration > 0,
                       abs(player.duration - song.duration) > 1 {
                        Text(String(format: "两者差 %+.0f 秒：实际在放的这条比元数据%@，歌词时间轴按元数据算就会偏。",
                                    player.duration - song.duration,
                                    player.duration > song.duration ? "长" : "短"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                // r68：把"当前高亮那句的词时间"和"播放位置"并排摆出来。
                // 偏差一直 ≈0 → 词和时间轴是贴的；差几秒 → 就是词源与这条音源不是同一版。
                Section("当前歌词行") {
                    if let line = player.currentLyricLine {
                        Text(line.text)
                            .font(.footnote)
                        LabeledContent("行时间", value: Self.tenths(line.timeMs))
                        LabeledContent("播放位置", value: Self.tenths(player.lyricPositionMs))
                        let delta = Double(player.lyricPositionMs - line.timeMs) / 1000
                        LabeledContent("偏差", value: String(format: "%+.1f 秒", delta))
                    } else {
                        Text("还没有定位到某一行")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("逐字时间", value: player.lyrics.first?.hasWordTiming == true ? "有" : "无")
                    if !player.lyricsMatchNote.isEmpty {
                        Text(player.lyricsMatchNote)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    Text("音质不是接口自报的，是取流时用 Range 请求读了容器头、再按体积÷时长算出来的。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("音源详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    /// 毫秒 → `m:ss.t`（带一位小数，看得出 0.1 秒级的偏差）
    private static func tenths(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let total = Double(clamped) / 1000
        let m = Int(total) / 60
        let s = total - Double(m * 60)
        return String(format: "%d:%04.1f", m, s)
    }
}
