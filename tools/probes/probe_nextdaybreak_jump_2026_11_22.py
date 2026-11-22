# -*- coding: utf-8 -*-
"""《下一个天亮》(我的音乐调频, 酷狗 27e25b70…, 263s) 播放中串成别的歌 —— 取证脚本。

老板 2026-11-22 16:28 的录屏（`tools/notify/inbox/11-22_162842_1991421647.mov.mov`）里，
UI 一直写着《下一个天亮》，声音却在第 13 秒换成了另一首歌。

这个脚本做两件事，互相独立、都可单独跑：

  ① **身份闸复刻**：把 `NameMatch.sameRecording`（歌手 token 交集 + 时长 ≤4s + 版本类，
     歌名不做否决）用 Python 复刻一遍，喂进「下一个天亮 我的音乐调频」的真实搜索结果
     （酷我 search.kuwo.cn / 酷狗 mobiles.kugou.com），列出哪些候选能过闸。
     —— 结论：40 条候选里只有 2 条过闸，都是 **我的音乐调频名下的别的歌**
        （《怎么会狠心伤害我》263s、《简单爱》267s）；真正的《下一个天亮》其它版本
        （郭静 266 / 覆予 263 / 颜人中 250 …）全部被"歌手不同"挡掉。

  ② **录屏音频指认**：从录屏里抽音轨，取 8–12s / 13–29s 两段，跟
     - 正确的《下一个天亮》（酷狗 hash 27e25b70…，320k）
     - 嫌疑曲《怎么会狠心伤害我》（酷我 rid 347079287，320k）
     做 chroma（12 维音级）互相关，看每一段到底是哪一首、在第几秒。
     —— 结论：8–12s 是《下一个天亮》@0.0s（0.94）；13–29s 是《怎么会狠心伤害我》@4.5s（0.99）。

依赖：ffmpeg（本机 `C:\\Ultimate Vocal Remover\\ffmpeg.exe`，没有就设 FFMPEG 环境变量）。
用法：`python tools/probes/probe_nextdaybreak_jump_2026_11_22.py`
"""
import glob
import json
import os
import re
import ssl
import subprocess
import sys
import unicodedata
import urllib.parse
import urllib.request
import wave

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(ROOT, ".build", "probe_nextdaybreak")
UA = ("Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) "
      "Chrome/122.0 Mobile Safari/537.36")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE
FFMPEG = os.environ.get("FFMPEG") or r"C:\Ultimate Vocal Remover\ffmpeg.exe"

# 这首歌的身份（酷狗搜索「下一个天亮 我的音乐调频」第一条，与收藏列表 04:23 一致）
SRC = {"platform": "kugou", "id": "27e25b708496b41e85bfad358ace818c",
       "name": "下一个天亮", "singer": "我的音乐调频", "dur": 263}
SIBLING_RID = "347079287"          # 怎么会狠心伤害我 / 我的音乐调频 / 263s
SIBLING_NAME = "怎么会狠心伤害我 我的音乐调频"
# 录屏：默认取 inbox 里 16:28 那条
RECORDING = os.path.join(ROOT, "tools", "notify", "inbox", "11-22_162842_1991421647.mov.mov")


# ---------------------------------------------------------------- HTTP

def http(url, headers=None, timeout=30, read=None):
    h = {"User-Agent": UA}
    h.update(headers or {})
    req = urllib.request.Request(url, headers=h)
    with urllib.request.urlopen(req, timeout=timeout, context=CTX) as resp:
        return resp.read(read) if read else resp.read()


def fetch(url, headers=None, timeout=120):
    return http(url, headers, timeout)


# ---------------------------------------------------------------- 身份闸（NameMatch.sameRecording 复刻）

def norm_title(raw):
    s = unicodedata.normalize("NFC", raw.strip()).lower()
    s = re.sub(r"[\(（\[【][^\)）\]】]*[\)）\]】]", "", s)
    return re.sub(r"[^\w\u4e00-\u9fff]", "", s)


def title_matches(a, b):
    x, y = norm_title(a), norm_title(b)
    if not x or not y:
        return False
    if x == y:
        return True
    return abs(len(x) - len(y)) <= 6 and (x in y or y in x)


