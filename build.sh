#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
PATCH_DIR="$BUILD_DIR/patched"
mkdir -p "$BUILD_DIR" "$PATCH_DIR"

python3 "$ROOT/tools/verify_translations.py"
python3 "$ROOT/tools/verify_runtime_safety.py"
python3 "$ROOT/tools/generate_translations.py"
python3 "$ROOT/tools/generate_known_strings.py"

# Minimal runtime build. Old overlay/root/offline translation layers are kept in
# the repository for reference but are intentionally not linked into the dylib.
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
        ch = text[i]
        if ch == '{':
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0:
                return text[:start] + replacement + text[i + 1:]
    raise SystemExit(f"closing brace not found: {signature}")

# Translation lookup fast path: cache selected language and lowercase tables.
translations = (root / "Sources" / "WGTranslations.m").read_text(encoding="utf-8")
translations = translations.replace(
    'static NSString *const WGMLSelectionKey = @"WGMultiLanguageSelection";\n',
    'static NSString *const WGMLSelectionKey = @"WGMultiLanguageSelection";\n'
    'static NSString *WGMLCachedLanguageCode = nil;\n'
)
translations = replace_function(
    translations,
    'NSString *WGCustomLanguageCode(void)',
    '''NSString *WGCustomLanguageCode(void) {
    @synchronized(NSUserDefaults.standardUserDefaults) {
        if (WGMLCachedLanguageCode.length > 0) return WGMLCachedLanguageCode;
        NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:WGMLSelectionKey];
        WGMLCachedLanguageCode = (stored.length > 0 && ![stored isEqualToString:@"builtin"])
            ? [stored.lowercaseString copy] : @"ar";
        return WGMLCachedLanguageCode;
    }
}'''
)
translations = replace_function(
    translations,
    'void WGSetCustomLanguageCode(NSString *languageCode)',
    '''void WGSetCustomLanguageCode(NSString *languageCode) {
    NSString *code = languageCode.length > 0 ? languageCode.lowercaseString : @"ar";
    @synchronized(NSUserDefaults.standardUserDefaults) {
        WGMLCachedLanguageCode = [code copy];
        [NSUserDefaults.standardUserDefaults setObject:code forKey:WGMLSelectionKey];
    }
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
    @synchronized(tablesByCode) {
        NSDictionary<NSString *, NSString *> *cached = tablesByCode[code];
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
(out / "WGTranslations.m").write_text(translations, encoding="utf-8")

# Keep one translation hook layer. No viewDidAppear full-window scan and no old
# Whitegram built-in language-picker retry. Global setters use exact lookups only.
tweak = (root / "Sources" / "Tweak.m").read_text(encoding="utf-8")
tweak = tweak.replace('WGTranslateString(', 'WGTranslateStringExact(')
tweak = tweak.replace('WGTranslateAttributedString(', 'WGTranslateAttributedStringExact(')
tweak = tweak.replace(
    '        WGSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(wg_nf_viewDidAppear:));\n',
    '        /* Global viewDidAppear scan disabled. */\n'
)
tweak = tweak.replace('            WGInstallWhitegramLanguagePickerHookWithRetry(0);\n', '')
tweak = tweak.replace('            WGScheduleSafeUIKitScan(0.30);\n', '')
(out / "Tweak.m").write_text(tweak, encoding="utf-8")

if 'WGSwizzle(UIViewController.class, @selector(viewDidAppear:)' in tweak:
    raise SystemExit('global viewDidAppear scan hook is still enabled')
if 'static NSString *WGMLCachedLanguageCode' not in translations or 'tablesByCode' not in translations:
    raise SystemExit('translation caches were not applied')
print('Prepared minimal fast runtime sources')
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

# These markers belong only to obsolete globe/duplicate-hook implementations.
for forbidden in \
  'iKiraPlus.WhitegramLanguages' \
  'WGRTFProbe' \
  'WGOfflineProbe' \
  'WhitegramLanguages.PhysicalRight'; do
  if grep -Fq "$forbidden" "$STRINGS_FILE"; then
    echo "Forbidden legacy runtime marker found: $forbidden" >&2
    exit 1
  fi
done

grep -Fq 'Telegram : @ikiraplus' "$STRINGS_FILE"
grep -Fq 'Whitegram Features Language' "$STRINGS_FILE"

file "$BIN"
otool -L "$BIN"
echo "Built minimal runtime: $BIN"
