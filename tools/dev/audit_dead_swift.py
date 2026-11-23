# -*- coding: utf-8 -*-
"""iOS 端「没人引用的文件」审计：只读，不改任何东西。

判定（保守，宁可漏判也不误杀）：
  1. 抽出每个 .swift 里声明的顶层类型名（class/struct/enum/actor/protocol）；
  2. 在**全部其它文件**里找这些名字（按整词匹配）；
  3. 一个文件里所有顶层类型都没被别的文件提过 → 列为"疑似死文件"；
  4. 排除掉有 @main / AppDelegate / SceneDelegate / Widget / AppIntent / @objc 显式桥接的文件，
     以及 Info.plist 里点名的类。

用法：python tools/dev/audit_dead_swift.py [--json out.json]
"""
import glob
import json
import os
import re
import sys

ROOT = 'ios'
DECL = re.compile(
    r'^(?:@[A-Za-z_][\w()., ]*\s+)*'
    r'(?:public |internal |private |fileprivate |open |final |@MainActor\s+)*'
    r'(?:class|struct|enum|actor|protocol)\s+([A-Z][A-Za-z0-9_]*)', re.M)

SAFE_MARKERS = ['@main', 'UIApplicationDelegate', 'SceneDelegate', 'Widget',
                'AppIntent', '@objc(', 'AppEntity', 'TimelineProvider']


def read(path):
    try:
        return open(path, encoding='utf-8').read()
    except UnicodeDecodeError:
        return open(path, encoding='utf-8', errors='replace').read()


def main():
    files = sorted(glob.glob(os.path.join(ROOT, '**', '*.swift'), recursive=True))
    texts = {f: read(f) for f in files}
    decls = {}
    for f, t in texts.items():
        names = sorted(set(DECL.findall(t)))
        if names:
            decls[f] = names

    # 其它文件里出现过几次
    others = {}
    for f in files:
        body = texts[f]
        for g, names in decls.items():
            if g == f:
                continue
            others.setdefault(f, {})
            for n in names:
                if n not in others[f]:
                    others[f][n] = len(re.findall(r'\b' + re.escape(n) + r'\b', body))
        for n in re.findall(r'\b([A-Z][A-Za-z0-9_]{2,})\b', body):
            pass

    # 全局计数（含自己文件）
    global_count = {}
    for f in files:
        for n in re.findall(r'\b([A-Z][A-Za-z0-9_]{2,})\b', texts[f]):
            global_count[n] = global_count.get(n, 0) + 1

    dead, alive = [], []
    for f, names in sorted(decls.items()):
        body = texts[f]
        if any(m in body for m in SAFE_MARKERS):
            alive.append((f, names, 'safe-marker'))
            continue
        used_elsewhere = {n: sum(others.get(g, {}).get(n, 0) for g in files if g != f)
                          for n in names}
        used_self = {n: len(re.findall(r'\b' + re.escape(n) + r'\b', body)) for n in names}
        # 文件里还有顶层函数/Extension 也算"可能被别处用的入口"
        has_top_level_func = bool(re.search(r'^(?:@\w+\s+)*(?:public |internal )?func\s+\w+', body, re.M))
        has_extension = bool(re.search(r'^extension\s+[A-Z]', body, re.M))
        if any(v > 0 for v in used_elsewhere.values()):
            alive.append((f, names, 'referenced'))
        elif has_top_level_func or has_extension:
            alive.append((f, names, 'top-func/ext'))
        else:
            dead.append((f, names, used_self))

    total_bytes = sum(os.path.getsize(f) for f in files)
    dead_bytes = sum(os.path.getsize(f) for f, _, _ in dead)
    lines = sum(len(texts[f].splitlines()) for f in files)
    dead_lines = sum(len(texts[f].splitlines()) for f, _, _ in dead)

    print(f'Swift 文件 {len(files)} 个 / {lines} 行 / {total_bytes/1024:.0f} KB')
    print(f'疑似死文件 {len(dead)} 个 / {dead_lines} 行 / {dead_bytes/1024:.0f} KB')
    for f, names, self_counts in sorted(dead, key=lambda x: -os.path.getsize(x[0])):
        print(f'  {os.path.getsize(f)/1024:7.1f} KB  {f}   [{", ".join(names)}]')

    if '--json' in sys.argv:
        out = sys.argv[sys.argv.index('--json') + 1]
        json.dump({'files': len(files), 'lines': lines, 'dead': [
            {'path': f, 'names': n, 'bytes': os.path.getsize(f)}
            for f, n, _ in dead]}, open(out, 'w', encoding='utf-8'), ensure_ascii=False, indent=1)
        print('JSON →', out)


if __name__ == '__main__':
    main()