def singer_tokens(raw):
    s = unicodedata.normalize("NFC", raw.strip()).lower()
    s = re.sub(r"[\(（\[【][^\)）\]】]*[\)）\]】]", "", s)
    out = set()
    for part in re.split(r"[/&、,，;；\s]+", s):
        cleaned = re.sub(r"[^\w\u4e00-\u9fff]", "", part)
        if cleaned:
            out.add(cleaned)
    return out


def singer_matches(a, b):
    ta, tb = singer_tokens(a), singer_tokens(b)
    if not ta or not tb:
        return True                      # 任一方无歌手信息时不拦
    if ta & tb:
        return True
    sa, sb = "".join(sorted(ta)), "".join(sorted(tb))
    return sa in sb or sb in sa


_VAR_ASCII = (r"(?<![a-z0-9])(live|inst|instrumental|remix|dj|cover|ktv|karaoke|acoustic|unplugged)"
              r"(?![a-z0-9])")
_VAR_CJK = [("live", ["现场", "演唱会", "音乐会", "春晚", "晚会", "颁奖", "综艺"]),
            ("inst", ["伴奏", "消音", "纯音乐", "钢琴", "吉他", "古筝", "童声", "八音盒", "学唱"]),
            ("remix", ["电音", "咚鼓", "混音", "重制", "串烧"]),
            ("dj", ["dj版"]), ("cover", ["翻唱"]),
            ("clip", ["片段", "剪辑", "加速", "降速", "慢速"]),
            ("lang", ["粤语版", "国语版", "日语版", "韩语版", "英语版",
                      "男声版", "女声版", "男版", "女版"]),
            ("duet", ["合唱版", "对唱"])]


def version_class(title):
    s = title.strip().lower()
    out = set()
    for m in re.finditer(_VAR_ASCII, s):
        w = m.group(1)
        out.add("inst" if w == "instrumental" else w)
    for cls, words in _VAR_CJK:
        if any(w in s for w in words):
            out.add(cls)
    return out


def same_recording(src, cand):
    """→ (是否同一条录音, 一句话原因)。与 Swift `NameMatch.sameRecording` 一一对应。"""
    if src["platform"] == cand["platform"] and src["id"] == cand["id"]:
        return False, "同一 id"
    src_ver, cand_ver = version_class(src["name"]), version_class(cand["name"])
    if not cand_ver <= src_ver:
        return False, "①版本闸：候选多了版本类 %s" % sorted(cand_ver - src_ver)
    cand_singers, src_singers = singer_tokens(cand["singer"]), singer_tokens(src["singer"])
    if cand_singers:
        if not singer_matches(src["singer"], cand["singer"]):
            return False, "②歌手不同（%s ≠ %s）" % (src["singer"], cand["singer"])
    elif not src_singers:
        return title_matches(src["name"], cand["name"]), "④双方都没歌手 → 只看歌名"
    sd, cd = src["dur"], cand["dur"]
    if sd > 0 and cd > 0:
        if abs(sd - cd) > 4:
            return False, "③时长差 %ds > 4s" % abs(sd - cd)
        return True, "✅ 歌手同 + 时长差 %ds（歌名不做否决）" % abs(sd - cd)
    return title_matches(src["name"], cand["name"]), "④时长未知 → 只看歌名"


def looks_like_uploader(src, pool, min_distinct=3):
    """→ 这个「歌手」是不是频道号/上传者。与 Swift `NameMatch.looksLikeUploader` 一一对应。"""
    titles = set()
    for c in pool:
        if c["platform"] == src["platform"] and c["id"] == src["id"]:
            continue
        if not singer_matches(src["singer"], c["singer"]):
            continue
        if title_matches(src["name"], c["name"]):
            return False                     # 人家真有这首 → 是歌手本人
        key = norm_title(c["name"])
        if not key:
            continue
        titles.add(key)
        if len(titles) >= min_distinct:
            return True
    return False


# ---------------------------------------------------------------- 候选池（真实的四个平台搜索）

