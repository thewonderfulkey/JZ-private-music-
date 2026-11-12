# 听歌识曲：链路、打分模型与调参方法

> 基准 v2.1.92。代码：`network/RecognizeAdapter.kt`（酷狗）、`network/NeteaseRecognizer.kt`（网易）、
> `network/NeteaseFingerprint.kt`（本地指纹引擎）、`network/RecognizeScore.kt`（打分/择优）、
> `data/VoiceCapture.kt`（采集）、`ui/App.kt#startRecognize`（编排）。

## 1. 为什么有两条通道

| 通道 | 端点 | 输入 | 元数据 | 强项 | 弱点 |
|---|---|---|---|---|---|
| 酷狗 | `gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit` | 8k 单声道 16bit 裸 PCM | 歌名/歌手/专辑/时长/`is_original` | 抗噪好、中文元数据、**带原唱标记** | 只回 5 条，且可能是翻唱/综艺版 |
| 网易 | `interface.music.163.com/api/music/audio/match` | 端上 afp 指纹（12s） | 歌名/歌手/专辑/时长/songId | 曲库中文原生元数据 | 只回 3 条，翻唱比例高，需 WebView 算指纹 |

两条通道的候选各有各的毛病，所以**不能按"谁先返回"决定结果**，必须按证据打分。

## 2. 一次识曲的完整时序（v2.1.92）

```
点麦克风
  ├─ 暂停本机播放（否则录到自己）
  ├─ VoiceCapture.record(seconds = max(设置档位, 12), partialAtSeconds = 0)
  │    · 音源 VOICE_RECOGNITION，失败退 MIC
  │    · 采样率 48k→32k→16k→8k 依次探测，多点平均降到 8k
  │    · 同时记录 peakRms（<0.004 判"几乎没听到声音"）
  ├─ RecPhase.THINK
  ├─ 并行：酷狗 recognize(cap.pcm)  ／ 网易 encode(raw 前 12s) → recognize(fp)
  ├─ 网易最多等 7s（withTimeoutOrNull），超时只当没结果
  ├─ RecognizeScore.fuse(酷狗候选, 网易候选)
  └─ 取第 1 名 → 结果卡；其余按分数列为"同批候选"
```

关键点：
- **不再有 6 秒提前收工**（v2.1.91 的做法）。代价是固定约 12 秒；换来的是网易始终参与比较。
- 网易指纹**只吃前 12 秒**：用户选 15/20 秒档时截断，避免指纹口径漂移。
- WebView 在识曲页 `1dp` 处预热（`NeteaseFingerprint.attach`），进页即编译 wasm，点麦克风时已就绪。

## 3. 打分模型

### 3.1 曲目身份（identity）

```
identityKey = norm(StudioPick.coreName(title)) + "|" + norm(firstArtist(artist))
```
- `coreName`：剥掉 `(feat. xxx)`、`【AI翻唱】`、`- Orchestra Ver. -` 这类括号与后缀
- `firstArtist`：`张杰、胡迪、范如臣` → `张杰`（多人合作版与独唱版归为同一位）
- `norm`：繁→简（`TradToSimpMap`）+ 小写 + 去标点空格

同一身份的候选（可能来自两条通道、不同专辑）合并后算"身份分"。

### 3.2 单条分 `memberScore`

| 项 | 分值 |
|---|---|
| `is_original == 1` | +45 |
| `is_original == 2` | −30 |
| `is_original == 4` | −8（v2.1.93） |
| 歌名裸名 | +12 |
| 歌名带版本说明 | −35 |
| 正式专辑 | +15 |
| 专辑名 == 歌名 | −20 |
| 现场/综艺/节目专辑 | −28 |
| 无专辑 | −8 |
| 时长可解析 | +4 |
| 通道内位次 | 0→+7, 1→+5, 2→+3, 3→+1, ≥4→0 |
| 来自网易 | +2 |

### 3.3 身份分

```
score = max(memberScore) 
      + 50  if 两条通道都命中该身份
      + 22  if 正式专辑 ≥ 2 张 且 这些候选时长极差 ≤ 3s
```

### 3.4 排序与展示

