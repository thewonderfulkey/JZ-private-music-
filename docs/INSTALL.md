# Windows 安装版（安装包 / 文件夹结构）

> 目标：交付一个 **`JZ Music` 文件夹**，里面有 `JZ Music.exe`、自动建好的 `Download`（下载的音乐）
> 与 `Log`（日志）等用户目录。双击安装包即可，卸载就是删文件夹（或走设置→应用）。

## 一、交付物

| 产物 | 路径 | 说明 |
|---|---|---|
| **安装包** | `releases\windows\JZ Music Setup-<版本>.exe` | 双击安装；内嵌整份 app-image + 卸载程序 + 说明文档 |
| 免安装单文件 | `releases\windows\JZ Music-<版本>-portable.exe` | 老分发方式，首跑解包到 `%LOCALAPPDATA%` |
| 脚本版安装 | `tools\setup\Setup.ps1` | 无 GUI / 批量部署用，从 app-image 直接铺目录 |

安装包本身就是「自解压 + 安装动作」：`payload.zip`（jpackage app-image）作为资源嵌在 exe 里，
`csc` 编译，不需要 WiX/Inno Setup，也不需要目标机器装 .NET 之外的东西（.NET Framework 4.x 是 Win10/11 自带）。

## 二、安装后的目录

```
D:\JZ Music\                      ← 安装目录（默认 D:\JZ Music；没有 D 盘则 %LOCALAPPDATA%\Programs\JZ Music）
├── JZ Music.exe                  ← 主程序（唯一入口）
├── app\  runtime\                ← 程序本体 + 自带 JRE（jpackage app-image，别单独移动）
├── Download\                     ← 下载的音乐自动保存到这里
├── Log\                          ← desktop.log / play.log / crash.log / 日志说明.txt
├── Cache\                        ← 播放缓存 / 预取缓存 / 下载临时文件（可随时清）
├── Data\                         ← prefs_*.json：设置 / 收藏 / 播放历史 / 下载记录
├── Backup\                       ← 一键备份（设置 → 数据与备份 → 立即备份）
├── 说明\                         ← 使用说明 / 更新日志 / 卸载说明 / 常见问题 / 安装信息
├── 使用说明.txt                   ← 根目录也放一份，双击就能看到
└── 卸载 JZ Music.exe              ← 卸载程序
```

安装器同时会：
- 建桌面快捷方式（可取消）、开始菜单 `JZ Music` 文件夹（含卸载）；
- 在 `HKCU\...\Uninstall\JZ Music` 登记，出现在「设置 → 应用」；
- 覆盖安装时先停掉正在运行的 JZ Music，只替换 `app\` / `runtime\`，`Download\`、`Data\`、`Log\` 全部保留。

## 三、程序怎么知道该往哪写

`AppEnv` 启动时找「安装根」，找到且可写就用安装版布局（详见 `data/Platform.kt`）：

1. `jpackage.app-path`（jpackage 启动器自己写的 `<安装根>\JZ Music.exe`）；
2. `java.home` 正好是 `<安装根>\runtime`；
3. 代码位置在 `<安装根>\app\` 里。

三种都不成立（`gradle run` 开发模式）或安装目录不可写（比如被塞进 `Program Files`）时，
自动退回旧布局：`%APPDATA%\JZ Music` 存配置、`音乐\JZ Music` 存下载、日志写 `<项目根>\logs`。

从旧布局升级到安装版时，第一次启动会把 `%APPDATA%\JZ Music`（以及更早的「JZ音乐助手」）里的
`prefs_*.json` 拷进 `Data\`（只拷不删，写 `.migrated-from-appdata` 标记），
如果旧配置里存过「自定义下载目录=音乐\JZ Music」，会清掉这条，让新的 `Download\` 生效。

## 四、安装 / 卸载 / 静默参数

```powershell
# 图形界面
.\JZ Music Setup-2.1.95.exe

# 静默安装（默认路径）
.\JZ Music Setup-2.1.95.exe --silent