def search_kuwo(keyword, limit=20):
    url = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
           "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(keyword), limit))
    text = http(url, {"Referer": "https://www.kuwo.cn/"}).decode("utf-8", "ignore")
    out = []
    for blk in re.split(r"\},\{", text):
        d = dict(re.findall(r"'([A-Z_]+)':'([^']*)'", blk))
        if d.get("SONGNAME") and d.get("MUSICRID"):
            out.append({"platform": "kuwo",
                        "id": d["MUSICRID"].replace("MUSIC_", ""),
                        "name": d["SONGNAME"].replace("&nbsp;", " ").strip(),
                        "singer": d.get("ARTIST", "").replace("&nbsp;", " ").strip(),
                        "dur": int(d.get("DURATION") or 0)})
    return out


def search_kugou(keyword, limit=20):
    url = ("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s"
           "&page=1&pagesize=%d&showtype=1" % (urllib.parse.quote(keyword), limit))
    j = json.loads(http(url, {"Referer": "https://www.kugou.com/"}).decode("utf-8", "ignore"))
    out = []
    for it in (j.get("data") or {}).get("info") or []:
        out.append({"platform": "kugou", "id": it.get("hash"),
                    "name": it.get("songname"), "singer": it.get("singername") or "",
                    "dur": int(it.get("duration") or 0)})
    return out


# ---------------------------------------------------------------- 音频比对

def load_wav(path):
    if path.lower().endswith(".wav"):
        wav = path
    else:
        wav = os.path.splitext(path)[0] + ".wav"
        subprocess.run([FFMPEG, "-y", "-loglevel", "error", "-i", path,
                        "-ac", "1", "-ar", "22050", "-c:a", "pcm_s16le", wav], check=True)
    f = wave.open(wav)
    return f.getframerate(), np.frombuffer(
        f.readframes(f.getnframes()), dtype=np.int16).astype(np.float32) / 32768


def chroma(sr, samples, hop=0.5, nfft=4096):
    h = int(sr * hop)
    win = np.hanning(nfft)
    freqs = np.fft.rfftfreq(nfft, 1 / sr)
    midi = 69 + 12 * np.log2(np.maximum(freqs, 1) / 440.0)
    pitch = np.mod(np.round(midi).astype(int), 12)
    valid = (freqs > 80) & (freqs < 4000)
    frames = []
    for i in range(0, len(samples) - nfft, h):
        spec = np.abs(np.fft.rfft(samples[i:i + nfft] * win))
        vec = np.array([spec[valid & (pitch == k)].sum() for k in range(12)])
        n = np.linalg.norm(vec)
        frames.append(vec / n if n > 0 else vec)
    return np.array(frames)


def align(rec_chroma, t0, t1, ref_chroma):
    import numpy as np
    w = rec_chroma[int(t0 / 0.5):int(t1 / 0.5)]
    if len(w) == 0 or len(ref_chroma) < len(w):
        return 0.0, 0.0
    scores = np.array([float(np.mean(np.sum(w * ref_chroma[o:o + len(w)], axis=1)))
                       for o in range(0, len(ref_chroma) - len(w) + 1)])
    j = int(np.argmax(scores))
    return float(scores[j]), j * 0.5


def resolve_kw_320(rid, name_singer):
    url = ("https://yy.zddyr.top/lx/api/?source=kw&name=%s&id=%s&quality=320kmp3"
           % (urllib.parse.quote(name_singer), rid))
    j = json.loads(fetch(url, {"Referer": "https://www.kuwo.cn/"}).decode("utf-8", "ignore"))
    return j.get("url") if j.get("code") == 200 else None


def resolve_kg(hash_, quality="320k"):
    url = ("https://yy.zddyr.top/lx/api/?source=kg&quality=%s&mainHash=%s"
           % (quality, hash_.upper()))
    j = json.loads(fetch(url, {"Referer": "https://www.kugou.com/"}).decode("utf-8", "ignore"))
    return j.get("url") if j.get("code") == 200 else None


def save(url, path):
    if not url:
        return False
    data = fetch(url, {"Referer": "https://www.kugou.com/"})
    with open(path, "wb") as f:
        f.write(data)
    print("    ↓ %s (%d B, %d kbps @263s)" % (os.path.basename(path), len(data),
                                             int(len(data) * 8 / 1000 / 263)))
    return True


