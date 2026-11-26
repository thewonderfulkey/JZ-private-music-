# -*- coding: utf-8 -*-
"""把新的 Swift 文件登记进手写的 Xcode 工程（pbxproj 要四处登记）。

用法：
    python tools/dev/register_pbxproj.py ios/JZMusicHelper/Views/DiscoverBanner.swift

四处：PBXBuildFile / PBXFileReference / group children / Sources 编译阶段。

实现方式刻意用**整行字符串定位**而不是正则跨行匹配：
2026-11-27 第一版用正则，`.*?\\};` 在 CRLF 文件里把锚点那一行从中间截断，
pbxproj 里留下半行（check_pbxproj 报"被引用但没有定义"）。整行插入不会切坏任何现有条目。
"""
import io
import sys

P = r"ios/JZMusicHelper.xcodeproj/project.pbxproj"


def insert_after_line(text: str, needle: str, line: str, nl: str) -> str:
    """把 line 插到**包含 needle 的那一整行**后面。needle 必须唯一。"""
    idx = text.find(needle)
    if idx < 0:
        raise SystemExit(f"找不到锚点：{needle}")
    if text.find(needle, idx + 1) >= 0:
        raise SystemExit(f"锚点不唯一：{needle}")
    end = text.find(nl, idx)
    if end < 0:
        raise SystemExit(f"锚点行没有换行：{needle}")
    end += len(nl)
    return text[:end] + line + nl + text[end:]


def main() -> int:
    if len(sys.argv) < 2:
        print("用法: register_pbxproj.py <swift 文件路径>")
        return 2
    path = sys.argv[1].replace("\\", "/")
    name = path.rsplit("/", 1)[-1]
    parts = path.split("/")
    parent = parts[-2] if len(parts) >= 2 else ""

    s = io.open(P, encoding="utf-8", newline="").read()
    if f"/* {name} */ = {{isa = PBXFileReference" in s:
        print(f"{name} 已登记，跳过")
        return 0

    nl = "\r\n" if "\r\n" in s else "\n"

    # 选同组里最后一个兄弟文件当锚点（按 children 列表顺序）
    gstart = s.find(f"/* {parent} */ = {{")
    if gstart < 0:
        print(f"找不到 {parent} 组")
        return 1
    gc = s.find("children = (", gstart)
    ge = s.find(");", gc)
    block = s[gc:ge]
    sibs = []
    for raw in block.split(nl):
        line = raw.strip()
        if not line.endswith(","):
            continue
        head = line.split(" ", 1)[0]
        if len(head) == 24 and head[0] in "FB":
            if "/*" in line and "*/" in line:
                sibs.append((head, line.split("/*", 1)[1].split("*/", 1)[0].strip()))
    if not sibs:
        print(f"{parent} 组里没有可当锚点的兄弟文件")
        return 1
    anchor_fid, anchor_name = sibs[-1]

    bm_needle = f"/* {anchor_name} in Sources */ = {{isa = PBXBuildFile; fileRef = {anchor_fid} /*"
    bm = s.find(bm_needle)
    if bm < 0:
        print(f"找不到 {anchor_name} 的 PBXBuildFile 条目")
        return 1
    bstart = s.rfind(nl, 0, bm) + len(nl)
    anchor_bid = s[bstart:].split(" ", 1)[0].strip()

    ids = set()
    for token in s.replace("{", " ").replace("}", " ").replace(";", " ").split():
        if len(token) == 24 and token[0] in "FB" and all(c in "0123456789ABCDEF" for c in token[1:]):
            ids.add(token)
    fid = "F" + format(max(int(i[1:], 16) for i in ids if i[0] == "F") + 1, "023X")
    bid = "B" + format(max(int(i[1:], 16) for i in ids if i[0] == "B") + 1, "023X")

    # 1) PBXBuildFile（锚在锚点那条 build 行之后）
    s = insert_after_line(
        s, bm_needle,
        "\t\t" + bid + " /* " + name + " in Sources */ = {isa = PBXBuildFile; fileRef = "
        + fid + " /* " + name + " */; };", nl)

    # 2) PBXFileReference
    s = insert_after_line(
        s, f"/* {anchor_name} */ = {{isa = PBXFileReference;",
        "\t\t" + fid + " /* " + name + " */ = {isa = PBXFileReference; "
        "lastKnownFileType = sourcecode.swift; path = " + name
        + "; sourceTree = \"<group>\"; };", nl)

    # 3) group children
    s = insert_after_line(s, f"\t\t\t\t{anchor_fid} /* {anchor_name} */,",
                          "\t\t\t\t" + fid + " /* " + name + " */,", nl)

    # 4) Sources 编译阶段
    s = insert_after_line(s, f"\t\t\t\t{anchor_bid} /* {anchor_name} in Sources */,",
                          "\t\t\t\t" + bid + " /* " + name + " in Sources */,", nl)

    io.open(P, "w", encoding="utf-8", newline="").write(s)
    print(f"已登记 {name}：fileRef={fid} build={bid}（组 {parent}，锚点 {anchor_name}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
