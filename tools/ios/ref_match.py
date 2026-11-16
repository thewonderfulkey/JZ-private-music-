# -*- coding: utf-8 -*-
"""LDDC 候选评分算法的 Python 参考实现（与 Android LddcMatch.kt 逐行对应）。

用途：给 Swift 移植生成"期望值"。两边都是照 Kotlin 转写的，独立写两遍再对数字，
能抓出转写错误（漏掉某个 +30、少除一次 max、tag 归一化顺序错之类）。

不要拿它当"算法正确"的证明——算法对不对由 LDDC 原版与 Android 线上表现负责。
"""
from __future__ import annotations

import re

TITLE_TAG_PATTERN = re.compile(
    r"[-<(\[～]([～\]^)>-]*)|([\w]+ ?(?:(?:solo |size )?ver(?:sion)?\.?|size|style|mix(?:ed)?|edit(?:ed)?|版|solo))|(纯音乐|inst\.?(?:rumental)|off ?vocal(?: ?[Vv]er.))"
)
TAG_SYMBOL_CLASS = r"[-><)(\]\[～]"
TAG_SUFFIX = re.compile(r"(?:solo|mix|edit|style|size|edit|inst)$")


def unified_symbol(text: str) -> str:
    table = str.maketrans({
        "（": "(", "）": ")", "：": ":", "！": "!", "？": "?", "／": "/", "＆": "&",
        "＊": "*", "＠": "@", "＃": "#", "＄": "$", "％": "%", "＼": "\\", "｜": "|",
        "＝": "=", "＋": "+", "－": "-", "＜": "<", "＞": ">", "［": "[", "］": "]",
        "｛": "{", "｝": "}",
    })
    return re.sub(r"\s+", " ", text.strip().translate(table)).strip()


def text_difference(a: str, b: str) -> float:
    if a == b:
        return 1.0
    if not a or not b:
        return 0.0
    n, m = len(a), len(b)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(1, n + 1):
        for j in range(1, m + 1):
            dp[i][j] = dp[i - 1][j - 1] + 1 if a[i - 1] == b[j - 1] else max(dp[i - 1][j], dp[i][j - 1])
    return 2.0 * dp[n][m] / (n + m)


def title_tags(not_same: str):
    tags = []
    for m in TITLE_TAG_PATTERN.finditer(not_same):
        for g in m.groups():
            if g and g.strip():
                tags.append(g.strip())
    other = not_same
    if tags:
        other = re.sub("|".join(tags) + "|" + TAG_SYMBOL_CLASS, "", not_same)
    out = []
    for t in tags:
        if "ver" in t or t == "伴奏" or t == "纯音乐":
            t = re.sub(r"ver(?:sion)?\.?|伴奏|纯音乐|inst\.?(?:rumental)|off ?vocal(?: ?[Vv]er.)?", "inst", t)
        if "ver" in t:
            t = re.sub(r"ver(?:sion)?\.?", "ver", t)
        t = t.replace("mixed", "mix").replace("edited", "edit")
        if any(k in t for k in ("solo", "mix", "edit", "style", "size")):
            t = re.sub(r"(solo|mix|edit|style|size) ver", r"\1", t)
        if "tv" in t or "anime" in t:
            t = re.sub(r"(?:tv|anime) ?(?:サイズ|size)?(?: ?edit)?(?: ?ver)?", "tv size", t)
        out.append(t)
    return out, other


