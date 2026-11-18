# -*- coding: utf-8 -*-
"""第三十二轮动效预演：识曲舞台 6 拍 + 底部栏 3 态（浏览器直接打开）。

数值全部从 `ios/JZMusicHelper/Services/RecognizeMotion.swift` 抄过来（同一批常量），
改手感时先改这里看画面，再同步回 Swift——两边对不上就是 bug。
只做视觉预览，不进 App。
"""
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

# ---- 与 RecognizeMotion.swift 同步的常量 ----
CORE = 136
HALO = 160
COUNTDOWN = 204
STAGE_H = 236
RIPPLE_COUNT = 3
RIPPLE_CYCLE = 1.5
RIPPLE_STAGGER = 0.42
RIPPLE_MAX = 1.55
RIPPLE_PEAK = 0.32
BAR_COUNT = 24
BAR_BASE = 3
BAR_MAX = 15
BAR_RADIUS = 80
BAR_PEAK = 0.75
SCAN_CYCLE = 1.1
BURST_MAX = 1.55

VERM = "#B03A2E"
PAPER = "#FAF8F3"
PAPER_EL = "#FFFDF8"
INK = "#1A1A1A"
SECOND = "#6B675E"
TERT = "#9A958A"


def clamp01(x):
    return min(max(x, 0.0), 1.0)


def ripple_progress(t, index):
    t = (t - index * RIPPLE_STAGGER) % RIPPLE_CYCLE
    return clamp01(t / RIPPLE_CYCLE)


def bar_length(index, level, t):
    phase = index * 0.73 + t * 2.3
    wobble = 0.55 + 0.45 * abs(math.sin(phase))
    return BAR_BASE + (BAR_MAX - BAR_BASE) * clamp01(level) * wobble


# ---- SVG 图标 ----
def icon_mic(filled=True):
    fill = INK if filled else "none"
    stroke = "none" if filled else INK
    return f'''<g transform="translate(118 118)">
      <rect x="-7" y="-18" width="14" height="23" rx="7" fill="{fill}" stroke="{stroke}" stroke-width="2"/>
      <path d="M-13 1a13 13 0 0 0 26 0" fill="none" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>
      <line x1="0" y1="14" x2="0" y2="20" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>
      <line x1="-8" y1="20" x2="8" y2="20" stroke="{INK}" stroke-width="2" stroke-linecap="round"/>
    </g>'''


def icon_stop():
    return f'''<g transform="translate(118 118)"><rect x="-12" y="-12" width="24" height="24" rx="6" fill="{VERM}"/></g>'''


def icon_waveform(color=VERM):
    heights = [10, 20, 28, 18, 12]
    parts = [f'<g transform="translate(118 118)">']
    for i, h in enumerate(heights):
        x = -18 + i * 9
        parts.append(f'<rect x="{x - 1.5}" y="{-h/2}" width="3" height="{h}" rx="1.5" fill="{color}"/>')
    parts.append("</g>")
    return "".join(parts)


def icon_check():
    return f'''<g transform="translate(118 118)"><path d="M-13 1 L-4 10 L14 -9" fill="none" stroke="{VERM}" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></g>'''


def icon_slash(base):
    return base + f'''<g transform="translate(118 118)"><line x1="-18" y1="18" x2="18" y2="-18" stroke="{SECOND}" stroke-width="3" stroke-linecap="round"/></g>'''


