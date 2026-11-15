import SwiftUI

struct DownloadsView: View {
    @EnvironmentObject var downloadManager: DownloadManager

    var body: some View {
        NavigationStack {
            Group {
                if downloadManager.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("还没有下载任务")
                            .font(.headline)
                        Text("在歌曲详情页点「下载」即可开始")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(downloadManager.items) { item in
                            DownloadRow(item: item)
                        }
                        .onDelete { indexSet in
                            for idx in indexSet {
                                downloadManager.remove(itemID: downloadManager.items[idx].id, deleteFile: true)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("下载")
            .toolbar {
                if !downloadManager.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("全部清理") {
                            let ids = downloadManager.items.filter { $0.status == .completed }.map(\.id)
                            for id in ids {
                                downloadManager.remove(itemID: id, deleteFile: true)
                            }
                        }
                        .disabled(!downloadManager.items.contains { $0.status == .completed })
                    }
                }
            }
        }
    }
}

// MARK: - 下载行
struct DownloadRow: View {
    @EnvironmentObject var downloadManager: DownloadManager
    let item: DownloadItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: statusIcon)
                    .font(.title3)
                    .foregroundColor(statusColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.song.name)
                        .font(.body)
                        .lineLimit(1)
                    Text("\(item.song.singer) · \(item.backendName)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if item.status == .downloading || item.status == .pending {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                HStack {
                    Text(item.progressText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Spacer()
                    if !item.sizeText.isEmpty {
                        Text(item.sizeText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let err = item.errorMessage, item.status == .failed {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }

            if item.status == .failed || item.status == .cancelled {
                HStack {
                    Button("重试") {
                        downloadManager.retry(itemID: item.id, useBackground: true)
                    }
                    .buttonStyle(.bordered)
                    Button("删除记录") {
                        downloadManager.remove(itemID: item.id, deleteFile: false)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if item.status == .completed {
                HStack {
                    Text(item.localPath != nil ? "已保存到文件 App" : "")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                    Button("删除文件") {
                        downloadManager.remove(itemID: item.id, deleteFile: true)
                    }
                    .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch item.status {
        case .pending: return "clock"
        case .downloading: return "arrow.down.circle"
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    private var statusColor: Color {
        switch item.status {
        case .pending: return .orange
        case .downloading: return .accentColor
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .gray
        }
    }

    private var statusText: String {
        switch item.status {
        case .pending: return "等待中"
        case .downloading: return "下载中"
        case .completed: return "已完成"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        }
    }
}

#Preview {
    DownloadsView()
}