# 静默安装到指定目录，且装完不启动
.\JZ Music Setup-2.1.95.exe --silent --dir="E:\Apps\JZ Music" --no-launch

# 不建快捷方式
.\JZ Music Setup-2.1.95.exe --silent --no-shortcut
```

卸载：

```powershell
& 'D:\JZ Music\卸载 JZ Music.exe'            # 弹窗：保留 / 全删 / 取消
& 'D:\JZ Music\卸载 JZ Music.exe' --yes=keep # 静默：保留 Download + Data
& 'D:\JZ Music\卸载 JZ Music.exe' --yes=all  # 静默：整个文件夹删除
```

安装器日志：`%TEMP%\jz-music-setup.log`；卸载日志：`%TEMP%\jz-music-uninstall.log`。

## 五、构建

```powershell
pwsh -File .\tools\build-setup.ps1              # 编译 app-image + 打安装包
pwsh -File .\tools\build-setup.ps1 -SkipBuild   # 只重打安装包（复用已有 app-image）
pwsh -File .\tools\build-setup.ps1 -Install     # 构建完静默装到 D:\JZ Music
```

产物：`releases\windows\JZ Music Setup-<版本>.exe`。

源码在 `tools/setup/`：

| 文件 | 作用 |
|---|---|
| `Setup.cs` | 图形安装器：选目录、解包、建目录、写说明、快捷方式、注册表、静默模式 |
| `Uninstall.cs` | 卸载器：停进程、删程序/数据、清快捷方式与注册表、自删 |
| `Setup.ps1` | 脚本版安装（从 app-image 铺目录，有 csc 就现编卸载器） |
| `docs\*.txt` | 装进「说明\」和「Log\」的用户文档（安装器把内容嵌进 exe） |

## 六、验证清单（出包后跑一遍）

1. `--silent --dir=<临时目录>` 安装 → 目录里有 exe / app / runtime / Download / Log / Cache / Data / Backup / 说明 / 卸载；
2. 启动主程序 → `Log\desktop.log` 出现 `layout -> install(portable) ... download=<安装目录>\Download`；
3. 搜索并下载一首 → 文件落在 `Download\`，下载管理页「保存在 …\Download」；
   不想点界面时，用探针直接走一遍下载链路：

   ```powershell
   cd "D:\JZ Music"
   java -cp "app\*" D:\Projects\Private_music\tools\probes\desktop-download-probe.java 003aAYrm3GE0Ac 稻香 周杰伦 223
   ```
4. 设置 → 数据与备份 → 立即备份 → `Backup\backup-<时间>\` 有 `Data\*.json` 与 `已下载.m3u`；
5. 覆盖安装（**程序还在运行时**）→ 安装器先把实例杀干净再替换 app\runtime，`Download\`、`Data\` 内容还在；
6. `卸载 --yes=all` → 文件夹消失、快捷方式与「设置→应用」条目消失。

本轮实测（2026-11-15，本机）：

- 首次安装：189 个文件，6 个用户目录 + 说明 + 卸载器 + 桌面/开始菜单快捷方式 + 注册表项齐全；
- 覆盖安装（JZ Music 正在运行）：先杀父子两个同名进程，只替换 `app\` / `runtime\`，`Data\` 里 4 条收藏保留；
- 启动日志：`layout -> install(portable) root=D:\JZ Music data=D:\JZ Music\Data download=D:\JZ Music\Download`；
- 真实下载：走 `DownloadManager` 全链路，文件落在 `D:\JZ Music\Download\...m4a`（2.7MB），记录 COMPLETED；
- 备份：`Backup\backup-YYYYMMDD-HHmmss\` 里 3 份 `prefs_*.json` + `已下载.m3u` + `我的收藏.txt` + `备份说明.txt`；
- 卸载（另装的临时目录，`--yes=all --quiet`）：exit 0，目录与自身被删干净；
- 设置页（`JZ_START_PAGE=settings`）正常渲染，「下载位置」显示 `D:\JZ Music\Download`。