def stage_svg(state, t=0.0, level=0.0):
    c = 118
    parts = [f'<svg class="stage-svg" viewBox="0 0 236 236" width="236" height="236">']
    halo_op = 0.05
    if state in ("listening",):
        halo_op = 0.10
    elif state in ("recognizing", "result"):
        halo_op = 0.10 if state == "result" else 0.08
    halo_r = HALO / 2 * (1.0 + (0.06 * level if state == "listening" else 0.0))
    parts.append(f'<circle cx="{c}" cy="{c}" r="{halo_r:.1f}" fill="{VERM}" opacity="{halo_op}"/>')

    if state == "listening":
        for i in range(BAR_COUNT):
            length = bar_length(i, level, t)
            angle = i * 360 / BAR_COUNT
            y = -(BAR_RADIUS + length / 2)
            op = BAR_PEAK * (0.45 + 0.55 * clamp01(level))
            parts.append(
                f'<rect x="{c-1.5:.1f}" y="{c+y-length/2:.1f}" width="3" height="{length:.1f}" rx="1.5" '
                f'fill="{VERM}" opacity="{op:.3f}" transform="rotate({angle:.3f} {c} {c})"/>'
            )
        for i in range(RIPPLE_COUNT):
            p = ripple_progress(t, i)
            r = CORE / 2 * (1 + (RIPPLE_MAX - 1) * p)
            op = RIPPLE_PEAK * (1 - p)
            parts.append(f'<circle cx="{c}" cy="{c}" r="{r:.1f}" fill="none" stroke="{VERM}" stroke-width="2" opacity="{op:.3f}"/>')
        # 倒计时环
        circ = 2 * math.pi * (COUNTDOWN / 2)
        p = 0.38
        parts.append(f'<circle cx="{c}" cy="{c}" r="{COUNTDOWN/2}" fill="none" stroke="rgba(0,0,0,.07)" stroke-width="2"/>')
        parts.append(
            f'<circle cx="{c}" cy="{c}" r="{COUNTDOWN/2}" fill="none" stroke="{VERM}" stroke-width="2" '
            f'stroke-linecap="round" stroke-dasharray="{circ*p:.2f} {circ:.2f}" transform="rotate(-90 {c} {c})"/>'
        )
        parts.append(icon_stop())
    elif state == "recognizing":
        circ = 2 * math.pi * (COUNTDOWN / 2)
        p = 0.22
        parts.append(f'<circle cx="{c}" cy="{c}" r="{COUNTDOWN/2}" fill="none" stroke="{VERM}" opacity=".10" stroke-width="2"/>')
        parts.append(
            f'<circle cx="{c}" cy="{c}" r="{COUNTDOWN/2}" fill="none" stroke="{VERM}" stroke-width="2.5" '
            f'stroke-linecap="round" stroke-dasharray="{circ*0.18:.2f} {circ:.2f}" '
            f'transform="rotate({-90 + p*360:.1f} {c} {c})"/>'
        )
        parts.append(icon_waveform())
    elif state == "result":
        parts.append(f'<circle cx="{c}" cy="{c}" r="{CORE/2*1.35:.1f}" fill="none" stroke="{VERM}" stroke-width="2" opacity=".22"/>')
        parts.append(icon_check())
    elif state == "nomatch":
        parts.append(icon_slash(icon_waveform(color=SECOND)))
    elif state == "failed":
        parts.append(icon_slash(icon_mic(filled=False)))
    else:
        parts.append(icon_mic(filled=True))

    stroke = "rgba(0,0,0,.08)" if state != "listening" else "rgba(0,0,0,.08)"
    parts.append(f'<circle cx="{c}" cy="{c}" r="{CORE/2}" fill="{PAPER_EL}" stroke="{stroke}" stroke-width="1"/>')
    # 中心图标再盖一次（在底盘之上）
    if state == "idle":
        parts.append(icon_mic(filled=True))
    elif state == "listening":
        parts.append(icon_stop())
    elif state == "recognizing":
        parts.append(icon_waveform())
    elif state == "result":
        parts.append(icon_check())
    elif state == "nomatch":
        parts.append(icon_slash(icon_waveform(color=SECOND)))
    elif state == "failed":
        parts.append(icon_slash(icon_mic(filled=False)))
    parts.append("</svg>")
    return "".join(parts)


