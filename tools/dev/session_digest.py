"""把这个项目所有历史会话（~/.dsh/sessions/--D-Projects-Private_music--/）读成一份「经验摘要」。

用途（老板 2026-11-20 明确要求）：修任何 bug 之前先读一遍，避免：
  · 把以前修好的 bug 又改回去（"修了一个 bug，又重复出现以前修过的 bug"）；
  · 丢掉以前确认过的口径与数字（阈值、断言语义、失败案例）。

产出：
  docs/dev/SESSION-LESSONS.md   —— 人读：每条会话一行 + 关键教训（按关键词抓）
  tools/dev/out/session-digest.json —— 机读：完整结构

用法：
  python tools/dev/session_digest.py            # 全量
  python tools/dev/session_digest.py --grep 播完  # 只看命中关键词的段落

过滤：注入的 system-reminder / 时间戳 / 后台任务通知不算"老板的话"。
"""
import argparse
import glob
import json
import os
import re
import sys
import time

import zstandard

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SESS_DIR = os.path.expanduser(r"~/.dsh/sessions/--D-Projects-Private_music--")
OUT_MD = os.path.join(ROOT, "docs", "dev", "SESSION-LESSONS.md")
OUT_JSON = os.path.join(ROOT, "tools", "dev", "out", "session-digest.json")

NOISE_PREFIX = ("Time sampled", "<system-reminder>", "<hindsight", "background job",
                "The available skill catalog", "<available_skills>")

# 「教训」关键词：以前踩过的坑、定死的口径、明确禁止的做法
LESSON_KEYS = (
    "不要再", "不能再", "千万别", "禁止", "根因", "真凶", "拍板", "口径", "必须",
    "教训", "代价", "上一轮", "以前", "退回", "回滚", "别再", "不能只", "假无损",
    "占位", "风控", "超时", "挂起", "卡住", "跳歌", "自动播放",
)


def text_of(msg):
    out = []
    for b in msg.get("content") or []:
        if b.get("type") == "text":
            out.append(b.get("text") or "")
    return "\n".join(out)


def is_noise(t: str) -> bool:
    return (not t.strip()) or t.lstrip().startswith(NOISE_PREFIX)


def load_session(path):
    with open(path, "rb") as f:
        raw = zstandard.ZstdDecompressor().stream_reader(f).read().decode("utf-8", "replace")
    evs = []
    for line in raw.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            evs.append(json.loads(line))
        except Exception:  # noqa: BLE001
            continue
    return evs


def digest_one(path):
    evs = load_session(path)
    sid, created, title = os.path.basename(os.path.dirname(path)), None, ""
    users, assistants, last_t = [], [], None
    for e in evs:
        t = e.get("type")
        if t == "session":
            sid = e.get("id") or sid
            try:
                created = int(e.get("createdAt")) / 1000
            except Exception:  # noqa: BLE001
                created = None
        elif t == "session/title":
            title = (e.get("data") or {}).get("title") or title
        elif t in ("user/message", "agent/inbox/spliced"):
            d = e.get("data") or {}
            for m in ([d.get("message")] if d.get("message") else (d.get("inserted") or [])):
                if not m or m.get("role") != "user":
                    continue
                txt = text_of(m)
                if not is_noise(txt):
                    users.append(txt.strip())
        elif t == "assistant/message":
            m = (e.get("data") or {}).get("message") or {}
            msg = {"role": "assistant", "content": m.get("content") or []}
            txt = text_of(msg).strip()
            if txt:
                assistants.append(txt)
        if e.get("time"):
            last_t = int(e["time"]) / 1000

    lessons = []
    for t in assistants:
        for line in t.splitlines():
            line = line.strip(" -·\t")
            if len(line) < 12 or len(line) > 220:
                continue
            if any(k in line for k in LESSON_KEYS):
                lessons.append(line)
    seen, uniq = set(), []
    for l in lessons:
        if l not in seen:
            seen.add(l)
            uniq.append(l)

    return {
        "sessionId": sid,
        "title": title,
        "started": time.strftime("%m-%d %H:%M", time.localtime(created)) if created else "",
        "ended": time.strftime("%m-%d %H:%M", time.localtime(last_t)) if last_t else "",
        "userMessages": len(users),
        "firstAsk": (users[0][:400] if users else ""),
        "lastSay": (assistants[-1][:900] if assistants else ""),
        "lessons": uniq[:40],
        "path": path,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--grep", help="只打印含该关键词的教训行")
    ap.add_argument("--limit", type=int, default=0, help="只取最近 N 个会话")
    a = ap.parse_args()

    paths = sorted(glob.glob(os.path.join(SESS_DIR, "session-*", "session.v4.jsonl.zstd")),
                   key=os.path.getmtime)
    if a.limit:
        paths = paths[-a.limit:]
    if not paths:
        print("没找到会话文件：", SESS_DIR)
        return 1

    rows = [digest_one(p) for p in paths]
    rows.sort(key=lambda r: r["started"])

    os.makedirs(os.path.dirname(OUT_JSON), exist_ok=True)
    os.makedirs(os.path.dirname(OUT_MD), exist_ok=True)
    json.dump(rows, open(OUT_JSON, "w", encoding="utf-8"), ensure_ascii=False, indent=2)

    lines = ["# 本项目的会话经验索引（自动生成，勿手改）",
             "",
             f"> 生成：`python tools/dev/session_digest.py` · 会话数 {len(rows)} · "
             f"{time.strftime('%Y-%m-%d %H:%M')}",
             "> 作用：修 bug 前先读一遍，避免重复踩坑 / 把修好的改回去。",
             ""]
    for r in rows:
        lines.append(f"## {r['started']} · {r['title'] or r['sessionId']}")
        lines.append(f"- Session：`{r['sessionId']}`（{r['started']} → {r['ended']}，"
                     f"{r['userMessages']} 条老板消息）")
        if r["firstAsk"]:
            lines.append("- 当时要什么：" + r["firstAsk"].replace("\n", " ")[:300])
        if r["lastSay"]:
            lines.append("- 最后结论：" + r["lastSay"].replace("\n", " ")[:500])
        if r["lessons"]:
            lines.append("- 留下的教训：")
            for l in r["lessons"][:12]:
                if a.grep and a.grep not in l:
                    continue
                lines.append(f"  - {l}")
        lines.append("")

    open(OUT_MD, "w", encoding="utf-8").write("\n".join(lines))

    print(f"会话 {len(rows)} 个 → {OUT_MD}")
    print(f"机读版 → {OUT_JSON}")
    if a.grep:
        print(f"\n=== 关键词「{a.grep}」命中 ===")
        for r in rows:
            for l in r["lessons"]:
                if a.grep in l:
                    print(f"[{r['sessionId'][:17]}] {l}")
    else:
        for r in rows:
            print(f"  {r['started']}  {r['sessionId'][:20]}  {r['title'][:28]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
