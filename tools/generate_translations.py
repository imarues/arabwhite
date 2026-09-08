#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCALES_DIR = ROOT / "Resources" / "locales"
TRIPLES = ROOT / "data" / "current_localization_triples.json"
OUTPUT = ROOT / "Sources" / "GeneratedTranslations.inc"


def objc_escape(value: str) -> str:
    return (
        value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("\r", "\\r")
        .replace("\n", "\\n")
        .replace("\t", "\\t")
    )


def emit_dict(lines: list[str], fn: str, data: dict[str, str]) -> None:
    lines += [f"static NSDictionary<NSString *, NSString *> *{fn}(void) {{", "    return @{"]
    for source, target in sorted(data.items(), key=lambda item: item[0].casefold()):
        lines.append(f'        @"{objc_escape(source)}": @"{objc_escape(target)}",')
    lines += ["    };", "}", ""]


def main() -> None:
    LOCALES_DIR.mkdir(parents=True, exist_ok=True)

    locales: dict[str, dict[str, str]] = {}
    for path in sorted(LOCALES_DIR.glob("*.json")):
        payload = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError(f"{path} must contain a JSON object")
        locales[path.stem] = payload

    triples = json.loads(TRIPLES.read_text(encoding="utf-8"))
    aliases: dict[str, str] = {}
    for item in triples:
        en = item.get("en")
        if not isinstance(en, str) or not en:
            continue
        for key in (item.get("en"), item.get("ru"), item.get("uk")):
            if isinstance(key, str) and key and key not in aliases:
                aliases[key] = en

    lines = ["// Generated. Do not edit by hand.", ""]
    for code, table in locales.items():
        emit_dict(lines, f"WGGeneratedTranslations_{code}", table)

    lines += [
        "static NSDictionary<NSString *, NSString *> *WGGeneratedTranslationsForLanguage(NSString *languageCode) {",
    ]
    for code in sorted(locales):
        lines.append(f'    if ([languageCode isEqualToString:@"{objc_escape(code)}"]) return WGGeneratedTranslations_{code}();')
    lines += ["    return @{};", "}", ""]
    emit_dict(lines, "WGGeneratedCanonicalAliases", aliases)

    OUTPUT.write_text("\n".join(lines), encoding="utf-8")
    print(
        f"Generated {OUTPUT.relative_to(ROOT)} with "
        f"{sum(len(v) for v in locales.values())} locale entries and {len(aliases)} source aliases."
    )


if __name__ == "__main__":
    main()
