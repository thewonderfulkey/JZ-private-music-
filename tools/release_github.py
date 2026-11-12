# -*- coding: utf-8 -*-
"""用 GitHub REST API 建 Release 并上传资产（本机 git push 已可用，但 Release 只能走 API）。

环境变量：
  GH_TOKEN  必填，PAT（repo 权限）
  GH_REPO   owner/repo
用法：
  python tools/release_github.py --tag v2.1.95 --name "第六版 v2.1.95（…）" --body-file docs/changelog/note_v2195.md --asset releases/xxx.apk --asset .build/xxx.zip
"""
import argparse
import json
import mimetypes
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"


def call(method, url, token, body=None, raw=None, content_type=None):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28",
               "User-Agent": "JZ-release-script"}
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=300) as r:
            return r.status, json.loads(r.read().decode() or "{}")
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")
        raise RuntimeError(f"HTTP {e.code} {url}\n{detail[:800]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True)
    ap.add_argument("--name", required=True)
    ap.add_argument("--body-file", required=True)
    ap.add_argument("--asset", action="append", default=[])
    ap.add_argument("--draft", action="store_true")
    args = ap.parse_args()

    token = os.environ.get("GH_TOKEN", "").strip()
    repo = os.environ.get("GH_REPO", "").strip()
    if not token or not repo:
        print("缺少 GH_TOKEN 或 GH_REPO", file=sys.stderr)
        sys.exit(2)

    body = open(args.body_file, encoding="utf-8").read()
    # 已有同 tag 的 release 就复用（幂等）
    st, rel = call("GET", f"{API}/repos/{repo}/releases/tags/{args.tag}", token) if False else (None, None)
    try:
        st, rel = call("GET", f"{API}/repos/{repo}/releases/tags/{urllib.parse.quote(args.tag)}", token)
        print(f"已存在 Release #{rel['id']}，复用")
    except RuntimeError as e:
        if "HTTP 404" not in str(e):
            raise
        st, rel = call("POST", f"{API}/repos/{repo}/releases", token, {
            "tag_name": args.tag, "name": args.name, "body": body,
            "draft": args.draft, "prerelease": False,
        })
        print(f"新建 Release #{rel['id']}  {rel['html_url']}")

    # 同名资产先删（幂等）
    st, assets = call("GET", f"{API}/repos/{repo}/releases/{rel['id']}/assets", token)
    for a in assets:
        if a["name"] in {os.path.basename(p) for p in args.asset}:
            call("DELETE", f"{API}/repos/{repo}/releases/assets/{a['id']}", token)
            print("删除旧资产", a["name"])

    for path in args.asset:
        name = os.path.basename(path)
        size = os.path.getsize(path)
        ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
        data = open(path, "rb").read()
        url = (f"https://uploads.github.com/repos/{repo}/releases/{rel['id']}/assets"
               f"?name={urllib.parse.quote(name)}")
        st, a = call("POST", url, token, raw=data, content_type=ctype)
        print(f"上传 {name}  {size:,} B  -> {a.get('browser_download_url')}")

    print("RELEASE:", rel["html_url"])


if __name__ == "__main__":
    main()
