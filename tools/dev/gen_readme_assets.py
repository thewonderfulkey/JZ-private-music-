"""Generate the README banner + architecture diagrams (SVG sources, then render PNG).

The visual language follows the app's paper/ink/vermilion tokens:
  paper #FAF8F3 · ink #1C1916 · vermilion #B03A2E
  dark paper #0E0D0B · dark accent #FF8A76

Run:
  python tools/dev/gen_readme_assets.py
  python tools/dev/render_readme_assets.py
The second script rasterizes the SVGs and composites the app icon into the banner
(the generic SVG renderer refuses embedded images).
"""
from __future__ import annotations

import base64
import html
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "ios/JZMusicHelper/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
OUT = ROOT / "docs/images/readme"
TMP = ROOT / ".build/readme-assets"
OUT.mkdir(parents=True, exist_ok=True)
TMP.mkdir(parents=True, exist_ok=True)

ICON_B64 = base64.b64encode(ICON.read_bytes()).decode()

INK = "#1C1916"
PAPER = "#FAF8F3"
PAPER2 = "#FFFDF8"
VERMILION = "#B03A2E"
MUTED = "#6B6257"
SOFT = "#8A7F71"
FONT_TITLE = "KaiTi, STKaiti, 'Noto Serif SC', serif"
FONT_BODY = "'Microsoft YaHei', 'PingFang SC', sans-serif"
FONT_MONO = "Consolas, 'SF Mono', monospace"


