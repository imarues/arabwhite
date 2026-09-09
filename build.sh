#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
PATCH_DIR="$BUILD_DIR/patched"
mkdir -p "$BUILD_DIR" "$PATCH_DIR"

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

# iOS 15-25 keeps the already-tested ultra-lean path.
# iOS 26+ skips every Foundation/UIKit runtime mutation in the dylib constructor
# and delegates installation to the delayed compatibility module.
tweak = (root / "Sources" / "Tweak.m").read_text(encoding="utf-8")
tweak = tweak.replace('WGTranslateString(', 'WGTranslateStringExact(')
tweak = tweak.replace('WGTranslateAttributedString(', 'WGTranslateAttributedStringExact(')
tweak = tweak.replace(
    '        WGSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(wg_nf_viewDidAppear:));\n',
    '        /* Lean build: no global UIViewController lifecycle scan. */\n'
)
tweak = tweak.replace('            WGInstallWhitegramLanguagePickerHookWithRetry(0);\n', '')
tweak = tweak.replace('            WGScheduleSafeUIKitScan(0.30);\n', '')
tweak = tweak.replace(
    '#pragma mark - Entry point\n',
    '#pragma mark - Entry point\n\nextern void WGIOS26InstallCompatibilityHooksLater(void);\n'
)
tweak = replace_function(
    tweak,
    'static void WGMultiLangEntryPoint(void)',
    '''static void WGMultiLangEntryPoint(void) {
    @autoreleasepool {
        NSInteger major = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        if (major >= 26) {
            WGIOS26InstallCompatibilityHooksLater();
            return;
        }
        WGInstallAttributedStringHooks();
        WGInstallUIKitHooks();
    }
}'''
)

if 'WGSwizzle(UIViewController.class, @selector(viewDidAppear:)' in tweak:
    raise SystemExit('global viewDidAppear scan hook still enabled')
if 'WGInstallWhitegramLanguagePickerHookWithRetry(0);' in tweak:
    raise SystemExit('legacy private picker retry still enabled')
if 'WGScheduleSafeUIKitScan(0.30);' in tweak:
    raise SystemExit('startup recursive UI scan still enabled')
if 'major >= 26' not in tweak or 'WGIOS26InstallCompatibilityHooksLater' not in tweak:
    raise SystemExit('iOS 26 compatibility branch missing')
(out / "TweakLean.m").write_text(tweak, encoding="utf-8")

fast = (root / "Sources" / "WGTranslationsFast.m").read_text(encoding="utf-8")
fast = replace_function(
    fast,
    'static NSString *WGFastTranslateCore(NSString *core, BOOL allowRegex)',
    '''static NSString *WGFastTranslateCore(NSString *core, BOOL allowRegex) {
    if (core.length == 0) return core;
    NSString *code = WGCustomLanguageCode();

    if ([code isEqualToString:@"en"]) {
        NSString *canonicalEnglish = WGFastAliasTable()[core];
        if (canonicalEnglish.length) return canonicalEnglish;
        if (!allowRegex) return core;
        return WGFastCanonicalEnglish(core);
    }

    NSDictionary *table = WGFastTranslationTableForCode(code);
    NSString *translated = table[core];
    if (translated.length) return translated;

    NSString *canonical = WGFastAliasTable()[core];
    if (canonical.length) {
        translated = table[canonical];
        if (translated.length) return translated;
    } else {
        canonical = core;
    }

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
print('Prepared dual runtime: iOS15-25 tested path + iOS26 delayed direct-IMP path')
PY

ACTIVE_SOURCES=(
  "$PATCH_DIR/TweakLean.m"
  "$PATCH_DIR/WGTranslationsFast.m"
  "$ROOT/Sources/WGIOS26Compatibility.m"
  "$ROOT/Sources/WGLanguageGesturesLean.m"
)

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

if grep -Fq 'wg_nf_original_initWithString:attributes:' "$ROOT/Sources/WGIOS26Compatibility.m"; then
  echo "ERROR: legacy attributed-string alias chain leaked into iOS26 path" >&2
  exit 1
fi
grep -Fq 'UIApplicationDidFinishLaunchingNotification' "$ROOT/Sources/WGIOS26Compatibility.m"
grep -Fq 'WG26AttributedOriginalIMP' "$ROOT/Sources/WGIOS26Compatibility.m"

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

grep -Fq 'Telegram : @ikiraplus' "$STRINGS_FILE"
grep -Fq 'Whitegram Features Language' "$STRINGS_FILE"
grep -Fq 'Apariencia' "$STRINGS_FILE"

# Function names are Mach-O symbols, not guaranteed to appear in `strings`.
nm -gU "$BIN" > "$BUILD_DIR/symbols.txt"
grep -Fq '_WGIOS26InstallCompatibilityHooksLater' "$BUILD_DIR/symbols.txt"

file "$BIN"
otool -L "$BIN"
echo "IOS26_COMPAT_OK: no constructor-time class-cluster swizzle on iOS26; delayed single direct-IMP hook after launch"
echo "Built: $BIN"
