"""列出飞书机器人所在的群，找到「ipa发布」那个群，并抓最近消息里的图片/视频。

凭据来源（不打印）：D:\\Projects\\Private_music\\.lark\\secret.env 的 LARK_APP_ID / LARK_APP_SECRET，
缺失则回落到 .lark\\config.json 的 app_id。
"""
import json
import os
import sys
import urllib.parse
import urllib.request

BASE = "https://open.feishu.cn/open-apis"
ROOT = r"D:\Projects\Private_music"


def load_creds():
    app_id = os.environ.get("LARK_APP_ID")
    app_secret = os.environ.get("LARK_APP_SECRET")
    env = os.path.join(ROOT, ".lark", "secret.env")
    if os.path.exists(env):
        for line in open(env, encoding="utf-8"):
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k, v = k.strip(), v.strip().strip('"').strip("'")
            if k == "LARK_APP_ID" and not app_id:
                app_id = v
            if k == "LARK_APP_SECRET" and not app_secret:
                app_secret = v
    cfg = os.path.join(ROOT, ".lark", "config.json")
    if os.path.exists(cfg):
        c = json.load(open(cfg, encoding="utf-8"))
        app_id = app_id or c.get("app_id")
        app_secret = app_secret or c.get("app_secret")
    return app_id, app_secret


def call(url, token=None, method="GET", body=None):
    headers = {"Content-Type": "application/json; charset=utf-8"}
    if token:
        headers["Authorization"] = "Bearer " + token
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=25) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return {"_http": e.code, "_body": e.read().decode("utf-8", "replace")[:400]}


app_id, app_secret = load_creds()
print("app_id:", (app_id or "")[:12] + "…", "| secret 长度:", len(app_secret or ""))
if not app_id or not app_secret:
    print("缺凭据，退出")
    sys.exit(1)

tok = call(BASE + "/auth/v3/tenant_access_token/internal", method="POST",
           body={"app_id": app_id, "app_secret": app_secret})
print("token 响应:", {k: v for k, v in tok.items() if k != "tenant_access_token"})
token = tok.get("tenant_access_token")
if not token:
    sys.exit(2)

chats, page = [], None
while True:
    q = {"page_size": "100"}
    if page:
        q["page_token"] = page
    r = call(BASE + "/im/v1/chats?" + urllib.parse.urlencode(q), token)
    if r.get("code") != 0:
        print("列群失败:", r)
        break
    d = r.get("data") or {}
    chats.extend(d.get("items") or [])
    page = d.get("page_token")
    if not d.get("has_more"):
        break

print(f"\n机器人所在群 {len(chats)} 个：")
for c in chats:
    print(f"  {c.get('name')!r:32s} chat_id={c.get('chat_id')}  owner={c.get('owner_id','')[:10]}…  "
          f"external={c.get('external')}  desc={str(c.get('description'))[:40]}")
json.dump(chats, open(os.path.join(ROOT, "tools", "notify", "lark-chats.json"), "w",
                      encoding="utf-8"), ensure_ascii=False, indent=2)
print("\n已写 tools/notify/lark-chats.json")
