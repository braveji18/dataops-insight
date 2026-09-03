#!/usr/bin/env python3
"""보고서에 삽입된 코드 발췌가 원본 소스와 일치하는지 대조한다.

보고서가 아래 형식을 지킬 때 동작한다 (링크 바로 다음에 코드 블록):

    **[Foo.java#L10-L20](https://github.com/trinodb/trino/blob/483/path/to/Foo.java#L10-L20)**

    ```java
    ...코드...
    ```

사용: python3 verify-code-blocks.py docs/report/01-....md [--root .]
종료코드: 불일치가 있으면 1
"""
import argparse
import re
import sys
import textwrap
from pathlib import Path

# GitHub 저장소 → works/ 아래 클론 디렉터리
REPOS = {
    "trinodb/trino": "works/trino",
    "StarRocks/starrocks": "works/starrocks",
}

LINK = re.compile(
    r"\[[^\]]+\]\(https://github\.com/(?P<repo>[\w.-]+/[\w.-]+)/blob/"
    r"(?P<ref>[^/]+)/(?P<path>[^)#]+)#L(?P<a>\d+)(?:-L(?P<b>\d+))?\)"
)
BLOCK = re.compile(r"```[a-zA-Z]*\n(?P<code>.*?)```", re.S)


def norm(text):
    """들여쓰기 기준을 없애고 앞뒤 빈 줄을 제거한다."""
    return textwrap.dedent(text).strip("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("report")
    ap.add_argument("--root", default=".", help="저장소 루트 (works/ 의 상위)")
    args = ap.parse_args()

    root = Path(args.root)
    doc = Path(args.report).read_text(encoding="utf-8")

    checked = mismatched = skipped = 0
    for m in LINK.finditer(doc):
        blk = BLOCK.search(doc, m.end())
        if not blk or doc.count("```", m.end(), blk.start()) != 0:
            continue  # 링크 뒤에 코드 블록이 없으면 대상 아님

        clone = REPOS.get(m.group("repo"))
        if clone is None:
            print(f"  건너뜀 (모르는 저장소): {m.group('repo')}")
            skipped += 1
            continue

        src = root / clone / m.group("path")
        if not src.is_file():
            print(f"불일치 ✗ 파일 없음: {clone}/{m.group('path')}")
            mismatched += 1
            continue

        a = int(m.group("a"))
        b = int(m.group("b") or a)
        want = norm("\n".join(src.read_text(encoding="utf-8").split("\n")[a - 1:b]))
        got = norm(blk.group("code"))
        checked += 1

        label = f"{Path(m.group('path')).name}#L{a}-L{b}"
        if got == want:
            print(f"일치 ✓  {label}")
        else:
            mismatched += 1
            print(f"불일치 ✗ {label}  ← 발췌라면 문서에 '발췌' 표기가 있는지 확인할 것")

    print(f"\n대조 {checked}건 / 불일치 {mismatched}건 / 건너뜀 {skipped}건")
    return 1 if mismatched else 0


if __name__ == "__main__":
    sys.exit(main())
