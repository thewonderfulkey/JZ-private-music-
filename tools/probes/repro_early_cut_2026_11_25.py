# -*- coding: utf-8 -*-
"""2026-11-25 · 「联网播放后半段被强行切歌」复现台

把 ios/JZMusicHelper/Services/AudioPlayer.swift 里那段**逐行搬过来**，喂真实时间线，
看它在第几秒调用 `handleTrackFinished()`（= 切下一首）。搬的是这三处：

  installTimeObserver()   每 0.5s 一拍：
      self.adoptDuration(item.duration.seconds)
      if self.durationLocked, self.isPlaying, !self.endGuardFired,
         TrackEndRules.isReached(currentTime: self.currentTime, duration: self.duration) {
              endGuardFired = true; handleTrackFinished()      // ← 切歌
      }

  adoptDuration(_:)       只认第一次：锁上之后谁都不许改
      guard !durationLocked else { return }
      guard abs(seconds - duration) > 0.2 else { durationLocked = true; return }
      duration = seconds; durationLocked = true

  TrackEndRules.isReached(currentTime:duration:)
      currentTime >= duration - 0.05

用例（时长取自本机刚测的**真实在线音频**，见 out/declared_vs_actual/result.json）：
  A 正常：锁到的数 == 真实音频长度              → 到真结尾才切（无 bug）
  B 远端首个报告是估算值、比真长短（之后播放器才修正）→ 锁死短值 → 提前 N 秒切
  C 同曲换源：换到更长的那一版，duration 没被重置   → 提前 N 秒切
  D duration 一直 indefinite（老问题那种流）        → 不锁、不切（说明这条闸门只对"报得出数"的流生效）
"""
import json
import os

TICK = 0.5
TRACK_END_TOLERANCE = 0.05
DURATION_LOCK_EPS = 0.2


def is_reached(current_time, duration):
    """PlaybackRules.TrackEndRules.isReached"""
    if not (duration == duration) or duration <= 1:      # isFinite / > 1
        return False
    if not (current_time == current_time):
        return False
    return current_time >= duration - TRACK_END_TOLERANCE


class Engine:
    """AudioPlayer 里与"到点收尾"有关的那几个字段 + 三个函数，其余照原样。"""

    def __init__(self, song_meta_sec):
        # resetProgress(): duration 先用**接口元数据**占位
        self.duration = float(song_meta_sec)
        self.durationLocked = False
        self.endGuardFired = False
        self.currentTime = 0.0
        self.isPlaying = True
        self.fired_at = None

    def adopt_duration(self, seconds):
        if not (seconds == seconds) or seconds <= 0:      # NaN / 0 → 丢弃
            return
        if self.durationLocked:
            return
        if abs(seconds - self.duration) <= DURATION_LOCK_EPS:
            self.durationLocked = True
            return
        self.duration = seconds
        self.durationLocked = True

    def tick(self, item_duration_report):
        """一个 0.5s 时间观察者回调。item_duration_report = item.duration.seconds"""
        self.adopt_duration(item_duration_report)
        if self.durationLocked and self.isPlaying and not self.endGuardFired \
                and is_reached(self.currentTime, self.duration):
            self.endGuardFired = True
            self.fired_at = self.currentTime

    def handle_track_finished(self):
        return "→ 切下一首（handleTrackFinished）"


