"""封面「脏图」普查：四个平台入口各抽一批歌，把封面拉下来，判断是不是盗版/包装图。

背景（2026-11-25 老板）：iOS 播放页出现过**盗版组的包装图**当封面（《断了的弦》那张
写着 `vmp65l3 5. ru,6xjp6 + 2ep JAY`）。老板要求先普查「大部分封面到底是不是脏的」，
再决定要不要废掉某个封面来源。

四个入口 = App 里真实会用到的那四条（见 `SearchAdapters.swift`）：
  QQ   → `https://y.gtimg.cn/music/photo_new/T002R300x300M000{albummid}.jpg`
  网易 → `api/song/detail` → `album.picUrl`（p1/p2.music.126.net）
  酷我 → 搜索 `MVPIC` → `https://img1.kuwo.cn/wmvpic/{MVPIC}`（曲图，不是专辑图）
  酷狗 → `trans_param.union_cover`（imge.kugou.com，{size}→500）

判「脏」的三类信号（任一命中算疑似，最后还要人眼看联系表复核）：
  A. 图上有**盗版/抓轨特征文字**：域名（.com/.net/.ru/.cn/www）、mp3/flac/320k、
     rip 组标记（vmp/wdma/vbr/scene/xxx 组名）、5 位以上「字母+数字」混合串
  B. 不是正方形（>6%）或边长 < 250（正常专辑图不会这样）
  C. ASCII 文字过多（≥10 个字符且无中文）——宣传图/版式图的典型形态

用法：
  python tools/probes/cover_census.py [--per-query 4] [--queries 文件名] [--no-ocr]
产出（`tools/probes/out/cover_census/`）：
  covers/<platform>/<n>.jpg     原始封面
  census.json                   每张图的全部指标
  summary.md                    按平台/域名的统计
  sheet_<platform>.jpg          联系表（带序号，人工复核用）
"""
import argparse
import json
import os
import re
import ssl
import time
import urllib.error
import urllib.parse
import urllib.request

UA = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                    "(KHTML, like Gecko) Version/17.0 Safari/605.1.15"}
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

ROOT = r"D:\Projects\Private_music"
OUT = os.path.join(ROOT, "tools", "probes", "out", "cover_census")
COVERS = os.path.join(OUT, "covers")

# 老板曲库里占大头的艺人（+ 他不止一首在测的两首）
DEFAULT_QUERIES = [
    "周杰伦", "黄霄雲", "林俊杰", "薛之谦", "邓紫棋", "陈奕迅",
    "李荣浩", "张学友", "王菲", "毛不易", "许嵩", "周传雄",
    "张韶涵", "汪苏泷", "宋冬野",
]

_last = {}


def _throttle(url, gap):
    host = urllib.parse.urlparse(url).netloc
    wait = gap - (time.time() - _last.get(host, 0))
    if wait > 0:
        time.sleep(wait)
    _last[host] = time.time()


def get(url, headers=None, timeout=12, gap=0.4):
    h = dict(UA)
    h.update(headers or {})
    _throttle(url, gap)
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=h),
                                    timeout=timeout, context=CTX) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read(2048)
    except Exception:  # noqa: BLE001
        return 0, b""


# ---------------------------------------------------------------- 取候选（四个入口）

def qq(limit):
    """QQ 官方搜索 → albummid → y.gtimg.cn 300×300"""
    return None, None  # 占位：见 candidates_qq


def candidates_qq(keyword, limit):
    url = ("https://c.y.qq.com/soso/fcgi-bin/client_search_cp?p=1&n=%d&w=%s&format=json"
           % (limit, urllib.parse.quote(keyword)))
    st, body = get(url, {"Referer": "https://y.qq.com/"})
    out = []
    try:
        data = json.loads(body.decode("utf-8", "replace"))
        for it in (((data.get("data") or {}).get("song") or {}).get("list") or []):
            am = it.get("albummid") or ""
            if not am or not it.get("songname"):
                continue
            out.append({"name": it.get("songname"), "album": it.get("albumname") or "",
                        "singer": "/".join(s.get("name", "") for s in (it.get("singer") or [])),
                        "pic": "https://y.gtimg.cn/music/photo_new/T002R300x300M000%s.jpg" % am})
    except Exception:  # noqa: BLE001
        pass
    return st, out


def candidates_netease(keyword, limit):
    url = ("https://music.163.com/api/search/get?s=%s&type=1&offset=0&limit=%d"
           % (urllib.parse.quote(keyword), limit))
    st, body = get(url, {"Referer": "https://music.163.com/"}, timeout=8)
    ids, meta = [], {}
    try:
        data = json.loads(body.decode("utf-8", "replace"))
        for it in (((data.get("result") or {}).get("songs")) or []):
            sid = it.get("id")
            if not sid:
                continue
            ids.append(str(sid))
            meta[str(sid)] = {
                "name": it.get("name") or "",
                "album": (it.get("album") or {}).get("name") or "",
                "singer": "/".join(a.get("name", "") for a in (it.get("artists") or [])),
            }
    except Exception:  # noqa: BLE001
        pass
    out = []
    if ids:
        url2 = "https://music.163.com/api/song/detail?ids=[%s]" % ",".join(ids)
        st2, body2 = get(url2, {"Referer": "https://music.163.com/"}, timeout=8)
        try:
            data = json.loads(body2.decode("utf-8", "replace"))
            for o in (data.get("songs") or []):
                sid = str(o.get("id"))
                pic = (o.get("album") or {}).get("picUrl") or ""
                m = meta.get(sid, {})
                if pic:
                    out.append({"name": m.get("name"), "album": m.get("album"),
                                "singer": m.get("singer"), "pic": pic})
        except Exception:  # noqa: BLE001
            pass
    return st, out


