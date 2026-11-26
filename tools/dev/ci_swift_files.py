# -*- coding: utf-8 -*-
"""从 CI workflow 里解析 logic-tests 的 swiftc 文件清单，一行一个。

用途：本地自测（`.build/swiftcheck/run-selftest.sh`）必须和 CI 编译同一批文件，
否则会出现「本地绿、CI 红在 cannot find X in scope」——2026-11-26 连撞两次。

注意：CI 的命令是 `swiftc ... -o build/jz-selftest \\` 然后才列文件，
所以不能用 `-o build/` 当结尾标记（那会一颗文件都抓不到），要按续行符跑。
"""
import re
import sys

WF = ".github/workflows/ios-ipa.yml"


def main() -> int:
    src = open(WF, encoding="utf-8").read()
    if "swiftc -Onone" not in src:
        print("workflow 里找不到 swiftc 段", file=sys.stderr)
        return 1
    lines = src[src.index("swiftc -Onone"):].splitlines()
    files = []
    for line in lines:
        m = re.search(r"(ios/\S+\.swift)", line)
        if m:
            files.append(m.group(1))
        # 续行符没了就是命令结束
        if not line.rstrip().endswith("\\"):
            break
    for f in files:
        print(f)
    if len(files) < 10:
        print(f"只解析到 {len(files)} 个文件，清单结构可能变了", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
