# 安装与首次使用（iOS / Android / Windows）

> 最新包：[v2.4.139 Release](https://github.com/thewonderfulkey/JZ-private-music-/releases/tag/v2.4.139)
> iOS `2.4.139 / 317` · Android `2.4.35` · Windows `2.4.35`
>
> 常见问题见 [FAQ.md](FAQ.md)；Windows 的「文件夹安装版」（可选）见 [INSTALL.md](INSTALL.md)。

---

## iOS（未签名 IPA，需要自签）

Apple 不会替第三方签名，所以发布的是**未签名 IPA**，要用自己的 Apple ID 签一次。

1. 电脑上装 [Sideloadly](https://sideloadly.io/)（Windows 即可）或 [AltStore](https://altstore.io/)。
2. 手机连电脑，把 IPA 拖进 Sideloadly，填自己的 Apple ID，点开始；按提示在手机上信任证书。
3. 或者用 AltStore：在手机上安装 AltStore，用同一账号登录后从「My Apps」里装 IPA。
4. 首次打开若提示「不受信任的开发者」：**设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任**。
5. 普通 Apple ID 签名 **7 天有效**，到期重签；AltStore 可在同一 Wi-Fi 下自动续签。付费开发者账号是 1 年。
6. 覆盖安装：**同一 bundle id + 同一张签名证书**才能直接覆盖，收藏/下载/设置不丢；换证书通常要先删旧 App。

不需要越狱；普通 Apple ID 就够（最多同时签 3 个 App）。

### iOS 注意事项

- **不做 CarPlay 车机界面**：车机屏上出现本 App 需要 Apple 单独审批的 `com.apple.developer.carplay-audio`，
  自签拿不到。能做的「连车载蓝牙自动接着播」已经做了。
- App 被系统杀掉后，连上车机不会自动响，需要先打开一次 App（iOS 不允许为蓝牙事件冷启动进程）。
- 下载目录：`文件 › JZ 音乐 › Download › Music / Lyrics / Cover`；换保存位置只影响**之后**的下载。
- 识曲要麦克风权限；让声源外放（手机扬声器或音箱），戴耳机时麦克风听不到。
- 没有悬浮歌词（iOS 不允许跨 App 浮窗），歌词在播放页内显示，锁屏是系统播放卡片。

---

## Android

1. 下载 `JZ-Music-v2.4.35-android.apk`，点开安装；系统提示「未知来源」时允许本文件安装。
2. 首次启动按提示给权限：**通知**（下载完成/通知栏控制）、**麦克风**（识曲）；悬浮窗可后续再给。
3. 升级直接覆盖安装，收藏/下载保留（签名与历次版本一致，不要装其它渠道改签过的包）。

### Android 注意

- 下载目录固定进系统媒体库 `Music / JZ音乐助手`，App 内不能改。
- 识曲必须外放；戴耳机识别不到（录到的是耳机里的静音）。
- 部分国产 ROM 会额外杀后台：到系统设置里给本应用「允许后台运行 / 自启动」，并把电池优化设为**不限制**，
  否则锁屏久了系统会掐网络，下一首取不到流。

---

## Windows

1. 下载 `JZ-Music-2.4.35-windows-portable.exe`，放到一个**固定目录**（例如 `D:\JZ Music\`）。
2. 双击运行。首次启动会解包到 `%LOCALAPPDATA%\JZ Music\app-2.4.35\`，之后启动就快。
3. 程序没有数字签名，Windows 会提示「Windows 已保护你的电脑」：点 **更多信息 → 仍要运行**；
   杀毒软件也可能报未知程序，加白名单即可。
4. 升级：新的 exe 覆盖旧的；`Data`、`Download` 不受影响。
5. 卸载：删掉 exe、`%LOCALAPPDATA%\JZ Music\` 和安装目录里的 `Download / Cache / Data / Backup`。

### Windows 注意

- 音乐默认下载到程序所在目录的 `Download\`；`Cache\` 是播放缓存，可随时清空。
- 首次启动会建 `Download / Log / Cache / Data / Backup` 五个目录；`Data` 里是收藏、历史、设置。
- 想做「一个 JZ Music 文件夹 + 卸载程序」的安装版，见 [INSTALL.md](INSTALL.md)（可选，不是对外主包）。

---

## 数据在哪

| 平台 | 数据位置 |
|---|---|
| iOS | App 沙盒；「文件」App 里可见 `JZ 音乐 › Download`（歌曲/歌词/封面） |
| Android | 应用私有目录（收藏/历史/设置）+ 系统媒体库 `Music / JZ音乐助手`（下载） |
| Windows | 程序目录 `Data\`（收藏/历史/设置）、`Download\`（音乐）、`Cache\`（缓存） |

没有账号体系，不上传行为；卸载/换机前想保留，iOS 可在设置里打开 iCloud 备份（默认关），
Windows/Android 直接拷 `Data` / 应用私有目录。

---

## 识曲的边界

- 一般 6~12 秒出结果；开始识别前会**故意暂停本机播放**，否则麦克风收到的是自己放的歌。
- 声源要外放：手机扬声器或另一台设备/音箱；戴耳机、环境太吵、音量太小都会失败。
- 不是真内录：麦克风听的是空气里的声音，版权保护/DRM 音频录不到。
