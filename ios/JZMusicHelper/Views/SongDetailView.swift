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
}
