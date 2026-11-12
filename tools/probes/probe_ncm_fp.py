# -*- coding: utf-8 -*-
"""用网易自家 afp 引擎（aplayer 项目的 wasm + sandbox 包）离线生成指纹，再打网易 audio/match"""
import base64, json, os, struct, subprocess, sys, urllib.parse, urllib.request

BASE = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build"
AFP = os.path.join(BASE, "afp")
FFMPEG = os.path.join(BASE, "bin", "ffmpeg.exe")
MP3 = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\sunny_day_test\results\kuwo_51685512_320k.mp3"

raw = os.path.join(BASE, "ncm_48k.pcm")
subprocess.run([FFMPEG, "-y", "-v", "error", "-ss", "30", "-t", "12", "-i", MP3,
                "-ac", "1", "-ar", "48000", "-f", "f32le", raw], check=True)
data = open(raw, "rb").read()
samples = struct.unpack("<%df" % (len(data) // 4), data)
pcm8k = samples[::6]
print(f"48k 样本 {len(samples)} → 8k 样本 {len(pcm8k)}")

pcm_b64 = base64.b64encode(struct.pack("<%df" % len(pcm8k), *pcm8k)).decode()
print("PCM base64 长度:", len(pcm_b64))

from py_mini_racer import MiniRacer

PRELUDE = r"""
globalThis.window = globalThis;
globalThis.self = globalThis;
globalThis.document = {
  createElement: function(){ return { style:{}, appendChild:function(){}, setAttribute:function(){} }; },
  body:{ appendChild:function(){}, removeChild:function(){} },
  head:{ appendChild:function(){} },
  addEventListener:function(){}, removeEventListener:function(){}, readyState:'complete'
};
globalThis.atob = function (b64) {
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  b64 = String(b64).replace(/[^A-Za-z0-9+\/=]/g, '');
  var out = '', i = 0, c1, c2, c3, c4;
  while (i < b64.length) {
    c1 = B64.indexOf(b64.charAt(i++)); c2 = B64.indexOf(b64.charAt(i++));
    c3 = B64.indexOf(b64.charAt(i++)); c4 = B64.indexOf(b64.charAt(i++));
    out += String.fromCharCode((c1 << 2) | (c2 >> 4));
    if (c3 !== -1) out += String.fromCharCode(((c2 & 15) << 4) | (c3 >> 2));
    if (c4 !== -1) out += String.fromCharCode(((c3 & 3) << 6) | c4);
  }
  return out;
};
globalThis.btoa = function (s) {
  var B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var out = '', i, c1, c2, c3;
  for (i = 0; i < s.length; i += 3) {
    c1 = s.charCodeAt(i); c2 = s.charCodeAt(i+1); c3 = s.charCodeAt(i+2);
    out += B64.charAt(c1 >> 2) + B64.charAt(((c1 & 3) << 4) | ((c2 || 0) >> 4));
    out += isNaN(c2) ? '=' : (B64.charAt(((c2 & 15) << 2) | ((c3 || 0) >> 6)) +
          (isNaN(c3) ? '=' : B64.charAt(c3 & 63)));
  }
  return out;
};
globalThis.TextDecoder = function(){ this.decode = function(u8){ return decodeURIComponent(escape(String.fromCharCode.apply(null, u8))); }; };
globalThis.TextEncoder = function(){ this.encode = function(s){ return Uint8Array.from(unescape(encodeURIComponent(s)).split('').map(function(c){return c.charCodeAt(0);})); }; };
globalThis.performance = { now: function(){ return Date.now(); } };
globalThis.crypto = {
  getRandomValues: function (arr) {
    for (var i = 0; i < arr.length; i++) { arr[i] = Math.floor(Math.random() * 256); }
    return arr;
  }
};
globalThis.navigator = { userAgent: 'Mozilla/5.0 Chrome/124.0.0.0 Safari/537.36', platform: 'Win32' };
globalThis.location = { href: 'file:///android_asset/recognizer.html', protocol: 'file:' };
globalThis.__timers = [];
globalThis.setTimeout = function (fn) { globalThis.__timers.push(fn); return globalThis.__timers.length; };
globalThis.setInterval = function (fn) { globalThis.__timers.push(fn); return globalThis.__timers.length; };
globalThis.requestAnimationFrame = function (fn) { globalThis.__timers.push(function(){ fn(Date.now()); }); return globalThis.__timers.length; };
globalThis.fetch = function () { return Promise.reject(new Error('no fetch in probe')); };
globalThis.clearInterval = function () {};
globalThis.clearTimeout = function () {};
"""

ctx = MiniRacer()
ctx.eval(PRELUDE)
for name in ("afp_wasm_b64.js", "sandbox.bundle.js"):
    src = open(os.path.join(AFP, name), encoding="utf-8", errors="replace").read()
    print(f"加载 {name} ({len(src)} 字符)...")
    try:
        ctx.eval(src, timeout=120)
    except Exception as e:
        print("  载入异常:", type(e).__name__, str(e)[:300])
        sys.exit(1)

print("__NCM__:", ctx.eval("typeof globalThis.__NCM__"))
print("processor:", ctx.eval("typeof globalThis.processor"))

expr = f"""
globalThis.__fp = null; globalThis.__err = null;
window.__NCM__.encodePcm8kB64({json.dumps(pcm_b64)})
  .then(function(fp) {{ globalThis.__fp = String(fp); }})
  .catch(function(e) {{ globalThis.__err = String((e && e.message) || e); }});
"""
ctx.eval(expr, timeout=180)

fp = None
for i in range(240):
    # 手动跑掉排队中的 setTimeout 回调，让 wasm 编译链推进
    try:
        ctx.eval("(function(){var n=0;while(globalThis.__timers.length && n<50){var f=globalThis.__timers.shift();try{f();}catch(e){globalThis.__err=String(e&&e.message||e);}n++;}})()", timeout=60)
    except Exception as e:
        print("timer 执行异常:", type(e).__name__, str(e)[:200])
    fp = ctx.eval("globalThis.__fp")
    err = ctx.eval("globalThis.__err")
    if fp:
        break
    if err:
        print("生成指纹失败:", err); sys.exit(1)
    __import__("time").sleep(0.3)
else:
    print("等待指纹超时"); sys.exit(1)

fp = str(fp)
print("指纹长度:", len(fp), "前 60:", fp[:60])

url = "https://interface.music.163.com/api/music/audio/match"
form = urllib.parse.urlencode({
    "sessionId": "441df692-afea-4a54-8aff-f5f20fd34f12",
    "algorithmCode": "shazam_v2", "duration": "12",
    "rawdata": fp, "times": "2", "decrypt": "1",
}).encode()
req = urllib.request.Request(url, data=form, method="POST", headers={
    "user-agent": ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
                   "Chrome/124.0.0.0 Safari/537.36"),
    "accept": "application/json",
    "content-type": "application/x-www-form-urlencoded; charset=UTF-8",
    "origin": "chrome-extension://pgphbbekcgpfaekhcbjamjjkegcclhhd",
})
body = urllib.request.urlopen(req, timeout=25).read().decode("utf-8", "replace")
j = json.loads(body)
print("网易 code:", j.get("code"), "noMatchReason:", (j.get("data") or {}).get("noMatchReason"))
for it in ((j.get("data") or {}).get("result") or [])[:5]:
    s = it.get("song") or {}
    print("  命中:", s.get("name"), "/", "/".join(a.get("name", "") for a in (s.get("artists") or [])),
          "| 专辑:", (s.get("album") or {}).get("name"), "| 时长(ms):", s.get("duration"))
if not ((j.get("data") or {}).get("result") or []):
    print("  原始返回:", body[:300])
