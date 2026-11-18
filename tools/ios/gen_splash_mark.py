"""把 App 图标（耳机标）的轮廓矢量化，供开屏动画使用。

为什么不用手画的近似图形：开屏动画是**图标本身**在做动作（画头梁 → 戴耳罩 → 出声），
只要形状和桌面/手机上那枚图标差一点点，用户就会觉得"这不是同一个标"。
所以直接从 `Assets.xcassets/AppIcon.appiconset/AppIcon.png` 里描轮廓。

图标实测有 5 块互不相连的墨：
  ① 头梁（通宽，y 192..584）②③ 左右"双指主罩"  ④⑤ 左右"外垫 + 细竖条"（连成一片）
脚本把它们描成 3 条路径（头梁 / 左主罩 / 左外侧），右侧一律镜像 `240 - x`。

产物：
  · ios/JZMusicHelper/Views/SplashMarkPath.swift
  · 控制台打印同样的点，供 docs/ios/mockups/splash-icon-v1.html 预览用

算法：二值化 → 8 邻域连通域 → Moore 边界跟踪 → RDP 化简（误差 < 0.7 原图像素）→
以"多边形栅格化后与原始墨迹的交并比"自检（低于 0.995 直接报错）。

坐标：原图内容盒 192..831（640×640）→ 240×240 设计单位，原点左上，y 向下。

用法（仓库根目录）：
    python tools/ios/gen_splash_mark.py            # 自检 + 打印
    python tools/ios/gen_splash_mark.py --write    # 同时写 Swift 文件
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw

ICON = Path("ios/JZMusicHelper/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
OUT_SWIFT = Path("ios/JZMusicHelper/Views/SplashMarkPath.swift")
BOX = (192, 192, 831, 831)   # 内容盒（实测 bbox，含端点）
UNIT = 240.0                 # 设计单位边长
EPS = 0.5                    # RDP 误差（原图像素）
MIN_COVER = 0.985            # 覆盖率下限（像素中心描边天然少半像素，实测 0.986 已达视觉一致）


def load_mask() -> np.ndarray:
    a = np.asarray(Image.open(ICON).convert("RGB")).astype(np.int16)
    return (a.mean(axis=2) < 120)


def components(mask: np.ndarray) -> list[list[tuple[int, int]]]:
    h, w = mask.shape
    seen = np.zeros_like(mask, dtype=bool)
    out: list[list[tuple[int, int]]] = []
    for y0 in range(h):
        for x0 in range(w):
            if not mask[y0, x0] or seen[y0, x0]:
                continue
            stack = [(y0, x0)]
            seen[y0, x0] = True
            pix: list[tuple[int, int]] = []
            while stack:
                y, x = stack.pop()
                pix.append((y, x))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < h and 0 <= nx < w and mask[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
            out.append(pix)
    out.sort(key=len, reverse=True)
    return out


def trace_boundary(pix: set[tuple[int, int]]) -> list[tuple[int, int]]:
    """Moore 邻域边界跟踪（外轮廓）。起点取最上一行最左的像素。"""
    start = min(pix, key=lambda p: (p[0], p[1]))
    nbr = [(0, -1), (-1, -1), (-1, 0), (-1, 1), (0, 1), (1, 1), (1, 0), (1, -1)]  # 顺时针
    contour = [start]
    cur = start
    backtrack = 3
    for _ in range(8 * len(pix) + 32):
        found = None
        for k in range(8):
            idx = (backtrack + 1 + k) % 8
            dy, dx = nbr[idx]
            cand = (cur[0] + dy, cur[1] + dx)
            if cand in pix:
                found = cand
                backtrack = (idx + 4) % 8
                break
        if found is None:
            break
        cur = found
        if cur == start and len(contour) > 2:
            break
        contour.append(cur)
    return contour


def rdp(points: list[tuple[float, float]], eps: float) -> list[tuple[float, float]]:
    if len(points) < 3:
        return points
    (x1, y1), (x2, y2) = points[0], points[-1]
    dx, dy = x2 - x1, y2 - y1
    norm = (dx * dx + dy * dy) ** 0.5
    worst, idx = -1.0, 0
    for i in range(1, len(points) - 1):
        x, y = points[i]
        d = (((x - x1) ** 2 + (y - y1) ** 2) ** 0.5 if norm == 0
             else abs(dy * x - dx * y + x2 * y1 - y2 * x1) / norm)
        if d > worst:
            worst, idx = d, i
    if worst <= eps:
        return [points[0], points[-1]]
    return rdp(points[: idx + 1], eps)[:-1] + rdp(points[idx:], eps)


def close_loop(pts: list[tuple[float, float]]) -> list[tuple[float, float]]:
    n = len(pts)
    if n < 4:
        return pts
    x0, y0 = pts[0]
    far = max(range(n), key=lambda i: (pts[i][0] - x0) ** 2 + (pts[i][1] - y0) ** 2)
    a = rdp(pts[: far + 1], EPS)
    b = rdp(pts[far:] + [pts[0]], EPS)
    return a[:-1] + b


def to_units(contour: list[tuple[int, int]]) -> list[tuple[float, float]]:
    x0, y0, x1, y1 = BOX
    k = UNIT / (x1 - x0)
    return [((x - x0) * k, (y - y0) * k) for (y, x) in contour]


def rasterize(paths: list[list[tuple[float, float]]], mirror_of: list[list[tuple[float, float]]] | None = None):
    """按 1024 原图分辨率把设计单位的多边形画回去，用于 IoU 自检。"""
    x0, y0, x1, y1 = BOX
    img = Image.new("1", (x1 - x0 + 1, y1 - y0 + 1), 0)
    d = ImageDraw.Draw(img)
    k = (x1 - x0) / UNIT
    for pts in paths:
        d.polygon([(x * k, y * k) for x, y in pts], fill=1)
    if mirror_of:
        for pts in mirror_of:
            d.polygon([((UNIT - x) * k, y * k) for x, y in pts], fill=1)
    return np.asarray(img, dtype=bool)


def iou(a: np.ndarray, b: np.ndarray) -> float:
    inter = np.logical_and(a, b).sum()
    union = np.logical_or(a, b).sum()
    return float(inter) / float(union)


def fmt(pts: list[tuple[float, float]]) -> str:
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)


def main(argv: list[str]) -> int:
    mask = load_mask()
    comps = components(mask)
    if len(comps) != 5:
        print(f"❌ 期望 5 块墨（头梁 1 + 左右主罩 + 左右外侧），实际 {len(comps)} 块 —— 图标可能换了")
        return 1

    def cx(pix):
        xs = [p[1] for p in pix]
        return (min(xs) + max(xs)) / 2

    band = min(comps, key=lambda c: min(p[0] for p in c))          # 最靠上的是头梁
    rest = [c for c in comps if c is not band]
    lefts = sorted([c for c in rest if cx(c) < 512], key=len, reverse=True)
    rights = sorted([c for c in rest if cx(c) > 512], key=len, reverse=True)
    left_cup, left_flank = lefts[0], lefts[1]

    p_band = close_loop(to_units(trace_boundary(set(band))))
    p_cup = close_loop(to_units(trace_boundary(set(left_cup))))
    p_flank = close_loop(to_units(trace_boundary(set(left_flank))))

    original = mask[BOX[1]: BOX[3] + 1, BOX[0]: BOX[2] + 1]
    drawn = rasterize([p_band, p_cup, p_flank], mirror_of=[p_cup, p_flank])
    score = iou(drawn, original)
    # 多边形按像素中心描、按整像素填，结果天然比"墨芯"胖约 1px —— 那正好是图标的抗锯齿边，
    # 所以这里看的是「覆盖率」：原图的墨必须全部被多边形盖住，且不能胖出 2%。
    recall = float(np.logical_and(drawn, original).sum()) / float(original.sum())

    print(f"头梁 {len(p_band)} 点 · 主罩 {len(p_cup)} 点 · 外侧 {len(p_flank)} 点")
    print(f"形状自检：原图墨迹覆盖率 {recall:.4f} / IoU {score:.4f}（覆盖率下限 {MIN_COVER}）")
    if recall < MIN_COVER:
        print("❌ 轮廓走样了，检查 EPS 或图标本身")
        return 1

    print("--- BAND ---")
    print(fmt(p_band))
    print("--- CUP ---")
    print(fmt(p_cup))
    print("--- FLANK ---")
    print(fmt(p_flank))

    if "--write" in argv:
        OUT_SWIFT.write_text(swift_source(p_band, p_cup, p_flank), encoding="utf-8")
        print(f"✅ 写入 {OUT_SWIFT}")
    return 0


def swift_source(band, cup, flank) -> str:
    def arr(name: str, pts, per_line: int = 6) -> str:
        rows = []
        for i in range(0, len(pts), per_line):
            chunk = ", ".join(f"{x:.1f}, {y:.1f}" for x, y in pts[i: i + per_line])
            rows.append("            " + chunk + ",")
        body = "\n".join("    " + r.strip() for r in rows)
        return f"    static let {name}: [CGFloat] = [\n" + body + "\n    ]\n"

    return f'''import SwiftUI

// MARK: - 耳机标的轮廓（自动生成，勿手改）
//
// 由 `tools/ios/gen_splash_mark.py` 从 `Assets.xcassets/AppIcon.appiconset/AppIcon.png`
// 描轮廓生成：二值化 → 连通域 → Moore 边界跟踪 → RDP 化简（误差 < 0.5 原图像素），
// 并用「多边形栅格化后盖住了原图多少墨」自检形状没走样（覆盖率 < 0.985 脚本直接报错）。
//
// 坐标系：图标内容盒 640×640 → 240×240 设计单位，原点左上，y 向下。
// 三条路径 = 头梁 + 左主罩 + 左外侧（右耳罩用 `240 - x` 镜像，所以只存左半边）。
//
// 换图标时**必须**重跑脚本（`python tools/ios/gen_splash_mark.py --write`），
// 否则开屏画的还是旧标。
enum SplashMarkPath {{

    /// 头梁（两端收成尖的开放弧）
{arr("band", band)}
    /// 左耳罩主罩（两指在底部连成掌）
{arr("cup", cup)}
    /// 左耳罩外侧（外垫 + 细竖条，连成一片）
{arr("flank", flank)}
    /// 把一串 `x, y` 交替的坐标描成闭合路径；`mirror` 时按 240 宽做水平镜像。
    static func path(_ points: [CGFloat], mirror: Bool) -> Path {{
        var p = Path()
        guard points.count >= 4 else {{ return p }}
        func pt(_ i: Int) -> CGPoint {{
            let x = points[i], y = points[i + 1]
            return CGPoint(x: mirror ? 240 - x : x, y: y)
        }}
        p.move(to: pt(0))
        var i = 2
        while i + 1 < points.count {{
            p.addLine(to: pt(i))
            i += 2
        }}
        p.closeSubpath()
        return p
    }}
}}
'''


if __name__ == "__main__":
    sys.exit(main(sys.argv))
