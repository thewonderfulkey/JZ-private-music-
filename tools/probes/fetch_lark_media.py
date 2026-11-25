"""单独把一条飞书 media 消息抓下来，并把 HTTP 错误体打出来（lark_fetch 只回 -400）。

用法：
  python tools/probes/fetch_lark_media.py --msg om_xxx [--type file|media --out xxx.mov]
不给 --msg 就列最近 5 条 media 消息的 message_id / file_key / 时长。
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
sys.path.insert(0, os.path.join(ROOT, "tools", "notify"))


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


def post_json(url, body):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json; charset=utf-8"},
                                 method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--msg")
    ap.add_argument("--type", default="file")
    ap.add_argument("--out")
    ap.add_argument("--chat", default=None)
    a = ap.parse_args()

    app_id, app_secret, chat = creds()
    chat = a.chat or chat
    token = post_json(BASE + "/auth/v3/tenant_access_token/internal",
                      {"app_id": app_id, "app_secret": app_secret})["tenant_access_token"]

    if not a.msg:
        q = urllib.parse.urlencode({"container_id_type": "chat", "container_id": chat,
                                    "sort_type": "ByCreateTimeDesc", "page_size": "20"})
        req = urllib.request.Request(BASE + "/im/v1/messages?" + q,
                                     headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(req, timeout=30) as r:
            data = json.loads(r.read().decode())
        for m in data["data"]["items"]:
            if m.get("msg_type") != "media":
                continue
            c = json.loads(m["body"]["content"])
            ts = time.strftime("%m-%d %H:%M:%S", time.localtime(int(m["create_time"]) / 1000))
            print(m["message_id"], ts, c.get("file_key"), c.get("file_name"),
                  "dur_ms=", c.get("duration"))
        return 0

    key = None
    q = urllib.parse.urlencode({"container_id_type": "chat", "container_id": chat,
                                "sort_type": "ByCreateTimeDesc", "page_size": "20"})
    req = urllib.request.Request(BASE + "/im/v1/messages?" + q,
                                 headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=30) as r:
        data = json.loads(r.read().decode())
    name = "clip.mov"
    for m in data["data"]["items"]:
        if m["message_id"] == a.msg:
            c = json.loads(m["body"]["content"])
            key = c.get("file_key")
            name = c.get("file_name") or name
    if not key:
        print("找不到该 message_id 的 file_key")
        return 2

    url = f"{BASE}/im/v1/messages/{a.msg}/resources/{key}?type={a.type}"
    out = a.out or os.path.join(ROOT, "tools", "notify", "inbox", f"dl_{a.msg[-8:]}_{name}")
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(req, timeout=600) as r, open(out, "wb") as f:
            total = 0
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                f.write(chunk)
                total += len(chunk)
                print(f"\r  {total} B", end="", flush=True)
        print(f"\nOK → {out} ({os.path.getsize(out)} B)")
        return 0
    except urllib.error.HTTPError as e:
        print("HTTP", e.code, e.read().decode("utf-8", "replace")[:600])
        return 1


if __name__ == "__main__":
    sys.exit(main())
