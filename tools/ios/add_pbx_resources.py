"""把资源文件（html / js / wasm …）登记进手写 pbxproj 的 Resources 阶段。

为什么需要脚本：`tools/ios/add_pbx_files.py` 只处理 `.swift`（进 Sources 阶段），
资源要同时进 PBXFileReference / PBXBuildFile（in Resources）/ 分组 children / Resources 阶段的 files，
四处少一处就是"运行时找不到文件"（`Bundle.main.url` 返回 nil），而不是编译报错——很难查。

用法（在仓库根目录）：
    python tools/ios/add_pbx_resources.py Recognizer recognizer.html afp_wasm_b64.js sandbox.bundle.js

第一个参数是分组名（pbxproj 里没有就新建，path 同名）；后面是要加进该组的文件（相对 `ios/JZMusicHelper/<组名>/`）。
幂等：已登记的文件会跳过。
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")

FILE_TYPES = {
    ".html": "text.html",
    ".js": "sourcecode.javascript",
    ".json": "text.json",
    ".plist": "text.plist.xml",
    ".md": "net.daringfireball.markdown",
}


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print(__doc__)
        return 2
    group = argv[1]
    files = [f for f in argv[2:] if "." in f]
    if not files:
        print("❌ 没有给出文件")
        return 2

    src = PBX.read_text(encoding="utf-8")
    existing = set(re.findall(r"/\* ([A-Za-z0-9_.\-]+) \*/ = \{isa = PBXFileReference", src))
    todo = [f for f in files if f not in existing]
    if not todo:
        print("全部已登记，无需改动")
        return 0

    def next_id(prefix: str) -> str:
        used = {int(m, 16) for m in re.findall(rf"\b{prefix}([0-9A-F]{{23}})\b", src)}
        candidate = (max(used) + 1) if used else 1
        while f"{prefix}{candidate:023X}" in src:
            candidate += 1
        return f"{prefix}{candidate:023X}"

    build_lines = ""
    ref_lines = ""
    child_lines = ""
    phase_lines = ""

    for name in todo:
        ext = Path(name).suffix.lower()
        file_type = FILE_TYPES.get(ext, "file")
        b_id, f_id = next_id("B"), next_id("F")
        build_lines += (
            f"\t\t{b_id} /* {name} in Resources */ = "
            f"{{isa = PBXBuildFile; fileRef = {f_id} /* {name} */; }};\n"
        )
        ref_lines += (
            f"\t\t{f_id} /* {name} */ = {{isa = PBXFileReference; "
            f'lastKnownFileType = {file_type}; path = {name}; sourceTree = "<group>"; }};\n'
        )
        child_lines += f"\t\t\t\t{f_id} /* {name} */,\n"
        phase_lines += f"\t\t\t\t{b_id} /* {name} in Resources */,\n"
        src += f"\n/* reserved {b_id} {f_id} */"

    for marker, lines in (
        ("/* End PBXBuildFile section */", build_lines),
        ("/* End PBXFileReference section */", ref_lines),
    ):
        assert src.count(marker) == 1, f"{marker} 出现 {src.count(marker)} 次"
        src = src.replace(marker, lines + marker)

    # 分组：没有就新建，有就往 children 里加
    group_pattern = re.compile(
        rf"(/\* {re.escape(group)} \*/ = \{{\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\n)(.*?)(\t\t\t\);)",
        re.S,
    )
    m = group_pattern.search(src)
    if m:
        src = src[: m.end(2)] + child_lines + src[m.end(2):]
    else:
        g_id = next_id("G")
        new_group = (
            f"\t\t{g_id} /* {group} */ = {{\n"
            f"\t\t\tisa = PBXGroup;\n"
            f"\t\t\tchildren = (\n"
            f"{child_lines}"
            f"\t\t\t);\n"
            f'\t\t\tpath = {group};\n'
            f'\t\t\tsourceTree = "<group>";\n'
            f"\t\t}};\n"
        )
        # 挂到主分组（JZMusicHelper）的 children 里
        host_pattern = re.compile(
            r"(/\* JZMusicHelper \*/ = \{\s*\n\s*isa = PBXGroup;\s*\n\s*children = \(\n)(.*?)(\t\t\t\);)",
            re.S,
        )
        hm = host_pattern.search(src)
        if not hm:
            print("❌ 找不到主分组 JZMusicHelper")
            return 1
        src = src[: hm.end(2)] + f"\t\t\t\t{g_id} /* {group} */,\n" + src[hm.end(2):]
        src = src.replace("/* End PBXGroup section */", new_group + "/* End PBXGroup section */")

    # Resources 阶段
    phase_pattern = re.compile(
        r"(isa = PBXResourcesBuildPhase;\s*\n\s*buildActionMask = \d+;\s*\n\s*files = \(\n)(.*?)(\t\t\t\);\n)",
        re.S)
    pm = phase_pattern.search(src)
    if not pm:
        print("❌ 找不到 PBXResourcesBuildPhase")
        return 1
    src = src[: pm.end(2)] + phase_lines + src[pm.end(2):]

    src = re.sub(r"\n/\* reserved [BG][0-9A-F]{23} [BF][0-9A-F]{23} \*/", "", src)

    defs = re.findall(r"^\t\t([BFG][0-9A-F]{23}) /\*", src, flags=re.M)
    dup = {i for i in defs if defs.count(i) > 1}
    if dup:
        print(f"❌ ID 重复：{dup}")
        return 1

    PBX.write_text(src, encoding="utf-8")
    print(f"✓ {group}: {', '.join(todo)}")
    print(f"定义行 {len(defs)}，无重复")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
