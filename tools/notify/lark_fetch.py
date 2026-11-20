"""读飞书群最近消息，把图片/视频/文件抓到本地，供后续看截图与录屏。

用法：python tools/notify/lark_fetch.py [chat_id] [--limit 30] [--out dir]
默认 chat_id 取 .lark/config.json（音乐软件开发 / IPA 交付群）。
"""
import argparse
import json
import os
import sys
import time
import urllib.parse
import urllib.request

BASE = "https://open.feishu.cn/open-apis"
ROOT = r"D:\Projects\Private_music"


def creds():
    app_id = os.environ.get("LARK_APP_ID")
    app_secret = os.environ.get("LARK_APP_SECRET")
    env = os.path.join(ROOT, ".lark", "secret.env")
    if os.path.exists(env):
        for line in open(env, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                k, v = k.strip(), v.strip().strip('"').strip("'")
                if k == "LARK_APP_ID" and not app_id:
                    app_id = v
                if k == "LARK_APP_SECRET" and not app_secret:
                    app_secret = v
    cfg = json.load(open(os.path.join(ROOT, ".lark", "config.json"), encoding="utf-8"))
    return (app_id or cfg.get("app_id")), (app_secret or cfg.get("app_secret")), cfg.get("chat_id")


def post_json(url, body, token=None):
    h = {"Content-Type": "application/json; charset=utf-8"}
    if token:
        h["Authorization"] = "Bearer " + token
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {"_http": e.code, "_body": e.read().decode("utf-8", "replace")[:400]}


def get_json(url, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return {"_http": e.code, "_body": e.read().decode("utf-8", "replace")[:400]}


def download(url, path, token):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=120) as r, open(path, "wb") as f:
            f.write(r.read())
        return os.path.getsize(path)
    except urllib.error.HTTPError as e:
        return -e.code


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chat_id", nargs="?")
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--out", default=os.path.join(ROOT, "tools", "notify", "inbox"))
    a = ap.parse_args()

    app_id, app_secret, default_chat = creds()
    chat = a.chat_id or default_chat
    tok = post_json(BASE + "/auth/v3/tenant_access_token/internal",
                    {"app_id": app_id, "app_secret": app_secret})
    token = tok.get("tenant_access_token")
    if not token:
        print("取 token 失败", tok)
        return 1
    print("chat_id =", chat)

    q = urllib.parse.urlencode({
        "container_id_type": "chat", "container_id": chat,
        "sort_type": "ByCreateTimeDesc", "page_size": str(a.limit),
    })
    r = get_json(BASE + "/im/v1/messages?" + q, token)
    if r.get("code") != 0:
        print("读消息失败：", json.dumps(r, ensure_ascii=False)[:600])
        return 2

    items = (r.get("data") or {}).get("items") or []
    os.makedirs(a.out, exist_ok=True)
    print(f"拿到 {len(items)} 条消息\n")
    manifest = []
    for m in items:
        mt = m.get("msg_type")
        ts = int(m.get("create_time") or 0) / 1000
        stamp = time.strftime("%m-%d %H:%M:%S", time.localtime(ts))
        body = m.get("body") or {}
        content = body.get("content") or "{}"
        try:
            c = json.loads(content)
        except Exception:  # noqa: BLE001
            c = {}
        sender = (m.get("sender") or {}).get("id", "")[:12]
        rec = {"id": m.get("message_id"), "type": mt, "time": stamp, "sender": sender}
        print(f"[{stamp}] {mt:10s} id={m.get('message_id')} sender={sender}")

        if mt == "text":
            print("   ", (c.get("text") or "")[:200].replace("\n", " "))
        elif mt in ("image",):
            key = c.get("image_key")
            rec["key"] = key
            dst = os.path.join(a.out, f"{stamp.replace(' ','_').replace(':','')}_{key[:8]}.png")
            url = f"{BASE}/im/v1/messages/{m['message_id']}/resources/{key}?type=image"
            n = download(url, dst, token)
            rec["path"] = dst
            print(f"    图片 → {dst} ({n} B)")
        elif mt in ("media", "file", "audio"):
            key = c.get("file_key")
            name = c.get("file_name") or (c.get("image_key") or "file")
            ext = os.path.splitext(name)[1] or (".mp4" if mt == "media" else ".bin")
            rec["key"] = key
            dst = os.path.join(a.out, f"{stamp.replace(' ','_').replace(':','')}_{str(name)[:40]}{ext}")
            kind = "file"  # 飞书：media(视频) 也要用 type=file 取
            url = f"{BASE}/im/v1/messages/{m['message_id']}/resources/{key}?type={kind}"
            n = download(url, dst, token)
            rec["path"] = dst
            extra = c.get("duration") or c.get("image_key") or ""
            print(f"    {mt} {name} → {dst} ({n} B) {extra}")
        elif mt == "post":
            txt = json.dumps(c, ensure_ascii=False)
            print("    富文本:", txt[:300])
        elif mt == "interactive":
            print("    卡片:", json.dumps(c, ensure_ascii=False)[:200])
        manifest.append(rec)

    json.dump(manifest, open(os.path.join(a.out, "manifest.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\nmanifest →", os.path.join(a.out, "manifest.json"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
