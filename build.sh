#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
PATCH_DIR="$BUILD_DIR/patched"
mkdir -p "$BUILD_DIR" "$PATCH_DIR"

# Merge runtime-only strings into every locale before generating embedded tables.
# The final dylib therefore needs no network translation layer.
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

# Prepare the two hot-path sources. Ordinary Telegram UI is allowed only exact
# hash-table lookups; it must never trigger recursive scans, lowercase-table
# construction, regex matching, network requests or controller polling.
python3 - "$ROOT" "$PATCH_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])


def replace_function(text: str, signature: str, replacement: str) -> str:
    start = text.find(signature)
    if start < 0:
        raise SystemExit(f"function signature not found: {signature}")
    brace = text.find('{', start)
    if brace < 0:
        raise SystemExit(f"opening brace not found: {signature}")
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return text[:start] + replacement + text[i + 1:]
    raise SystemExit(f"closing brace not found: {signature}")

# ---- One text hook layer; no UIViewController lifecycle scans ----
tweak = (root / "Sources" / "Tweak.m").read_text(encoding="utf-8")
tweak = tweak.replace('WGTranslateString(', 'WGTranslateStringExact(')
tweak = tweak.replace('WGTranslateAttributedString(', 'WGTranslateAttributedStringExact(')
tweak = tweak.replace(
    '        WGSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(wg_nf_viewDidAppear:));\n',
    '        /* Lean build: no global UIViewController lifecycle scan. */\n'
)
tweak = tweak.replace('            WGInstallWhitegramLanguagePickerHookWithRetry(0);\n', '')
tweak = tweak.replace('            WGScheduleSafeUIKitScan(0.30);\n', '')
if 'WGSwizzle(UIViewController.class, @selector(viewDidAppear:)' in tweak:
    raise SystemExit('global viewDidAppear scan hook still enabled')
if 'WGInstallWhitegramLanguagePickerHookWithRetry(0);' in tweak:
    raise SystemExit('legacy private picker retry still enabled')
if 'WGScheduleSafeUIKitScan(0.30);' in tweak:
    raise SystemExit('startup recursive UI scan still enabled')
(out / "TweakLean.m").write_text(tweak, encoding="utf-8")

# ---- Strict O(1) exact lookup ----
fast = (root / "Sources" / "WGTranslationsFast.m").read_text(encoding="utf-8")
fast = replace_function(
    fast,
    'static NSString *WGFastTranslateCore(NSString *core, BOOL allowRegex)',
    '''static NSString *WGFastTranslateCore(NSString *core, BOOL allowRegex) {
    if (core.length == 0) return core;
    NSString *code = WGCustomLanguageCode();

    // English source is canonical. Exact mode performs one alias hash lookup
    // only; slower case-insensitive aliasing is reserved for explicit fallback.
    if ([code isEqualToString:@"en"]) {
        NSString *canonicalEnglish = WGFastAliasTable()[core];
        if (canonicalEnglish.length) return canonicalEnglish;
        if (!allowRegex) return core;
        return WGFastCanonicalEnglish(core);
    }

    NSDictionary *table = WGFastTranslationTableForCode(code);

    // Hot path: exact source key.
    NSString *translated = table[core];
    if (translated.length) return translated;

    // Cross-language exact alias: handles text already localized by another
    // construction path without any lowercase-map work.
    NSString *canonical = WGFastAliasTable()[core];
    if (canonical.length) {
        translated = table[canonical];
        if (translated.length) return translated;
    } else {
        canonical = core;
    }

    // Cheap punctuation fallback still uses exact dictionary keys only.
    if (canonical.length > 1) {
        unichar last = [canonical characterAtIndex:canonical.length - 1];
        if (last == ':' || last == '?' || last == '!' || last == '.') {
            NSString *base = [canonical substringToIndex:canonical.length - 1];
            NSString *baseTranslation = table[base];
            if (baseTranslation.length) {
                return [baseTranslation stringByAppendingString:[canonical substringFromIndex:canonical.length - 1]];
            }
        }
    }

    // All globally-hooked Telegram setters use exact mode and return here.
    if (!allowRegex) return core;

    NSDictionary *lowerTable = WGFastLowercaseTableForCode(code);
    NSString *lowerCore = core.lowercaseString;
    translated = lowerTable[lowerCore];
    if (translated.length) return translated;

    NSString *lowerCanonical = WGFastLowerAliasTable()[lowerCore];
    if (lowerCanonical.length) {
        translated = table[lowerCanonical] ?: lowerTable[lowerCanonical.lowercaseString];
        if (translated.length) return translated;
        canonical = lowerCanonical;
    }

    if ([code isEqualToString:@"ar"]) {
        NSString *dynamic = WGFastApplyArabicRegex(canonical);
        if (![dynamic isEqualToString:canonical]) return dynamic;
    }
    return core;
}'''
)
(out / "WGTranslationsFast.m").write_text(fast, encoding="utf-8")

print('Prepared strict O(1) exact translation path with zero lifecycle/window polling')
PY

ACTIVE_SOURCES=(
  "$PATCH_DIR/TweakLean.m"
  "$PATCH_DIR/WGTranslationsFast.m"
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

# Binary-level proof that none of the historical icon/duplicate-hook modules was
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
echo "LEAN_OK: strict exact lookup, one hook layer, event-driven gestures, no icon, no polling, no network fallback"
echo "Built: $BIN"
