import SwiftUI

// MARK: - 保存位置（第四十轮补丁 3）
//
// 老板真机录屏（r112）结论修正：**不是我们没收到结果，是系统选择器右上角「打开」按下去连关都不关**
// ——那个选择器在这台机器上压根没有完成选择，最后是他自己手动关掉的。也就是说
// 「从系统选择器里选文件夹」这条路在他这里根本走不通，再修我们的回调也没用。
//
// 所以这一页不再依赖系统选择器，改成**确定能成**的两步：
//   ① 列出「文件 › JZ 音乐」下面已有的文件夹（Music、以及他自己建的），点一下选中；
//   ② 点 **「保存」** 立刻生效，路径立刻变。
// 想换新名字就「新建文件夹…」：输名字 → 创建并保存（建在 App 自己的 Documents 下，
// 永远有写权限，也不会遇到"系统不给我权限"）。「恢复默认」也在这一页。
//
// 旧版本存过的安全书签（如果哪台机器真选成了）继续有效：这里会显示它、也能一键恢复默认，
// 只是不再引导用户去走那个会卡住的选择器。
struct DownloadLocationView: View {

    @Environment(SettingsStore.self) private var settings

    /// 选中、还没保存的文件夹名（nil = 没动，等于当前生效的那个）
    @State private var selection: String?
    @State private var errorMessage: String?
    @State private var savedHint: String?
    @State private var showNewFolder = false
    @State private var newFolderName = ""
    @State private var folders: [String] = []

    var body: some View {
        Form {
            Section("当前保存位置") {
                Text(DownloadLocation.currentPathText)
                Text(DownloadLocation.currentAbsolutePathText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let savedHint {
                    Text(savedHint)
                        .font(.caption)
                        .foregroundStyle(Tokens.Palette.vermilion)
                }
                if settings.downloadFolderBookmark != nil,
                   DownloadLocation.savedCustomDirectory() == nil {
                    Text("之前用系统选择器选的文件夹现在打不开了（可能被移动或删除），下载暂时回到默认位置；重新选一个就好。")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(folders, id: \.self) { name in
                    Button {
                        selection = name
                    } label: {
                        HStack(spacing: Tokens.Spacing.xs) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(name)
                                .foregroundStyle(.primary)
                            if name == DownloadLocation.defaultFolderName {
                                Text("默认")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: Tokens.Spacing.xs)
                            if isSelected(name) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Tokens.Palette.vermilion)
                            }
                        }
                    }
                }
                Button {
                    newFolderName = ""
                    showNewFolder = true
                } label: {
                    Label("新建文件夹…", systemImage: "folder.badge.plus")
                }
            } header: {
                Text("选一个文件夹")
            } footer: {
                Text("都在「文件 › JZ 音乐」下面：选完点下面的「保存」立刻生效，新下载的歌就存到这里（已下好的不动）。")
            }

            Section {
                Button {
                    saveSelection()
                } label: {
                    Text("保存")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selection == nil || isSelected(selection ?? ""))
                if DownloadLocation.isCustomFolder {
                    Button(role: .destructive) {
                        restoreDefault()
                    } label: {
                        Text("恢复默认（\(DownloadLocation.defaultPathText)）")
                    }
                }
            }
        }
        .navigationTitle("保存位置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { reloadFolders() }
        .alert("新建文件夹", isPresented: $showNewFolder) {
            TextField("文件夹名，例如 车载音乐", text: $newFolderName)
            Button("创建并保存") { createAndSave() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("会建在「文件 › JZ 音乐」下面，建完立刻生效。")
        }
        .alert("没保存成", isPresented: Binding(get: { errorMessage != nil },
                                              set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: 目录列表

    private func reloadFolders() {
        let docs = DownloadLocation.documentsDirectory()
        var names: [String] = []
        if let items = try? FileManager.default.contentsOfDirectory(
            at: docs, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for url in items {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { names.append(url.lastPathComponent) }
            }
        }
        // 默认的 Music 永远在第一位，其余按名字排
        let others = names.filter { $0 != DownloadLocation.defaultFolderName }.sorted()
        folders = [DownloadLocation.defaultFolderName] + others
        selection = nil
    }

    private func effectiveName() -> String {
        // 外部书签优先（老版本存的）；否则看 App 内子文件夹
        if DownloadLocation.savedCustomDirectory() != nil { return "" }
        return DownloadLocation.subfolderName() ?? DownloadLocation.defaultFolderName
    }

    private func isSelected(_ name: String) -> Bool {
        let current = effectiveName()
        if selection == nil { return name == current }
        return name == selection
    }

    // MARK: 保存

    private func saveSelection() {
        guard let name = selection else { return }
        if name == DownloadLocation.defaultFolderName {
            restoreDefault()
            return
        }
        guard let dir = DownloadLocation.ensuredSubfolder(name),
              DownloadLocation.isWritable(dir) else {
            errorMessage = "这个文件夹现在写不进去，换一个试试。"
            return
        }
        settings.downloadFolderBookmark = nil
        settings.downloadFolderName = name
        selection = nil
        savedHint = "已保存：之后的下载会存到这里"
        reloadFolders()
    }

    private func createAndSave() {
        guard let dir = DownloadLocation.createSubfolder(newFolderName) else {
            errorMessage = "这个文件夹名不能用（不能为空，也不能带 /）。换一个名字试试。"
            return
        }
        guard DownloadLocation.isWritable(dir) else {
            errorMessage = "文件夹建好了，但写不进去。换一个名字试试。"
            return
        }
        settings.downloadFolderBookmark = nil
        settings.downloadFolderName = dir.lastPathComponent
        selection = nil
        savedHint = "已保存：之后的下载会存到这里"
        reloadFolders()
    }

    private func restoreDefault() {
        settings.downloadFolderBookmark = nil
        settings.downloadFolderName = nil
        selection = nil
        savedHint = "已恢复默认位置"
        reloadFolders()
    }
}
