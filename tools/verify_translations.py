#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES_DIR = ROOT / "Resources" / "locales"
KNOWN = ROOT / "data" / "extracted_whitegram_strings.json"
TRIPLES = ROOT / "data" / "current_localization_triples.json"
REPORT = ROOT / "coverage-report.txt"

PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?(?:@|d|ld|lld|u|lu|llu|f|s|%)")


def placeholders(value: str) -> list[str]:
    return sorted(PLACEHOLDER_RE.findall(value))


def main() -> int:
    known = json.loads(KNOWN.read_text(encoding="utf-8"))
    triples = json.loads(TRIPLES.read_text(encoding="utf-8"))
    if not isinstance(known, list) or not all(isinstance(value, str) for value in known):
        raise ValueError(f"{KNOWN} must contain a JSON array of strings")
    if len(known) != 716:
        raise ValueError(f"Expected build-70 catalog to contain 716 strings, found {len(known)}")

    locale_paths = sorted(LOCALES_DIR.glob("*.json"))
    if not locale_paths:
        raise ValueError("No locale packs found")

    errors: list[str] = []
    report = [
        "Whitegram MultiLang translation coverage",
        "========================================",
        "Target: Whitegram 7.0 / Telegram 12.9.2 build 70",
        f"Current Whitegram strings: {len(known)}",
        f"Built-in source triples:   {len(triples)} (RU / UK / EN)",
        "",
    ]

    for path in locale_paths:
        code = path.stem
        table = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(table, dict):
            errors.append(f"{path}: not a JSON object")
            continue

        missing = [value for value in known if value not in table]
        empty = [key for key, value in table.items() if not isinstance(value, str) or not value.strip()]
        placeholder_errors = [
            key for key, value in table.items()
            if isinstance(value, str) and placeholders(key) != placeholders(value)
        ]

        translated = len(known) - len(missing)
        coverage = translated / len(known) * 100.0 if known else 100.0
        report += [
            f"Locale: {code}",
            f"  Current translated:      {translated}/{len(known)}",
            f"  Current coverage:        {coverage:.2f}%",
            f"  Total dictionary entries:{len(table)}",
            f"  Missing current strings: {len(missing)}",
            f"  Empty translations:      {len(empty)}",
            f"  Placeholder mismatches:  {len(placeholder_errors)}",
            "",
        ]

        if missing:
            errors.append(f"{code}: {len(missing)} current strings missing")
            report.append(f"Missing ({code}):")
            report.extend(f"- {value!r}" for value in missing)
            report.append("")
        if empty:
            errors.append(f"{code}: {len(empty)} empty translations")
        if placeholder_errors:
            errors.append(f"{code}: {len(placeholder_errors)} placeholder mismatches")
            report.append(f"Placeholder mismatches ({code}):")
            for key in placeholder_errors:
                report.append(
                    f"- {key!r}: source={placeholders(key)} target={placeholders(table[key])}"
                )
            report.append("")

    # Every triple must have all three built-in variants so Arabic can map
    # pre-existing Russian/Ukrainian rows back to the canonical English key.
    bad_triples = [
        item for item in triples
        if not all(isinstance(item.get(key), str) and item.get(key) for key in ("ru", "uk", "en"))
    ]
    if bad_triples:
        errors.append(f"{len(bad_triples)} invalid RU/UK/EN alias triples")

    report.append("Result: " + ("PASS" if not errors else "FAIL"))
    if errors:
        report.extend(f"- {error}" for error in errors)

    REPORT.write_text("\n".join(report) + "\n", encoding="utf-8")
    print(REPORT.read_text(encoding="utf-8"))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
