# -*- coding: utf-8 -*-
import cv2, os, math
from PIL import Image

SRC = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\rec_1111_dl_2174.mp4"
FR = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\frames_dl"
os.makedirs(FR, exist_ok=True)

cap = cv2.VideoCapture(SRC)
fps = cap.get(cv2.CAP_PROP_FPS) or 0
n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
w = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
h = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
dur = n / fps if fps else 0
print("fps=%.3f frames=%d %.1fx%d dur=%.2fs" % (fps, n, w, h, dur))

# 每 0.5s 抽一帧
times = [i * 0.5 for i in range(int(math.floor(dur * 2)) + 1)]
for t in times:
    f = int(round(t * fps))
    if f >= n:
        break
    cap.set(cv2.CAP_PROP_POS_FRAMES, f)
    ok, frame = cap.read()
    if not ok:
        continue
    cv2.imwrite(os.path.join(FR, "t%05.2f.jpg" % t), frame, [cv2.IMWRITE_JPEG_QUALITY, 92])
cap.release()

# 联系表：4 列
files = sorted(os.listdir(FR))
files = [f for f in files if f.endswith(".jpg")]
per = 12
cw = 300
ch = int(h * cw / w)
cols = 4
for si in range(0, len(files), per):
    chunk = files[si:si + per]
    rows = math.ceil(len(chunk) / cols)
    sheet = Image.new("RGB", (cols * cw, rows * (ch + 22)), (255, 255, 255))
    from PIL import ImageDraw, ImageFont
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype(r"C:\Windows\Fonts\msyh.ttc", 16)
    except Exception:
        font = ImageFont.load_default()
    for i, name in enumerate(chunk):
        im = Image.open(os.path.join(FR, name)).convert("RGB").resize((cw, ch))
        x = (i % cols) * cw
        y = (i // cols) * (ch + 22)
        sheet.paste(im, (x, y + 22))
        d.text((x + 6, y + 4), name.replace(".jpg", "s"), font=font, fill=(0, 0, 0))
    out = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_fb3\sheet_dl_%02d.jpg" % (si // per + 1)
    sheet.save(out, quality=90)
    print("sheet", out, sheet.size)
