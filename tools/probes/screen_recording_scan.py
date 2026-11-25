"""录屏取证扫描器：一次跑完「画面结构 + 声音包络 + 场景切换 + 静音段」。

为什么需要它（2026-11-25）：老板的报障录屏动辄 5-9 分钟、几百帧，
靠肉眼看联系表会漏掉"某一段没声音""某一屏停住不动"这种关键证据。
这个脚本把录屏变成三条可核对的曲线 + 关键帧，再用 read_image 只挑重点看。

用法：
  python tools/probes/screen_recording_scan.py <video> [--outdir .tmp_video] [--fps 2]

产出（outdir 下）：
  meta.json        时长/分辨率/fps/帧数
  timeline.json    每 0.25s：画面差分、是否静止、是否有声（RMS dBFS）
  cuts.txt         场景切换时间点（秒 + 帧号）
  audio.txt        每秒音频 RMS/峰值 dBFS
  key/*.png        场景切换处的关键帧（全分辨率）
  sheet_*.png      每 30s 一张的四宫格联系表
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np

try:
    import cv2
except ImportError:  # pragma: no cover
    print("需要 opencv-python（cv2）")
    raise


def audio_envelope(path):
    """用 imageio_ffmpeg 的 ffmpeg 解成 8kHz 单声道 s16，算每 0.25s 的 RMS/peak（dBFS）。"""
    try:
        import imageio_ffmpeg
    except ImportError:
        return None
    exe = imageio_ffmpeg.get_ffmpeg_exe()
    p = subprocess.run([exe, "-v", "error", "-i", path, "-vn", "-ac", "1", "-ar", "8000",
                        "-f", "s16le", "-"], capture_output=True)
    if p.returncode != 0 or not p.stdout:
        return None
    pcm = np.frombuffer(p.stdout, dtype=np.int16).astype(np.float32) / 32768.0
    sr = 8000
    win = int(sr * 0.25)
    n = len(pcm) // win
    out = []
    for i in range(n):
        seg = pcm[i * win:(i + 1) * win]
        rms = float(np.sqrt(np.mean(seg * seg)) + 1e-9)
        peak = float(np.max(np.abs(seg)) + 1e-9)
        out.append({"t": round(i * 0.25, 2),
                    "rms_db": round(20 * np.log10(rms), 1),
                    "peak_db": round(20 * np.log10(peak), 1)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("video")
    ap.add_argument("--outdir", default=".tmp_video")
    ap.add_argument("--fps", type=float, default=2.0, help="抽样帧的采样率（只用于差分/缩略）")
    ap.add_argument("--cut-thresh", type=float, default=0.22, help="场景切换阈值（0-1，越小越敏感）")
    a = ap.parse_args()

    out = a.outdir
    os.makedirs(os.path.join(out, "key"), exist_ok=True)

    cap = cv2.VideoCapture(a.video)
    if not cap.isOpened():
        print("打不开视频", a.video)
        return 2
    fps = cap.get(cv2.CAP_PROP_FPS) or 30.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    meta = {"video": os.path.abspath(a.video), "fps": fps, "frames": total,
            "w": w, "h": h, "duration_s": round(total / fps, 2) if fps else None}
    json.dump(meta, open(os.path.join(out, "meta.json"), "w", encoding="utf-8"), indent=2)
    print(f"{w}x{h} @ {fps:.2f}fps  {total} 帧  {meta['duration_s']}s")

    step = max(1, int(round(fps / a.fps)))
    timeline = []
    cuts = []
    prev_small = None
    idx = 0
    sampled = 0
    while True:
        ok = cap.grab()
        if not ok:
            break
        if idx % step == 0:
            ok, frame = cap.retrieve()
            if not ok:
                break
            t = idx / fps
            small = cv2.resize(frame, (108, 234), interpolation=cv2.INTER_AREA)
            g = cv2.cvtColor(small, cv2.COLOR_BGR2GRAY).astype(np.float32) / 255.0
            diff = 0.0 if prev_small is None else float(np.mean(np.abs(g - prev_small)))
            timeline.append({"t": round(t, 2), "frame": idx, "diff": round(diff, 5)})
            if prev_small is not None and diff > a.cut_thresh:
                cuts.append({"t": round(t, 2), "frame": idx, "diff": round(diff, 4)})
                cv2.imwrite(os.path.join(out, "key", f"cut_{t:08.2f}.png"), frame)
            prev_small = g
            sampled += 1
        idx += 1
    cap.release()
    print(f"抽样 {sampled} 帧，场景切换 {len(cuts)} 处")

    audio = audio_envelope(a.video)
    if audio:
        with open(os.path.join(out, "audio.txt"), "w", encoding="utf-8") as f:
            for r in audio:
                f.write(f"{r['t']:8.2f}  rms={r['rms_db']:7.1f}  peak={r['peak_db']:7.1f}\n")
        # 把 0.25s 的声音并进 timeline
        amap = {r["t"]: r for r in audio}
        for r in timeline:
            near = amap.get(round(round(r["t"] * 4) / 4, 2))
            if near:
                r["rms_db"] = near["rms_db"]
                r["peak_db"] = near["peak_db"]
        print("音频包络 OK")
    else:
        print("音频解码失败，跳过声音分析")

    json.dump(timeline, open(os.path.join(out, "timeline.json"), "w", encoding="utf-8"))
    with open(os.path.join(out, "cuts.txt"), "w", encoding="utf-8") as f:
        for c in cuts:
            f.write(f"{c['t']:8.2f}s  frame={c['frame']}  diff={c['diff']}\n")

    # 静止段（连续 1s 以上画面几乎不动）
    still = []
    run_start = None
    for r in timeline:
        if r["diff"] < 0.0015:
            if run_start is None:
                run_start = r["t"]
        else:
            if run_start is not None and r["t"] - run_start >= 1.0:
                still.append((run_start, r["t"]))
            run_start = None
    if run_start is not None and timeline and timeline[-1]["t"] - run_start >= 1.0:
        still.append((run_start, timeline[-1]["t"]))
    print("静止段（>=1s）：", ", ".join(f"{s:.1f}-{e:.1f}s" for s, e in still) or "无")
    json.dump([{"start": s, "end": e} for s, e in still],
              open(os.path.join(out, "still.json"), "w", encoding="utf-8"), indent=2)
    return 0


if __name__ == "__main__":
    sys.exit(main())
