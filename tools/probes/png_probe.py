# -*- coding: utf-8 -*-
import struct, os
D = r'C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\JZMusicHelperAndroid\app\src\main\res\drawable-nodpi'
out = []
for f in sorted(os.listdir(D)):
    if not f.startswith('splash_'):
        continue
    p = os.path.join(D, f)
    b = open(p, 'rb').read()
    sig = b[:8] == b'\x89PNG\r\n\x1a\n'
    if not sig:
        out.append("%-24s NOT PNG  head=%r" % (f, b[:12]))
        continue
    w, h, depth, ctype, comp, filt, inter = struct.unpack('>IIBBBBB', b[16:29])
    out.append("%-24s %dx%d depth=%d color=%d interlace=%d size=%d" % (f, w, h, depth, ctype, inter, len(b)))
open(r'C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\png_probe.txt', 'w', encoding='utf-8').write("\n".join(out))
print("\n".join(out))
