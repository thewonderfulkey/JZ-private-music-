# JZ的音乐助手 — 构建与侧载指引

> 原生 iOS 16+ SwiftUI 应用。把已实测的 33 条 GitHub 音乐源（酷我/QQ/网易/酷狗四大后端族）组合成一个「搜索 → 试听 → 下载到 iPhone 文件 App」的 App。
> 本版不含歌词与封面抓取，只负责获取音乐文件本体。

---

## 一、这是什么

- **App 名称**：JZ的音乐助手
- **最低系统**：iOS 16.0（iPhone / iPad）
- **界面语言**：简体中文
- **核心能力**：
  - 搜索：并发搜索 QQ / 网易云 / 酷我 / 酷狗 4 个平台，先返回的源先显示，失败/超时的源自动忽略；
  - 试听：在线播放（不走中转，App 直连第三方源）；
  - 下载：多后端并发解析取流，可选手动下载，支持后台下载、进度、重试、取消、删除；
  - 音质：标准 128k / 高品 320k / 无损 FLAC；
  - 历史：搜索历史、最近查看自动记录；
  - 保存位置：App 沙盒 `Documents/Music/`，通过「文件」App 可见、可导出（已开启 UIFileSharingEnabled）。

## 二、工程结构

```
JZMusicHelper/
├── JZMusicHelper.xcodeproj/project.pbxproj     # Xcode 工程（手写生成，无需 pod/SwiftPM 依赖）
└── JZMusicHelper/
    ├── JZMusicHelperApp.swift                  # 入口：Tab 主界面 + 通知权限
    ├── Info.plist                              # ATS 任意加载 / 文件共享 / 显示名
    ├── Assets.xcassets                         # App 图标 + 主题色
    ├── Models/
    │   ├── Song.swift                          # 歌曲模型 + 平台/音质枚举
    │   └── DownloadItem.swift                  # 下载条目 / 流地址 / 历史模型
    ├── Services/
    │   ├── APIClient.swift                     # 统一 HTTP GET（UA/Referer/超时/JSON）
    │   ├── SearchAdapters.swift                # QQ/网易/酷我/酷狗 搜索适配器
    │   ├── SearchService.swift                 # 并发搜索 + 流式先到先显示
    │   ├── SourceAdapters.swift                # 10 个取流后端解析器 + 轻量音频校验
    │   ├── URLResolver.swift                   # 单曲多后端并发解析
    │   ├── DownloadManager.swift               # 前后台下载管理 + AppDelegate 桥接
    │   ├── PlayerManager.swift                 # AVPlayer 在线试听
    │   └── HistoryStore.swift                  # 历史/下载记录 JSON 持久化
    └── Views/
        ├── MainTabView.swift                   # 四个 Tab
        ├── SearchView.swift                    # 搜索页
        ├── SongDetailView.swift                # 歌曲详情：音质选择/取流/试听/下载
        ├── DownloadsView.swift                 # 下载管理页
        ├── HistoryView.swift                   # 历史页
        └── SettingsView.swift                  # 设置页
```

零第三方依赖，全部使用系统框架（SwiftUI / Foundation / AVFoundation / URLSession）。

## 三、构建环境（你需要一台 Mac）

本工程在 Windows 上编写、无法本地编译，请把整个 `JZMusicHelper/` 目录拷到任意一台装有 **Xcode 15+** 的 Mac 上：

1. **打开工程**：双击 `JZMusicHelper.xcodeproj`（或 `open JZMusicHelper.xcodeproj`）。
2. **设置签名团队**（首次构建必须）：
   - 选中左侧工程 → Target `JZMusicHelper` → Signing & Capabilities；
   - 勾选 Automatically manage signing；
   - Team 选你自己的 Apple ID（免费账号即可，侧载有效期 7 天，需每周重签）；
   - 若未登录 Apple ID：Xcode → Settings → Accounts 添加。
3. **选择运行设备**：
   - 真机：iPhone 用数据线连 Mac，顶部工具栏选你的 iPhone，点 ▶ 运行；
   - 首次真机运行需在 iPhone 上信任开发者证书：设置 → 通用 → VPN与设备管理 → 信任。
4. **构建产物**：Run 后 App 直接安装到 iPhone（Debug 包）；如需 .ipa 分发，菜单 Product → Archive → Distribute App（自签/企业签自理）。

> 说明：工程无 pod/SPM 依赖，无需 `pod install`，打开即可编译。若 Xcode 提示升级工程格式，选 Convert 即可（objectVersion 56 对应 Xcode 14+）。

## 四、没有 Mac 时的替代侧载路线（签名自理）

按你的要求签名/侧载不在此次交付范围，以下是常见路线（任选，需自行评估）：

| 方式 | 需要 | 有效期 | 说明 |
|---|---|---|---|
| 云 Mac + Xcode | 租一台云 Mac | 7 天/付费 | 在云 Mac 上编译出 ipa |
| AltStore / Sideloadly / 爱思助手 | 一台 Windows/PC + Apple ID | 7 天（无开发者账号） | 把 ipa 装到 iPhone |
| 付费开发者账号（¥688/年） | Apple ID + 账号 | 1 年 | 免 7 天重签 |

拿到 .ipa 后：iOS 上「文件」App 打开或用爱思助手安装，首次打开需在设置里信任证书。

## 五、使用说明

1. 打开 App → 搜索框输入歌名（建议带歌手名，如「晴天 周杰伦」）→ 搜索。
2. 结果按平台分色标注（QQ/网易/酷我/酷狗），点任意结果进入详情。
3. 详情页选择音质 → 点「获取播放/下载链接」→ 出现若干条可用链接（每条标注后端名、音质、格式）。
4. 「试听」直接在线播放；「下载」写入 `Documents/Music/`，下载页可见进度、可重试/取消/删除。
5. 查看文件：iPhone「文件」App → 我的 iPhone → **JZ的音乐助手** → Music 文件夹，可直接播放/导出/拷贝到音乐库（用其他 App 导入，如 MusicMate 等）。

## 六、关于第三方源（重要）

- 全部源为**实测过、当前可用**的第三方接口（详见主目录《GitHub音乐源连通性测试报告.md》与《接口归类清单-音乐与歌词.md》），**时点性强，随时可能失效**：
  - 酷我系（haitangw / nxinxz / oiapi / KuwoDES 官方签名链 / zddyr）：320k MP3 全量可下，官方链对 VIP 曲只给 11 秒试听；
  - QQ 系（cyapi.top / a.aa.cab）：VIP 曲可出全量 m4a/mp3；
  - 网易云系（gdstudio / oiapi Music_163）：VIP 曲可出全量 mp3；
  - 酷狗系（haitangw.cc kg）：hash 直查。
- 部分直链带防盗链（校验 UA/Referer），App 已统一带移动端 UA + Referer；个别源短期签名会过期，下载失败可「重试」或换一条链接。
- **版权提示**：仅供个人学习测试使用，请支持正版音乐。
- 搜索层依赖各平台开放接口，未做账号登录；「网易云独有歌曲」类目因版权事实（周杰伦曲库网易云无原版）未单独支持。

## 七、已知限制（本版）

- 无歌词、无封面下载（按你的要求暂不做）；
- 单曲验证：下载完整度判定沿用前序测试口径（字节数 == Content-Length 且时长吻合）；
- 酷狗搜索域名证书与主机名不匹配，依赖 Info.plist 的 ATS 例外（已配置 NSAllowsArbitraryLoads=true）；
- 后台下载依赖系统后台会话，链接带短期签名时可能失效，失败后请手动重试。
