"""开屏动画卡帧取证：逐帧算差分，找出"画面完全不动"的区段。

用法：
  python tools/probes/splash_stall_probe.py <video> [--thresh 0.6]

判据：把每帧缩成 54x117 灰度，算与上一帧的平均绝对差（0~255）。
真实动画在跑时 diff 通常 > 1.0；卡住时受视频压缩抖动影响在 0~0.4 之间。
输出：所有 >=3 帧几乎不动的区段（起止时间 / 持续帧数 / 平均亮度），
      以及每 0.5s 的 diff 摘要，便于人工对照。
"""
import sys
import numpy as np
import cv2

def main():
    path = sys.argv[1]
    thresh = 0.6
    for i, a in enumerate(sys.argv):
        if a == "--thresh":
            thresh = float(sys.argv[i + 1])

    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    print(f"video={path}")
    print(f"fps={fps:.3f} frames={total} duration={total / fps:.2f}s")

    prev = None
    diffs = []
    means = []
    idx = 0
    while True:
        ok, frame = cap.read()
        if not ok:
            break
        g = cv2.cvtColor(cv2.resize(frame, (54, 117)), cv2.COLOR_BGR2GRAY).astype(np.float32)
        means.append(float(g.mean()))
        if prev is None:
            diffs.append(0.0)
        else:
            diffs.append(float(np.abs(g - prev).mean()))
        prev = g
        idx += 1
    cap.release()
    n = len(diffs)
    print(f"read {n} frames")

    # 找出连续低差分区段
    runs = []
    start = None
    for i, d in enumerate(diffs):
        if i == 0:
            continue
        if d < thresh:
            if start is None:
                start = i
        else:
            if start is not None:
                runs.append((start, i - 1))
                start = None
    if start is not None:
        runs.append((start, n - 1))

    print("\n=== 近似静止区段（>=3 帧，diff < %.2f） ===" % thresh)
    for s, e in runs:
        if e - s + 1 >= 3:
            print(f"  {s / fps:7.2f}s → {e / fps:7.2f}s  ({e - s + 1} frames, {1000 * (e - s + 1) / fps:5.0f}ms)  mean_lum={np.mean(means[s:e + 1]):.1f}")

    print("\n=== 每秒摘要 ===")
    for sec in range(0, int(n / fps) + 1):
        a = int(sec * fps)
        b = min(n, int((sec + 1) * fps))
        if a >= b:
            break
        seg = diffs[a + 1:b] or [0.0]
        print(f"  {sec:3d}s  diff_avg={np.mean(seg):5.2f} diff_max={np.max(seg):6.2f} lum={np.mean(means[a:b]):5.1f}")

if __name__ == "__main__":
    main()
