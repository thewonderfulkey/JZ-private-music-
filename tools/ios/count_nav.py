"""单导航 / 5 Tab 的精确计数（用词边界，避免 accessibilityLabel 之类误命中）。"""
import re
from pathlib import Path

files = list(Path("ios").rglob("*.swift"))


def count(pattern: str) -> int:
    return sum(len(re.findall(pattern, p.read_text(encoding="utf-8"))) for p in files)


checks = [
    ("SwiftUI Label(\"历史\")", r'(?<![A-Za-z])Label\("历史"'),
    ("SwiftUI Label(\"设置\")", r'(?<![A-Za-z])Label\("设置"'),
    ("TabView 视图", r'(?<![A-Za-z])TabView\('),
    (".tabItem", r'\.tabItem'),
    ("NavigationStack", r'(?<![A-Za-z])NavigationStack'),
]
for label, pattern in checks:
    print(f"{label:22} : {count(pattern)}")
