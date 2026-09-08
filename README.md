# LanguageWhitegram — iKiraPlus

Runtime localization dylib for **Whitegram 7.0 / Telegram 12.9.2 build 70**.

## Current build

Output dylib:

```text
LanguageWhitegram-ikiraplus.dylib
```

The project keeps the verified Arabic build-70 dictionary and adds an iKiraPlus language switcher directly to Whitegram's main features screen.

## Languages

The globe button offers 10 languages:

- العربية
- English
- Français
- Español
- 简体中文
- Tiếng Việt
- فارسی
- Português
- Русский
- Türkçe

Arabic is the first-run default **regardless of the iPhone system language**. A previous legacy `builtin` selection is migrated to Arabic. A language selected from the new menu is persisted and remains active across launches.

After selecting another language, Whitegram asks for confirmation and closes so the selected feature-language is applied on the next launch.

## Translation coverage

The bundled Arabic catalog still covers all **716 / 716** extracted current Whitegram build-70 strings and contains **1307** total Arabic dictionary entries. The visible Whitegram-only overlay additionally handles dynamic/composite rows that were not reached by the original exact-string catalog, including labels, attributed labels, buttons, placeholders and non-editable descriptive text.

For the extra languages, visible Whitegram feature strings are translated on demand and cached persistently per language. This fallback is scoped to Whitegram feature controllers; it does not translate Telegram's normal interface. Once a string is cached it is reused on later launches.

## Runtime design

The previous NodeFix safety model remains in place:

- immutable `NSAttributedString` construction is used for the verified bundled catalog;
- stable UIKit setters are used for visible labels, buttons, titles and placeholders;
- the new multilingual overlay only scans visible Whitegram feature controllers;
- no Swift ivar writes;
- no global `NSBundle` localization hook;
- no editable message `UITextView` hook;
- no private Texture lifecycle hook.

The main Whitegram page is detected by build/version and Whitegram markers, then receives a top-right globe button. Sub-pages inherit Whitegram scope from the navigation stack and are rescanned while visible so newly appearing rows are translated while scrolling.

## Build

GitHub Actions runs on `macos-15` with the iPhoneOS SDK and produces a real arm64 iOS device dylib:

```text
build/LanguageWhitegram-ikiraplus.dylib
```

The artifact also contains `SHA256.txt`, `coverage-report.txt`, and `source_build.json`.

## Injection

Inject `LanguageWhitegram-ikiraplus.dylib` once into a clean Whitegram 7.0 (12.9.2 build 70) IPA and sign normally. Do not keep the older Arabic/MultiLang dylib injected at the same time.
