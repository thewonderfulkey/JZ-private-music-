# -*- coding: utf-8 -*-
"""把构建/交付结果发到飞书群「音乐软件开发」。

设计目标：**一次交付只发一条消息**（飞书的文件消息不能带正文，卡片也不支持文件块，
所以"文字 + APK"合成一条做不到，这里选"文件即消息、文件名带版本与主题"）。

行为：
  · 成功（有 APK，且没加 --fail）→ 只发一条**文件消息**，文件名取 --name（默认用本地文件名）
  · 失败 / 没有 APK（--fail）→ 只发一条**卡片**（红色标题 + 正文）
  · --note 显式要求时，才在文件之后再补一条说明卡（默认关闭）
  · 机器人发送失败时回退到自定义机器人 webhook（纯文本），保证消息不丢

凭据：
  app_secret 依次从 环境变量 LARK_APP_SECRET → .lark/secret.env → .lark/config.json 读取；
  app_id 同理（LARK_APP_ID）。

用法：
  python tools/notify/lark.py --title "v2.1.93 已出包" --apk releases/....apk \
      --name "JZ音乐助手-v2.1.93-识曲双通道打分.apk"
  python tools/notify/lark.py --title "v2.1.93 冒烟失败" --body "…" --fail
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
SECRET_ENV = os.path.join(ROOT, ".lark", "secret.env")
API = "https://open.feishu.cn/open-apis"


def load_config():
    # CI（GitHub Actions）里没有 .lark/ 目录：配置全部走环境变量，缺文件不报错
    cfg = {}
    if os.path.exists(CONFIG):
        with open(CONFIG, encoding="utf-8") as f:
            cfg = json.load(f)
    else:
        print(f"未找到 {CONFIG}，改用环境变量 LARK_APP_ID / LARK_APP_SECRET / LARK_CHAT_ID",
              file=sys.stderr)

    # secret 优先环境变量（不进任何文件），其次 .lark/secret.env（gitignore），最后 config（兼容旧配置）
    env_file = {}
    if os.path.exists(SECRET_ENV):
        for line in open(SECRET_ENV, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env_file[k.strip()] = v.strip()
    cfg["app_id"] = os.environ.get("LARK_APP_ID") or env_file.get("LARK_APP_ID") or cfg.get("app_id", "")
    cfg["app_secret"] = (os.environ.get("LARK_APP_SECRET") or env_file.get("LARK_APP_SECRET")
                         or cfg.get("app_secret", ""))
    cfg["chat_id"] = os.environ.get("LARK_CHAT_ID") or cfg.get("chat_id", "")
    return cfg


def post_json(url, payload, headers=None, timeout=25):
    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST",
                                 headers={"Content-Type": "application/json; charset=utf-8", **(headers or {})})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {e.code}：{detail[:400]}")


def send_webhook(cfg, text):
    url = (cfg.get("webhook") or "").strip()
    if not url:
        print("未配置 webhook，跳过文本通知", file=sys.stderr)
        return None
    resp = post_json(url, {"msg_type": "text", "content": {"text": text}})
    print("webhook:", json.dumps(resp, ensure_ascii=False)[:200])
    return resp


def tenant_token(cfg):
    if not cfg.get("app_id") or not cfg.get("app_secret"):
        raise RuntimeError("没有 app_id / app_secret（环境变量或 .lark/secret.env）")
    resp = post_json(f"{API}/auth/v3/tenant_access_token/internal",
                     {"app_id": cfg["app_id"], "app_secret": cfg["app_secret"]})
    if resp.get("code") != 0:
        raise RuntimeError(f"取 tenant_access_token 失败：{resp}")
    return resp["tenant_access_token"]


def upload_file(token, path, display_name):
    """multipart 上传，返回 file_key；display_name 决定群里看到的文件名"""
    boundary = "----JZ" + uuid.uuid4().hex
    name = display_name or os.path.basename(path)
    mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
    content = open(path, "rb").read()

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
        with urllib.request.urlopen(req, timeout=180) as r:
            resp = json.loads(r.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"上传文件 HTTP {e.code}：{e.read().decode('utf-8', 'replace')[:400]}")
    if resp.get("code") != 0:
        raise RuntimeError(f"上传文件失败：{resp}")
    return resp["data"]["file_key"]


def send_message(token, chat_id, msg_type, content):
    body = {"receive_id": chat_id, "msg_type": msg_type,
            "content": json.dumps(content, ensure_ascii=False)}
    resp = post_json(f"{API}/im/v1/messages?receive_id_type=chat_id", body,
                     headers={"Authorization": f"Bearer {token}"})
    if resp.get("code") != 0:
        raise RuntimeError(f"发消息失败：{resp}")
    return resp["data"]["message_id"]


def build_card(title, body, template="blue"):
    return {
        "config": {"wide_screen_mode": True, "enable_forward": True},
        "header": {"template": template, "title": {"tag": "plain_text", "content": title}},
        "elements": [{"tag": "div", "text": {"tag": "plain_text", "content": body or "（无正文）"}}],
    }


def ensure_bot_in_chat(token, chat_id, app_id):
    """best-effort 校验机器人已在群；飞书不允许机器人把自己拉进群（232011），只能由人添加。"""
    if not chat_id or not app_id:
        return False
    body = {"id_list": [app_id]}
    try:
        resp = post_json(f"{API}/im/v1/chats/{chat_id}/members?member_id_type=app_id", body,
                         headers={"Authorization": f"Bearer {token}"})
        return resp.get("code") == 0
    except RuntimeError as e:
        msg = str(e)
        if "232011" in msg:
            print("提示：机器人不在群。飞书不允许机器人自己进群，请在客户端：群设置 → 群机器人 → 添加机器人",
                  file=sys.stderr)
        return False


def fmt_title(title, fail):
    return ("❌ " if fail else "✅ ") + title


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--title", required=True)
    ap.add_argument("--body", default="")
    ap.add_argument("--apk", default="", help="要发的文件（apk / ipa / dmg 均可）")
    ap.add_argument("--file", dest="file", default="", help="同 --apk，语义更清楚（优先）")
    ap.add_argument("--name", default="", help="群里显示的文件名（默认用本地文件名）")
    ap.add_argument("--chat", default="", help="覆盖配置里的 chat_id")
    ap.add_argument("--fail", action="store_true", help="失败通知：发红色卡片")
    ap.add_argument("--note", action="store_true", help="文件之后再补一条说明卡（默认不发）")
    args = ap.parse_args()

    cfg = load_config()
    chat_id = args.chat or cfg.get("chat_id", "")
    title = fmt_title(args.title, args.fail)

    apk_path = args.file or args.apk
    if apk_path and not os.path.isabs(apk_path):
        apk_path = os.path.join(ROOT, apk_path)
    has_apk = bool(apk_path) and os.path.exists(apk_path) and not args.fail
    file_ext = os.path.splitext(apk_path)[1].lower() if apk_path else ""

    # 回退用的纯文本（机器人不可用时至少把结论发出去）
    fallback = title + "\n" + (args.body or "")
    if apk_path:
        fallback += f"\n文件：{args.name or os.path.basename(apk_path)}（{os.path.getsize(apk_path):,} B）" \
                    if os.path.exists(apk_path) else f"\n文件未找到：{apk_path}"

    try:
        token = tenant_token(cfg)
        ensure_bot_in_chat(token, chat_id, cfg["app_id"])

        if has_apk:
            # 一条消息 = 文件本身，文件名带版本与主题
            display = args.name or os.path.basename(apk_path)
            if file_ext and not display.lower().endswith(file_ext):
                display += file_ext
            key = upload_file(token, apk_path, display)
            mid = send_message(token, chat_id, "file", {"file_key": key})
            md5 = hashlib.md5(open(apk_path, "rb").read()).hexdigest().upper()
            print(f"file message: {mid}  name={display}  md5={md5}")
            if args.note:
                send_message(token, chat_id, "interactive",
                             build_card(title, args.body, "green"))
        else:
            # 一条消息 = 卡片（失败说明 / 无 APK）
            send_message(token, chat_id, "interactive",
                         build_card(title, args.body, "red" if args.fail else "blue"))
            print("card message sent")
    except Exception as e:
        print(f"机器人通道失败，回退 webhook：{e}", file=sys.stderr)
        send_webhook(cfg, fallback)
    print("OK")


if __name__ == "__main__":
    main()