def candidates_kuwo(keyword, limit):
    url = ("https://search.kuwo.cn/r.s?all=%s&ft=music&rn=%d&pn=1&rformat=json&encoding=utf8"
           "&vipver=MUSIC_8.7.8.0_WX" % (urllib.parse.quote(keyword), limit))
    st, body = get(url, {"Referer": "https://www.kuwo.cn/"}, timeout=8)
    text = body.decode("utf-8", "replace")
    out = []
    # r.s 回的是 Python 风格单引号文本（键也带单引号：`'MVPIC':'…'`），只做最小解析。
    # 注意：键是 `'KEY'`，正则必须带那对引号，否则一条都匹配不到（2026-11-26 踩过）。
    for block in re.split(r"\{'", text):
        if "SONGNAME" not in block:
            continue

        def fld(k):
            m = re.search(r"'%s'\s*:\s*'([^']*)'" % k, block)
            return m.group(1) if m else ""

        mv = fld("MVPIC").strip("/")
        # App 搜索页用的就是 wmvpic（曲图）；没有曲图才退回专辑图 albumcover
        if mv:
            pic, src = "https://img1.kuwo.cn/wmvpic/" + mv, "wmvpic"
        else:
            short = fld("web_albumpic_short").strip("/")
            if not short:
                continue
            pic, src = "https://img1.kuwo.cn/star/albumcover/500/" + short, "albumcover"
        out.append({"name": fld("SONGNAME"), "album": fld("ALBUM"), "singer": fld("ARTIST"),
                    "pic": pic, "picFrom": src})
        if len(out) >= limit:
            break
    return st, out


def candidates_kugou(keyword, limit):
    url = ("https://mobiles.kugou.com/api/v3/search/song?format=json&keyword=%s&page=1"
           "&pagesize=%d&showtype=1" % (urllib.parse.quote(keyword), limit))
    st, body = get(url, {"Referer": "https://www.kugou.com/"}, timeout=10)
    out = []
    try:
        data = json.loads(body.decode("utf-8", "replace"))
        for it in (((data.get("data") or {}).get("info")) or []):
            union = ((it.get("trans_param") or {}).get("union_cover") or "")
            if not union:
                continue
            pic = union.replace("{size}", "500").replace("http://", "https://")
            out.append({"name": it.get("songname") or "", "album": it.get("album_name") or "",
                        "singer": it.get("singername") or "", "pic": pic})
    except Exception:  # noqa: BLE001
        pass
    return st, out


PLATFORMS = [
    ("qq", candidates_qq),
    ("netease", candidates_netease),
    ("kuwo", candidates_kuwo),
    ("kugou", candidates_kugou),
]

# ---------------------------------------------------------------- 判脏

DOMAIN_RE = re.compile(r"(\.(com|net|cn|ru|org|cc|tk|info)\b|www\.|https?://)", re.I)
RIP_RE = re.compile(r"\b(vmp|wdma|scene|rip|nfo|320k?|flac|mp3|vbr|cbr|hq|ape)\b", re.I)
MIXED_RE = re.compile(r"\b(?=[a-z0-9]*[a-z])(?=[a-z0-9]*\d)[a-z0-9]{5,}\b", re.I)
CJK = re.compile(r"[\u4e00-\u9fff]")


def ascii_text(ocr):
    return " ".join(ocr).strip()


def analyse(path, ocr_lines):
    from PIL import Image
    out = {"w": 0, "h": 0, "bytes": os.path.getsize(path), "flags": [], "ocr": ocr_lines}
    try:
        with Image.open(path) as im:
            out["w"], out["h"] = im.size
    except Exception:  # noqa: BLE001
        out["flags"].append("unreadable")
        return out
    w, h = out["w"], out["h"]
    if w and h:
        if abs(w - h) / max(w, h) > 0.06:
            out["flags"].append("non_square")
        if min(w, h) < 250:
            out["flags"].append("tiny")
    txt = ascii_text(ocr_lines)
    joined = " ".join(ocr_lines)
    if DOMAIN_RE.search(joined):
        out["flags"].append("domain")
    if RIP_RE.search(joined):
        out["flags"].append("rip_word")
    if MIXED_RE.search(joined):
        out["flags"].append("mixed_code")
    ascii_only = len(re.sub(r"[^ -~]", "", joined))
    if ascii_only >= 10 and not CJK.search(joined):
        out["flags"].append("ascii_heavy")
    return out


