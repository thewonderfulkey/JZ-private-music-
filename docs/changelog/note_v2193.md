# v2.1.93 · 识曲可自动化测试 + 现场收录版不再抢位

版本：v2.1.93 / versionCode 151　包名 `com.jz.musichelper`
产物：`releases/JZ音乐助手-v2.1.93.apk`　29,859,137 B　MD5 `3DF55161F98A9B639AFA8C5336E9851D`
签名：Android Debug（SHA-256 `916ad232…`，与历史一致）

## 一、这版最要紧的不是修 bug，是把识曲变成"能自动验证"

以前识曲只能靠真机对着音箱录，模拟器测不了（没有真实声源）。现在加了一条**只在冒烟包里存在**的通道：

- `buildTypes` 新增 `smoke`：与 `release` 同源同签，只多一个编译期开关 `RECOG_TEST_HOOK=true`；
- 冒烟包内置两段 12 秒 / 8kHz / 单声道 PCM（`assets/fixtures/`，各 192,000 B）；
- `adb shell am start -n com.jz.musichelper/.MainActivity --es jz_test_pcm qingtian_8k.pcm`
  就会把这 12 秒当成"刚录完的音"，走**和真机完全一样**的两条通道 + 打分 + 结果卡；
- 结论同时打进 logcat：`JZ_TEST: RECOG fixture=… kg=5 ne=2 note=识别依据：酷狗 83 ／ 网易 40 → 采用酷狗 top=晴天/周杰伦/叶惠美/83`

**正式包不含这条通道**：`RECOG_TEST_HOOK=false` 是编译期常量，`jz_test_pcm` 这个字符串在 release dex 里都查不到（验证脚本会断言），fixtures 资产也不打进正式包。

### 冒烟实测（Android 14 模拟器，本机真实跑）

| 用例 | 酷狗 | 网易 | 结论 | 结果 |
|---|---|---|---|---|
| 晴天（周杰伦） | 5 条，`is_original=1` / 叶惠美 | 2 条（翻唱） | 酷狗 83 ／ 网易 40 → **采用酷狗** | 晴天 / 周杰伦 / 叶惠美 ✓ |
| 我们都一样（张杰） | 5 条，最高分只有 2（全是翻唱/综艺） | 1 条，张杰 / 明天过后 | 酷狗 2 ／ 网易 40 → **双通道互证** | 我们都一样 / 张杰 / 明天过后 **90 分** ✓ |

**这正好是你提的那个场景**：酷狗认不出张杰原唱，网易有，打分把结果落到张杰。而且这次是在设备上跑出来的，不是桌面复算。

## 二、修掉的判定问题：`is_original` 还有第 4 种值

做样本时实抓到的：酷狗原唱标记除了 `1`（原唱）、`2`（翻唱），还会返回 **`4`**：
- 《晴天》→ 周杰伦《2004 无与伦比 演唱会 Live CD》版是 4；
- 《我们都一样》→ 张杰《中国新声代 第三季 第十三期》版是 4。

语义应是「原唱，但不是这张录音室录音」。旧代码把 4 当未知（0 分），结果是**现场版能和录音室版平起平坐**，只要位次靠前就会抢到第一。现在 4 → **−8**，配合「专辑是演唱会/综艺 −28」，现场收录版不会再压过录音室版。

## 三、改动的文件

| 文件 | 改动 |
|---|---|
| `app/build.gradle.kts` | vc151 / 2.1.93；`buildFeatures.buildConfig=true`；release 关钩子；新增 `smoke` 变体 |
| `MainActivity.kt` | 钩子：读 intent 的 `jz_test_pcm` → 600ms 后触发注入识曲 |
| `ui/App.kt` | `startRecognizeWithFixture()`：读 assets 样本 → 两条通道 → `fuseRecognize` → 写回结果卡 + 打 `JZ_TEST` 日志 |
| `network/RecognizeScore.kt` | `is_original=4 → −8` |
| `ui/SettingsScreen.kt` | 关于页 → v2.1.93（只写用户能感知的判定修正，不提测试钩子） |
| `tools/smoke/` | 新增 `make_fixtures.py`（从妖狐酷我直链下歌 → miniaudio 解码 → 8k PCM）、`fixtures/` 两段样本；`smoke.ps1` 增加识曲 4 项×2 断言 |
| `tools/dev.ps1` | 先编 release，再编 smoke，冒烟测 smoke 包；发布仍是 release |

## 四、验证

- `python tools\verify\verify_2193.py` → **57 项 PASS / 0 FAIL**，新增：钩子只在 smoke（release dex 无 `jz_test_pcm`、无 fixtures 资产；smoke dex 有、资产两个各 192,000 B）、`4 -> -8` 源码断言、样本长度断言。
- 模拟器冒烟 → **18 项全 PASS**（启动/安装/版本/FATAL/ANR/进程/六格导航/识曲页/关于页 + 识曲两组各 4 项）。
- 构建：`tools/build.ps1` + `tools/build.ps1 -Task assembleSmoke`，均 BUILD SUCCESSFUL。

## 五、缺口

1. **模拟器与真机仍有差异**：模拟器的麦克风没有真实声源（所以用注入替代），Doze/息屏连播、桌面歌词悬浮窗在模拟器上都不具备真实语义，仍需真机点一遍。
2. **样本只有两首**：覆盖了"酷狗赢"和"网易赢"两种路径，但没有覆盖"两通道都没对上"、以及方言/慢歌/纯音乐等长尾。
3. **`is_original` 的语义仍是推断**：来自两条实测样本（studio=1、live/综艺=4、翻唱=2）。若酷狗改字段含义，需要重新标定。

## 六、跑一遍

```powershell
cd D:\Projects\Private_music
pwsh -File .\tools\dev.ps1          # 构建 → 57 项静态验证 → 18 项冒烟 → 飞书
```
