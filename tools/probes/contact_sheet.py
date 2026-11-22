"""把视频按时间抽帧拼成一张联系表（contact sheet），一次看清整段。

用法：
  python tools/probes/contact_sheet.py <video> <out.png> --start 0 --end 10 --fps 4 --cols 5
"""
import sys
import cv2
import numpy as np


def main():
    path = sys.argv[1]
    out = sys.argv[2]
    args = dict(start=0.0, end=None, fps=2.0, cols=5, thumb_w=270)
    for i, a in enumerate(sys.argv):
        if a.startswith("--"):
            key = a[2:]
            val = sys.argv[i + 1]
            args[key] = float(val) if key != "out" else val

    cap = cv2.VideoCapture(path)
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    duration = total / fps
    end = duration if args["end"] is None else float(args["end"])
    step = 1.0 / args["fps"]

    times = []
    t = float(args["start"])
    while t < end:
        times.append(t)
        t += step

    thumbs = []
    for t in times:
        cap.set(cv2.CAP_PROP_POS_MSEC, t * 1000.0)
        ok, frame = cap.read()
        if not ok:
            continue
        h, w = frame.shape[:2]
        tw = int(args["thumb_w"])
        th = int(h * tw / w)
        small = cv2.resize(frame, (tw, th), interpolation=cv2.INTER_AREA)
        # 左上角写时间戳
        cv2.rectangle(small, (0, 0), (86, 26), (0, 0, 0), -1)
        cv2.putText(small, f"{t:6.2f}s", (4, 19), cv2.FONT_HERSHEY_SIMPLEX,
                    0.55, (0, 255, 0), 1, cv2.LINE_AA)
        thumbs.append(small)
    cap.release()

    cols = int(args["cols"])
    rows = (len(thumbs) + cols - 1) // cols
    th_, tw_ = thumbs[0].shape[:2]
    sheet = np.full((rows * th_, cols * tw_, 3), 40, np.uint8)
    for i, img in enumerate(thumbs):
        r, c = divmod(i, cols)
        sheet[r * th_:(r + 1) * th_, c * tw_:(c + 1) * tw_] = img
    cv2.imwrite(out, sheet)
    print(f"{len(thumbs)} frames → {out} ({sheet.shape[1]}x{sheet.shape[0]})")


if __name__ == "__main__":
    main()