def title_score(title1: str, title2: str) -> float:
    t1 = unified_symbol(title1).lower()
    t2 = unified_symbol(title2).lower()
    if t1 == t2:
        return 100.0
    score0 = max(text_difference(t1, t2), 0.0) * 100.0
    same_begin = ""
    for a, b in zip(t1, t2):
        if a == b:
            same_begin += a
        else:
            break
    if same_begin == t1 or same_begin == t2 or not same_begin:
        return score0

    tags1, other1 = title_tags(t1[len(same_begin):])
    tags2, other2 = title_tags(t2[len(same_begin):])

    tag1_no_match: list[str] = []
    tag2_no_match = list(tags2)
    other1_adj, other2_adj = other1, other2

    for tag1 in tags1:
        if tag1 in tag2_no_match:
            tag2_no_match.remove(tag1)
        elif TAG_SUFFIX.search(tag1):
            tag1_no_match.append(tag1)
        elif tag1 in other2_adj:
            other1_adj += tag1

    remove2 = []
    for tag2 in tag2_no_match:
        if not TAG_SUFFIX.search(tag2) and tag2 in other1_adj:
            other2_adj += tag2
            remove2.append(tag2)
    for r in remove2:
        tag2_no_match.remove(r)

    kp = len(same_begin) / (((len(other1_adj) + len(other2_adj)) / 2.0) + len(same_begin))
    score1 = 100.0 * kp + max(text_difference(other1_adj, other2_adj), 0.0) * (1 - kp)

    if not tag1_no_match and not tag2_no_match:
        return max(score1 * 0.7 + 30.0, score0)

    score2 = score3 = 0.0
    if tag1_no_match and tag2_no_match:
        for tag1 in tag1_no_match:
            best = max(text_difference(tag1, tag2) for tag2 in tag2_no_match)
            score2 += best * (30.0 / len(tag1_no_match))
        for tag2 in tag2_no_match:
            best = max(text_difference(tag1, tag2) for tag1 in tag1_no_match)
            score3 += best * (30.0 / len(tag2_no_match))
    return max(score1 * 0.7 + max(score2, score3), score0)


def artist_str2list(artist: str) -> list[list[str]]:
    unified = artist.strip().replace("·", "・").replace("（", "(").replace("）", ")").replace("：", ":")
    parts = [p.strip() for p in re.split(r"[,、/\\&]", unified) if p.strip()]
    result = []
    for p in parts:
        m = re.match(r"^(.*?)\s?\(([^()]*)\)$", p)
        if m:
            name1 = m.group(1).strip()
            name2 = m.group(2).strip()
            for prefix in ("CV:", "CV：", "VO:"):
                if name2.startswith(prefix):
                    name2 = name2[len(prefix):].strip()
            if name1:
                names = [name1]
                if name2 and name2 != name1:
                    names.append(name2)
                result.append(names)
            elif name2:
                result.append([name2])
        else:
            result.append([p])
    return result


def list_max_difference(l1: list[list[str]], l2: list[list[str]]) -> float:
    a = [[s for s in g if s] for g in l1]
    a = [g for g in a if g]
    b = [[s for s in g if s] for g in l2]
    b = [g for g in b if g]
    if not a or not b:
        return 0.0
    scores = []
    for i, g1 in enumerate(a):
        for j, g2 in enumerate(b):
            best = max(text_difference(s1, s2) for s1 in g1 for s2 in g2)
            scores.append((i, j, best))
    scores.sort(key=lambda x: -x[2])
    used1, used2, total = set(), set(), 0.0
    for i, j, s in scores:
        if i in used1 or j in used2:
            continue
        used1.add(i)
        used2.add(j)
        total += s
        if len(used1) == len(a) or len(used2) == len(b):
            break
    return total / max(len(a), len(b))


def artist_score(a1: str, a2: str) -> float:
    if not a1.strip() or not a2.strip():
        return 0.0
    flat1 = [g[0] for g in artist_str2list(a1) if g and g[0]]
    flat2 = [g[0] for g in artist_str2list(a2) if g and g[0]]
    if len(flat1) == 1 and len(flat2) == 1 and flat1[0].lower() == flat2[0].lower():
        return 100.0
    ls = list_max_difference(artist_str2list(a1), artist_str2list(a2))
    joined = text_difference("".join(flat1), "".join(flat2))
    return max(ls, joined) * 100.0


def score(title: str, cand_title: str, artist: str, cand_artist: str) -> float:
    ts = title_score(title, cand_title)
    total = ts
    if artist.strip():
        total = ts * 0.5 + artist_score(artist, cand_artist) * 0.5
    if ts < 30:
        total = max(0.0, total - 35)
    return total
