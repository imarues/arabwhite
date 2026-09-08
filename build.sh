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

# Runtime-performance patching.
# Keep the working translation engine and gestures, but remove the expensive
# global/repeating work that made Telegram Settings and Whitegram feel heavy.
python3 - "$ROOT" "$PATCH_DIR" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])

names = [
    "WGLanguageOverlay.m",
    "WGWindowLanguageGestures.m",
    "WGTwoFingerHoldGesture.m",
]

for name in names:
    text = (root / "Sources" / name).read_text(encoding="utf-8")

    # Keep branding directly in the language sheets; no global UIAlert swizzle.
    text = text.replace(
        'message:@"Whitegram Features Language"',
        'message:@"Whitegram Features Language\\nTelegram : @ikiraplus"'
    )

    if name == "WGLanguageOverlay.m":
        # Gesture-only: never instantiate the legacy globe button.
        text = text.replace(
            '    WGInstallLanguageButtonIfNeeded(controller);\n',
            '    /* Gesture-only language access: visible language button disabled. */\n'
        )

        # The old 0.65s heartbeat recursively rescanned up to thousands of views.
        # Translation still runs on entry plus delayed refreshes and cache events.
        text = text.replace(
            '    WGScheduleHeartbeat();\n',
            '    /* Continuous translation heartbeat disabled for performance. */\n'
        )

    elif name == "WGWindowLanguageGestures.m":
        # The language button is no longer created, so recursive globe purges are
        # unnecessary. Avoid scanning the whole UIWindow on install/gesture.
        text = text.replace('    WGWindowRemoveGlobes(self.window);\n', '')
        text = text.replace('    WGWindowRemoveGlobes(window);\n', '')

        old_scheduler = '''static void WGWindowScheduleInstaller(void) {
    if (WGWindowGestureInstallerScheduled) return;
    WGWindowGestureInstallerScheduled = YES;

    __block NSUInteger remaining = 80; // ~24 seconds covers slow scene/controller creation.
    __block void (^tick)(void) = nil;
    tick = ^{
        WGWindowInstallEverywhere();
        if (remaining-- == 0) {
            WGWindowGestureInstallerScheduled = NO;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), tick);
    };
    dispatch_async(dispatch_get_main_queue(), tick);
}
'''
        new_scheduler = '''static void WGWindowScheduleInstaller(void) {
    // Three short installation attempts are enough for scene creation and avoid
    // the previous 80 passes / ~24 seconds of repeated UIWindow traversal.
    WGWindowInstallEverywhere();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WGWindowInstallEverywhere(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ WGWindowInstallEverywhere(); });
}
'''
        if old_scheduler not in text:
            raise SystemExit("expected old window installer scheduler not found")
        text = text.replace(old_scheduler, new_scheduler)

    (out / name).write_text(text, encoding="utf-8")

patched_overlay = (out / "WGLanguageOverlay.m").read_text(encoding="utf-8")
patched_window = (out / "WGWindowLanguageGestures.m").read_text(encoding="utf-8")

if "WGInstallLanguageButtonIfNeeded(controller);" in patched_overlay:
    raise SystemExit("legacy language-button call still present")
if "    WGScheduleHeartbeat();" in patched_overlay:
    raise SystemExit("continuous heartbeat call still present")
if "remaining = 80" in patched_window:
    raise SystemExit("old 24-second gesture polling still present")
if "WGWindowRemoveGlobes(self.window);" in patched_window or "WGWindowRemoveGlobes(window);" in patched_window:
    raise SystemExit("window-wide globe purge call still present")

for name in names:
    text = (out / name).read_text(encoding="utf-8")
    if "Whitegram Features Language\\nTelegram : @ikiraplus" not in text:
        raise SystemExit(f"branding line missing from patched {name}")

print("Prepared performance-optimized gesture-only language sources")
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
