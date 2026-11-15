# note_v2.1.95-installer —— Windows 安装版：一个文件夹里装齐程序 / 音乐 / 日志

日期：2026-11-15
产物：

- **`releases\windows\JZ Music Setup-2.1.95.exe`**（138.8 MB，双击安装；`--silent` 可静默）
- 安装默认目录 `D:\JZ Music`（没有 D 盘则 `%LOCALAPPDATA%\Programs\JZ Music`）

## 要解决的问题

上一版对外只有一个 `JZ Music-2.1.95-portable.exe`：双击后把程序解到
`%LOCALAPPDATA%\JZ Music\app-<版本>-<指纹>\`，下载的音乐在 `%USERPROFILE%\Music\JZ Music`，
日志在项目目录的 `logs\`。用户看到的是"程序藏在 C 盘、音乐在音乐库、日志不知道在哪"，
没有任何一个地方能一次看全这个软件的东西。

这一版把交付形态改成**安装版**：一个 `JZ Music` 文件夹装齐所有东西。

## 安装后的目录

```
JZ Music\
├── JZ Music.exe          主程序
├── app\  runtime\        程序本体 + 自带 JRE（jpackage app-image）
├── Download\             下载的音乐自动保存到这里
├── Log\                  desktop.log / play.log / crash.log / 日志说明.txt
├── Cache\                播放缓存 / 预取 / 下载临时文件
├── Data\                 prefs_*.json：设置 / 收藏 / 历史 / 下载记录
├── Backup\               一键备份
├── 说明\                 使用说明 / 更新日志 / 卸载说明 / 常见问题 / 安装信息
├── 使用说明.txt
└── 卸载 JZ Music.exe
```

## 程序侧（`desktop/src`）

1. **`AppEnv` 认安装根**（`data/Platform.kt`）：依次看 `jpackage.app-path` →
   `java.home` 是不是 `<根>\runtime` → 代码是不是在 `<根>\app\`。认到且可写就用安装版布局：
   `Data\` / `Cache\` / `Log\` / `Download\` / `Backup\` 全在安装目录里。
   开发模式（`gradle run`）或装到只读位置时自动退回旧布局（`%APPDATA%` + 音乐文件夹 + 项目 logs）。
2. **日志统一进 `Log\`**：`desktop.log`（JzLog）、`play.log`（PlayLog）、`crash.log`（未捕获异常）。
3. **下载默认落 `Download\`**：`AppEnv.musicDir` 在安装版里就是 `<安装根>\Download`，
   设置页「更改目录 / 恢复默认」的语义不变。
4. **老数据迁移**：第一次启动把 `%APPDATA%\JZ Music`（及更早的「JZ音乐助手」）里的
   `prefs_*.json` 拷进 `Data\`，写 `.migrated-from-appdata` 标记，只拷不删。
   旧配置里的 `download_dir` 如果指向旧的 `音乐\JZ Music`、或者是 `D:\` 这种磁盘根目录
   （早先测试留下的脏值），迁移时清掉；读取时也再挡一次磁盘根目录。
5. **下载记录自愈**：`DownloadManager.init()` 对 `localPath` 已失效的记录按文件名去
   `Download\` 里找，找到就改写路径，「打开所在文件夹 / 删除（含文件）」不会指空。
6. **一键备份**（`data/BackupManager.kt`）：`Backup\backup-yyyyMMdd-HHmmss\` 里放
   `Data\*.json` + `已下载.m3u` + `我的收藏.txt` + `备份说明.txt`。
7. **设置页新增「数据与备份」**：五个目录一行一个（下载/日志/缓存/配置/备份）+ 一键打开 +
   立即备份 + 清空搜索历史；「关于」里仍显示日志目录与最近异常。
8. **`JZ_START_PAGE=settings`**：启动直接落到指定页（截图/排障用，和 `JZ_SMOKE_*` 同口径）。

## 安装器（`tools/setup/`，csc 编译，不需要 WiX/Inno）

- `Setup.cs`：WinForms 选目录 → 解 `payload.zip`（整份 app-image 作为资源内嵌）→
  建六个用户目录 → 写说明文档 → 放卸载器 → 快捷方式（桌面可选 + 开始菜单）→
  `HKCU\...\Uninstall\JZ Music` 登记。覆盖安装会先停掉安装目录里正在跑的实例，
  只替换 `app\` / `runtime\`，`Download\` / `Data\` / `Log\` 保留。
- `Uninstall.cs`：停进程 → 删程序文件 / 按选择删音乐与配置 → 清快捷方式与注册表 →
  `cmd` 延迟自删。卸载器自己也放在安装目录里，名字 `卸载 JZ Music.exe`。
- `Setup.ps1`：脚本版（无 GUI / 批量），从 app-image 直接铺目录，有 csc 就现编卸载器。
- `docs\*.txt`：装进「说明\」「Log\」的用户文档，构建时作为资源嵌进 Setup.exe。
- `tools/build-setup.ps1`：`packageAppImage` → 压 payload → 编卸载器 → 编安装器 →
  `releases\windows\JZ Music Setup-<版本>.exe`；`-Install` 可直接静默装一遍。

## 实测（本机）

- `Setup.exe --silent --dir="D:\JZ Music"`：189 个文件解包，六个目录 + 说明 + 卸载器齐全，
  exit 0；覆盖安装第二次同样 exit 0，`Data\` 里迁移来的 4 条收藏还在。
- 启动后 `Log\desktop.log` 第一行：
  `layout -> install(portable) root=D:\JZ Music data=D:\JZ Music\Data download=D:\JZ Music\Download`。
- 真实下载一首（走 `DownloadManager` 全链路：解析 → 换源 → 体积校验）：
  文件落在 `D:\JZ Music\Download\...m4a`（2.7MB），记录状态 COMPLETED，`localPath` 指向该文件。
- `%APPDATA%` 里旧配置只在迁移时读过，新进程不再往那里写。
- 截图：发现音乐页正常；`JZ_START_PAGE=settings` 的设置页（含「数据与备份」卡片）正常渲染。

## 没做的 / 已知

- 安装包 138.8 MB（app-image 200.9 MB 压过），没有增量升级，整包覆盖。
- 安装到 `Program Files` 这类只读位置会退回旧布局（配置/下载/日志不在安装目录）——
  默认路径与推荐路径都是用户可写目录，正常安装不会遇到。
- 安装器没有代码签名，SmartScreen 可能提示"未知发布者"（和之前的单文件 exe 一样）。
- 桌面歌词子进程仍由主进程带 `--log-dir` 启动；安装版里父子进程的日志都在同一个 `Log\`。
