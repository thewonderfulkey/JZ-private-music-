#!/bin/bash
# 用 selftest-flat 的同一批源文件编一个迷你 main，只跑本轮新增断言
# （本机 WSL 的 zlib 桩跑不通，官方 SelfTest 会在歌词解密那节中止）
set -u
cd /mnt/d/Projects/Private_music || exit 1
export PATH=/home/zhou/swift/usr/bin:/usr/local/bin:/usr/bin:/bin
OUT=.build/swiftcheck/selftest-flat
if [ ! -d "$OUT" ]; then
    echo "先跑一次 .build/swiftcheck/run-selftest.sh 生成 $OUT"
    exit 2
fi
STAGE=.build/swiftcheck/r146mini
rm -rf "$STAGE"; mkdir -p "$STAGE"
for f in "$OUT"/*.swift; do
    b=$(basename "$f")
    [ "$b" = "main.swift" ] && continue
    cp "$f" "$STAGE/$b"
done
cp tools/dev/r146_mini_assertions.swift "$STAGE/main.swift"
swiftc -Onone -swift-version 5 -I .build/swiftcheck/mod -L .build/swiftcheck/mod \
    -lCompression -lCryptoKit -o "$STAGE/run" "$STAGE"/*.swift 2>&1 | tail -15
echo "BUILD_EXIT=${PIPESTATUS[0]}"
if [ -x "$STAGE/run" ]; then
    LD_LIBRARY_PATH=.build/swiftcheck/mod "$STAGE/run"
    echo "RUN_EXIT=$?"
fi
