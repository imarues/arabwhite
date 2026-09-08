#!/usr/bin/env python3
from __future__ import annotations

import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KNOWN = ROOT / "data" / "extracted_whitegram_strings.json"
LOCALES = ROOT / "Resources" / "locales"

LANGUAGES = {
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
    request = urllib.request.Request(
        url,
        data=data,
        headers={
            "User-Agent": "Mozilla/5.0 iKiraPlus Whitegram Localization Builder",
            "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    if not isinstance(payload, list) or not payload or not isinstance(payload[0], list):
        raise RuntimeError("unexpected Google Translate response")
    parts: list[str] = []
    for segment in payload[0]:
        if isinstance(segment, list) and segment and isinstance(segment[0], str):
            parts.append(segment[0])
    result = "".join(parts)
    if not result:
        raise RuntimeError("empty translation response")
    return result


def translate_batch(batch: list[tuple[int, str]], target: str) -> dict[int, str]:
    protected: dict[int, tuple[str, list[str]]] = {}
    chunks: list[str] = []
    for index, source in batch:
        safe, placeholders = protect(source)
        protected[index] = (safe, placeholders)
        chunks.append(f"__WGID{index:04d}__ {safe}")

    translated_blob = google_translate("\n".join(chunks), target)
    matches = list(MARKER_RE.finditer(translated_blob))
    if len(matches) != len(batch):
        raise RuntimeError(f"marker mismatch: got {len(matches)}, expected {len(batch)}")

    result: dict[int, str] = {}
    for pos, match in enumerate(matches):
        index = int(match.group(1))
        start = match.end()
        end = matches[pos + 1].start() if pos + 1 < len(matches) else len(translated_blob)
        value = translated_blob[start:end].strip(" \t\r\n:-")
        placeholders = protected[index][1]
        value = unprotect(value, placeholders)
        result[index] = value
    return result


def translate_one(index: int, source: str, target: str) -> str:
    safe, placeholders = protect(source)
    translated = google_translate(safe, target)
    return unprotect(translated, placeholders)


def build_language(code: str, target: str, sources: list[str]) -> dict[str, str]:
    output: dict[str, str] = {}
    batch_size = 28
    for start in range(0, len(sources), batch_size):
        batch_sources = sources[start:start + batch_size]
        batch = [(start + offset, source) for offset, source in enumerate(batch_sources)]
        translated: dict[int, str] | None = None
        last_error: Exception | None = None

        for attempt in range(3):
            try:
                translated = translate_batch(batch, target)
                break
            except Exception as exc:
                last_error = exc
                time.sleep(0.6 * (attempt + 1))

        if translated is None:
            print(f"[{code}] batch {start}-{start + len(batch_sources) - 1} fallback: {last_error}")
            translated = {}
            for index, source in batch:
                try:
                    translated[index] = translate_one(index, source, target)
                    time.sleep(0.08)
                except Exception as exc:
                    print(f"[{code}] keeping source for {index}: {exc}")
                    translated[index] = source

        for index, source in batch:
            value = translated.get(index, source).strip()
            if not value:
                value = source
            if PLACEHOLDER_RE.findall(source) != PLACEHOLDER_RE.findall(value):
                print(f"[{code}] placeholder guard kept source: {source!r}")
                value = source
            output[source] = value

        print(f"[{code}] {min(start + batch_size, len(sources))}/{len(sources)}")
        time.sleep(0.12)

    return output


def main() -> None:
    sources = json.loads(KNOWN.read_text(encoding="utf-8"))
    if not isinstance(sources, list) or not all(isinstance(x, str) and x for x in sources):
        raise ValueError("invalid current string catalog")

    LOCALES.mkdir(parents=True, exist_ok=True)
    for code, target in LANGUAGES.items():
        path = LOCALES / f"{code}.json"
        print(f"Building {code} -> {target}")
        table = build_language(code, target, sources)
        path.write_text(json.dumps(table, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"Wrote {path.relative_to(ROOT)} ({len(table)} entries)")


if __name__ == "__main__":
    main()
