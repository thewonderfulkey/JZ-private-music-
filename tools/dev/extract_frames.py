import cv2, os, sys

p = sys.argv[1]
out = sys.argv[2]
every = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
os.makedirs(out, exist_ok=True)
cap = cv2.VideoCapture(p)
fps = cap.get(cv2.CAP_PROP_FPS) or 0
n = cap.get(cv2.CAP_PROP_FRAME_COUNT)
w = cap.get(cv2.CAP_PROP_FRAME_WIDTH)
h = cap.get(cv2.CAP_PROP_FRAME_HEIGHT)
print("fps", fps, "frames", n, "size", w, h, "dur_s", (n / fps if fps else 0))
i = 0
saved = 0
fps_i = max(1, int(round(fps))) if fps else 30
step = max(1, int(round(fps_i * every)))
while True:
    ok, frame = cap.read()
    if not ok:
        break
    if i % step == 0:
        sec = int(round(i / fps_i))
        # downscale to keep files small but readable
        hh, ww = frame.shape[:2]
        if ww > 900:
            s = 900.0 / ww
            frame = cv2.resize(frame, (900, int(hh * s)))
        cv2.imwrite(os.path.join(out, "t%03ds.jpg" % sec), frame, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
        saved += 1
    i += 1
cap.release()
print("saved", saved)
