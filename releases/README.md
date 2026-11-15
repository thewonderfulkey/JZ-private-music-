# releases/ · 交付规则

1. **只放最新一版 APK**，命名 `JZ音乐助手-v<versionName>.apk`（与 `versionName` 严格一致）。
2. 旧包一律移到 `../archive/apk/`，不要留在这一层。
3. 每版同时写 `docs/changelog/note_v<版本>.md`；本目录不再单独写说明。
4. 签名：Android Debug 证书（SHA-256 `916ad2328810c691a4022d9716a77709e9ebb08aa262b373c0b05b8c6aed07ac`），
   **所有版本必须同签**，否则用户无法覆盖安装。
5. GitHub 同步：仓库 `thewonderfulkey/JZ-private-music-`，发布时 `git push` + 新建 Release（APK + 源码 zip）。

## Windows 桌面版

| 产物 | 用途 |
|---|---|
| `windows\JZ Music Setup-<版本>.exe` | **对外主发**：双击安装成一个 `JZ Music` 文件夹（程序 + Download + Log + Cache + Data + Backup + 说明 + 卸载器） |
| `windows\JZ Music-<版本>-portable.exe` | 老分发方式：单文件免安装，首跑解包到 `%LOCALAPPDATA%` |

安装/卸载/静默参数：`--silent --dir="D:\JZ Music" --no-launch`；详见 `docs/INSTALL.md`。

## 版本表

| 版本 | versionCode | 主题 | APK |
|---|---|---|---|
| v2.1.95 | 153 | 四个界面细节：识曲列表贴底/去平台并发/酷我时长/结果行对齐 | `JZ音乐助手-v2.1.95.apk` |
| v2.1.94 | 152 | 六项修复（原唱/酷我解析/酷狗/封面/闸门/提示） | archive |
| v2.1.93 | 151 | 识曲可自动测（smoke 变体）+ 现场收录版不再抢位 | archive |
| v2.1.92 | 150 | 识曲改「双通道统一打分」，不再酷狗优先 | archive |
| v2.1.91 | 149 | 识曲酷狗＋网易双通道互为兜底 | archive |
| v2.1.90 | 148 | 「原唱」D 口径重做 | archive |
| v2.1.89 | 147 | 识曲起播按「歌名+第一歌手」择优录音室版 | archive |
| v2.1.88 | 146 | 核心歌名匹配 / 平台条数 / 酷我大小写 | archive |
| v2.1.87 | 145 | 酷我封面（MVPIC）+ 酷我官方歌词 | archive |
| v2.1.86 | 144 | 识曲结果页重做（纸签） | archive |
| v2.1.85 | 143 | 严格歌手匹配 + 其他版本 + 播放缓存 | archive |
| v2.1.84 | 142 | 取消交互 / 50 条历史 / 时长四档 | archive |
| v2.1.83 | 141 | 识曲独立成页 + 直接起播 | archive |
| v2.1.82 | 140 | 采集口径与静音判据修复 | archive |
| v2.1.81 | 139 | 识曲作用域/权限误报修复 | archive |
| v2.1.80 | 138 | 听歌识曲上线（酷狗） | archive |
| v2.1.79 | 137 | 桌面歌词：去进度条 + 真实逐字时间 | archive |
| v2.1.74–2.1.78 | 132–136 | 桌面歌词上线与迭代 | archive |
| v2.1.73 | 131 | 平板/横屏自适应（归档基准版） | archive |



