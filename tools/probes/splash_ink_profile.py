"""开屏动画逐帧"墨量"曲线：看清哪一段画面完全不动、动了多少。

对每一帧统计：
  ink   —— 图标区域里明显亮于纸底的像素数（相当于"画了多少"）
  diff  —— 与上一帧的平均绝对差（0~255）
  dink  —— 与上一帧的 ink 变化量

用法：
  python tools/probes/splash_ink_profile.py <video> --start 3.2 --end 5.6 [--fps 30]
"""
import sys
import cv2
import numpy as np


def main():
    path = sys.argv[1]
    args = dict(start=0.0, end=3.0)
    for i, a in enumerate(sys.argv):
        if a.startswith("--"):
            args[a[2:]] = float(sys.argv[i + 1])
    start, end = args["start"], args["end"]

    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    cap.set(cv2.CAP_PROP_POS_MSEC, start * 1000.0)

    prev_gray = None
    prev_ink = None
    t = start
    dt = 1.0 / fps
    print(f"{'idx':>4} {'t(s)':>7} {'ink':>6} {'dink':>6} {'diff':>6}  bar")
    i = 0
    while t < end:
        ok, frame = cap.read()
        if not ok:
            break
        h, w = frame.shape[:2]
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY).astype(np.float32)
        small = cv2.resize(gray, (54, 117))
        # 亮像素：图标是浅色/白色，纸底是深色
        ink = int((gray > gray.mean() + 45).sum())
        diff = 0.0 if prev_gray is None else float(np.abs(small - prev_gray).mean())
        dink = 0 if prev_ink is None else ink - prev_ink
        bar = "#" * min(60, int(diff * 6))
        print(f"{i:>4} {t:>7.3f} {ink:>6} {dink:>6} {diff:>6.2f}  {bar}")
        prev_gray = small
        prev_ink = ink
        t += dt
        i += 1
    cap.release()


if __name__ == "__main__":
    main()
