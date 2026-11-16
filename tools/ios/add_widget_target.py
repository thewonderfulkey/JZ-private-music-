"""给手写工程加一个 Widget Extension target（JZWidgets）。

为什么单独一个脚本：加 target 要同时改 8 处（构建文件、文件引用、分组、target、
四个 build phase、嵌入阶段、依赖、build 配置），少任何一处 `xcodebuild` 的报错都很含糊
（"Cycle inside" / "target has no product"），而且 ID 必须唯一。

用法（仓库根目录）：
    python tools/ios/add_widget_target.py

幂等：目标里已有 JZWidgets target 就直接退出。
先备份：脚本会先把 project.pbxproj 复制成 project.pbxproj.bak-<时间戳>。
"""
from __future__ import annotations

import re
import shutil
import sys
import time
from pathlib import Path

PBX = Path("ios/JZMusicHelper.xcodeproj/project.pbxproj")

# 新对象 ID（固定值，便于人工核对；与现有 ID 不冲突，脚本末尾会自检唯一性）
ID = {
    "target": "D00000000000000000000002",
    "product_ref": "F00000000000000000000046",        # JZWidgets.appex
    "widget_swift_ref": "F00000000000000000000047",
    "widget_plist_ref": "F00000000000000000000048",
    "group": "G00000000000000000000008",
    "sources_phase": "E00000000000000000000004",
    "frameworks_phase": "E00000000000000000000005",
    "resources_phase": "E00000000000000000000006",
    "embed_phase": "E00000000000000000000007",
    "config_list": "C00000000000000000000008",
    "config_debug": "C00000000000000000000009",
    "config_release": "C0000000000000000000000A",
    "sd_build": "B00000000000000000000044",           # JZWidgets.swift in Sources
    "cat_build": "B00000000000000000000045",          # DiscoverCatalog.swift in Sources
    "rules_build": "B00000000000000000000046",        # DiscoverRules.swift in Sources
    "embed_build": "B00000000000000000000047",        # JZWidgets.appex in Embed
    "proxy": "P00000000000000000000001",
    "dependency": "T00000000000000000000001",
}

WIDGET_SOURCES = ["JZWidgets.swift", "DiscoverCatalog.swift", "DiscoverRules.swift"]
BUNDLE_ID = "com.jz.musichelper.widgets"


