#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把一份 `诊断/trace.log` 算成三条丝滑红线的报表（R1 / R2 / R3）。

背景（2026-11-26 老板拍板）：丝滑优先级高于音质——
  R1 不许播一半重头播
  R2 不许明显卡顿（连续无声 >200ms）
  R3 必须能自动切歌，且切歌不能久等

这三条以前只能靠"感觉"。现在 App 会往 trace 里打三类新事件：
  · `item 替换` —— 每个 item 装进播放器的时刻，备注里带「本曲第 N 次」
  · `进度回退` —— 正在播的时候进度往回跳 >1s
  · `饥饿`     —— 播放器等字节、等了 ≥200ms
阈值与 App 里 `PlaybackTraceRules` 完全一致（那边有 CI 断言钉着）。

跑法：
    python tools/ios/analyze_trace.py 诊断/trace.log
    python tools/ios/analyze_trace.py 诊断/trace.log --json
    python tools/ios/analyze_trace.py --self-test      # 用内置样例自检解析器

一行格式（PlaybackTrace.line）：
    HH:mm:ss.SSS  前台  事件  备注
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta

try:
    sys.stdout.reconfigure(encoding="utf-8")
except Exception:  # noqa: BLE001
    pass

# 与 PlaybackTraceRules 同步（改了那边必须改这里，反之亦然）
STARVATION_SEC = 0.2
BACKWARD_JUMP_SEC = 1.0
SLOW_ADVANCE_SEC = 1.5
STUCK_ADVANCE_SEC = 10.0

LINE_RE = re.compile(r"^(\d{2}:\d{2}:\d{2}\.\d{3})\s+(\S+)\s+(.*)$")
REPLACE_RE = re.compile(r"^(?P<song>.+?)\s*←.*本曲第(?P<n>\d+)次\s*(?P<same>（同曲重装）)?\s*$")
HUNGRY_RE = re.compile(r"等了\s*(\d+)ms")
BACK_RE = re.compile(r"(\d+)s\s*→\s*(-?\d+)s")

# 事件名里带空格的不少（`item 替换` / `resolve 开始` / `seek 重跳`…），
# 先按已知前缀切，再退回"第一个词"。只列我们真正要算的，其余按首词归类。
KNOWN_STAGES = ("item 替换", "item ready", "进度回退", "饥饿", "didPlayToEnd", "play",
                "goTo", "resolve 开始", "resolve 结束", "resolve 丢弃", "起播阶段",
                "起播低档", "索引闸门", "缓存完成", "缓存补档", "时长头偏长",
                "下一首", "到点收尾", "后台任务", "预取", "预取命中", "预取失败")
RESOLVE_RE = re.compile(r"^(\d+)ms\s*")

# 这些事件说明「前一步刚失败过」——它之后的同曲重装是恢复，不是违规。
FAILURE_STAGES = ("源失败", "缓存文件坏", "缓存层回退", "同曲换源", "缓存续拉解析")
FAILURE_WINDOW_SEC = 10.0


@dataclass
class Entry:
    t: datetime
    state: str
    stage: str
    note: str


@dataclass
class Report:
    lines: int = 0
    states: dict = field(default_factory=dict)

    # R1
    replace_per_song: dict = field(default_factory=dict)   # song -> max N
    replace_events: int = 0
    backward_jumps: list = field(default_factory=list)
    reinstalls_recovered: list = field(default_factory=list)   # 前面有失败 → 恢复，可接受
    reinstalls_unexplained: list = field(default_factory=list)  # 没有失败 → R1 违规

    # R2
    starvations: list = field(default_factory=list)        # (state, ms, song, offset)

    # R3
    advances: list = field(default_factory=list)           # (state, gap, song_prev, song_next)
    stuck_without_next: int = 0
    ends: int = 0

    # 手动选歌 / 解析耗时（2026-11-26 诊断新增）
    manual_skips: list = field(default_factory=list)        # {gotoAt, latency, next}
    resolves: list = field(default_factory=list)            # {ms, backend, at}
    stages: list = field(default_factory=list)              # 起播阶段原始行


