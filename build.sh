#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
PATCH_DIR="$BUILD_DIR/patched"
mkdir -p "$BUILD_DIR" "$PATCH_DIR"

# Fold the few strings that previously depended on runtime/context translators
# into every locale pack. This keeps the final dylib fully offline and lets us
# completely omit the old globe/root/offline layers.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import json, sys

root = Path(sys.argv[1])
extras = json.loads((root / "data" / "runtime_extra_translations.json").read_text(encoding="utf-8"))
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
python3 "$ROOT/tools/generate_known_strings.py"

# Final minimal runtime:
#   * one NSAttributedString translation chain (Tweak.m)
#   * one lightweight gesture implementation (WGLanguageGesturesLite.m)
#   * no WGLanguageOverlay
#   * no WGRootTextureFix / visible language control
#   * no WGOfflineLanguageFix / globe fixer / runtime prefetch
#   * no global viewDidAppear scans or Whitegram picker polling
python3 - "$ROOT" "$PATCH_DIR" <<'PY'
from pathlib import Path
import re, sys

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

# ---- Fast translation core ----
translations = (root / "Sources" / "WGTranslations.m").read_text(encoding="utf-8")
translations = translations.replace(
    'static NSString *const WGMLSelectionKey = @"WGMultiLanguageSelection";\n',
    'static NSString *const WGMLSelectionKey = @"WGMultiLanguageSelection";\n'
    'static NSString *WGMLCachedLanguageCode = nil;\n'
    'static dispatch_once_t WGMLLanguageCodeOnce;\n'
)
translations = replace_function(
    translations,
    'NSString *WGCustomLanguageCode(void)',
    '''NSString *WGCustomLanguageCode(void) {
    dispatch_once(&WGMLLanguageCodeOnce, ^{
        NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:WGMLSelectionKey];
        WGMLCachedLanguageCode = (stored.length > 0 && ![stored isEqualToString:@"builtin"])
            ? [stored.lowercaseString copy]
            : @"ar";
    });
    return WGMLCachedLanguageCode ?: @"ar";
}'''
)
translations = replace_function(
    translations,
    'void WGSetCustomLanguageCode(NSString *languageCode)',
    '''void WGSetCustomLanguageCode(NSString *languageCode) {
    NSString *code = languageCode.length > 0 ? languageCode.lowercaseString : @"ar";
    WGMLCachedLanguageCode = [code copy];
    [NSUserDefaults.standardUserDefaults setObject:code forKey:WGMLSelectionKey];
}'''
)
translations = replace_function(
    translations,
    'static NSDictionary<NSString *, NSString *> *WGLowercaseTranslationTable(void)',
    '''static NSDictionary<NSString *, NSString *> *WGLowercaseTranslationTable(void) {
    static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *tablesByCode;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ tablesByCode = [NSMutableDictionary dictionary]; });

    NSString *code = WGCustomLanguageCode() ?: @"ar";
    NSDictionary<NSString *, NSString *> *cached = tablesByCode[code];
    if (cached) return cached;

    @synchronized(tablesByCode) {
        cached = tablesByCode[code];
        if (cached) return cached;
        NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
        [WGTranslationTable() enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            (void)stop;
            NSString *lower = key.lowercaseString;
            if (!result[lower]) result[lower] = value;
        }];
        cached = [result copy];
        tablesByCode[code] = cached;
        return cached;
    }
}'''
)

# Exact translations are the global UIKit hot path. Do not build/access the
# lowercase table for every ordinary Telegram string. Lowercase and regex
# fallback are reserved for non-exact calls only.
translations = replace_function(
    translations,
    'static NSString *WGTranslateCore(NSString *core, BOOL allowRegex)',
    '''static NSString *WGTranslateCore(NSString *core, BOOL allowRegex) {
    NSDictionary<NSString *, NSString *> *table = WGTranslationTable();
    NSString *canonical = WGCanonicalEnglish(core);
    NSString *translated = table[canonical];
    if (!translated && ![canonical isEqualToString:core]) translated = table[core];

    if (!translated && canonical.length > 1) {
        unichar last = [canonical characterAtIndex:canonical.length - 1];
        if (last == ':' || last == '?' || last == '!' || last == '.') {
            NSString *base = [canonical substringToIndex:canonical.length - 1];
            NSString *baseTranslation = table[base];
            if (baseTranslation) {
                NSString *punctuation = [canonical substringFromIndex:canonical.length - 1];
                translated = [baseTranslation stringByAppendingString:punctuation];
            }
        }
    }

    if (!translated && allowRegex) {
        NSDictionary<NSString *, NSString *> *lowerTable = WGLowercaseTranslationTable();
        translated = lowerTable[canonical.lowercaseString];
        if (!translated && ![canonical isEqualToString:core]) translated = lowerTable[core.lowercaseString];
        if (!translated) {
            NSString *regexResult = WGApplyRegexRules(canonical);
            if (![regexResult isEqualToString:canonical]) translated = regexResult;
        }
    }
    return translated ?: core;
}'''
)
(out / "WGTranslations.m").write_text(translations, encoding="utf-8")

