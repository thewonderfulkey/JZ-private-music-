# -*- coding: utf-8 -*-
"""把构建/交付结果发到飞书群「音乐软件开发」。

两种模式（自动选择）：
  1) 只配了 webhook（自定义机器人）→ 发文本消息（含版本、体积、MD5、说明、APK 路径）
  2) 同时配了 app_id / app_secret（自建应用，需 im:message + im:resource 权限，且机器人已进群）
     → 先上传 APK 作为文件消息，再补一条文本说明

用法：
  python tools/notify/lark.py --title "v2.1.92 已出包" --body "改了什么…" \
      --apk releases/JZ音乐助手-v2.1.92.apk
  python tools/notify/lark.py --title "构建失败" --body "错误摘要…" --fail
"""
import argparse
import hashlib
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.request
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CONFIG = os.path.join(ROOT, ".lark", "config.json")
API = "https://open.feishu.cn/open-apis"


def load_config():
    if not os.path.exists(CONFIG):
        print(f"缺少配置文件：{CONFIG}", file=sys.stderr)
        sys.exit(2)
    with open(CONFIG, encoding="utf-8") as f:
        return json.load(f)


def post_json(url, payload, headers=None, timeout=25):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json; charset=utf-8", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode("utf-8"))


def send_webhook(cfg, text):
    url = cfg.get("webhook", "").strip()
    if not url:
        print("未配置 webhook，跳过文本通知", file=sys.stderr)
        return None
    resp = post_json(url, {"msg_type": "text", "content": {"text": text}})
    print("webhook:", json.dumps(resp, ensure_ascii=False))
    code = resp.get("code", resp.get("StatusCode", 0))
    if code not in (0, None):
        raise RuntimeError(f"webhook 返回异常：{resp}")
    return resp


def tenant_token(cfg):
    """自建应用：换取 tenant_access_token（有效期 2h，这里不缓存）"""
    body = {"app_id": cfg["app_id"], "app_secret": cfg["app_secret"]}
    resp = post_json(f"{API}/auth/v3/tenant_access_token/internal", body)
    if resp.get("code") != 0:
        raise RuntimeError(f"取 tenant_access_token 失败：{resp}")
    return resp["tenant_access_token"]


def upload_file(token, path):
    """multipart 上传 APK，返回 file_key"""
    boundary = "----JZ" + uuid.uuid4().hex
    name = os.path.basename(path)
    mime = mimetypes.guess_type(name)[0] or "application/vnd.android.package-archive"
    with open(path, "rb") as f:
        content = f.read()

    def field(k, v):
        return (f"--{boundary}\r\nContent-Disposition: form-data; name=\"{k}\"\r\n\r\n{v}\r\n").encode()

    body = b""
    body += field("file_type", "stream")
    body += field("file_name", name)
    body += (f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"{name}\"\r\n"
             f"Content-Type: {mime}\r\n\r\n").encode()
    body += content + b"\r\n"
    body += f"--{boundary}--\r\n".encode()

    req = urllib.request.Request(
        f"{API}/im/v1/files", data=body, method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": f"multipart/form-data; boundary={boundary}"})
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            resp = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"上传文件 HTTP {e.code}：{body}")
    if resp.get("code") != 0:
        raise RuntimeError(f"上传文件失败：{resp}")
    return resp["data"]["file_key"]


def send_message(token, chat_id, msg_type, content):
    body = {"receive_id": chat_id, "msg_type": msg_type,
            "content": json.dumps(content, ensure_ascii=False)}
    req = urllib.request.Request(
        f"{API}/im/v1/messages?receive_id_type=chat_id",
        data=json.dumps(body).encode("utf-8"), method="POST",
        headers={"Authorization": f"Bearer {token}",
                 "Content-Type": "application/json; charset=utf-8"})
    with urllib.request.urlopen(req, timeout=30) as r:
        resp = json.loads(r.read().decode("utf-8"))
    if resp.get("code") != 0:
        raise RuntimeError(f"发消息失败：{resp}")
    return resp["data"]["message_id"]


def fmt(text):
    return text.replace("\r\n", "\n").strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--body", default="")
    ap.add_argument("--apk", default="")
    ap.add_argument("--chat", default="", help="覆盖配置里的 chat_id")
    ap.add_argument("--fail", action="store_true", help="失败通知（标题加 ❌）")
    args = ap.parse_args()

    cfg = load_config()
    chat_id = args.chat or cfg.get("chat_id", "")

    apk_info = ""
    apk_path = args.apk
    if apk_path:
        if not os.path.isabs(apk_path):
            apk_path = os.path.join(ROOT, apk_path)
        if os.path.exists(apk_path):
            size = os.path.getsize(apk_path)
            md5 = hashlib.md5(open(apk_path, "rb").read()).hexdigest().upper()
            apk_info = (f"\nAPK：{os.path.basename(apk_path)}\n"
                        f"体积：{size:,} B\nMD5：{md5}\n"
                        f"路径：{apk_path}")
        else:
            apk_info = f"\nAPK 未找到：{apk_path}"

    head = ("❌ " if args.fail else "✅ ") + args.title
    text = fmt(f"{head}\n{args.body}{apk_info}\n"
               f"— 自动发送 · {cfg.get('chat_name', '')}")

    sent_file = False
    if apk_path and os.path.exists(apk_path) and cfg.get("app_id") and cfg.get("app_secret"):
        try:
            token = tenant_token(cfg)
            key = upload_file(token, apk_path)
            msg_id = send_message(token, chat_id, "file", {"file_key": key})
            print("file message:", msg_id)
            sent_file = True
        except Exception as e:
            print(f"文件发送失败（回退到纯文本）：{e}", file=sys.stderr)

    if not sent_file and apk_path:
        text += "\n（未配置应用凭据，APK 未随消息发送）"

    send_webhook(cfg, text)
    print("OK")


if __name__ == "__main__":
    main()
