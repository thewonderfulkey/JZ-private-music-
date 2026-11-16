# iOS 系统面（P4 第一段）：分享 / 快捷指令（App Intents）/ 全局路由

> 状态：**已落码、CI 编译与纯逻辑断言通过**（2026-11-16）。真机未验（Windows 无设备）。
> 这一段是 P4 里**不需要新建 Extension target** 的部分；Live Activity 与 Widget 要单独建 target，放在下一段（§5 有风险说明）。

---

## 1 分享（ShareLink）

播放页「⋯」菜单里多了一项「分享」，走系统的 `ShareLink`（不自己画分享面板）：

```
晴天 - 周杰伦
专辑：叶惠美
来源：QQ音乐
音源：cyapi QQ · M4A · 97 kbps
— 来自 JZ 音乐
```

**为什么不带链接**：我们的音源是各平台直链，几分钟就失效，分享出去必然是死链——不如让对面自己去搜。
文案只拼事实（歌名、歌手、专辑、来源），不带签名/接口地址（审核与安全口径见 [IOS-ROLLOUT.md](IOS-ROLLOUT.md) §3）。

纯函数在 `SongShare`，CI 断言了"含歌名歌手/含专辑/含来源/**不含 http**/空歌手不产生 ` - `"。

---

## 2 快捷指令（App Intents）

三个动作，全部 `openAppWhenRun = true`（先把 App 带到前台，再做动作）：

| 动作 | 参数 | 效果 |
|---|---|---|
| 播放我的收藏 | — | 收藏里随机起播，切到资料库 |
| 听歌识曲 | — | 切到识曲页并**自动开始听** |
| 搜索歌曲 | 关键词 | 切到搜索页并把词填进去直接搜 |

**动作本身不在 Intent 里执行**——这是这一段最关键的取舍：

```
AppIntent.perform()（可能不在主线程）
  → IntentInbox.shared.post(...)      // NSLock 保护的小信箱
  → App 回到前台（scenePhase == .active）
  → RootTabView.drainIntents()        // 取走全部并清空
  → 切 Tab / 起播 / 塞搜索词
```

为什么不直接在 `perform()` 里调播放器：那要求把 `PlayerEngine` 变成全局单例（它现在是 App 的 `@State`，
刻意不是单例，因为它的生命周期要跟视图一致），而且 Intent 会持有一个不属于它的 UI 状态。
信箱只有 30 行，线程安全，能被 CI 直接测"先放先取、取完清空"。

**为什么没做 `AppShortcutsProvider`（Siri 固定短语）**：那套 API 的短语插值是 `AppShortcutPhrase`
的自定义字符串插值，编译器版本一换就容易红；而这三个 Intent 只要能出现在「快捷指令」App 里就已经可用
（也能被聚焦、自动化调用）。等真机确认 Intent 真的能跑通，再补短语层——顺序反过来会变成
"短语注册好了、动作不通"。

---

## 3 全局路由（AppRouter）

Tab 的选择状态从 `RootTabView` 的 `@State` 挪到 `AppRouter`：

| 字段 | 用途 |
|---|---|
| `tab` | TabView 直接绑它（`Binding(get:set:)`） |
| `pendingSearch` | Intent 塞进来的搜索词；搜索页取走后置 nil |
| `pendingRecognize` | "立刻开始听"标记；识曲页取走后置 nil |

为什么要挪：Intent 只拿得到"要做什么"，拿不到视图层级。状态放在一个可注入的 `@Observable` 里，
两边都不用互相持有；搜索页/识曲页各自用 `.onChange` + `.task` 消费并清空，避免同一条请求重复触发。

---

## 4 验证边界

| 验证 | 手段 | 结果 |
|---|---|---|
| 信箱语义（先放先取 / 取完清空 / 计数） | CI `logic-tests` | ✅ 6 条断言 |
| 分享文案（含字段 / 不带链接 / 空歌手） | CI `logic-tests` | ✅ 6 条断言 |
| 整包编译（Intent 协议实现是否对得上 SDK） | CI `build-ipa` | 见本轮 run |
| **真机：快捷指令里能看到这三个动作、能跑通** | ❌ 无设备 | **未验证** |

> App Intents 的协议细节（`description` 的可选性、`@Parameter` 的初始化器）是最容易跟 SDK 版本错位的地方，
> 这一轮是照着 iOS 17 的声明写的，**装机后第一件事是打开「快捷指令」App 搜索"JZ"看三个动作在不在**。

---

## 5 下一段：Live Activity / Widget（需要新 target，风险最高）

Live Activity 与 Widget 都必须做成 **Extension target**，而这个工程的 `project.pbxproj` 是手写的，加 target 要动：

```
PBXNativeTarget（新 target + productReference + buildConfigurationList）
PBXFileReference（.appex 产物）
PBXCopyFilesBuildPhase（dstSubfolderSpec = 13，把 .appex 嵌进主 App 的 PlugIns）
PBXTargetDependency + PBXContainerItemProxy（主 App 依赖扩展）
XCBuildConfiguration（扩展自己的 Debug/Release、Info.plist、bundle id 前缀）
```

少任何一处，`xcodebuild` 的报错都不是"你漏了哪段"，而是很含糊的 "Cycle inside" 或 "target has no product"。
所以这一段单独一轮做，并且：

1. 先备份 `project.pbxproj`（本仓库已有 `tools/ios/` 下的登记脚本，新的 target 也写成脚本，可重跑）；
2. 先只做 **App Intents 之外的静态 Widget**（不碰 ActivityKit），确认扩展能被编译进 IPA（看 IPA 里有没有 `PlugIns/`）；
3. 再做 Live Activity（锁屏歌词/灵动岛），它依赖播放引擎的状态，要额外想清楚"App 不在前台时谁更新它"。

---

## 6 装机要试的 3 件事

1. 打开「快捷指令」→ 搜索 "JZ" → 应能看到「播放我的收藏 / 听歌识曲 / 搜索歌曲」。
2. 跑「搜索歌曲」并给一个词（如"晴天"）→ App 应被带到搜索页并直接出结果。
3. 播放页「⋯」→「分享」→ 系统分享面板里文案应是歌名/歌手/专辑/来源，**没有 URL**。
