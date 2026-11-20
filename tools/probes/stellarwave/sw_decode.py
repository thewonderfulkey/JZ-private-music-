"""星澜聚合音源 StellarWave v4.0.2 —— 静态解析：解混淆 + 端点清单

脚本用 `_u(s)` 做了一层"字符 +5 位移"混淆（c.charCodeAt(0)+5），所有第三方后端
域名都被藏在这层里。本脚本把全文所有 `_u('...')` 字面量解出来，还原成可探测的
真实 URL 模板，并按 host 归类，供 sw_probe.py 做连通性测试。

用法： python sw_decode.py <音源.js> [-o inventory.json]
"""
import json
import re
import sys
from collections import OrderedDict

DEFAULT_SRC = (r"C:\Users\17948\xwechat_files\wxid_bx89f9gkjtbc22_26bf\temp\RWTemp"
               r"\2026-11\9e20f478899dc29eb19741386f9343c8\stellarwave音源（推荐）.js")

# JS 字面量里可能出现的转义；_u 的入参只有 \ 与引号需要还原
_ESC = {"n": "\n", "t": "\t", "r": "\r", "\\": "\\", "'": "'", '"': '"', "/": "/"}


def unescape_js(body: str) -> str:
    out, i = [], 0
    while i < len(body):
        c = body[i]
        if c == "\\" and i + 1 < len(body):
            nxt = body[i + 1]
            out.append(_ESC.get(nxt, nxt))
            i += 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def _u(s: str) -> str:
    """与脚本里的 _u 完全一致：每字符 +5"""
    return "".join(chr(ord(c) + 5) for c in s)


def main() -> int:
    args = sys.argv[1:]
    out_path = None
    if "-o" in args:
        i = args.index("-o")
        out_path = args[i + 1]
        args = args[:i] + args[i + 2:]
    src = args[0] if args else DEFAULT_SRC

    text = open(src, encoding="utf-8").read()

    # 抓 _u('...') / _u("...")，body 允许转义
    pat = re.compile(r"_u\(\s*(['\"])((?:\\.|(?!\1).)*)\1\s*\)")
    hits = []
    for m in pat.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        decoded = _u(unescape_js(m.group(2)))
        hits.append({"line": line, "raw": m.group(0), "decoded": decoded})

    # 明文 URL（未混淆的，如 haitangw / ffapi / 官方域名）
    plain = re.compile(r"https?://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]{4,}")
    plain_urls = OrderedDict()
    for m in plain.finditer(text):
        line = text.count("\n", 0, m.start()) + 1
        cur = plain_urls.setdefault(m.group(0), [])
        if line not in cur:
            cur.append(line)

    # 按 host 汇总（解混淆后的 + 明文的）
    hosts = OrderedDict()
    for h in hits:
        d = h["decoded"]
        m = re.match(r"https?://([^/?#]+)", d)
        if m:
            hosts.setdefault(m.group(1), {"sources": set(), "lines": [], "samples": []})
            hosts[m.group(1)]["lines"].append(h["line"])
            if len(hosts[m.group(1)]["samples"]) < 3:
                hosts[m.group(1)]["samples"].append(d[:160])
        else:
            hosts.setdefault("(非URL片段)", {"sources": set(), "lines": [], "samples": []})
            hosts["(非URL片段)"]["samples"] = hosts["(非URL片段)"]["samples"][:8]
            if len(hosts["(非URL片段)"]["samples"]) < 8:
                hosts["(非URL片段)"]["samples"].append(d[:120])
    for u, lines in plain_urls.items():
        m = re.match(r"https?://([^/?#]+)", u)
        if m:
            key = m.group(1)
            hosts.setdefault(key, {"sources": set(), "lines": [], "samples": []})
            hosts[key]["lines"].extend(lines)
            if len(hosts[key]["samples"]) < 3:
                hosts[key]["samples"].append(u[:160])

    inv = OrderedDict()
    for host, info in hosts.items():
        inv[host] = {
            "lines": sorted(set(info["lines"])),
            "samples": info["samples"],
        }

    print("=" * 78)
    print(f"源文件：{src}")
    print(f"_u() 解混淆字面量 {len(hits)} 条；明文 URL {len(plain_urls)} 条")
    print(f"独立 host/片段 {len(inv)} 个")
    print("=" * 78)

    urlish = {k: v for k, v in inv.items() if k != "(非URL片段)"}
    for host, info in sorted(urlish.items()):
        print(f"\n● {host}   (行 {','.join(map(str, info['lines'][:6]))}{'…' if len(info['lines']) > 6 else ''})")
        for s in info["samples"]:
            print(f"    {s}")

    if "(非URL片段)" in inv:
        print("\n● 非 URL 片段（音质/参数/拼接值）")
        for s in inv["(非URL片段)"]["samples"]:
            print(f"    {s!r}")

    if out_path:
        clean = OrderedDict()
        for host, info in urlish.items():
            clean[host] = {"lines": info["lines"], "samples": info["samples"]}
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(clean, f, ensure_ascii=False, indent=2)
        print(f"\n已写出 {out_path}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
