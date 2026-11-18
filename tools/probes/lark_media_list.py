# -*- coding: utf-8 -*-
"""列出飞书群「音乐软件开发」最近的媒体消息（图片/视频/文件），用于取老板发的网易云录屏。

只读：GET /im/v1/messages 与 resources 下载。凭据复用 tools/notify/lark.py 的加载顺序。
用法：
  python tools/probes/lark_media_list.py                # 列最近 100 条，标出媒体
  python tools/probes/lark_media_list.py --days 7
"""
import argparse
import json
import os
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
sys.path.insert(0, os.path.join(ROOT, "tools", "notify"))
import lark  # noqa: E402

API = "https://open.feishu.cn/open-apis"


def get(url, token, raw=False):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            data = r.read()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"HTTP {e.code} {url}\n{e.read().decode('utf-8', 'replace')[:600]}")
    return data if raw else json.loads(data.decode("utf-8"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=float, default=10)
    ap.add_argument("--page-size", type=int, default=50)
    args = ap.parse_args()

    cfg = lark.load_config()
    token = lark.tenant_token(cfg)
    chat = cfg["chat_id"]
    start = int((time.time() - args.days * 86400) * 1000)
    page_token = ""
    rows = []
    for _ in range(6):
        url = (f"{API}/im/v1/messages?container_id_type=chat&container_id={chat}"
               f"&start_time={start}&sort_type=ByCreateTimeDesc&page_size={args.page_size}")
        if page_token:
            url += f"&page_token={page_token}"
        resp = get(url, token)
        if resp.get("code") != 0:
            print("ERR", json.dumps(resp, ensure_ascii=False)[:500])
            return 2
        data = resp.get("data", {})
        rows.extend(data.get("items", []))
        if not data.get("has_more"):
            break
        page_token = data.get("page_token", "")
        if not page_token:
            break

    print(f"messages={len(rows)} chat={chat}")
    for m in rows:
        mt = m.get("msg_type")
        body = m.get("body", {}).get("content", "")
        try:
            content = json.loads(body)
        except Exception:
            content = body[:120]
        ts = time.strftime("%m-%d %H:%M", time.localtime(int(m.get("create_time", "0")) / 1000))
        tag = "MEDIA" if mt in ("media", "image", "file", "audio") else "     "
        print(f"{tag} {ts} {m.get('message_id')} {mt} {json.dumps(content, ensure_ascii=False)[:160]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
