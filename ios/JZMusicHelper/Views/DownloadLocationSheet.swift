import SwiftUI
import UniformTypeIdentifiers

// MARK: - 保存位置（第四十轮补丁）
//
// 老板真机反馈（第二轮）：
//   · "可配置的位置只有打开按钮，没有保存按钮，怎么就算路径设置好了也没办法更改"；
//   · "设置页面显示的只有一个 Music，我要把完整的路径显示出来，像之前版本一样"。
//
// 上一版把「保存位置」做成了一个点了就弹系统文件夹选择器的 Form 行：
// 系统选择器对文件夹只有「打开」这个按钮（不是我们写错），而选完之后**没有再给一次明确的"确认保存"**，
// 用户看到的还是原来的名字——所以这一页把流程拆成可见的三步：
//   ① 先看当前在哪（面包屑 + 绝对路径）；
//   ② 点「选择文件夹…」进系统选择器（那个「打开」就是"选中这个文件夹"）；
//   ③ 回来这一段会写明"将要保存到 …"，再点 **「保存到这里」** 才真正改。
// 这是老板要的那颗「保存」按钮，也是"到底改没改"一眼可验证的地方。
struct DownloadLocationSheet: View {

    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss

    @State private var showPicker = false
    /// 选过、还没保存的目录（保存前不写任何设置，避免"点一下就被改掉"）
    @State private var pendingURL: URL?
    @State private var pendingBookmark: Data?
    @State private var errorMessage: String?
    @State private var savedHint: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("当前保存位置") {
                    Text(DownloadLocation.currentPathText)
                        .font(.body)
                    Text(DownloadLocation.currentAbsolutePathText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if settings.downloadFolderBookmark != nil,
                       DownloadLocation.savedCustomDirectory() == nil {
                        Text("之前选的文件夹现在打不开了（可能被移动或删除），下载暂时回到默认位置；可以重新选一个。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let savedHint {
                        Text(savedHint)
                            .font(.caption)
                            .foregroundStyle(Tokens.Palette.vermilion)
                    }
                }

                if let pendingURL, pendingBookmark != nil {
                    Section("将要保存到这里") {
                        Text(DownloadLocation.breadcrumb(for: pendingURL))
                        Text(pendingURL.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            save(pendingURL, pendingBookmark)
                        } label: {
                            Text("保存到这里")
                                .font(.body.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        Button("不换了", role: .cancel) {
                            clearPending()
                        }
                    }
                }

                Section("改成别的文件夹") {
                    Button {
                        showPicker = true
                    } label: {
                        Label("选择文件夹…", systemImage: "folder")
                    }
                    if settings.downloadFolderBookmark != nil {
                        Button(role: .destructive) {
                            settings.downloadFolderBookmark = nil
                            settings.downloadFolderName = nil
                            clearPending()
                            savedHint = "已恢复默认位置"
                        } label: {
                            Text("恢复默认（\(DownloadLocation.defaultPathText)）")
                        }
                    }
                }

                Section {
                    Text("换位置只影响**之后**的下载：已经下好的歌还在原来的文件夹里，照样能播、能删。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("能长期保存的位置：本 App 的「文件 › JZ 音乐」下面的文件夹、iCloud Drive 里的文件夹。别的 App 自己的文件夹系统不允许长期访问。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("保存位置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showPicker,
                          allowedContentTypes: [.folder],
                          allowsMultipleSelection: false) { result in
                handlePick(result)
            }
            .alert("没选成", isPresented: Binding(get: { errorMessage != nil },
                                                 set: { if !$0 { errorMessage = nil } })) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: 动作

    private func handlePick(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            // 建书签必须在这个作用域内做：出了这层，系统的授权就收回了
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let bookmark = DownloadLocation.makeBookmark(for: url) else {
                errorMessage = "这个文件夹拿不到长期权限。换一个试试：本 App 的「文件 › JZ 音乐」下面的文件夹，或 iCloud Drive 里的文件夹。"
                return
            }
            pendingURL = url
            pendingBookmark = bookmark
            savedHint = nil
        case .failure(let error):
            errorMessage = "没选成文件夹：\(error.localizedDescription)"
        }
    }

    private func save(_ url: URL, _ bookmark: Data?) {
        guard let bookmark else { return }
        // 真写一次再删：目录存在≠能给写（iCloud 只读共享、别的 App 的容器都会在这儿露出来）
        let scoped = url.startAccessingSecurityScopedResource()
        let writable = DownloadLocation.isWritable(url)
        if scoped { url.stopAccessingSecurityScopedResource() }
        guard writable else {
            errorMessage = "这个文件夹现在写不进去（可能是只读的、或 iCloud 里别人共享给你的）。换一个能写的文件夹试试。"
            return
        }
        settings.downloadFolderBookmark = bookmark
        settings.downloadFolderName = url.lastPathComponent
        savedHint = "已保存：之后的下载会存到这里"
        clearPending()
    }

    private func clearPending() {
        pendingURL = nil
        pendingBookmark = nil
    }
}
