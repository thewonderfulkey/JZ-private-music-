import array, base64, hashlib, json, ssl, struct, time, urllib.parse, urllib.request, wave

SALT = "LnT6xpN3khm36zse0QzvmgTZ3waWdRSA"
ENDPOINT = "https://gateway.kugou.com/fingerprint.service/v1/music_trackid_mulit"
WAV = r"C:\Users\17948\DoubaoWork\chats\2026-10-22\new-chat-1\_tmp_build\sh_10s_0.wav"
OUT = r"C:\Users\17948\Documents\deepseek-harness\default-workspace\scratch\kugou_晴天_real.json"


def to_8k(path, seconds=10, offset=44, rate=44100):
    raw = open(path, "rb").read()[offset: offset + rate * 2 * seconds]
    a = array.array("h"); a.frombytes(raw)
    n_out = int(len(a) * 8000 / rate)
    step = rate / 8000.0
    out = array.array("h", bytes(2 * n_out))
    for i in range(n_out):
        x = i * step
        i0 = int(x)
        frac = x - i0
        i1 = min(i0 + 1, len(a) - 1)
        out[i] = int(a[i0] * (1 - frac) + a[i1] * frac)
    out = out[: seconds * 8000]
    peak = max(1, max(abs(v) for v in out))
    gain = (0.7 * 32767) / peak
    if gain > 1.0:
        out = array.array("h", [max(-32768, min(32767, int(v * gain))) for v in out])
    return out.tobytes()


def call(pcm):
    now = int(time.time() * 1000)
    mid = hashlib.md5(str(now).encode()).hexdigest()
    params = {
        "fpid": str(now), "area_code": "1", "include_unpublish": "1",
        "useid": "0", "multi_result": "1", "dfid": "-", "mid": mid, "uuid": "-",
        "appid": "3116", "clientver": "11070", "clienttime": str(now // 1000),
    }
    joined = "".join(f"{k}={v}" for k, v in sorted(params.items()))
    md = hashlib.md5()
    md.update(SALT.encode()); md.update(joined.encode()); md.update(pcm); md.update(SALT.encode())
    q = urllib.parse.urlencode(sorted(params.items())) + "&signature=" + md.hexdigest()
    req = urllib.request.Request(ENDPOINT + "?" + q, data=pcm, method="POST",
                                 headers={"User-Agent": "KuGou/11490 (Android)", "mid": mid,
                                          "dfid": "-", "Content-Type": "application/octet-stream"})
    with urllib.request.urlopen(req, timeout=25, context=ssl.create_default_context()) as r:
        return json.loads(r.read().decode("utf-8", "replace"))


pcm = to_8k(WAV)
print("pcm bytes", len(pcm), "sec", len(pcm) / 16000)
root = call(pcm)
print("code", root.get("error_code"), "n", len(root.get("data") or []))
for i, it in enumerate(root.get("data") or []):
    al = (it.get("album") or [{}])[0]
    print(f"[{i}] {it.get('songname')} / {it.get('singername')} / is_original={it.get('is_original')} / "
          f"album={al.get('albumname')} / tl320={it.get('timelength_320')} / FpHit={it.get('FpHit')} / "
          f"PeakHit={it.get('PeakHit')} / db_from={it.get('db_from')}")
json.dump(root, open(OUT, "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print("saved", OUT)