def parse(path: str) -> list[Entry]:
    out: list[Entry] = []
    day = datetime(2000, 1, 1)
    prev: datetime | None = None
    with open(path, encoding="utf-8", errors="ignore") as f:
        for raw in f:
            m = LINE_RE.match(raw.strip())
            if not m:
                continue
            hh, mm, rest = m.group(1).split(":")
            ss, ms = rest.split(".")
            t = day.replace(hour=int(hh), minute=int(mm), second=int(ss),
                            microsecond=int(ms) * 1000)
            # 跨午夜：时间往回跳超过 12 小时就认为进了第二天
            if prev and (prev - t) > timedelta(hours=12):
                day += timedelta(days=1)
                t += timedelta(days=1)
            prev = t
            rest = (m.group(3) or "").strip()
            stage, note = rest, ""
            for known in KNOWN_STAGES:
                if rest == known or rest.startswith(known + " "):
                    stage, note = known, rest[len(known):].strip()
                    break
            else:
                if " " in rest:
                    first, tail = rest.split(" ", 1)
                    stage, note = first, tail.strip()
            out.append(Entry(t=t, state=m.group(2), stage=stage, note=note))
    return out


def analyze(entries: list[Entry]) -> Report:
    rep = Report(lines=len(entries))
    pending_end: Entry | None = None
    pending_goto: Entry | None = None
    last_failure: Entry | None = None

    for e in entries:
        rep.states[e.state] = rep.states.get(e.state, 0) + 1

        if e.stage in FAILURE_STAGES:
            last_failure = e

        if e.stage == "item 替换":
            rep.replace_events += 1
            m = REPLACE_RE.match(e.note)
            if m:
                song, n = m.group("song").strip(), int(m.group("n"))
                rep.replace_per_song[song] = max(rep.replace_per_song.get(song, 0), n)
                if n > 1:
                    recent = (last_failure is not None
                              and (e.t - last_failure.t).total_seconds() <= FAILURE_WINDOW_SEC)
                    item = f"{song}×{n}（{e.t.strftime('%H:%M:%S')}）"
                    if recent:
                        rep.reinstalls_recovered.append(item)
                    else:
                        rep.reinstalls_unexplained.append(item)

        elif e.stage == "进度回退":
            m = BACK_RE.search(e.note)
            rep.backward_jumps.append({
                "state": e.state, "at": e.t.strftime("%H:%M:%S"),
                "song": e.note.split(" ")[0],
                "from": int(m.group(1)) if m else None,
                "to": int(m.group(2)) if m else None,
            })

        elif e.stage == "饥饿":
            m = HUNGRY_RE.search(e.note)
            ms = int(m.group(1)) if m else 0
            rep.starvations.append({"state": e.state, "at": e.t.strftime("%H:%M:%S"),
                                    "ms": ms, "note": e.note})

        elif e.stage == "resolve 结束":
            m = RESOLVE_RE.match(e.note)
            if m:
                backend = e.note[m.end():].strip()
                rep.resolves.append({"ms": int(m.group(1)), "backend": backend,
                                     "at": e.t.strftime("%H:%M:%S")})

        elif e.stage == "goTo":
            if "pauseFirst=true" in e.note:
                pending_goto = e

        elif e.stage == "didPlayToEnd":
            rep.ends += 1
            pending_end = e

        elif e.stage == "item ready":
            if pending_end is not None:
                gap = (e.t - pending_end.t).total_seconds()
                rep.advances.append({"state": e.state, "gap": round(gap, 3),
                                     "endAt": pending_end.t.strftime("%H:%M:%S"),
                                     "next": e.note.rsplit(" ", 1)[0][:40]})
                pending_end = None
            if pending_goto is not None:
                latency = (e.t - pending_goto.t).total_seconds()
                rep.manual_skips.append({"at": pending_goto.t.strftime("%H:%M:%S"),
                                         "latency": round(latency, 3),
                                         "next": e.note.rsplit(" ", 1)[0][:40]})
                pending_goto = None

    if pending_end is not None:
        rep.stuck_without_next += 1
    return rep


def advance_kind(gap: float) -> str:
    if gap >= STUCK_ADVANCE_SEC:
        return "卡住"
    if gap > SLOW_ADVANCE_SEC:
        return "慢"
    return "正常"


