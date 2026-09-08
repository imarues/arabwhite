#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
PATCH_DIR="$BUILD_DIR/patched"
mkdir -p "$BUILD_DIR" "$PATCH_DIR"

# Merge the few runtime-only strings into every locale before generating the
# embedded tables. The final dylib therefore needs no network translation layer.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, sys

root = Path(sys.argv[1])
extras_path = root / "data" / "runtime_extra_translations.json"
if extras_path.exists():
    extras = json.loads(extras_path.read_text(encoding="utf-8"))
    for code in ("ar", "fr", "es", "zh", "vi", "fa", "pt", "ru", "tr"):
        path = root / "Resources" / "locales" / f"{code}.json"
        if not path.exists():
            raise SystemExit(f"missing locale pack: {path}")
        data = json.loads(path.read_text(encoding="utf-8"))
        for source, translations in extras.items():
            value = translations.get(code)
            if not value:
                raise SystemExit(f"missing extra translation for {code}: {source}")
            data[source] = value
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"{code}: {len(data)} merged locale entries")
PY

python3 "$ROOT/tools/verify_translations.py"
python3 "$ROOT/tools/verify_runtime_safety.py"
python3 "$ROOT/tools/generate_translations.py"

# Tweak.m remains the one text-construction hook layer, but all whole-window and
# controller lifecycle scans are removed. Global UIKit setters use exact O(1)
# dictionary matching only; no regex/lowercase fallback runs on ordinary
# Telegram UI strings.
python3 - "$ROOT" "$PATCH_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])
text = (root / "Sources" / "Tweak.m").read_text(encoding="utf-8")

text = text.replace('WGTranslateString(', 'WGTranslateStringExact(')
text = text.replace('WGTranslateAttributedString(', 'WGTranslateAttributedStringExact(')
text = text.replace(
    '        WGSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(wg_nf_viewDidAppear:));\n',
    '        /* Lean build: no global UIViewController lifecycle scan. */\n'
)
text = text.replace('            WGInstallWhitegramLanguagePickerHookWithRetry(0);\n', '')
text = text.replace('            WGScheduleSafeUIKitScan(0.30);\n', '')

if 'WGSwizzle(UIViewController.class, @selector(viewDidAppear:)' in text:
    raise SystemExit('global viewDidAppear scan hook still enabled')
if 'WGInstallWhitegramLanguagePickerHookWithRetry(0);' in text:
    raise SystemExit('legacy private picker retry still enabled')
if 'WGScheduleSafeUIKitScan(0.30);' in text:
    raise SystemExit('startup recursive UI scan still enabled')

(out / "TweakLean.m").write_text(text, encoding="utf-8")
print('Prepared TweakLean.m: exact setter hooks only, no lifecycle/window scans')
PY

ACTIVE_SOURCES=(
  "$PATCH_DIR/TweakLean.m"
  "$ROOT/Sources/WGTranslationsFast.m"
  "$ROOT/Sources/WGLanguageGesturesLean.m"
)

# Nothing capable of drawing a language icon or performing runtime translation
# requests is allowed in the active source set.
for forbidden in \
  'systemImageNamed:@"globe"' \
  'iKiraPlus.WhitegramLanguages' \
  'WGRTFInstallGlobe' \
  'WGOLFFixGlobeNow' \
  'WGInstallLanguageButtonIfNeeded' \
  'WGOLFPinButtonToPhysicalRight' \
  'translate.googleapis.com' \
  'dispatch_semaphore_wait'; do
  if grep -Fq "$forbidden" "${ACTIVE_SOURCES[@]}"; then
    echo "ERROR: forbidden runtime path in active source: $forbidden" >&2
    exit 1
  fi
done

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos --find clang)"

"$CLANG" \
  -arch arm64 \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=15.0 \
  -dynamiclib \
  -fobjc-arc \
  -fmodules \
  -O2 \
  -Wall \
  -Wextra \
  -Wno-nullability-completeness \
  -Wno-deprecated-declarations \
  -framework Foundation \
  -framework UIKit \
  -Wl,-dead_strip \
  -Wl,-install_name,@rpath/LanguageWhitegram-ikiraplus.dylib \
  "${ACTIVE_SOURCES[@]}" \
  -I"$ROOT/Sources" \
  -o "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

codesign --force --sign - "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

BIN="$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"
STRINGS_FILE="$BUILD_DIR/runtime-strings.txt"
strings "$BIN" > "$STRINGS_FILE"

# Binary-level proof that none of the historical icon/duplicate hook modules was
# linked accidentally.
for forbidden in \
  'iKiraPlus.WhitegramLanguages' \
  'WhitegramLanguages.PhysicalRight' \
  'WGRTFProbe' \
  'WGOfflineProbe' \
  'wg_ikira_rtf_original' \
  'wg_ikira_offline_original' \
  'translate.googleapis.com'; do
  if grep -Fq "$forbidden" "$STRINGS_FILE"; then
    echo "ERROR: forbidden legacy marker in final dylib: $forbidden" >&2
    exit 1
  fi
done

# The literal used by all previous visible buttons must be absent too.
if grep -Fiq 'globe' "$STRINGS_FILE"; then
  echo "ERROR: unexpected language-icon literal in final dylib" >&2
  grep -Fi 'globe' "$STRINGS_FILE" >&2 || true
  exit 1
fi

# Required functionality/branding must still be embedded.
grep -Fq 'Telegram : @ikiraplus' "$STRINGS_FILE"
grep -Fq 'Whitegram Features Language' "$STRINGS_FILE"
grep -Fq 'Apariencia' "$STRINGS_FILE"
grep -Fq 'VirusTotal' "$STRINGS_FILE"

file "$BIN"
otool -L "$BIN"
echo "LEAN_OK: one translation layer, event-driven gestures, no visible icon, no polling, no network fallback"
echo "Built: $BIN"
