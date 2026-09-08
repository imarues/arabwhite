#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import sys
import time
import urllib.parse
import urllib.request
import urllib.error
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KNOWN = ROOT / "data" / "extracted_whitegram_strings.json"
EXTRA = ROOT / "data" / "extra_ui_strings.json"
TRIPLES = ROOT / "data" / "current_localization_triples.json"
LOCALES = ROOT / "Resources" / "locales"

TARGETS = {
    "fr": "fr",
    "es": "es",
    "zh": "zh-CN",
    "vi": "vi",
    "fa": "fa",
    "pt": "pt",
    "ru": "ru",
    "tr": "tr",
}

PLACEHOLDER_RE = re.compile(r"%(?:\d+\$)?(?:@|d|ld|lld|u|lu|llu|f|s|%)")
MARKER_RE = re.compile(r"__WGID(\d{4})__")


def protect(text: str) -> tuple[str, list[str]]:
    placeholders: list[str] = []

    def repl(match: re.Match[str]) -> str:
        placeholders.append(match.group(0))
        return f"__WGPH{len(placeholders)-1:02d}__"

    text = PLACEHOLDER_RE.sub(repl, text)
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\n", "__WGNL__")
    return text, placeholders


def unprotect(text: str, placeholders: list[str]) -> str:
    text = text.replace("__WGNL__", "\n")
    for i, value in enumerate(placeholders):
        text = text.replace(f"__WGPH{i:02d}__", value)
    return text.strip()


def google_translate(text: str, target: str) -> str:
    url = "https://translate.googleapis.com/translate_a/single"
    data = urllib.parse.urlencode({
        "client": "gtx",
        "sl": "en",
        "tl": target,
        "dt": "t",
        "q": text,
    }).encode("utf-8")
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "User-Agent": "Mozilla/5.0 iKiraPlus LanguageWhitegram Builder",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, list) or not payload or not isinstance(payload[0], list):
        raise RuntimeError("unexpected translate response")
    pieces: list[str] = []
    for segment in payload[0]:
        if isinstance(segment, list) and segment and isinstance(segment[0], str):
            pieces.append(segment[0])
    result = "".join(pieces)
    if not result:
        raise RuntimeError("empty translate response")
    return result


def translate_batch(items: list[tuple[int, str]], target: str) -> dict[int, str]:
    protected: dict[int, tuple[str, list[str]]] = {}
    lines: list[str] = []
    for index, source in items:
        safe, placeholders = protect(source)
        protected[index] = (safe, placeholders)
        lines.append(f"__WGID{index:04d}__ {safe}")

    translated_blob = google_translate("\n".join(lines), target)
    matches = list(MARKER_RE.finditer(translated_blob))
    if len(matches) != len(items):
        raise RuntimeError(f"marker mismatch: {len(matches)}/{len(items)}")

    result: dict[int, str] = {}
    for position, match in enumerate(matches):
        index = int(match.group(1))
        start = match.end()
        end = matches[position + 1].start() if position + 1 < len(matches) else len(translated_blob)
        value = translated_blob[start:end].strip(" \t\r\n:-")
        placeholders = protected[index][1]
        value = unprotect(value, placeholders)
        if PLACEHOLDER_RE.findall(items[[x[0] for x in items].index(index)][1]) != PLACEHOLDER_RE.findall(value):
            raise RuntimeError(f"placeholder mismatch for index {index}")
        result[index] = value
    return result


def request_with_retry(items: list[tuple[int, str]], target: str) -> dict[int, str]:
    last: Exception | None = None
    for attempt in range(7):
        try:
            return translate_batch(items, target)
        except urllib.error.HTTPError as exc:
            last = exc
            if exc.code == 429:
                time.sleep(min(12.0, 1.5 * (attempt + 1)))
            else:
                time.sleep(0.8 * (attempt + 1))
        except Exception as exc:
            last = exc
            time.sleep(0.7 * (attempt + 1))
    if len(items) > 1:
        mid = len(items) // 2
        left = request_with_retry(items[:mid], target)
        right = request_with_retry(items[mid:], target)
        left.update(right)
        return left
    raise RuntimeError(f"translation failed for {items[0][1]!r}: {last}")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in TARGETS:
        print("usage: build_one_lang.py <fr|es|zh|vi|fa|pt|ru|tr>", file=sys.stderr)
        return 2

    code = sys.argv[1]
    target = TARGETS[code]
    known = json.loads(KNOWN.read_text(encoding="utf-8"))
    extra = json.loads(EXTRA.read_text(encoding="utf-8"))
    all_sources = list(dict.fromkeys([*known, *extra]))

    output: dict[str, str] = {}

    # Russian is already shipped by Whitegram. Reuse the exact build-70 RU/EN
    # triples for the main catalog, then translate only root strings not present
    # in those triples. This is faster and more accurate than machine translating
    # all Russian strings again.
    if code == "ru":
        triples = json.loads(TRIPLES.read_text(encoding="utf-8"))
        for item in triples:
            en, ru = item.get("en"), item.get("ru")
            if isinstance(en, str) and en and isinstance(ru, str) and ru:
                output[en] = ru

    pending = [(i, source) for i, source in enumerate(all_sources) if source not in output]
    batch_size = 24
    for start in range(0, len(pending), batch_size):
        batch = pending[start:start + batch_size]
        translated = request_with_retry(batch, target)
        for index, source in batch:
            value = translated.get(index, "").strip()
            if not value:
                raise RuntimeError(f"empty translation for {source!r}")
            if PLACEHOLDER_RE.findall(source) != PLACEHOLDER_RE.findall(value):
                raise RuntimeError(f"placeholder mismatch for {source!r}")
            output[source] = value
        print(f"[{code}] {min(start + batch_size, len(pending))}/{len(pending)}", flush=True)
        time.sleep(0.12)

    missing = [source for source in all_sources if source not in output]
    if missing:
        raise RuntimeError(f"{code}: {len(missing)} missing strings")

    unchanged = [source for source in all_sources if output[source].strip() == source.strip()]
    ratio = len(unchanged) / max(1, len(all_sources))
    # Brand names and a few technical tokens can legitimately remain unchanged,
    # but a mostly-English pack is a failed build, not a successful localization.
    if ratio > 0.18:
        raise RuntimeError(f"{code}: too many untranslated strings: {len(unchanged)}/{len(all_sources)}")

    LOCALES.mkdir(parents=True, exist_ok=True)
    path = LOCALES / f"{code}.json"
    path.write_text(json.dumps(output, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Wrote {path.relative_to(ROOT)}: {len(output)} entries, unchanged={len(unchanged)}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