# ---------------------------------------------------------------- main

def main():
    os.makedirs(OUT, exist_ok=True)
    keyword = "%s %s" % (SRC["name"], SRC["singer"])
    print("=" * 96)
    print("① 身份闸复刻 —— 搜「%s」" % keyword)
    print("=" * 96)
    cands = []
    try:
        cands += search_kuwo(keyword)
    except Exception as e:                                  # noqa: BLE001
        print("  酷我搜索失败：%s" % e)
    try:
        cands += search_kugou(keyword)
    except Exception as e:                                  # noqa: BLE001
        print("  酷狗搜索失败：%s" % e)
    seen, pool = set(), []
    for c in cands:
        if not c["id"] or not c["name"]:
            continue
        k = (c["platform"], c["id"])
        if k in seen:
            continue
        seen.add(k)
        pool.append(c)
    passed = []
    for c in pool:
        ok, why = same_recording(SRC, c)
        print("%s %-30s | %-12s | %4ss | %-6s | %s"
              % ("PASS" if ok else "    ", c["name"][:30], c["singer"][:12],
                 c["dur"], c["platform"], why))
        if ok:
            passed.append(c)
    print("\n候选 %d 条，过闸 %d 条：%s\n"
          % (len(pool), len(passed),
             [(p["name"], p["singer"], p["dur"]) for p in passed]))

    # ---- v2.4.71 的新口径：歌手像"频道号/上传者"时，只认歌名一致 ----
    print("-" * 96)
    print("①b 新口径（v2.4.71：频道号/上传者只认歌名一致）")
    print("-" * 96)
    uploader = looks_like_uploader(SRC, pool)
    print("  looksLikeUploader = %s（名下挂了 ≥3 首互不相同、且一首都没对上源歌名的歌）" % uploader)
    kept = []
    for c in passed:
        ok = norm_title(SRC["name"]) == norm_title(c["name"])
        print("  %s %-30s | %-12s | %4ss | 歌名一致=%s"
              % ("仍然放行" if ok else "新口径挡掉", c["name"][:30], c["singer"][:12],
                 c["dur"], ok))
        if ok:
            kept.append(c)
    print("\n  → 新口径下可用候选 %d 条（旧口径 %d 条）；"
          "这 2 条串歌全部被挡，播放链会继续用酷狗自己的那条源。\n"
          % (len(kept), len(passed)))

    print("=" * 96)
    print("② 录屏音频指认")
    print("=" * 96)
    if not os.path.exists(RECORDING):
        print("  录屏不在：%s（跳过②）" % RECORDING)
        return
    refs = []
    for label, fn, url in [
            ("下一个天亮 / 我的音乐调频（酷狗 27e25b70…）", "nextday_kg_320k.mp3",
             lambda: resolve_kg(SRC["id"])),
            ("怎么会狠心伤害我 / 我的音乐调频（酷我 rid 347079287）", "howcan_kw_320k.mp3",
             lambda: resolve_kw_320(SIBLING_RID, SIBLING_NAME))]:
        p = os.path.join(OUT, fn)
        if not os.path.exists(p):
            if not save(url(), p):
                print("  取流失败，跳过：%s" % label)
                continue
        refs.append((label, p))
    if not refs:
        return
    sr, samples = load_wav(RECORDING)
    rec = chroma(sr, samples)
    print("  录屏长度 %.1fs\n" % (len(samples) / sr))
    print("  %-46s %-18s %-18s" % ("参考音源（320k）", "录屏 8–12s", "录屏 13–29s"))
    for label, p in refs:
        ref = chroma(*load_wav(p))
        a = align(rec, 8.0, 12.0, ref)
        b = align(rec, 13.0, 29.0, ref)
        print("  %-46s %.3f@%5.1fs      %.3f@%5.1fs" % (label, a[0], a[1], b[0], b[1]))
    print("\n  解读：8–12s 命中《下一个天亮》@0.0s（起播是对的）；"
          "13–29s 命中《怎么会狠心伤害我》@4.5s（≈换源前的进度），"
          "即『后台升档』把播放项换成了同一位上传者的另一首歌。")


if __name__ == "__main__":
    sys.exit(main())
