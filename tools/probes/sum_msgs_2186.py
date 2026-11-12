# -*- coding: utf-8 -*-
import json, io

p = r"_tmp_build\msgs_latest_2186.txt"
raw = open(p, encoding="utf-8").read()
data = json.loads(raw[raw.index("{"):])
msgs = data.get("data", {}).get("messages", []) or data.get("messages", [])
out = []
for m in msgs:
    c = m.get("content", "")
    try:
        cj = json.loads(c) if isinstance(c, str) else c
    except Exception:
        cj = {}
    txt = ""
    if isinstance(cj, dict):
        txt = cj.get("text") or cj.get("image_key") or cj.get("file_key") or ""
        if cj.get("title"):
            txt = cj["title"]
    body = (cj.get("body") or {}).get("content") if isinstance(cj, dict) else None
    if not txt and body:
        txt = " ".join(seg.get("text","") for line in body for seg in line)
    res = m.get("resources") or []
    out.append({
        "id": m.get("message_id"),
        "type": m.get("msg_type"),
        "time": m.get("create_time"),
        "sender": (m.get("sender") or {}).get("name"),
        "text": txt[:180].replace("\n", " "),
        "res": [(r.get("type"), r.get("local_path"), r.get("size_bytes")) for r in res],
    })
open(r"_tmp_build\msgs_latest_2186_sum.txt", "w", encoding="utf-8").write(
    json.dumps(out, ensure_ascii=False, indent=2))
print("n=", len(out))
for o in out:
    print(o["time"], o["type"], o["sender"], "|", o["text"][:90], "|", o["res"])
