#!/bin/bash
set -u
cd /mnt/d/Projects/Private_music || exit 1
LOG=.build/selftest-run.log
echo "PASS=$(grep -c '✔' "$LOG")"
echo "FAIL=$(grep -c '✗' "$LOG")"
echo '--- 失败项 ---'
grep -n '✗' "$LOG" | head -12
echo '--- 本轮新增小节 ---'
grep -nE '内容闸门|无损兜底|后端熔断|落月 v3|多源：' "$LOG"
echo '--- 新增小节明细（后 45 行） ---'
grep -nE '✔|✗' "$LOG" | tail -45
