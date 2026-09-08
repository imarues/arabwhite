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

# Build-time source patching keeps the previously stable translation/gesture
# implementation intact while making the language UI gesture-only.
#
# Important: do NOT use global UIView/UIAlertController swizzles here. Those
# hooks conflicted with Whitegram/Texture and could crash shortly after opening
# the features root.
python3 - "$ROOT" "$PATCH_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])

names = [
    "WGLanguageOverlay.m",
    "WGTwoFingerLanguageGesture.m",
    "WGWindowLanguageGestures.m",
    "WGTwoFingerHoldGesture.m",
]

for name in names:
    text = (root / "Sources" / name).read_text(encoding="utf-8")

    # Put the Telegram handle directly in every language-sheet implementation.
    text = text.replace(
        'message:@"Whitegram Features Language"',
        'message:@"Whitegram Features Language\\nTelegram : @ikiraplus"'
    )

    if name == "WGLanguageOverlay.m":
        # The old overlay still contains the legacy globe button implementation.
        # Disable the single call site at compile time so the button is never
        # instantiated in the first place. The translation lifecycle remains.
        text = text.replace(
            '    WGInstallLanguageButtonIfNeeded(controller);\n',
            '    /* Gesture-only language access: visible language button disabled. */\n'
        )

    (out / name).write_text(text, encoding="utf-8")

patched_overlay = (out / "WGLanguageOverlay.m").read_text(encoding="utf-8")
if "WGInstallLanguageButtonIfNeeded(controller);" in patched_overlay:
    raise SystemExit("legacy language-button call still present in patched overlay")

for name in names:
    text = (out / name).read_text(encoding="utf-8")
    if "Whitegram Features Language\\nTelegram : @ikiraplus" not in text:
        raise SystemExit(f"branding line missing from patched {name}")

print("Prepared crash-safe gesture-only language sources")
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
  "$ROOT/Sources/Tweak.m" \
  "$ROOT/Sources/WGTranslations.m" \
  "$PATCH_DIR/WGLanguageOverlay.m" \
  "$PATCH_DIR/WGTwoFingerLanguageGesture.m" \
  "$PATCH_DIR/WGWindowLanguageGestures.m" \
  "$PATCH_DIR/WGTwoFingerHoldGesture.m" \
  "$ROOT/Sources/WGRootTextureFixCompile.m" \
  "$ROOT/Sources/WGOfflineLanguageFix.m" \
  -I"$ROOT/Sources" \
  -o "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

codesign --force --sign - "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

file "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"
otool -L "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

echo "Built: $BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"
