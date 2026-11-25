#!/bin/bash
# 只编 PlaybackRules.swift + 本轮迷你断言（不依赖 UIKit / AVFoundation）
set -u
cd /mnt/d/Projects/Private_music || exit 1
export PATH=/home/zhou/swift/usr/bin:/usr/local/bin:/usr/bin:/bin
STAGE=.build/swiftcheck/r251
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp ios/JZMusicHelper/Services/PlaybackCacheRules.swift "$STAGE/PlaybackCacheRules.swift"
cp tools/dev/r251_cache_assertions.swift "$STAGE/main.swift"
swiftc -Onone -swift-version 5 -o "$STAGE/run" "$STAGE"/*.swift 2>&1 | head -25
echo "BUILD_EXIT=${PIPESTATUS[0]}"
if [ -x "$STAGE/run" ]; then
    "$STAGE/run"
    echo "RUN_EXIT=$?"
fi

