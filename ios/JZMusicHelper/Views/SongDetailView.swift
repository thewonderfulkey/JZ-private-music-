import SwiftUI

struct SongDetailView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var historyStore: HistoryStore

    let song: Song
    @State private var quality: QualityLevel = .high
    @State private var sources: [StreamSource] = []
    @State private var isResolving = false
    @State private var backendStatus: [String: String] = [:]  // 后端名 -> 状态文案

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                qualityPicker
                resolveButton
                sourceList
            }
            .padding()
        }
        .navigationTitle(song.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            historyStore.recordSong(song)
        }
        .onDisappear {
            playerManager.stop()
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(spacing: 16) {
            AsyncImage(url: song.picURL.map { URL(string: $0) } ?? nil) { image in
                image.resizable()
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemGray5))
                    Image(systemName: "music.note")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(song.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(song.singer)
                    .font(.body)
                    .foregroundColor(.secondary)
                Text(song.album)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                Text("来源：\(song.platform.displayName)")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            Spacer()
        }
    }

    // MARK: - 音质选择

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("音质")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Picker("音质", selection: $quality) {
                ForEach(QualityLevel.allCases, id: \.self) { q in
                    Text(q.displayName).tag(q)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    // MARK: - 解析按钮

    private var resolveButton: some View {
        Button {
            resolve()
        } label: {
            HStack {
                Spacer()
                if isResolving {
                    ProgressView()
                        .tint(.white)
                    Text("解析中…")
                } else {
                    Image(systemName: "link.badge.plus")
                    Text(sources.isEmpty ? "获取播放/下载链接" : "重新解析")
                }
                Spacer()
            }
            .fontWeight(.semibold)
            .padding(.vertical, 12)
        }
        .buttonStyle(.borderedProminent)
        .disabled(isResolving)
    }

    // MARK: - 源结果列表

    private var sourceList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !sources.isEmpty {
                Text("可用链接（\(sources.count) 条）")
                    .font(.headline)
            }
            ForEach(sources) { source in
                SourceCard(song: song, source: source)
            }
            if !backendStatus.isEmpty && sources.count < backendStatus.count {
                Text("部分后端失败，已自动忽略：")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 解析

    private func resolve() {
        sources = []
        backendStatus = [:]
        isResolving = true
        let stream = URLResolver.shared.resolve(song: song, quality: quality)
        Task {
            for await event in stream {
                switch event {
                case .started(let backend):
                    backendStatus[backend] = "解析中"
                case .success(let source):
                    sources.append(source)
                    backendStatus[source.backendName] = "成功"
                case .failed(let name, let msg):
                    backendStatus[name] = "失败：\(msg)"
                case .finished:
                    isResolving = false
                }
            }
        }
    }
}

// MARK: - 单条源卡片
struct SourceCard: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var downloadManager: DownloadManager

    let song: Song
    let source: StreamSource
    @State private var showDownloadMenu = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.backendName)
                        .font(.headline)
                    Text("\(source.quality.displayName) · \(source.format.uppercased())")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(source.platform.shortName)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }

            HStack(spacing: 12) {
                Button {
                    if playerManager.currentURL == source.url {
                        playerManager.toggle()
                    } else {
                        playerManager.play(url: source.url)
                    }
                } label: {
                    Label(playerManager.currentURL == source.url && playerManager.isPlaying ? "暂停" : "试听",
                          systemImage: playerManager.currentURL == source.url && playerManager.isPlaying ? "pause.circle" : "play.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)

                Button {
                    downloadManager.download(song: song, streamSource: source, useBackground: true)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.systemGray6)))
    }
}

#Preview {
    SongDetailView(song: Song(platform: .qq, platformID: "0039MnYb0qxYhV", name: "晴天", singer: "周杰伦", album: "叶惠美", duration: 270, picURL: nil))
}
