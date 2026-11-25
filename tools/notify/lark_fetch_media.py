"""把飞书群里的一条 media（录屏）抓下来 —— 走 Range 分块，绕开 234037「Downloaded file size exceeds limit」。

背景（2026-11-25 实测）：
  - 飞书 `im/v1/messages/{id}/resources/{key}?type=file` 一次性下载超过 ~100MB 会回
    HTTP 400 `{"code":234037,"msg":"Downloaded file size exceeds limit."}`；
  - 但同一 URL **支持 Range**（`Range: bytes=0-1023` → 206 + `Content-Range: bytes 0-1023/109135993`），
    所以按块拉全量即可；
  - `type=media` 对本 app 回 `234001 Invalid request param`，视频必须用 `type=file`。

用法：
  python tools/notify/lark_fetch_media.py --msg <message_id> [--out <目标路径.mov>]
  python tools/notify/lark_fetch_media.py --latest        # 自动取群里最新一条 media
"""
import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.request

BASE = "https://open.feishu.cn/open-apis"
ROOT = r"D:\Projects\Private_music"
CHUNK = 8 << 20  # 8MB


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


def token_of(app_id, app_secret):
    req = urllib.request.Request(
        BASE + "/auth/v3/tenant_access_token/internal",
        data=json.dumps({"app_id": app_id, "app_secret": app_secret}).encode(),
        headers={"Content-Type": "application/json; charset=utf-8"}, method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())["tenant_access_token"]


def recent_media(chat, token, limit=20):
    import urllib.parse
    q = urllib.parse.urlencode({"container_id_type": "chat", "container_id": chat,
                                "sort_type": "ByCreateTimeDesc", "page_size": str(limit)})
    req = urllib.request.Request(BASE + "/im/v1/messages?" + q,
                                headers={"Authorization": "Bearer " + token})
    with urllib.request.urlopen(req, timeout=30) as r:
        items = json.loads(r.read().decode())["data"]["items"]
    out = []
    for m in items:
        if m.get("msg_type") != "media":
            continue
        c = json.loads(m["body"]["content"])
        ts = time.strftime("%m-%d %H:%M:%S", time.localtime(int(m["create_time"]) / 1000))
        out.append({"id": m["message_id"], "key": c.get("file_key"),
                    "name": c.get("file_name") or "clip.mov",
                    "dur_ms": c.get("duration"), "time": ts})
    return out


def fetch(msg, key, token, out):
    url = f"{BASE}/im/v1/messages/{msg}/resources/{key}?type=file"
    # 先问一次总长
    h = {"Authorization": "Bearer " + token, "Range": "bytes=0-0"}
    with urllib.request.urlopen(urllib.request.Request(url, headers=h), timeout=60) as r:
        cr = r.headers.get("Content-Range") or ""
        total = int(cr.rsplit("/", 1)[-1]) if "/" in cr else 0
    print(f"总长 = {total} B ({total / 1048576:.1f} MB)，按 {CHUNK >> 20}MB 分块")
    done = os.path.getsize(out) if os.path.exists(out) else 0
    if done >= total:
        print("已完整，跳过")
        return os.path.getsize(out)
    mode = "ab" if done else "wb"
    with open(out, mode) as f:
        pos = done
        while pos < total:
            end = min(pos + CHUNK - 1, total - 1)
            hh = {"Authorization": "Bearer " + token, "Range": f"bytes={pos}-{end}"}
            got = 0
            for attempt in range(4):
                try:
                    with urllib.request.urlopen(urllib.request.Request(url, headers=hh), timeout=300) as r:
                        blob = r.read()
                    got = len(blob)
                    if got == 0:
                        raise IOError("empty chunk")
                    f.write(blob)
                    f.flush()
                    break
                except (urllib.error.HTTPError, urllib.error.URLError, IOError) as e:
                    print(f"\n  块 {pos}-{end} 第 {attempt + 1} 次失败：{e}")
                    time.sleep(1.5 * (attempt + 1))
                    f.seek(0, os.SEEK_END)
            else:
                raise RuntimeError(f"块 {pos}-{end} 反复失败")
            pos += got
            print(f"\r  {pos}/{total} B ({pos * 100.0 / total:5.1f}%)", end="", flush=True)
    print()
    return os.path.getsize(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--msg")
    ap.add_argument("--latest", action="store_true")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--out")
    a = ap.parse_args()

    app_id, app_secret, chat = creds()
    token = token_of(app_id, app_secret)
    medias = recent_media(chat, token)
    if a.list or not (a.msg or a.latest):
        for m in medias:
            print(f"{m['id']}  {m['time']}  {m['name']}  dur={m['dur_ms']}ms  {m['key']}")
        return 0
    pick = medias[0] if a.latest else next((m for m in medias if m["id"] == a.msg), None)
    if not pick:
        print("没找到这条消息")
        return 2
    out = a.out or os.path.join(ROOT, "tools", "notify", "inbox",
                                f"media_{pick['id'][-8:]}_{pick['name'].replace(' ', '_')}")
    print(f"抓 {pick['time']} {pick['name']} dur={pick['dur_ms']}ms → {out}")
    n = fetch(pick["id"], pick["key"], token, out)
    print(f"完成：{n} B")
    return 0


if __name__ == "__main__":
    sys.exit(main())
