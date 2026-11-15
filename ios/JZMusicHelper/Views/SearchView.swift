import SwiftUI

struct SearchView: View {
    @EnvironmentObject var historyStore: HistoryStore
    @State private var keyword = ""
    @State private var songs: [Song] = []
    @State private var platformStatus: [MusicPlatform: PlatformStatus] = [:]
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    enum PlatformStatus {
        case searching
        case done
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                statusLine
                resultsList
            }
            .navigationTitle("JZ的音乐助手")
            .navigationDestination(for: Song.self) { song in
                SongDetailView(song: song)
            }
        }
    }

    // MARK: - 搜索栏

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("搜索歌曲（如：晴天 周杰伦）", text: $keyword)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { startSearch() }
            if !keyword.isEmpty {
                Button {
                    keyword = ""
                    songs = []
                    platformStatus = [:]
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
            Button("搜索") {
                startSearch()
            }
            .fontWeight(.semibold)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
    }

    // MARK: - 平台状态行

    private var statusLine: some View {
        HStack(spacing: 12) {
            ForEach(MusicPlatform.allCases, id: \.self) { p in
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor(p))
                        .frame(width: 8, height: 8)
                    Text(p.shortName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }

    private func statusColor(_ p: MusicPlatform) -> Color {
        switch platformStatus[p] {
        case .searching: return .orange
        case .done: return .green
        case .failed: return .red
        case nil: return .gray.opacity(0.4)
        }
    }

    // MARK: - 结果列表

    private var resultsList: some View {
        Group {
            if songs.isEmpty && !isSearching && !keyword.isEmpty {
                emptyState(icon: "music.note.list", title: "没有找到结果", subtitle: "换个关键词试试")
            } else if songs.isEmpty && !isSearching {
                emptyState(icon: "music.note", title: "输入关键词开始搜索", subtitle: "支持 QQ / 网易 / 酷我 / 酷狗")
            } else {
                List {
                    ForEach(songs) { song in
                        SongRow(song: song)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // iOS 16 兼容的空态视图（ContentUnavailableView 需要 iOS 17）
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(subtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 搜索

    private func startSearch() {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        searchTask?.cancel()
        songs = []
        platformStatus = [:]
        isSearching = true
        historyStore.recordSearch(trimmed)

        searchTask = Task {
            var seen = Set<String>()
            let stream = SearchService.shared.search(keyword: trimmed)
            for await event in stream {
                if Task.isCancelled { break }
                switch event {
                case .started(let p):
                    platformStatus[p] = .searching
                case .results(let p, let result):
                    platformStatus[p] = .done
                    let filtered = result.filter { seen.insert($0.id).inserted }
                    songs.append(contentsOf: filtered)
                case .failed(let p, let msg):
                    platformStatus[p] = .failed(msg)
                case .finished:
                    isSearching = false
                }
            }
            if Task.isCancelled {
                isSearching = false
            }
        }
    }
}

// MARK: - 歌曲行
struct SongRow: View {
    let song: Song

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.picURL.map { URL(string: $0) } ?? nil) { image in
                image.resizable()
            } placeholder: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                    Image(systemName: "music.note")
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 3) {
                Text(song.name)
                    .font(.body)
                    .lineLimit(1)
                Text(song.singer)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(song.platform.shortName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.accentColor.opacity(0.15))
                )
            Text(song.durationText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

#Preview {
    SearchView()
}