排序：`分数↓ → is_original(1 < 未知 < 2) → 标题长度↑ → 位次↑ → 酷狗优先`。
结果卡显示：`识别依据：酷狗 83 ／ 网易 38 → 采用酷狗`（缺通道显示 `—`，互证显示「双通道互证」）。

## 4. 已知边界

1. **打分只能"在给出的候选里选最好的"**，不能凭空造出原唱。如果两条通道都只回翻唱，结果仍是翻唱（例：《晴天》的网易侧真实响应只有王先森/雷米克斯/丹尼尔）。此时「其他版本」是兜底出口。
2. **`is_original` 的语义来自一条实测样本**（原唱=1、翻唱=2、无信息=0），酷狗无公开文档。若字段变化，损失的是这一维证据，其余维度仍生效。
3. **翻唱与原唱时长常常相同**（同一伴奏），所以时长只作"同歌手多专辑"的互证原料，不单独判好坏。
4. **识别结果到可播条目还有一段路**：识曲只给元数据，播放仍走 `SearchService` + `StudioPick`（`App.kt#playRecognizedHit`）。

## 5. 怎么验证与调参（不用真机）

打分是纯函数（`RecognizeScore` 不依赖 Android），所以可以在桌面侧同构复算：

```powershell
# 用真实/构造夹具跑一遍排序，看分数是否符合预期
python tools\probes\score_test.py

# 抓一份真实的酷狗指纹响应（需要 8k 单声道 16bit PCM）
python tools\probes\kugou_from_wav.py
```

`score_test.py` 里的夹具：
- A：酷狗 5 条真实候选（含 `is_original`）+ 网易 3 条真实翻唱 → 期望周杰伦
- B：酷狗翻唱 vs 网易原唱（张杰）→ 期望网易
- C/D：单通道；E：双通道互证；F：命中综艺版

改权重的原则：**先看夹具 A/B 是否仍然正确，再看排序是否被"同名合集"翻盘**。不要为了单个案例加特判。

## 6. 在模拟器里跑识曲（测试钩子，v2.1.93）

模拟器没有真实声源，所以留了一条**只在 smoke 变体**里的注入通道：

```powershell
# 1) 编冒烟包（与 release 同源同签，只多一个编译期开关）
pwsh -File tools\build.ps1 -Task assembleSmoke
# 2) 装 + 注入一段 12s/8k PCM
adb install -r android\app\build\outputs\apk\smoke\app-smoke.apk
adb shell am start -n com.jz.musichelper/.MainActivity --es jz_test_pcm qingtian_8k.pcm
# 3) 看结论（同时也会画在结果卡上）
adb logcat -d -s JZ_TEST
# RECOG fixture=qingtian_8k.pcm kg=5 ne=2 note=识别依据：酷狗 83 ／ 网易 40 → 采用酷狗 top=晴天/周杰伦/叶惠美/83
```

- 样本在 `android/app/src/smoke/assets/fixtures/`（只有 smoke 变体打进去），
  由 `tools/smoke/make_fixtures.py` 从妖狐酷我直链生成；
- `MainActivity` 里的调用被 `BuildConfig.RECOG_TEST_HOOK` 包着，release 包是 `false`（编译期常量），
  所以 `jz_test_pcm` 字符串、fixtures 资产都不会出现在正式包（`verify_2193.py` 会断言）；
- 注入走的是**同一条** `fuseRecognize`，不是另写一套逻辑，所以测出来的结论就是真机结论。

新增样本：把歌加进 `make_fixtures.py` 的 `SONGS`，重跑脚本，再拷到 `src/smoke/assets/fixtures/`。

## 7. 结果卡上的那行字是排查入口

真机上识别不对时，先看「识别依据」的两个分数：

| 现象 | 说明 |
|---|---|
| 酷狗 −27 / 网易 62 → 采用网易 | 符合预期（张杰场景） |
| 酷狗 83 / 网易 — | 网易通道没结果（WebView 没起来 / 网络 / 接口拒绝），看设置页或日志 |
| 两边都很低（< 20） | 两个通道都只给了翻唱/合集，属于曲库上限，用「其他版本」挑 |
| 酷狗 83 / 网易 79 | 同曲不同版，差距小，属正常竞争，看排序规则 |
