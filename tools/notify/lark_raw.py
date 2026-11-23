"""把指定 message_id 的**完整内容**打出来（lark_fetch 只打摘要，构建失败卡片里的报错会被截掉）。

用法：python tools/notify/lark_raw.py <message_id>
"""
import json
import sys

sys.path.insert(0, r"D:\Projects\Private_music\tools\notify")
import lark_fetch as lf  # noqa: E402

msg_id = sys.argv[1]
app_id, app_secret, chat = lf.creds()
tok = lf.post_json(lf.BASE + "/auth/v3/tenant_access_token/internal",
                   {"app_id": app_id, "app_secret": app_secret})
token = tok.get("tenant_access_token")
if not token:
    print("取 token 失败", tok)
    raise SystemExit(1)

res = lf.get_json(lf.BASE + "/im/v1/messages/" + msg_id, token)
items = res.get("data", {}).get("items") or []
if not items:
    print(json.dumps(res, ensure_ascii=False)[:800])
    raise SystemExit(0)

body = items[0].get("body", {}).get("content", "")
try:
    payload = json.loads(body)
except Exception:
    print(body)
    raise SystemExit(0)

# 富文本卡片：把 elements 里的 text 全打出来
def walk(node, depth=0):
    if isinstance(node, dict):
        if node.get("tag") in ("text", "plain_text") or "text" in node and isinstance(node.get("text"), str):
            txt = node.get("text") or ""
            if txt.strip():
                print(txt)
        for key in ("title", "content", "elements", "fields", "columns", "header"):
            if key in node:
                walk(node[key], depth + 1)
    elif isinstance(node, list):
        for item in node:
            walk(item, depth + 1)

if isinstance(payload, dict):
    walk(payload)
else:
    print(payload)