def pct(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    s = sorted(vals)
    k = min(len(s) - 1, max(0, int(round((len(s) - 1) * p))))
    return s[k]


def render(rep: Report) -> tuple[str, dict]:
    multi = {k: v for k, v in rep.replace_per_song.items() if v > 1}
    gaps = [a["gap"] for a in rep.advances]
    kinds = {"正常": 0, "慢": 0, "卡住": 0}
    for g in gaps:
        kinds[advance_kind(g)] += 1
    starv = [s["ms"] for s in rep.starvations]
    skips = [m["latency"] for m in rep.manual_skips]
    rms = [r["ms"] for r in rep.resolves]

    summary = {
        "lines": rep.lines,
        "states": rep.states,
        "R1": {
            "songsPlayed": len(rep.replace_per_song),
            "songsReplacedMoreThanOnce": multi,
            "reinstallsRecovered": rep.reinstalls_recovered,
            "reinstallsUnexplained": rep.reinstalls_unexplained,
            "backwardJumps": len(rep.backward_jumps),
            "pass": not rep.reinstalls_unexplained and not rep.backward_jumps,
        },
        "R2": {
            "starvations": len(rep.starvations),
            "maxMs": max(starv) if starv else 0,
            "totalMs": sum(starv),
            "pass": len(rep.starvations) == 0,
        },
        "R3": {
            "trackEnds": rep.ends,
            "advancesMeasured": len(gaps),
            "p50": round(pct(gaps, 0.5), 3),
            "p90": round(pct(gaps, 0.9), 3),
            "max": round(max(gaps), 3) if gaps else 0,
            "kinds": kinds,
            "noNextTrack": rep.stuck_without_next,
            "pass": rep.stuck_without_next == 0 and kinds["卡住"] == 0,
        },
        "manualSkip": {
            "n": len(skips),
            "p50": round(pct(skips, 0.5), 3),
            "p90": round(pct(skips, 0.9), 3),
            "max": round(max(skips), 3) if skips else 0,
            "pass": (not skips) or pct(skips, 0.5) <= SLOW_ADVANCE_SEC,
        },
        "resolve": {
            "n": len(rms),
            "p50": round(pct(rms, 0.5) / 1000, 2),
            "p90": round(pct(rms, 0.9) / 1000, 2),
            "max": round(max(rms) / 1000, 2) if rms else 0,
        },
    }

    def mark(ok: bool) -> str:
        return "✅" if ok else "❌"

    lines = [
        "## 丝滑红线报表（trace.log）",
        "",
        f"共 {rep.lines} 行；状态分布：" + "、".join(f"{k} {v}" for k, v in rep.states.items()),
        "",
        "| 红线 | 指标 | 实测 | 判定 |",
        "|---|---|---|---|",
        f"| R1 不许重头播 | 播过 {len(rep.replace_per_song)} 首；同曲重装 "
        f"{len(rep.reinstalls_recovered) + len(rep.reinstalls_unexplained)} 次"
        f"（失败恢复 {len(rep.reinstalls_recovered)} / 无理由 {len(rep.reinstalls_unexplained)}） | "
        f"{('无理由：' + '、'.join(rep.reinstalls_unexplained[:3])) if rep.reinstalls_unexplained else '—'} | "
        f"{mark(not rep.reinstalls_unexplained)} |",
        f"| R1 不许重头播 | 进度回退事件 | {len(rep.backward_jumps)} 次 | "
        f"{mark(not rep.backward_jumps)} |",
        f"| R2 不许卡顿 | 饥饿（≥{int(STARVATION_SEC*1000)}ms） | {len(rep.starvations)} 次，"
        f"最长 {max(starv) if starv else 0}ms，合计 {sum(starv)}ms | "
        f"{mark(not rep.starvations)} |",
        f"| R3 自动切歌 | 播完 {rep.ends} 首，测到 {len(gaps)} 次切歌 | "
        f"P50 {pct(gaps,0.5):.2f}s / P90 {pct(gaps,0.9):.2f}s / 最长 "
        f"{max(gaps) if gaps else 0:.2f}s | {mark(kinds['卡住'] == 0 and rep.stuck_without_next == 0)} |",
        f"| R3 不许久等 | 正常 {kinds['正常']} / 慢 {kinds['慢']} / 卡住 {kinds['卡住']} | "
        f"没有下一首 {rep.stuck_without_next} 次 | "
        f"{mark(kinds['卡住'] == 0 and rep.stuck_without_next == 0)} |",
        f"| 手动选歌 | {len(skips)} 次点击到出声 | P50 {pct(skips,0.5):.2f}s / "
        f"P90 {pct(skips,0.9):.2f}s / 最长 {(max(skips) if skips else 0):.2f}s | "
        f"{mark((pct(skips,0.5) <= SLOW_ADVANCE_SEC) if skips else True)} |",
        f"| 解析耗时 | {len(rms)} 次 resolve | P50 {pct(rms,0.5)/1000:.1f}s / "
        f"P90 {pct(rms,0.9)/1000:.1f}s / 最长 {(max(rms)/1000 if rms else 0):.1f}s | — |",
    ]

    if multi:
        lines += ["", "**R1 同曲多次装载明细**"]
        lines += [f"- {k}：装了 {v} 次" for k, v in multi.items()]
    if rep.reinstalls_recovered:
        lines += ["", "**R1 失败恢复（可接受，但会闪一下）**"]
        lines += [f"- {x}" for x in rep.reinstalls_recovered[:10]]
    if rep.backward_jumps:
        lines += ["", "**R1 进度回退明细**"]
        lines += [f"- {b['at']} {b['state']} {b['song']} {b['from']}s → {b['to']}s"
                  for b in rep.backward_jumps[:20]]
    if rep.starvations:
        lines += ["", "**R2 饥饿明细**"]
        lines += [f"- {s['at']} {s['state']} {s['ms']}ms {s['note'][:60]}"
                  for s in rep.starvations[:20]]
    if gaps:
        worst = sorted(rep.advances, key=lambda a: -a["gap"])[:5]
        lines += ["", "**R3 最慢的 5 次切歌**"]
        lines += [f"- {a['endAt']} 结束 → 下一首 `{a['next']}`：{a['gap']}s（{advance_kind(a['gap'])}）"
                  for a in worst]
    if skips:
        lines += ["", "**手动选歌最慢的 5 次（点击 → 出声）**"]
        for m in sorted(rep.manual_skips, key=lambda x: -x["latency"])[:5]:
            lines.append(f"- {m['at']} `{m['next']}`：{m['latency']}s")
    if rms:
        lines += ["", "**解析最慢的 5 次**"]
        for r in sorted(rep.resolves, key=lambda x: -x["ms"])[:5]:
            lines.append(f"- {r['at']} {r['ms'] / 1000:.1f}s ← {r['backend'][:40]}")
    return "\n".join(lines), summary


SELF_TEST_LOG = """\
10:00:00.000  前台  play  晴天 ← 落月 QQ MP3 320kbps
10:00:00.010  前台  item 替换  晴天 ← 落月 QQ MP3 320kbps 本曲第1次
10:00:00.120  前台  item ready  晴天 269s
10:00:03.000  前台  饥饿  晴天 等了 350ms @524288B
10:04:29.000  前台  didPlayToEnd  index=0/20 mode=列表循环
10:04:29.400  前台  item 替换  七里香 ← cyapi QQ M4A 97kbps 本曲第1次
10:04:29.500  前台  play  七里香 ← cyapi QQ M4A 97kbps
10:04:29.600  前台  item ready  七里香 299s
10:05:10.000  前台  进度回退  七里香 100s → 12s
10:05:12.000  前台  饥饿  七里香 等了 1200ms @900000B
10:09:00.000  前台  didPlayToEnd  index=1/20 mode=列表循环
10:09:14.000  前台  item 替换  稻香 ← 星海酷狗 MP3 320kbps 本曲第1次
10:09:14.100  前台  play  稻香 ← 星海酷狗 MP3 320kbps
10:09:14.200  前台  item ready  稻香 223s
10:09:20.000  前台  item 替换  稻香 ← 星海酷狗 MP3 320kbps 本曲第2次（同曲重装）
10:10:00.000  前台  goTo  →5/20 pauseFirst=true
10:10:02.900  前台  resolve 结束  2900ms gdstudio 网易 320kbps
10:10:03.000  前台  item ready  某歌 200s
10:13:00.000  前台  didPlayToEnd  index=2/20 mode=列表循环
"""


def self_test() -> int:
    entries = parse_text(SELF_TEST_LOG)
    rep = analyze(entries)
    text, summary = render(rep)
    ok = (
        rep.reinstalls_unexplained == ["稻香×2（10:09:20）"]
        and not rep.reinstalls_recovered
        and summary["R1"]["backwardJumps"] == 1
        and summary["R2"]["starvations"] == 2
        and summary["R2"]["maxMs"] == 1200
        and summary["R3"]["advancesMeasured"] == 2
        and summary["R3"]["kinds"]["卡住"] == 1        # 14.0s 那次
        and summary["R3"]["noNextTrack"] == 1
        and summary["manualSkip"]["n"] == 1
        and abs(summary["manualSkip"]["max"] - 3.0) < 0.01
        and summary["resolve"]["n"] == 1
        and abs(summary["resolve"]["max"] - 2.9) < 0.01
    )
    print(text)
    print("\n自检：", "通过" if ok else "失败", json.dumps(summary["R3"], ensure_ascii=False))
    return 0 if ok else 1


def parse_text(text: str) -> list[Entry]:
    tmp = "_selftest_trace.log"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        return parse(tmp)
    finally:
        try:
            import os
            os.remove(tmp)
        except OSError:
            pass


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("path", nargs="?", default="", help="trace.log 路径")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    args = ap.parse_args()
    if args.self_test or not args.path:
        return self_test()
    rep = analyze(parse(args.path))
    text, summary = render(rep)
    print(text)
    if args.json:
        print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if (summary["R1"]["pass"] and summary["R2"]["pass"] and summary["R3"]["pass"]) else 2


if __name__ == "__main__":
    sys.exit(main())
