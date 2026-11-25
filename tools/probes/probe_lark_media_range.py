"""探测飞书 media 资源取文件的限制：类型 / Range / 分块，能否绕过 234037 体积上限。

用法：python tools/probes/probe_lark_media_range.py <message_id> [<file_key>]
不带 file_key 就自己查。
"""
import json
import os
import sys
import urllib.error
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


def main():
    msg = sys.argv[1]
    key = sys.argv[2] if len(sys.argv) > 2 else None
    app_id, app_secret, chat = creds()
    req = urllib.request.Request(
        BASE + "/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(),
        headers={"Content-Type": "application/json; charset=utf-8"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        token = json.loads(r.read().decode())["tenant_access_token"]

    if not key:
        q = urllib.parse.urlencode({"container_id_type": "chat", "container_id": chat,
                                    "sort_type": "ByCreateTimeDesc", "page_size": "20"})
        rq = urllib.request.Request(BASE + "/im/v1/messages?" + q,
                                    headers={"Authorization": "Bearer " + token})
        with urllib.request.urlopen(rq, timeout=30) as r:
            data = json.loads(r.read().decode())
        for m in data["data"]["items"]:
            if m["message_id"] == msg:
                key = json.loads(m["body"]["content"])["file_key"]
    print("file_key =", key)

    for typ in ("file", "media"):
        for rng in (None, "bytes=0-1023"):
            url = f"{BASE}/im/v1/messages/{msg}/resources/{key}?type={typ}"
            h = {"Authorization": "Bearer " + token}
            if rng:
                h["Range"] = rng
            rq = urllib.request.Request(url, headers=h)
            try:
                with urllib.request.urlopen(rq, timeout=120) as r:
                    body = r.read()
                    print(f"type={typ:5s} range={rng} -> {r.status} "
                          f"len={len(body)} cr={r.headers.get('Content-Range')} "
                          f"cl={r.headers.get('Content-Length')}")
            except urllib.error.HTTPError as e:
                print(f"type={typ:5s} range={rng} -> HTTP {e.code} "
                      f"{e.read().decode('utf-8', 'replace')[:200]}")


if __name__ == "__main__":
    main()
