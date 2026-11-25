#!/bin/bash
# 只做语法检查（-parse）：快、不依赖 UIKit
cd /mnt/d/Projects/Private_music || exit 1
SW=/home/zhou/swift/usr/bin/swiftc
for f in \
  ios/JZMusicHelper/Services/PlaybackRules.swift \
  ios/JZMusicHelper/Services/PlaybackCache.swift \
  ios/JZMusicHelper/Services/AudioPlayer.swift \
  ios/JZMusicHelper/Models/SettingsStore.swift \
  ios/JZMusicHelper/Views/SettingsView.swift \
  ios/SelfTest/main.swift ; do
  OUT=$($SW -parse "$f" 2>&1)
  if [ -n "$OUT" ]; then
    echo "== $f"
    echo "$OUT" | head -15
  else
    echo "ok $f"
  fi
done
