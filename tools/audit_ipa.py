#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KNOWN_FILE = ROOT / "data" / "extracted_whitegram_strings.json"
TRANSLATIONS_FILE = ROOT / "Resources" / "locales" / "ar.json"
SOURCE_BUILD_FILE = ROOT / "data" / "source_build.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def find_single(root: Path, pattern: str) -> Path:
    matches = list(root.glob(pattern))
    if not matches:
        raise FileNotFoundError(f"No file matched {pattern}")
    return matches[0]


def extract_utf8_c_strings(path: Path) -> set[str]:
    result: set[str] = set()
    carry = b""
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            parts = (carry + chunk).split(b"\0")
            carry = parts.pop()
            for raw in parts:
                if not 2 <= len(raw) <= 16384:
                    continue
                try:
                    value = raw.decode("utf-8")
                except UnicodeDecodeError:
                    continue
                if all(ord(char) >= 32 or char in "\n\r\t" for char in value):
                    result.add(value)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit Whitegram 7.0 build 70 against the MultiLang catalog")
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--report", type=Path, default=ROOT / "ipa-audit-report.txt")
    args = parser.parse_args()

    translations = json.loads(TRANSLATIONS_FILE.read_text(encoding="utf-8"))
    expected = json.loads(KNOWN_FILE.read_text(encoding="utf-8"))
    source_build = json.loads(SOURCE_BUILD_FILE.read_text(encoding="utf-8"))

    with tempfile.TemporaryDirectory(prefix="whitegram-audit-") as temp_dir:
        temp = Path(temp_dir)
        with zipfile.ZipFile(args.ipa) as archive:
            archive.extractall(temp)

        app = find_single(temp, "Payload/*.app")
        framework = app / "Frameworks" / "TelegramUIFramework.framework" / "TelegramUIFramework"
        info_path = app / "Info.plist"
        if not framework.is_file():
            raise FileNotFoundError(f"TelegramUIFramework not found at {framework}")

        binary_strings = extract_utf8_c_strings(framework)
        present = [value for value in expected if value in binary_strings]
        missing = [value for value in expected if value not in binary_strings]
        untranslated = [value for value in present if value not in translations]

        with info_path.open("rb") as handle:
            info = plistlib.load(handle)

        actual_hash = sha256(framework)
        hash_match = actual_hash == source_build["framework_sha256"]
        coverage = (len(present) / len(expected) * 100.0) if expected else 100.0
        report = [
            "Whitegram 7.0 build-70 IPA audit",
            "=================================",
            f"IPA: {args.ipa.name}",
            f"Bundle ID: {info.get('CFBundleIdentifier', 'unknown')}",
            f"Display name: {info.get('CFBundleDisplayName', 'unknown')}",
            f"Version: {info.get('CFBundleShortVersionString', 'unknown')} ({info.get('CFBundleVersion', 'unknown')})",
            f"Framework SHA-256: {actual_hash}",
            f"Exact reference hash: {'YES' if hash_match else 'NO'}",
            f"Expected current strings: {len(expected)}",
            f"Found in this IPA: {len(present)}",
            f"Build match: {coverage:.2f}%",
            f"Found but untranslated (ar): {len(untranslated)}",
            "",
        ]

        if missing:
            report.append("Expected strings not found:")
            report.extend(f"- {value!r}" for value in missing)
            report.append("")
        if untranslated:
            report.append("Found strings missing from Arabic pack:")
            report.extend(f"- {value!r}" for value in untranslated)
            report.append("")

        args.report.write_text("\n".join(report) + "\n", encoding="utf-8")
        print(args.report.read_text(encoding="utf-8"))

    return 1 if untranslated or missing or not hash_match else 0


if __name__ == "__main__":
    raise SystemExit(main())