def run_case(name, real_audio_sec, meta_sec, reports, note):
    """reports: [(t, item.duration.seconds)] —— 播放器在 t 秒时报出来的总长。"""
    e = Engine(meta_sec)
    timeline = []
    t = 0.0
    while t <= real_audio_sec + 1:
        e.currentTime = min(t, real_audio_sec)          # 播放头 = 真实播放位置（这版时钟是准的）
        report = None
        for (rt, rv) in reports:
            if rt <= t:
                report = rv
        e.tick(report)
        if e.fired_at is not None:
            break
        t = round(t + TICK, 3)
    cut = e.fired_at
    early = None if cut is None else round(real_audio_sec - cut, 2)
    print("  %-4s %-46s 锁到总长=%-8s 第 %-7s 秒切  提前 %-6s 秒%s"
          % (name, note, round(e.duration, 2) if e.duration > 0 else "0(未锁)",
             round(cut, 1) if cut is not None else "未切",
             early if early is not None else "—",
             "" if (early is None or early <= 0) else "  ← 音频还在放" ))
    return {"case": name, "real": real_audio_sec, "meta": meta_sec,
            "locked": e.duration if e.durationLocked else None,
            "cut_at": cut, "early": early, "note": note}


def main():
    here = os.path.dirname(__file__)
    data = []
    for fn in ("declared_vs_actual/result.json",):
        p = os.path.join(here, "out", fn)
        if os.path.exists(p):
            data += json.load(open(p, encoding="utf-8"))
    # 真实在线音频：取两首（QQ m4a / 网易 mp3），时长是本机 ffmpeg 解码出来的真长
    real = {}
    for r in data:
        real.setdefault(r["song"], r)
    samples = [("晴天 / Jay（在线 mp3）", 198.0135 + 71.0),  # 用稻香的真长便于说明
               ("稻香 / Jay（在线 mp3）", 198.0135)]
    # 直接用探测里最干净的一条：稻香 198.01 / 晴天 269.82
    rows = []
    print("真实在线音频（本机解码）：稻香 198.01s、QQ 晴天 269.82s —— 容器声明与真长误差 ≤0.08s\n")
    print("复算 AudioPlayer 的判定（每 0.5s 一拍）：")

    # A 正常
    rows.append(run_case("A", 198.01, 198, [(0.0, 198.01)],
                         "正常：锁到的数 == 真长"))
    # B 首个报告短、之后修正（长版本 269.8，首个报告 240）
    rows.append(run_case("B", 269.82, 270,
                         [(0.0, 240.0), (12.0, 269.82)],
                         "远端首个报告 240，14s 后修正成 269.82"))
    # B2 首个报告短 30s
    rows.append(run_case("B2", 198.01, 198,
                         [(0.0, 168.0), (10.0, 198.01)],
                         "远端首个报告 168（短 30s），10s 后修正"))
    # C 同曲换源到更长版本（歌曲真实 236.09，换源后 243.87）
    class Swap(Engine):
        pass
    e = Engine(236)
    e.adopt_duration(236.09)          # 第一条源（真长 236.09）
    # 换源：AudioPlayer.switchSourceWithinSong() → beginLoad() → start()，**不调用 resetProgress()**
    # 所以 duration / durationLocked 原样保留；新源 243.87 永远进不来
    e.adopt_duration(243.87)
    cut = None
    t = 0.0
    while t <= 243.87 + 1:
        e.currentTime = min(t, 236.09)
        e.tick(243.87)
        if e.fired_at is not None:
            cut = e.fired_at
            break
        t = round(t + TICK, 3)
    rows.append({"case": "C", "real": 243.87, "meta": 236, "locked": e.duration,
                 "cut_at": cut, "early": round(243.87 - cut, 2) if cut else None,
                 "note": "同曲换源换到更长版本，duration 没重置"})
    print("  C    同曲换源到更长版本（236.09 → 243.87）        锁到总长=%-8s 第 %-7s 秒切  提前 %-6s 秒  ← 音频还在放"
          % (round(e.duration, 2), round(cut, 1) if cut else "未切",
             round(243.87 - cut, 2) if cut else "—"))

    # D duration 一直 indefinite
    rows.append(run_case("D", 230.0, 224, [(0.0, float("nan"))],
                         "duration 一直 indefinite（老流）"))

    out = os.path.join(here, "out", "early_cut_repro.json")
    json.dump(rows, open(out, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("\n写出：", out)


if __name__ == "__main__":
    main()
