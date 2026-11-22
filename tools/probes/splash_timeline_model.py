"""把 `SplashTimeline` + `SplashView` 的曲线在 Python 里复算一遍，找出"画面上完全不动"的区间。

目的：判断老板说的"卡在固定的一帧"到底是主线程卡顿，还是时间轴本身留了一段空档。
输出每一拍对可见像素的贡献随时间的变化率，任何 33ms 内变化都低于阈值的区段 = 死帧区。
"""

PI = 3.141592653589793


def clamp01(v):
    return 0.0 if v < 0 else (1.0 if v > 1 else v)


def beat(start, dur, t):
    raw = (t - start) / dur if dur > 0 else (1.0 if t >= start else 0.0)
    return clamp01(raw)


def ease_out(v):
    m = 1 - clamp01(v)
    return 1 - m * m * m


def spring(elapsed, response=0.40, damping=0.72):
    if elapsed <= 0:
        return 0.0
    import math
    w0 = 2 * PI / response
    wd = w0 * (1 - damping * damping) ** 0.5
    decay = math.exp(-damping * w0 * elapsed)
    return 1 - decay * (math.cos(wd * elapsed) + (damping * w0 / wd) * math.sin(wd * elapsed))


# 时间轴（现行 v2.4.81）
BAND = (0.00, 0.62)
CUP_L = (0.34, 0.62)
CUP_R = (0.40, 0.62)
SOUND = (0.66, 0.66)
THUMP = (0.66, 0.32)
EXIT = (1.30, 0.42)
MARK_FADE = (1.30, 0.28)

# 提案常数（--proposal 时生效）：退场提前、声波活到退场、轻顶拉满一整拍
if "--proposal" in __import__("sys").argv:
    SOUND = (0.66, 0.54)
    THUMP = (0.66, 0.36)
    EXIT = (1.10, 0.42)
    MARK_FADE = (1.10, 0.28)
    WAVE_ALPHA = 0.62
    WAVE_POW = 1.1
else:
    WAVE_ALPHA = 0.55
    WAVE_POW = None  # None = 现行写法：0.55 * (1 - easeOut(local))


def visible_state(t):
    """返回 (头梁进度, 左耳罩, 右耳罩, 左声波透明度, 右声波透明度, 轻顶, 退场)"""
    band = ease_out(beat(*BAND, t))
    cl = spring(t - CUP_L[0])
    cr = spring(t - CUP_R[0])
    p = beat(*SOUND, t)
    if WAVE_POW is None:
        left_local = ease_out(clamp01((p - 0.05) / 0.78))
        right_local = ease_out(clamp01((p - 0.11) / 0.78))
        op_l = WAVE_ALPHA * (1 - left_local) if p > 0 else 0.0
        op_r = WAVE_ALPHA * (1 - right_local) if p > 0 else 0.0
    else:
        p_r = clamp01((t - (SOUND[0] + 0.06)) / SOUND[1])
        op_l = WAVE_ALPHA * (1 - p) ** WAVE_POW if p > 0 else 0.0
        op_r = WAVE_ALPHA * (1 - p_r) ** WAVE_POW if p_r > 0 else 0.0
    import math
    s = math.sin(PI * beat(*THUMP, t))
    thump = s * s
    exit_p = beat(*EXIT, t)
    return band, cl, cr, op_l, op_r, thump, exit_p


def main():
    import math
    dt = 1 / 30
    t = 0.0
    prev = visible_state(0.0)
    print(f"{'t':>6} {'band':>5} {'cupL':>5} {'cupR':>5} {'waveL':>6} {'waveR':>6} {'thump':>6} {'exit':>5}  {'Δ':>7}")
    dead = []
    cur = None
    while t <= 1.80:
        st = visible_state(t)
        # 各分量的"每帧变化"，波浪按透明度×尺度算可见强度
        d = (
            abs(st[0] - prev[0]) * 100
            + abs(st[1] - prev[1]) * 6
            + abs(st[2] - prev[2]) * 6
            + abs(st[3] - prev[3]) * 22
            + abs(st[4] - prev[4]) * 22
            + abs(st[5] - prev[5]) * 8
            + abs(st[6] - prev[6]) * 100
        )
        flag = "  <== 死帧" if d < 0.6 else ""
        print(f"{t:6.3f} {st[0]:5.2f} {st[1]:5.2f} {st[2]:5.2f} {st[3]:6.3f} {st[4]:6.3f} {st[5]:6.3f} {st[6]:5.2f}  {d:7.3f}{flag}")
        if d < 0.6:
            if cur is None:
                cur = t - dt
        else:
            if cur is not None and t - cur > 0.1:
                dead.append((cur, t))
            cur = None
        prev = st
        t += dt
    if cur is not None:
        dead.append((cur, 1.80))
    print("\n=== 死帧区段（可见变化 < 阈值）===")
    for a, b in dead:
        print(f"  {a:.3f}s → {b:.3f}s   ({(b - a) * 1000:.0f}ms)")


if __name__ == "__main__":
    main()
