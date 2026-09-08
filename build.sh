#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT/build"
mkdir -p "$BUILD_DIR"

# Arabic is committed and verified by hand. The other eight translated packs
# are generated in CI from the build-70 English catalog so the dylib ships
# with real offline translations instead of waiting on runtime HTTP requests.
python3 "$ROOT/tools/build_multilang_packs.py"
python3 "$ROOT/tools/verify_translations.py"
python3 "$ROOT/tools/verify_runtime_safety.py"
python3 "$ROOT/tools/generate_translations.py"

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
  "$ROOT/Sources/WGLanguageOverlay.m" \
  "$ROOT/Sources/WGRootTextureFixCompile.m" \
  "$ROOT/Sources/WGOfflineLanguageFix.m" \
  -I"$ROOT/Sources" \
  -o "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

codesign --force --sign - "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

file "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"
otool -L "$BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"

echo "Built: $BUILD_DIR/LanguageWhitegram-ikiraplus.dylib"
