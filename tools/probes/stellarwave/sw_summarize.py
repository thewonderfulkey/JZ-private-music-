"""把 sw_harness.js 的线材日志（每次真实 HTTP 往返）汇总成「端点健康表」。

判定口径：
  · 通     = 该 host 有 ≥1 次 2xx/3xx 响应
  · 半通   = 只有 4xx/5xx（服务在，但接口拒绝/上游挂）
  · 不通   = 全部 0（DNS/TCP/TLS 失败或超时）
并附上「它属于脚本里的哪个后端」，因为同一个 host 往往被多个后端复用。
"""
import glob
import json
import os
import statistics
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))

# host → 脚本里的后端名（一个 host 可能被多个后端复用）
BACKEND_OF = {
    "api.vkeys.cn": "落月QQ（v2 geturl / v3 song-link）、vkeys",
    "musicserver.haitangw.cc": "云记QQ/云记咪咕（resolve-url）、HelloWorld KW主API、海堂KG",
    "qt.haitangw.net": "云记QQ/云记咪咕（备用 host）",
    "103.79.184.97": "HYWmusic 全平台、白姬KG、咪咕 proxy",
    "106.55.0.102": "baimusic QQ",
    "175.27.166.236:8928": "酷我流媒体（atmos/master 专用）",
    "a.aa.cab": "HelloWorld QQ",
    "api.317ak.cn": "317ak QQ",
    "api.canxiang.cn": "残像 WY",
    "api.cenguigui.cn": "笒鬼鬼 WY",
    "api.xinghai.com": "星海聚合（酷我/酷狗/咪咕通用）",
    "api.ygking.cn": "ygking QQ",
    "api.yunmge.com": "yunmge 酷我",
    "app.c.nf.migu.cn": "Migu API",
    "c.wwwweb.top": "ikun 网易云、HelloWorld KW 备用API",
    "ffapi.cn": "FFAPI（全平台末位兜底）",
    "interface3.music.163.com": "网易云官方 eapi",
    "mcp.nianxinxz.com": "念心酷狗、长青海棠",
    "mobi.kuwo.cn": "酷我官方",
    "nmobi.kuwo.cn": "酷我手机版",
    "music.migu.cn": "Migu 直接源、FFAPI 页面",
    "music.nxinxz.com": "念心直链（tx/wy/kw）、念心KG",
    "u.y.qq.com": "QQ 官方 musicu.fcg",
    "wwwapi.kugou.com": "酷狗官方",
    "yy.zddyr.top": "星海主后端、星海KG/酷我/汽水、酷我 flac 跳板",
    "zrcdy.dpdns.org": "星海汽水备用线路",
    "isure.stream.qqmusic.qq.com": "（CDN，只作取流终点）",
}


def load_all():
    recs = []
    for f in glob.glob(os.path.join(HERE, "out", "report-*.json")):
        try:
            d = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        for phase in ("resolve", "stability"):
            for e in d.get(phase, []) or []:
                for w in e.get("wire", []) or []:
                    recs.append({"phase": phase, **w})
                if phase == "stability":
                    for r in e.get("runs", []):
                        pass
    return recs


def main():
    recs = load_all()
    agg = defaultdict(lambda: {"n": 0, "ok": 0, "errs": defaultdict(int), "ms": []})
    for r in recs:
        h = r.get("host") or "?"
        a = agg[h]
        a["n"] += 1
        st = r.get("status") or 0
        if 200 <= st < 400:
            a["ok"] += 1
        if r.get("err"):
            a["errs"][r["err"]] += 1
        elif st and not (200 <= st < 400):
            a["errs"][f"HTTP {st}"] += 1
        if r.get("ms"):
            a["ms"].append(r["ms"])

    rows = []
    for h, a in agg.items():
        if a["ok"] == 0 and not a["errs"]:
            verdict = "不通"
        elif a["ok"] == 0:
            verdict = "半通"
        elif a["ok"] < a["n"]:
            verdict = "不稳"
        else:
            verdict = "通"
        rows.append({
            "host": h, "verdict": verdict, "n": a["n"], "ok": a["ok"],
            "rate": round(100.0 * a["ok"] / a["n"], 0),
            "med": int(statistics.median(a["ms"])) if a["ms"] else 0,
            "max": max(a["ms"]) if a["ms"] else 0,
            "errs": dict(a["errs"]),
            "backend": BACKEND_OF.get(h, "—"),
        })

    order = {"通": 0, "不稳": 1, "半通": 2, "不通": 3}
    rows.sort(key=lambda r: (order[r["verdict"]], -r["n"]))

    print(f"{'判定':4s} {'成功率':>6s} {'次数':>4s} {'中位':>6s} {'最慢':>6s}  host / 后端")
    print("-" * 108)
    for r in rows:
        err = ("  " + ",".join(f"{k}×{v}" for k, v in list(r["errs"].items())[:2])) if r["errs"] else ""
        print(f'{r["verdict"]:4s} {str(r["rate"]) + "%":>6s} {r["n"]:>4d} {r["med"]:>5d}ms {r["max"]:>5d}ms  {r["host"]}' + err)
        print(f'{"":22s}   ↳ {r["backend"]}')

    tally = defaultdict(int)
    for r in rows:
        tally[r["verdict"]] += 1
    print("\n小结：", "、".join(f"{k} {v} 个 host" for k, v in tally.items()))
    json.dump(rows, open(os.path.join(HERE, "out", "endpoint-health.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)


if __name__ == "__main__":
    main()
