#!/bin/bash
# 只做语法解析（-parse 不解析 import 背后的模块，所以 AVFoundation/UIKit 也能过）
# 用途：本机先把语法错误挑出来，别等 CI 那十几分钟。
export PATH=/home/zhou/swift/usr/bin:$PATH
cd /mnt/d/Projects/Private_music || exit 1
FILES=(
  ios/JZMusicHelper/Services/AudioPlayer.swift
  ios/JZMusicHelper/Views/NowPlayingView.swift
  ios/JZMusicHelper/Services/PlaybackRules.swift
  ios/SelfTest/main.swift
)
fail=0
for f in "${FILES[@]}"; do
  out=$(swiftc -parse "$f" 2>&1)
  if [ -z "$out" ]; then
    printf '%-58s OK\n' "$f"
  else
    printf '%-58s FAIL\n' "$f"
    echo "$out" | head -6
    fail=1
  fi
done
exit $fail
