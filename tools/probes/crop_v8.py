# -*- coding: utf-8 -*-
from PIL import Image
import os
ROOT = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1"
FB = os.path.join(ROOT, "_tmp_fb3")
im = Image.open(os.path.join(FB, "impl_v8_states.jpg"))
im.crop((40, 1640, 1060, 1900)).resize((1560, 390)).save(os.path.join(FB, "crop_v8_bar.jpg"), quality=95)
im.crop((1080 + 40, 1640, 1080 + 1060, 2130)).resize((1560, 644)).save(os.path.join(FB, "crop_v8_tb.jpg"), quality=95)
st = Image.open(os.path.join(FB, "impl_v8_step.jpg"))
print("ok", im.size, st.size)