# ---- 底栏图标 ----
def bar_icon(tab, color):
    if tab == "discover":
        path = "M4 11.2 L11 4.5 L18 11.2 V19 H4 Z"
        return f'<path d="{path}" fill="none" stroke="{color}" stroke-width="1.9" stroke-linejoin="round"/>'
    if tab == "favorites":
        path = "M11 18.3 C4.8 14.2 3.2 10.8 5.4 8.3 C7.1 6.4 9.6 6.9 11 8.9 C12.4 6.9 14.9 6.4 16.6 8.3 C18.8 10.8 17.2 14.2 11 18.3 Z"
        return f'<path d="{path}" fill="none" stroke="{color}" stroke-width="1.9" stroke-linejoin="round"/>'
    if tab == "recognize":
        out = []
        for i, h in enumerate([7, 14, 20, 13, 8]):
            out.append(f'<rect x="{2 + i*4}" y="{11-h/2}" width="2.4" height="{h}" rx="1.2" fill="{color}"/>')
        return "".join(out)
    if tab == "downloads":
        return (f'<circle cx="11" cy="11" r="8.2" fill="none" stroke="{color}" stroke-width="1.8"/>'
                f'<path d="M11 6.8 V14 M8.2 11.4 L11 14.2 L13.8 11.4" fill="none" stroke="{color}" '
                f'stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/>')
    # settings
    out = [f'<circle cx="11" cy="11" r="3.1" fill="none" stroke="{color}" stroke-width="1.8"/>']
    for i in range(8):
        a = i * math.pi / 4
        x1, y1 = 11 + math.cos(a) * 6.1, 11 + math.sin(a) * 6.1
        x2, y2 = 11 + math.cos(a) * 8.2, 11 + math.sin(a) * 8.2
        out.append(f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" stroke="{color}" stroke-width="1.8" stroke-linecap="round"/>')
    return "".join(out)


BAR_TABS = [("discover", "发现"), ("favorites", "收藏"), ("recognize", "识曲"),
            ("downloads", "下载"), ("settings", "设置")]


def tabbar(selected="recognize", badge=0):
    items = []
    for key, label in BAR_TABS:
        active = key == selected
        color = VERM if active else SECOND
        icon = f'<svg width="22" height="22" viewBox="0 0 22 22">{bar_icon(key, color)}</svg>'
        badge_html = ""
        if key == "downloads" and badge:
            badge_html = f'<span class="badge">{badge}</span>'
        if active:
            items.append(f'''<div class="tab active"><div class="pill">{icon}{badge_html}<span class="tab-label">{label}</span></div></div>''')
        else:
            items.append(f'''<div class="tab">{icon}{badge_html}</div>''')
    return f'<div class="tabbar">{"".join(items)}</div>'


def phone(state, caption_title, caption_detail, selected="recognize", result=False, badge=0,
          t=0.0, level=0.0):
    card = ""
    if result:
        card = f'''<div class="result-card">
          <div class="art"></div>
          <div class="result-meta"><div class="result-title">富士山下</div><div class="result-artist">陈奕迅</div><div class="result-album">What's Going On...?</div></div>
          <div class="play-btn">▶</div>
        </div>'''
    return f'''<div class="phone">
      <div class="status"><span>9:41</span><span class="status-icons">▮▮▮ ⌁ ▰</span></div>
      <div class="nav"><h1>识曲</h1><div class="listen-pill">听 12 秒 ⌄</div></div>
      <div class="stage">{stage_svg(state, t, level)}</div>
      <div class="caption"><div class="caption-title">{caption_title}</div><div class="caption-detail">{caption_detail}</div></div>
      {card}
      <div class="flex1"></div>
      {tabbar(selected, badge)}
    </div>'''


def bar_strip(selected, badge=0):
    return f'''<div class="strip">{tabbar(selected, badge)}</div>'''


def main():
    frames = [
        phone("idle", "点一下麦克风，开始听", "把手机靠近正在外放的音箱"),
        phone("listening", "正在聆听…", "还能听 8 秒 · 再点一下可取消", t=0.9, level=0.85),
        phone("recognizing", "正在辨认…", "比对曲库中"),
        phone("result", "听出来了", "识别依据：酷狗 · 通道标为原唱 · 时长 259s", result=True),
        phone("nomatch", "这次没听出来", "靠近一点、音量别太小，或者换个安静点的地方再试"),
        phone("failed", "识别没成功", "麦克风没采到声音（可能是被别的 App 占着），再试一次。"),
    ]

    doc = f'''<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>第三十二轮动效预演 · 识曲 + 底部栏</title>
<style>
  * {{ box-sizing: border-box; -webkit-font-smoothing: antialiased; }}
  body {{ margin:0; padding:40px; background:#EFEBE3; color:{INK};
         font-family:-apple-system,BlinkMacSystemFont,"PingFang SC","Helvetica Neue",sans-serif; }}
  h1 {{ font-size:22px; margin:0 0 6px; }}
  .sub {{ font-size:13px; color:{SECOND}; margin-bottom:28px; line-height:1.6; }}
  .grid {{ display:flex; flex-wrap:wrap; gap:28px; }}
  .phone {{ position:relative; width:393px; height:852px; background:{PAPER}; border-radius:44px;
            overflow:hidden; display:flex; flex-direction:column; box-shadow:0 0 0 8px #111, 0 24px 60px rgba(0,0,0,.18); }}
  .status {{ height:54px; display:flex; align-items:flex-end; justify-content:space-between;
             padding:0 28px 6px; font-size:14px; font-weight:600; }}
  .status-icons {{ letter-spacing:2px; font-size:11px; color:{INK}; }}
  .nav {{ display:flex; align-items:center; justify-content:space-between; padding:6px 20px 2px; }}
  .nav h1 {{ font-size:34px; font-weight:700; margin:0; letter-spacing:-.6px; }}
  .listen-pill {{ font-size:12px; color:{SECOND}; background:{PAPER_EL}; border-radius:14px; padding:6px 10px; }}
  .stage {{ display:flex; align-items:center; justify-content:center; height:{STAGE_H}px; margin-top:14px; }}
  .stage-svg {{ overflow:visible; }}
  .caption {{ padding:6px 24px 0; text-align:center; min-height:66px; }}
  .caption-title {{ font-size:20px; font-weight:600; }}
  .caption-detail {{ font-size:14px; color:{SECOND}; margin-top:3px; line-height:1.4; }}
  .flex1 {{ flex:1; }}
  .result-card {{ margin:16px 16px 0; display:flex; align-items:center; gap:12px; background:{PAPER_EL};
                  border-radius:12px; padding:10px 12px; }}
  .art {{ width:64px; height:64px; border-radius:8px; background:linear-gradient(135deg,#5c5a52,#23221f); flex:0 0 64px; }}
  .result-meta {{ flex:1; min-width:0; }}
  .result-title {{ font-size:17px; font-weight:600; }}
  .result-artist {{ font-size:14px; color:{SECOND}; margin-top:2px; }}
  .result-album {{ font-size:12px; color:{TERT}; margin-top:2px; }}
  .play-btn {{ width:32px; height:32px; border-radius:50%; background:{VERM}; color:#fff; font-size:13px;
               display:flex; align-items:center; justify-content:center; }}
  .tabbar {{ height:58px; display:flex; align-items:center; padding:0 6px; background:{PAPER};
             border-top:.5px solid rgba(0,0,0,.08); }}
  .tab {{ flex:1; display:flex; align-items:center; justify-content:center; position:relative; height:58px; }}
  .pill {{ position:relative; display:flex; align-items:center; gap:5px; height:34px; padding:0 10px;
           border-radius:17px; background:rgba(176,58,46,.10); }}
  .tab-label {{ font-size:11px; font-weight:600; color:{VERM}; }}
  .badge {{ position:absolute; top:-5px; right:-9px; min-width:16px; height:16px; border-radius:8px;
            background:{VERM}; color:#fff; font-size:9px; font-weight:700; display:flex;
            align-items:center; justify-content:center; padding:0 4px; }}
  .strip {{ margin-top:8px; background:{PAPER}; border-radius:16px; overflow:hidden; width:393px;
            box-shadow:0 0 0 6px #111; }}
  .strip .tabbar {{ border-top:none; }}
  .note {{ margin-top:34px; font-size:12px; color:{SECOND}; line-height:1.8; max-width:900px; }}
  .note b {{ color:{INK}; }}
</style></head><body>
<h1>第三十二轮 · 动效预演（识曲 + 底部栏）</h1>
<div class="sub">左起：待机 / 聆听（三圈声波 + 24 根电平条 + 12 秒倒计时环）/ 辨认（雷达弧）/ 出结果（成功脉冲 + 结果卡）/ 没听出来（抖动 + 斜杠）/ 失败。</div>
<div class="grid">{''.join(frames)}</div>

<h1 style="margin-top:44px;font-size:18px">底部栏的三种选中态</h1>
<div class="sub">选中项是一颗朱砂 10% 的胶囊 + 文字；切换时胶囊在槽位之间滑动（0.36s / damping 0.80），文字只淡入。下载有角标。</div>
<div class="grid" style="gap:22px">
  {bar_strip("discover")}
  {bar_strip("downloads", 2)}
  {bar_strip("settings")}
</div>

<div class="note">
  <b>曲线：</b>按下 0.14s spring（damping 0.86）→ 松手 0.30s spring（0.70）；胶囊滑动 0.36s（0.80）；Tab 内容交叉淡变 0.26s（0.94）；结果卡 0.42s（0.86）；识曲声波 1.5s 一圈、错峰 0.42s。<br>
  <b>Reduce Motion：</b>声波 / 抖动 / 成功脉冲 / 胶囊滑动全部取消，只留 0.15s 淡变与倒计时环；图标不做 bounce。<br>
  <b>触觉：</b>开始聆听 medium；辨认 light；出结果 success；没听出来 warning；失败 error；切 Tab selection（只一下）。
</div>
</body></html>'''

    out = ROOT / "docs/ios/mockups/motion-rework.html"
    out.write_text(doc, encoding="utf-8")
    print(out)


if __name__ == "__main__":
    main()
