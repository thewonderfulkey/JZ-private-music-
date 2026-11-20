#!/bin/bash
# 只做语法解析（-parse 不解析 import，Windows/WSL 也能跑），用来兜住手写 Swift 的语法错。
export PATH=/home/zhou/swift/usr/bin:/usr/local/bin:/usr/bin:/bin
cd /mnt/d/Projects/Private_music || exit 1
FILES=(
  ios/JZMusicHelper/Services/NameMatch.swift
  ios/JZMusicHelper/Models/LibraryStore.swift
  ios/JZMusicHelper/JZMusicHelperApp.swift
  ios/JZMusicHelper/Views/LibraryView.swift
  ios/JZMusicHelper/Views/Components.swift
  ios/JZMusicHelper/Services/DownloadManager.swift
  ios/JZMusicHelper/Services/DownloadFlow.swift
  ios/JZMusicHelper/Services/DownloadLocation.swift
  ios/JZMusicHelper/Services/CoverImageCache.swift
  ios/JZMusicHelper/Models/SettingsStore.swift
  ios/JZMusicHelper/Views/DownloadsTabView.swift
  ios/JZMusicHelper/Views/SettingsView.swift
  ios/SelfTest/main.swift
)
fail=0
for f in "${FILES[@]}"; do
  out=$(swiftc -parse "$f" 2>&1)
  if [ -z "$out" ]; then
    printf "OK    %s\n" "$f"
  else
    printf "FAIL  %s\n" "$f"
    echo "$out" | head -6
    fail=1
  fi
done
echo "PARSE_FAIL=$fail"
exit $fail
