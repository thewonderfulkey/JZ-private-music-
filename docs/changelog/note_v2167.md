v2.1.67 已出包：修「息屏后播完不自动切歌」

**复现路径（和你描述一致）**：点最近播放的一首 → 退回桌面（进程与前台服务都在）→ 不锁屏：播完能正常切下一首；一锁屏就停在当前歌，亮屏后立刻恢复。

**根因（两处叠在一起）**
1. **自动连播的监听挂错了地方**：`PlayerManager.completed / sourceMismatch / playbackFailed` 这三个 `collect` 原先写在 `App()` 的 `LaunchedEffect` 里，跑在 Compose 组合的协程上下文（`AndroidUiDispatcher` + 帧时钟）。息屏后窗口不可见，系统不再产生帧，MediaPlayer 的 completion 虽然已经把事件置位，协程却排在帧后面得不到调度——所以只是"不切歌"，音频链路本身没坏。屏幕亮着时帧一直在走，因此看不出问题。
2. **前台服务不等于 CPU 不休眠**：v2.1.5 起已经用 `foregroundServiceType=mediaPlayback` 保住了进程，但前台服务挡不住 Doze 下的 CPU 休眠；一首歌播完（音频流停止、音频层 wakelock 随之释放）到下一首取流之间，回调、协程、网络请求都可能停摆。

**改法**
- 三个监听从组合搬到 `AppState.startAutoContinue()`：应用级协程（`Dispatchers.Main`，普通主线程 Handler，不依赖帧），由 `MainActivity.onCreate` 启动一次；组合里的三处 `LaunchedEffect` 已删除，避免双重推进。
- `PlayerService` 持有 `PARTIAL_WAKE_LOCK`（不亮屏、只保 CPU），服务创建时获取、销毁时释放；`AndroidManifest` 补 `WAKE_LOCK` 权限。

**验证（静态）**
- 构建：BUILD SUCCESSFUL（assembleRelease）
- badging：`com.jz.musichelper / versionCode 125 / versionName 2.1.67`，`WAKE_LOCK` 已在安装包权限表里（共 8 条）
- 签名：apksigner 通过，证书 SHA-256 与上版一致
- 完整性：zip 183 条目，testzip 无损坏；APK 29,585,079 字节
- 代码核对：组合内已无 `completed` 收集（只剩定义处 1 处）、服务持有保活锁、`MainActivity` 已启动监听
- **缺口**：`adb devices` 为空，没做真机息屏复现；这条只能你在真机上验证：播一首歌 → 退桌面 → 息屏 → 等它播完，看是否自动切下一首。
