# -*- coding: utf-8 -*-
import io
import json

p = r"_tmp_build\msgs_latest_re.txt"
d = json.load(io.open(p, encoding="utf-8"))
ms = d["data"]["messages"]
print("count", len(ms))
for i, m in enumerate(ms):
    s = (m.get("sender") or {}).get("name") or (m.get("sender") or {}).get("id")
    print(i, m.get("create_time"), m.get("msg_type"), s)
    print("   ", str(m.get("content"))[:300].replace("\n", " "))
    for r in (m.get("resources") or []):
        print("    RES", r.get("type"), r.get("size_bytes"), r.get("local_path"))