def main() -> int:
    src = PBX.read_text(encoding="utf-8")
    if "/* JZWidgets */ = {" in src and "PBXNativeTarget" in src:
        if re.search(r"/\* JZWidgets \*/ = \{\s*\n\s*isa = PBXNativeTarget;", src):
            print("JZWidgets target 已存在，无需改动")
            return 0

    for key, value in ID.items():
        if value in src:
            print(f"❌ ID {value} 已被占用（{key}），请换一个")
            return 1

    backup = PBX.with_suffix(f".pbxproj.bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy(PBX, backup)
    print(f"备份：{backup}")

    # ── 1) PBXBuildFile ───────────────────────────────────────────────
    build_lines = (
        f"\t\t{ID['sd_build']} /* JZWidgets.swift in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = {ID['widget_swift_ref']} /* JZWidgets.swift */; }};\n"
        f"\t\t{ID['cat_build']} /* DiscoverCatalog.swift in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = F00000000000000000000035 /* DiscoverCatalog.swift */; }};\n"
        f"\t\t{ID['rules_build']} /* DiscoverRules.swift in Sources */ = "
        f"{{isa = PBXBuildFile; fileRef = F00000000000000000000036 /* DiscoverRules.swift */; }};\n"
        f"\t\t{ID['embed_build']} /* JZWidgets.appex in Embed Foundation Extensions */ = "
        f"{{isa = PBXBuildFile; fileRef = {ID['product_ref']} /* JZWidgets.appex */; "
        f"settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n"
    )
    src = src.replace("/* End PBXBuildFile section */", build_lines + "/* End PBXBuildFile section */")

    # ── 2) PBXFileReference ──────────────────────────────────────────
    ref_lines = (
        f"\t\t{ID['product_ref']} /* JZWidgets.appex */ = {{isa = PBXFileReference; "
        f'explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = JZWidgets.appex; '
        f'sourceTree = BUILT_PRODUCTS_DIR; }};\n'
        f"\t\t{ID['widget_swift_ref']} /* JZWidgets.swift */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = sourcecode.swift; path = JZWidgets.swift; sourceTree = "<group>"; }};\n'
        f"\t\t{ID['widget_plist_ref']} /* Info.plist */ = {{isa = PBXFileReference; "
        f'lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};\n'
    )
    src = src.replace("/* End PBXFileReference section */", ref_lines + "/* End PBXFileReference section */")

    # ── 3) 分组 + 挂到主分组 + 产物分组 ────────────────────────────────
    group_block = (
        f"\t\t{ID['group']} /* JZWidgets */ = {{\n"
        f"\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n"
        f"\t\t\t\t{ID['widget_swift_ref']} /* JZWidgets.swift */,\n"
        f"\t\t\t\t{ID['widget_plist_ref']} /* Info.plist */,\n"
        f"\t\t\t);\n"
        f"\t\t\tpath = JZWidgets;\n"
        f'\t\t\tsourceTree = "<group>";\n'
        f"\t\t}};\n"
    )
    src = src.replace("/* End PBXGroup section */", group_block + "/* End PBXGroup section */")
    # 挂到**根分组**（与 JZMusicHelper / Products 同级），不能挂进 JZMusicHelper 组：
    # 组的 path 是相对父组解析的，挂进去会变成 ios/JZMusicHelper/JZWidgets/…（第一次就是这么错的）
    src = src.replace(
        "\t\t\t\tG00000000000000000000002 /* JZMusicHelper */,\n"
        "\t\t\t\tG00000000000000000000006 /* Products */,\n",
        "\t\t\t\tG00000000000000000000002 /* JZMusicHelper */,\n"
        f"\t\t\t\t{ID['group']} /* JZWidgets */,\n"
        "\t\t\t\tG00000000000000000000006 /* Products */,\n")
    # 产物分组里挂 .appex
    src = src.replace(
        "\t\t\t\tF00000000000000000000014 /* JZMusicHelper.app */,\n",
        "\t\t\t\tF00000000000000000000014 /* JZMusicHelper.app */,\n"
        f"\t\t\t\t{ID['product_ref']} /* JZWidgets.appex */,\n")

    # ── 4) 新 target ─────────────────────────────────────────────────
    target_block = (
        f"\t\t{ID['target']} /* JZWidgets */ = {{\n"
        f"\t\t\tisa = PBXNativeTarget;\n"
        f"\t\t\tbuildConfigurationList = {ID['config_list']} /* Build configuration list for PBXNativeTarget \"JZWidgets\" */;\n"
        f"\t\t\tbuildPhases = (\n"
        f"\t\t\t\t{ID['sources_phase']} /* Sources */,\n"
        f"\t\t\t\t{ID['frameworks_phase']} /* Frameworks */,\n"
        f"\t\t\t\t{ID['resources_phase']} /* Resources */,\n"
        f"\t\t\t);\n"
        f"\t\t\tbuildRules = (\n\t\t\t);\n"
        f"\t\t\tdependencies = (\n\t\t\t);\n"
        f"\t\t\tname = JZWidgets;\n"
        f"\t\t\tproductName = JZWidgets;\n"
        f"\t\t\tproductReference = {ID['product_ref']} /* JZWidgets.appex */;\n"
        f'\t\t\tproductType = "com.apple.product-type.app-extension";\n'
        f"\t\t}};\n"
    )
    src = src.replace("/* End PBXNativeTarget section */", target_block + "/* End PBXNativeTarget section */")

    # 主 target 加嵌入阶段与依赖
    src = src.replace(
        "\t\t\tbuildPhases = (\n"
        "\t\t\t\tE00000000000000000000001 /* Sources */,\n"
        "\t\t\t\tE00000000000000000000002 /* Frameworks */,\n"
        "\t\t\t\tE00000000000000000000003 /* Resources */,\n"
        "\t\t\t);\n",
        "\t\t\tbuildPhases = (\n"
        "\t\t\t\tE00000000000000000000001 /* Sources */,\n"
        "\t\t\t\tE00000000000000000000002 /* Frameworks */,\n"
        "\t\t\t\tE00000000000000000000003 /* Resources */,\n"
        f"\t\t\t\t{ID['embed_phase']} /* Embed Foundation Extensions */,\n"
        "\t\t\t);\n")
    src = src.replace(
        "\t\t\tdependencies = (\n\t\t\t);\n"
        "\t\t\tname = JZMusicHelper;\n",
        "\t\t\tdependencies = (\n"
        f"\t\t\t\t{ID['dependency']} /* PBXTargetDependency */,\n"
        "\t\t\t);\n"
        "\t\t\tname = JZMusicHelper;\n")

    # ── 5) project：targets 列表 + TargetAttributes ────────────────────
    src = src.replace(
        "\t\t\ttargets = (\n"
        "\t\t\t\tD00000000000000000000001 /* JZMusicHelper */,\n"
        "\t\t\t);\n",
        "\t\t\ttargets = (\n"
        "\t\t\t\tD00000000000000000000001 /* JZMusicHelper */,\n"
        f"\t\t\t\t{ID['target']} /* JZWidgets */,\n"
        "\t\t\t);\n")
    src = src.replace(
        "\t\t\t\t\tD00000000000000000000001 = {\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        "\t\t\t\t\t};\n",
        "\t\t\t\t\tD00000000000000000000001 = {\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        "\t\t\t\t\t};\n"
        f"\t\t\t\t\t{ID['target']} = {{\n"
        "\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n"
        "\t\t\t\t\t};\n")

    # ── 6) 四个 build phase ──────────────────────────────────────────
    sources_phase = (
        f"\t\t{ID['sources_phase']} /* Sources */ = {{\n"
        f"\t\t\tisa = PBXSourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{ID['sd_build']} /* JZWidgets.swift in Sources */,\n"
        f"\t\t\t\t{ID['cat_build']} /* DiscoverCatalog.swift in Sources */,\n"
        f"\t\t\t\t{ID['rules_build']} /* DiscoverRules.swift in Sources */,\n"
        f"\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};\n"
    )
    src = src.replace("/* End PBXSourcesBuildPhase section */",
                      sources_phase + "/* End PBXSourcesBuildPhase section */")

    frameworks_phase = (
        f"\t\t{ID['frameworks_phase']} /* Frameworks */ = {{\n"
        f"\t\t\tisa = PBXFrameworksBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};\n"
    )
    src = src.replace("/* End PBXFrameworksBuildPhase section */",
                      frameworks_phase + "/* End PBXFrameworksBuildPhase section */")

    resources_phase = (
        f"\t\t{ID['resources_phase']} /* Resources */ = {{\n"
        f"\t\t\tisa = PBXResourcesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f"\t\t\tfiles = (\n\t\t\t);\n"
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};\n"
    )
    src = src.replace("/* End PBXResourcesBuildPhase section */",
                      resources_phase + "/* End PBXResourcesBuildPhase section */")

    # 嵌入阶段（dstSubfolderSpec = 13 → PlugIns）
    embed_phase = (
        f"\t\t{ID['embed_phase']} /* Embed Foundation Extensions */ = {{\n"
        f"\t\t\tisa = PBXCopyFilesBuildPhase;\n"
        f"\t\t\tbuildActionMask = 2147483647;\n"
        f'\t\t\tdstPath = "";\n'
        f"\t\t\tdstSubfolderSpec = 13;\n"
        f"\t\t\tfiles = (\n"
        f"\t\t\t\t{ID['embed_build']} /* JZWidgets.appex in Embed Foundation Extensions */,\n"
        f"\t\t\t);\n"
        f'\t\t\tname = "Embed Foundation Extensions";\n'
        f"\t\t\trunOnlyForDeploymentPostprocessing = 0;\n"
        f"\t\t}};\n"
    )
    src = src.replace("/* Begin PBXCopyFilesBuildPhase section */",
                      "/* Begin PBXCopyFilesBuildPhase section */\n" + embed_phase) \
        if "/* Begin PBXCopyFilesBuildPhase section */" in src else \
        src.replace("/* End PBXResourcesBuildPhase section */",
                    "/* End PBXResourcesBuildPhase section */\n\n"
                    "/* Begin PBXCopyFilesBuildPhase section */\n"
                    + embed_phase +
                    "/* End PBXCopyFilesBuildPhase section */\n")

    # ── 7) 依赖 + 代理 ───────────────────────────────────────────────
    dependency_block = (
        "/* Begin PBXTargetDependency section */\n"
        f"\t\t{ID['dependency']} /* PBXTargetDependency */ = {{\n"
        f"\t\t\tisa = PBXTargetDependency;\n"
        f"\t\t\ttarget = {ID['target']} /* JZWidgets */;\n"
        f"\t\t\ttargetProxy = {ID['proxy']} /* PBXContainerItemProxy */;\n"
        f"\t\t}};\n"
        "/* End PBXTargetDependency section */\n\n"
        "/* Begin PBXContainerItemProxy section */\n"
        f"\t\t{ID['proxy']} /* PBXContainerItemProxy */ = {{\n"
        f"\t\t\tisa = PBXContainerItemProxy;\n"
        f"\t\t\tcontainerPortal = A00000000000000000000001 /* Project object */;\n"
        f"\t\t\tproxyType = 1;\n"
        f"\t\t\tremoteGlobalIDString = {ID['target']};\n"
        f"\t\t\tremoteInfo = JZWidgets;\n"
        f"\t\t}};\n"
        "/* End PBXContainerItemProxy section */\n"
    )
    src = src.replace("/* Begin PBXProject section */", dependency_block + "\n/* Begin PBXProject section */")

    # ── 8) build 配置 ────────────────────────────────────────────────
    common = (
        "\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;\n"
        "\t\t\t\tCODE_SIGN_STYLE = Automatic;\n"
        "\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n"
        "\t\t\t\tDEVELOPMENT_TEAM = \"\";\n"
        "\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n"
        "\t\t\t\tINFOPLIST_FILE = JZWidgets/Info.plist;\n"
        "\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n"
        "\t\t\t\t\t\"$(inherited)\",\n"
        "\t\t\t\t\t\"@executable_path/Frameworks\",\n"
        "\t\t\t\t\t\"@executable_path/../../Frameworks\",\n"
        "\t\t\t\t);\n"
        "\t\t\t\tMARKETING_VERSION = 1.0;\n"
        f"\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID};\n"
        "\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";\n"
        "\t\t\t\tSKIP_INSTALL = YES;\n"
        "\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n"
        "\t\t\t\tSWIFT_VERSION = 5.0;\n"
        "\t\t\t\tTARGETED_DEVICE_FAMILY = \"1,2\";\n"
    )
    configs = ""
    for cid, name in ((ID["config_debug"], "Debug"), (ID["config_release"], "Release")):
        configs += (
            f"\t\t{cid} /* {name} */ = {{\n"
            f"\t\t\tisa = XCBuildConfiguration;\n"
            f"\t\t\tbuildSettings = {{\n"
            f"{common}"
            f"\t\t\t}};\n"
            f"\t\t\tname = {name};\n"
            f"\t\t}};\n"
        )
    src = src.replace("/* End XCBuildConfiguration section */",
                      configs + "/* End XCBuildConfiguration section */")

    config_list = (
        f"\t\t{ID['config_list']} /* Build configuration list for PBXNativeTarget \"JZWidgets\" */ = {{\n"
        f"\t\t\tisa = XCConfigurationList;\n"
        f"\t\t\tbuildConfigurations = (\n"
        f"\t\t\t\t{ID['config_debug']} /* Debug */,\n"
        f"\t\t\t\t{ID['config_release']} /* Release */,\n"
        f"\t\t\t);\n"
        f"\t\t\tdefaultConfigurationIsVisible = 0;\n"
        f"\t\t\tdefaultConfigurationName = Release;\n"
        f"\t\t}};\n"
    )
    src = src.replace("/* End XCConfigurationList section */",
                      config_list + "/* End XCConfigurationList section */")

    # ── 9) 自检：ID 定义唯一 ─────────────────────────────────────────
    defs = re.findall(r"^\t\t([A-Z][0-9A-F]{23}) /\*", src, flags=re.M)
    dup = {i for i in defs if defs.count(i) > 1}
    if dup:
        print(f"❌ ID 重复：{dup}")
        return 1

    PBX.write_text(src, encoding="utf-8")
    print("✓ 已加入 JZWidgets target（含嵌入阶段与依赖）")
    print(f"定义行 {len(defs)}，无重复")
    return 0


if __name__ == "__main__":
    sys.exit(main())