def banner(dark: bool, embed_icon: bool = True) -> str:
    bg = "#0E0D0B" if dark else PAPER
    ink = PAPER if dark else INK
    muted = "#A79B8B" if dark else MUTED
    soft = "#8A7F71" if dark else SOFT
    accent = "#FF8A76" if dark else VERMILION
    seal_text = "#0E0D0B" if dark else PAPER
    card = 'fill="#FAF8F3"' if dark else 'fill="none"'
    icon_size = 200 if dark else 240
    icon_xy = (108, 132) if dark else (88, 112)
    image = ""
    if embed_icon:
        image = (f'<image x="{icon_xy[0]}" y="{icon_xy[1]}" width="{icon_size}" height="{icon_size}" '
                 f'clip-path="url(#icon-clip)" xlink:href="data:image/png;base64,{ICON_B64}"/>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="1600" height="560" viewBox="0 0 1600 560" role="img"
     aria-labelledby="readme-banner-title readme-banner-desc">
  <title id="readme-banner-title">JZ 音乐助手 · 一个客户端，四家曲库</title>
  <desc id="readme-banner-desc">纸墨底色的项目横幅：JZ 音乐助手，四家曲库，一个播放器。</desc>
  <defs>
    <linearGradient id="paper" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{bg}"/>
      <stop offset="1" stop-color="{'#151310' if dark else '#F4EEE2'}"/>
    </linearGradient>
    <radialGradient id="wash" cx="0.84" cy="0.30" r="0.55">
      <stop offset="0" stop-color="{accent}" stop-opacity="{0.16 if dark else 0.09}"/>
      <stop offset="1" stop-color="{accent}" stop-opacity="0"/>
    </radialGradient>
    <filter id="grain">
      <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" stitchTiles="stitch"/>
      <feColorMatrix type="saturate" values="0"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.035"/></feComponentTransfer>
    </filter>
    <clipPath id="icon-clip"><rect x="{icon_xy[0]}" y="{icon_xy[1]}" width="{icon_size}" height="{icon_size}" rx="30"/></clipPath>
  </defs>

  <rect width="1600" height="560" fill="url(#paper)"/>
  <rect width="1600" height="560" fill="url(#wash)"/>
  <rect x="0.5" y="0.5" width="1599" height="559" fill="none" stroke="{ink}" stroke-opacity="0.10"/>

  <rect x="{icon_xy[0]-4}" y="{icon_xy[1]-4}" width="{icon_size+8}" height="{icon_size+8}" rx="34"
        {card} stroke="{ink}" stroke-opacity="0.10"/>
  {image}

  <text x="380" y="168" font-family="{FONT_BODY}" font-size="19" letter-spacing="4.2"
        fill="{muted}">JZ MUSIC · PERSONAL PROJECT</text>
  <text x="380" y="266" font-family="{FONT_TITLE}" font-size="96" font-weight="700"
        letter-spacing="2" fill="{ink}">JZ 音乐助手</text>
  <text x="382" y="334" font-family="{FONT_TITLE}" font-size="38" fill="{accent}">四家曲库 · 一个播放器</text>
  <text x="382" y="386" font-family="{FONT_BODY}" font-size="21" fill="{muted}">搜索 / 播放 / 识曲 / 下载 / 歌词，一套干净的水墨体验</text>

  <rect x="1360" y="118" width="120" height="120" rx="10" fill="{accent}"/>
  <text x="1420" y="190" text-anchor="middle" font-family="Georgia, 'Times New Roman', serif"
        font-size="46" letter-spacing="2" fill="{seal_text}">JZ</text>
  <text x="1420" y="218" text-anchor="middle" font-family="{FONT_TITLE}" font-size="15"
        letter-spacing="3" fill="{seal_text}" opacity="0.82">音乐</text>

  <line x1="88" y1="468" x2="1512" y2="468" stroke="{ink}" stroke-opacity="0.14"/>
  <text x="88" y="512" font-family="{FONT_BODY}" font-size="19" fill="{muted}">iOS 17+   ·   Android 8+   ·   Windows 10 / 11</text>
  <text x="1512" y="512" text-anchor="end" font-family="{FONT_MONO}" font-size="17" fill="{soft}">SwiftUI · Compose · FFmpeg · CI</text>
</svg>'''


def esc(text: str) -> str:
    return html.escape(text, quote=True)


def t(x, y, s, size=16, fill=INK, family=FONT_BODY, weight="400", anchor="start", spacing=None):
    sp = f' letter-spacing="{spacing}"' if spacing else ""
    return (f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" '
            f'font-weight="{weight}" text-anchor="{anchor}" fill="{fill}"{sp}>{esc(s)}</text>')


def box(x, y, w, h, fill=PAPER2, stroke=INK, opacity=0.16, rx=8):
    return (f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{rx}" fill="{fill}" '
            f'stroke="{stroke}" stroke-opacity="{opacity}"/>')


def chip(x, y, w, s, accent=False):
    if accent:
        return (f'<rect x="{x}" y="{y}" width="{w}" height="30" rx="4" fill="{VERMILION}" fill-opacity="0.07" '
                f'stroke="{VERMILION}" stroke-opacity="0.45"/>'
                + t(x + 12, y + 20, s, 13, VERMILION, FONT_MONO))
    return (f'<rect x="{x}" y="{y}" width="{w}" height="30" rx="4" fill="#FAF6EC" '
            f'stroke="{INK}" stroke-opacity="0.10"/>'
            + t(x + 12, y + 20, s, 13, INK, FONT_MONO))


def architecture() -> str:
    main_x, main_w = 80, 860
    right_x, right_w = 980, 340
    parts = [
        '<svg xmlns="http://www.w3.org/2000/svg" width="1400" height="900" viewBox="0 0 1400 900" '
        'role="img" aria-labelledby="readme-arch-title readme-arch-desc">',
        '<title id="readme-arch-title">JZ 音乐助手的数据层</title>',
        '<desc id="readme-arch-desc">五层客户端架构：交互、状态与引擎、服务、适配器、外部曲库，'
        '两侧是本地持久化与平台能力。</desc>',
        '<defs><linearGradient id="arch-bg" x1="0" y1="0" x2="1" y2="1">'
        f'<stop offset="0" stop-color="{PAPER}"/><stop offset="1" stop-color="#F5EFE3"/>'
        '</linearGradient></defs>',
        '<rect width="1400" height="900" fill="url(#arch-bg)"/>',
        '<rect x="0.5" y="0.5" width="1399" height="899" fill="none" stroke="#1C1916" stroke-opacity="0.10"/>',
        t(80, 74, "数据层：一个客户端，四家曲库", 40, INK, FONT_TITLE, "700"),
        t(80, 108, "没有自建服务器 · 所有编排在客户端 · 失败就换源，验真才播放", 18, MUTED),
        f'<line x1="80" y1="132" x2="1320" y2="132" stroke="{INK}" stroke-opacity="0.12"/>',
    ]

    layers = [
        (150, 92, "01", "交互层",
         "SwiftUI（iOS）· Jetpack Compose（Android）· Compose Desktop（Windows）",
         "5 个 Tab · 播放页 · 歌词 · 下载 · 设置"),
        (260, 84, "02", "状态与引擎",
         "PlayerEngine · LibraryStore · SettingsStore · Router",
         ""),
        (360, 190, "03", "服务层",
         "搜索 · 取流 · 缓存 · 歌词 · 识曲 · 下载",
         ""),
        (566, 100, "04", "适配层",
         "4 个搜索适配器 · 10+ 个取流适配器 · 歌词 / 封面源",
         "QQ / 网易 / 酷我 / 酷狗，各自协议各自解析"),
        (682, 84, "05", "外部曲库与开放服务",
         "QQ 音乐 · 网易云 · 酷我 · 酷狗 · LDDC · LRCLIB · iTunes",
         "公开接口，仅供个人学习"),
    ]
    for y, h, num, title, sub, body in layers:
        num_color = VERMILION if num == "03" else SOFT
        parts.append(t(56, y + 34, num, 18, num_color, FONT_MONO, "700"))
        parts.append(box(main_x, y, main_w, h))
        parts.append(t(main_x + 24, y + 32, title, 20, INK, FONT_BODY, "700"))
        parts.append(t(main_x + 24, y + 58, sub, 14, MUTED))
        if body:
            parts.append(t(main_x + 24, y + 82, body, 13, SOFT))

    chips = ["SearchService", "URLResolver", "PlaybackCache",
             "LyricsService", "RecognizeScore", "DownloadManager"]
    cw, gap = 258, 12
    for i, name in enumerate(chips):
        col, row = i % 3, i // 3
        x = main_x + 24 + col * (cw + gap)
        y = 440 + row * 38
        parts.append(chip(x, y, cw, name))
    parts.append(chip(main_x + 24, 512, 520, "身份闸 · 字节验真 · 主结果时长闸门", accent=True))

    # right column
    parts.append(box(right_x, 360, right_w, 190))
    parts.append(t(right_x + 16, 394, "本地持久化", 20, INK, FONT_BODY, "700"))
    parts.append(t(right_x + 16, 426, "JSON / UserDefaults / Files / Cache", 13, INK, FONT_MONO))
    parts.append(t(right_x + 16, 452, "收藏 · 历史 · 设置 · 歌词 · 封面", 13, MUTED))
    parts.append(t(right_x + 16, 486, "无账号 · 无服务端数据库", 13, SOFT))

    parts.append(box(right_x, 566, right_w, 100))
    parts.append(t(right_x + 16, 600, "平台能力", 20, INK, FONT_BODY, "700"))
    parts.append(t(right_x + 16, 626, "AVFoundation / WKWebView + wasm", 12.5, INK, FONT_MONO))
    parts.append(t(right_x + 16, 648, "MediaPlayer / 前台服务 / FFmpeg", 12.5, MUTED, FONT_MONO))

    # connectors
    parts.append(f'<path d="M940 450 H980" fill="none" stroke="{INK}" stroke-opacity="0.48" stroke-dasharray="5,4"/>')
    parts.append(f'<rect x="944" y="426" width="38" height="16" fill="{PAPER2}"/>')
    parts.append(t(948, 438, "读写", 12, MUTED))
    parts.append(f'<path d="M940 500 H960 V616 H980" fill="none" stroke="{INK}" stroke-opacity="0.48" stroke-dasharray="5,4"/>')
    parts.append(f'<rect x="944" y="476" width="38" height="16" fill="{PAPER2}"/>')
    parts.append(t(948, 488, "能力", 12, MUTED))

    parts.append(t(80, 840, "为什么没有服务端：收藏、历史、缓存都在本机；曲库通过客户端适配器直连，"
                             "少一个中转就少一份隐私和可用性风险。", 15, MUTED))
    parts.append('</svg>')
    return "\n".join(parts)


(OUT / "banner.svg").write_text(banner(False), encoding="utf-8")
(OUT / "banner-dark.svg").write_text(banner(True), encoding="utf-8")
(OUT / "architecture.svg").write_text(architecture(), encoding="utf-8")
(TMP / "banner-render.svg").write_text(banner(False, embed_icon=False), encoding="utf-8")
(TMP / "banner-dark-render.svg").write_text(banner(True, embed_icon=False), encoding="utf-8")
print("wrote banner.svg / banner-dark.svg / architecture.svg")
print("wrote render variants to", TMP)
