#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
INPUT = ROOT / "data" / "extracted_whitegram_strings.json"
OUTPUT = ROOT / "Sources" / "KnownWhitegramStrings.inc"


def objc_escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def main() -> None:
    values = json.loads(INPUT.read_text(encoding="utf-8"))
    if not isinstance(values, list) or not all(isinstance(x, str) and x for x in values):
        raise ValueError("invalid Whitegram source catalog")

    lines = [
        "// Generated. Do not edit by hand.",
        "static NSArray<NSString *> *WGGeneratedKnownWhitegramStrings(void) {",
        "    return @[",
    ]
    for value in values:
        lines.append(f'        @"{objc_escape(value)}",')
    lines += ["    ];", "}", ""]
    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(f"Generated {OUTPUT.relative_to(ROOT)} with {len(values)} strings.")


if __name__ == "__main__":
    main()