# ---- One exact translation hook layer, no lifecycle scans/picker polling ----
tweak = (root / "Sources" / "Tweak.m").read_text(encoding="utf-8")
# All globally swizzled UIKit entry points use exact dictionary lookups only.
tweak = tweak.replace('WGTranslateString(', 'WGTranslateStringExact(')
tweak = tweak.replace('WGTranslateAttributedString(', 'WGTranslateAttributedStringExact(')
tweak = tweak.replace(
    '        WGSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(wg_nf_viewDidAppear:));\n',
    '        /* No global UIViewController lifecycle scan. */\n'
)
tweak = tweak.replace('            WGInstallWhitegramLanguagePickerHookWithRetry(0);\n', '')
tweak = tweak.replace('            WGScheduleSafeUIKitScan(0.30);\n', '')
(out / "Tweak.m").write_text(tweak, encoding="utf-8")

if 'WGSwizzle(UIViewController.class, @selector(viewDidAppear:)' in tweak:
    raise SystemExit('global viewDidAppear scan hook is still enabled')
if 'WGInstallWhitegramLanguagePickerHookWithRetry(0);' in tweak:
    raise SystemExit('legacy picker polling is still enabled')
if 'WGScheduleSafeUIKitScan(0.30);' in tweak:
    raise SystemExit('launch-wide UIKit scan is still enabled')
if 'static NSString *WGMLCachedLanguageCode' not in translations:
    raise SystemExit('language-code hot cache missing')

# The only compiled sources are checked before clang as an additional guard.
compiled = [out / "Tweak.m", out / "WGTranslations.m", root / "Sources" / "WGLanguageGesturesLite.m"]
for path in compiled:
    text = path.read_text(encoding="utf-8")
    for forbidden in (
        'systemImageNamed:@"globe"',
        'iKiraPlus.WhitegramLanguages',
        'WGRTFInstallGlobe',
        'WGOLFFixGlobeNow',
        'WGInstallLanguageButtonIfNeeded',
        'WGOLFPinButtonToPhysicalRight'
    ):
        if forbidden in text:
            raise SystemExit(f"forbidden language-icon path in compiled source {path.name}: {forbidden}")

print('Prepared single-hook, gesture-only, no-icon runtime')
PY

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
  "$PATCH_DIR/Tweak.m" \
  "$PATCH_DIR/WGTranslations.m" \
  "$ROOT/Sources/WGLanguageGesturesLite.m" \
  -I"$ROOT/Sources" \
  -o "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

codesign --force --sign - "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

BIN="$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"
STRINGS_FILE="$BUILD_DIR/runtime-strings.txt"
strings "$BIN" > "$STRINGS_FILE"

# Final Mach-O must contain none of the historical visible-icon or duplicate
# attributed-string hook markers.
for forbidden in \
  'iKiraPlus.WhitegramLanguages' \
  'WGRTFProbe' \
  'WGOfflineProbe' \
  'WhitegramLanguages.PhysicalRight' \
  'wg_ikira_rtf_original' \
  'wg_ikira_offline_original'; do
  if grep -Fq "$forbidden" "$STRINGS_FILE"; then
    echo "Forbidden legacy runtime marker found: $forbidden" >&2
    exit 1
  fi
done

if grep -Fiq 'globe' "$STRINGS_FILE"; then
  echo "Unexpected globe string found in final dylib" >&2
  grep -Fi 'globe' "$STRINGS_FILE" >&2 || true
  exit 1
fi

grep -Fq 'Telegram : @ikiraplus' "$STRINGS_FILE"
grep -Fq 'Whitegram Features Language' "$STRINGS_FILE"
grep -Fq 'Apariencia' "$STRINGS_FILE"
grep -Fq 'VirusTotal' "$STRINGS_FILE"

file "$BIN"
otool -L "$BIN"
echo "Built minimal no-icon runtime: $BIN"
