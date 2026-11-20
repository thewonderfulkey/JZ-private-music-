#!/bin/bash
# 在 WSL 里跑 iOS 逻辑自测，并把"通过/失败/新小节"摘出来（PowerShell 里直接 grep 会被吃掉 $()）
set -u
cd /mnt/d/Projects/Private_music || exit 1
bash .build/swiftcheck/run-selftest.sh > /tmp/st.log 2>&1
echo "PASS=$(grep -c '✔' /tmp/st.log)"
echo "FAIL=$(grep -c '✗' /tmp/st.log)"
echo '--- 失败项 ---'
grep -n '✗' /tmp/st.log | head -12
echo '--- 本轮新增小节 ---'
grep -nE '内容闸门|无损兜底|后端熔断|落月 v3|多源：' /tmp/st.log
echo '--- 断言总数 ---'
grep -nE '通过|assert|条' /tmp/st.log | tail -5