# ---------------------------------------------------------------- 联系表

def contact_sheet(platform, rows, cols=6, cell=210, label_h=26):
    from PIL import Image, ImageDraw
    rows_n = max(1, (len(rows) + cols - 1) // cols)
    sheet = Image.new("RGB", (cols * cell, rows_n * (cell + label_h)), (24, 24, 26))
    draw = ImageDraw.Draw(sheet)
    for i, r in enumerate(rows):
        x = (i % cols) * cell
        y = (i // cols) * (cell + label_h)
        try:
            with Image.open(r["file"]) as im:
                im = im.convert("RGB")
                im.thumbnail((cell - 6, cell - 6))
                sheet.paste(im, (x + 3 + (cell - 6 - im.width) // 2,
                                 y + 3 + (cell - 6 - im.height) // 2))
        except Exception:  # noqa: BLE001
            draw.rectangle([x + 3, y + 3, x + cell - 3, y + cell - 3], outline=(120, 40, 40))
        mark = "!" if r["flags"] else " "
        draw.text((x + 5, y + cell + 4),
                  "%s%02d %s" % (mark, r["idx"], (r["name"] or "")[:11]), fill=(210, 210, 210))
    p = os.path.join(OUT, "sheet_%s.jpg" % platform)
    sheet.save(p, quality=88)
    return p


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-query", type=int, default=4)
    ap.add_argument("--queries", default=None, help="每行一个关键词的文本文件")
    ap.add_argument("--no-ocr", action="store_true")
    a = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    queries = DEFAULT_QUERIES
    if a.queries and os.path.exists(a.queries):
        queries = [l.strip() for l in open(a.queries, encoding="utf-8") if l.strip()]

    ocr = None
    if not a.no_ocr:
        from rapidocr_onnxruntime import RapidOCR
        ocr = RapidOCR()

    all_rows = []
    for platform, fetch in PLATFORMS:
        d = os.path.join(COVERS, platform)
        os.makedirs(d, exist_ok=True)
        rows = []
        for q in queries:
            st, cands = fetch(q, a.per_query)
            print(f"[{platform}] {q}: HTTP {st} → {len(cands)} 条有图", flush=True)
            for c in cands[:a.per_query]:
                idx = len(rows) + 1
                fn = os.path.join(d, f"{idx:02d}.jpg")
                if not os.path.exists(fn) or os.path.getsize(fn) < 200:
                    st2, blob = get(c["pic"], {"Referer": "https://y.qq.com/"}, timeout=15)
                    if st2 != 200 or len(blob) < 200:
                        continue
                    open(fn, "wb").write(blob)
                lines = []
                if ocr is not None:
                    try:
                        res, _ = ocr(fn)
                        lines = [r[1] for r in (res or []) if float(r[2]) >= 0.5]
                    except Exception:  # noqa: BLE001
                        pass
                info = analyse(fn, lines)
                info.update({"platform": platform, "query": q, "name": c["name"],
                             "singer": c["singer"], "album": c["album"], "pic": c["pic"],
                             "host": urllib.parse.urlparse(c["pic"]).netloc,
                             "file": fn, "idx": idx})
                rows.append(info)
        all_rows.extend(rows)
        sheet = contact_sheet(platform, rows)
        print(f"[{platform}] {len(rows)} 张，联系表 → {sheet}", flush=True)

    json.dump(all_rows, open(os.path.join(OUT, "census.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=1)

    # 汇总
    lines = ["# 封面脏图普查", "",
             f"样本：{len(all_rows)} 张（每平台每关键词最多取若干），OCR={'关' if a.no_ocr else '开'}", ""]
    lines.append("| 平台 | 张数 | 非方 | 过小 | 有域名 | rip字样 | 混合串 | ASCII文字多 | 疑似脏(任一) |")
    lines.append("|---|---|---|---|---|---|---|---|---|")
    for platform, _ in PLATFORMS:
        rs = [r for r in all_rows if r["platform"] == platform]
        if not rs:
            continue
        c = lambda f: sum(1 for r in rs if f in r["flags"])  # noqa: E731
        dirty = sum(1 for r in rs if r["flags"])
        lines.append(f"| {platform} | {len(rs)} | {c('non_square')} | {c('tiny')} | "
                     f"{c('domain')} | {c('rip_word')} | {c('mixed_code')} | "
                     f"{c('ascii_heavy')} | **{dirty}（{dirty * 100 // max(1, len(rs))}%）** |")
    lines.append("")
    lines.append("## 命中明细（人眼复核用）")
    for r in all_rows:
        if r["flags"]:
            lines.append(f"- [{r['platform']}] {r['name']} / {r['singer']} · {r['w']}×{r['h']} · "
                         f"{','.join(r['flags'])} · `{r['host']}` · OCR: {' '.join(r['ocr'])[:60]}")
    open(os.path.join(OUT, "summary.md"), "w", encoding="utf-8").write("\n".join(lines) + "\n")
    print("\n".join(lines[:12]))
    print("→", OUT)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
