# Whitegram MultiLang — iKiraPlus

Runtime localization dylib updated specifically for **Whitegram 7.0 / Telegram 12.9.2 build 70**.

## Languages

Whitegram 7.0 already contains built-in **English, Russian and Ukrainian**. This project preserves those languages and extends Whitegram's own language picker with a full **Arabic** pack. On an Arabic device the Arabic pack is selected automatically on first run; selecting any built-in Whitegram language disables the overlay immediately.

The locale engine is pack-based (`Resources/locales/*.json`), so additional custom languages can be added without changing the hook architecture.

## Build-70 coverage

The reference `TelegramUIFramework` from Whitegram build 70 was audited directly:

- Framework SHA-256: `3c2610dc573b3cf3eff5b389fe9a672b5887ce428d8d6d7a3611ed53c2897ff5`
- Current Whitegram localized strings: **716**
- Arabic coverage for that current catalog: **716 / 716 (100%)**
- Arabic dictionary includes legacy/dynamic labels too: **1307 entries**
- Russian/Ukrainian/English aliases are generated from the build-70 localization triples so already-created rows can still resolve to the same canonical key.

## Runtime design

The previous NodeFix safety model is retained. The dylib:

- translates immutable `NSAttributedString` objects during normal construction;
- uses stable UIKit setters for visible labels, buttons, titles and placeholders;
- rescans only the visible UIKit tree as a fallback;
- discovers `WGLanguagePickerViewController` by its stable Swift class suffix and interposes only its public `UITableView` data-source/delegate methods to append Arabic;
- never writes Swift ivars;
- never hooks global `NSBundle` localization;
- never hooks editable `UITextView` content or private Texture views.

## Build

GitHub Actions runs on `macos-15` with the iPhoneOS SDK and produces a real arm64 iOS device dylib:

```text
build/WhiteGramMultiLang-iKiraPlus.dylib
```

The artifact also contains `SHA256.txt`, `coverage-report.txt`, and `source_build.json`.

## Injection

Inject `WhiteGramMultiLang-iKiraPlus.dylib` once into a clean Whitegram 7.0 (12.9.2 build 70) IPA and sign the IPA normally. Do not keep the older Arabic dylib injected at the same time.

## IPA audit

If you have the reference IPA locally:

```bash
python3 tools/audit_ipa.py "Whitegram 7.0.ipa"
```

The audit checks the bundle version, exact framework hash, presence of all 716 current strings, and Arabic coverage.
