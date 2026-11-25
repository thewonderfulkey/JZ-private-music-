"""把抽出来的每一帧都 OCR 一遍，产出「时间 → 屏幕上的文字」时间线。

为什么：老板的录屏里真正的证据大多是界面上的小字（歌手名/版本号/「暂无」「失败」「超时」），
肉眼看 500 帧会漏；OCR 之后可以 grep，也可以对齐「哪一秒屏幕上出现了什么」。

用法：
  python tools/probes/ocr_timeline.py <frames_dir> [--out ocr.json] [--workers 4] [--step 1]

产出：
  ocr.json         每帧的 [bbox, text, score]
  ocr_lines.txt    人读时间线（按时间排序，一行一帧）
"""
import argparse
import json
import os
import sys
from multiprocessing import Pool

_OCR = None


def _init():
    global _OCR
    from rapidocr_onnxruntime import RapidOCR
    _OCR = RapidOCR()


def _work(path):
    global _OCR
    if _OCR is None:
        _init()
    try:
        res, _ = _OCR(path)
    except Exception as e:  # noqa: BLE001
        return path, [], str(e)
    out = []
    for item in (res or []):
        box, text, score = item[0], item[1], float(item[2])
        if score < 0.45:
            continue
        ys = [p[1] for p in box]
        xs = [p[0] for p in box]
        out.append({"y": int(sum(ys) / 4), "x": int(sum(xs) / 4),
                    "text": text, "score": round(score, 2)})
    # 按版面顺序排（先上后下、先左后右），方便人读
    out.sort(key=lambda r: (round(r["y"] / 40), r["x"]))
    return path, out, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("frames")
    ap.add_argument("--out", default=None)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--step", type=int, default=1)
    a = ap.parse_args()

    files = sorted(f for f in os.listdir(a.frames) if f.lower().endswith((".jpg", ".png")))[::a.step]
    paths = [os.path.join(a.frames, f) for f in files]
    results = {}
    with Pool(a.workers, initializer=_init) as pool:
        for i, (path, lines, err) in enumerate(pool.imap_unordered(_work, paths)):
            results[os.path.basename(path)] = lines
            if err:
                print("ERR", path, err)
            if (i + 1) % 25 == 0:
                print(f"  {i + 1}/{len(paths)}", flush=True)

    out = a.out or os.path.join(os.path.dirname(a.frames.rstrip("\\/")), "ocr.json")
    json.dump(results, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=1)

    txt = os.path.join(os.path.dirname(out), "ocr_lines.txt")
    with open(txt, "w", encoding="utf-8") as f:
        for name in sorted(results):
            f.write(f"===== {name} =====\n")
            for r in results[name]:
                f.write(f"  y={r['y']:4d} | {r['text']}\n")
    print("→", out, txt)
    return 0


if __name__ == "__main__":
    sys.exit(main())
