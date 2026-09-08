#!/usr/bin/env python3
from pathlib import Path
import re
import sys

source = Path(__file__).resolve().parents[1] / "Sources" / "Tweak.m"
text = source.read_text(encoding="utf-8")

code = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
code = re.sub(r"//.*", "", code)

forbidden = {
    "object_setIvar(": "direct Objective-C runtime writes into Swift storage",
    "object_setIvarWithStrongDefault": "private strong-ivar mutation",
    "localizedStringForKey:value:table:": "global NSBundle localization interception",
    "_ASDisplayView": "private Texture lifecycle interception",
    "@interface UITextView": "global editable/message text interception",
}

errors = []
for token, reason in forbidden.items():
    if token in code:
        errors.append(f"Forbidden token {token!r}: {reason}")

required = [
    "initWithString:attributes:",
    "WGInstallAttributedStringHooks",
    "WGTranslateStringExact",
    "WGLanguagePickerViewController",
    "method_setImplementation",
]
for token in required:
    if token not in text:
        errors.append(f"Missing required safe translation path: {token}")

if errors:
    print("Runtime safety verification failed:")
    for error in errors:
        print(f"- {error}")
    sys.exit(1)

print("Runtime safety verification passed: immutable attributed-string + UIKit path; no Swift ivar writes or global NSBundle/UITextView hooks.")
