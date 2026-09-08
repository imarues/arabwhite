#import "WGTranslations.h"
#include "GeneratedTranslations.inc"

/*
 * Fast runtime translation engine for LanguageWhitegram.
 *
 * The old implementation rebuilt a full lowercase translation dictionary on
 * every lookup and repeatedly queried NSUserDefaults. Since UILabel and
 * NSAttributedString hooks execute very frequently, that created noticeable UI
 * lag in Telegram Settings. This implementation keeps the same public API but
 * caches language tables and only falls back to slower matching when exact
 * lookup misses.
 */

static NSString *const WGMLSelectionKey = @"WGMultiLanguageSelection";
static NSString *WGFastLanguageCode = nil;
static dispatch_once_t WGFastLanguageOnce;

static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *WGFastLowerTables;
static NSObject *WGFastLowerTablesLock;
static dispatch_once_t WGFastLowerTablesOnce;

static void WGFastEnsureLowerCache(void) {
    dispatch_once(&WGFastLowerTablesOnce, ^{
        WGFastLowerTables = [NSMutableDictionary dictionary];
        WGFastLowerTablesLock = [NSObject new];
    });
}

NSString *WGCustomLanguageCode(void) {
    dispatch_once(&WGFastLanguageOnce, ^{
        NSString *stored = [NSUserDefaults.standardUserDefaults stringForKey:WGMLSelectionKey];
        if (stored.length > 0 && ![stored isEqualToString:@"builtin"]) {
            WGFastLanguageCode = [stored.lowercaseString copy];
        } else {
            WGFastLanguageCode = @"ar";
        }
    });
    return WGFastLanguageCode ?: @"ar";
}

void WGSetCustomLanguageCode(NSString *languageCode) {
    NSString *code = languageCode.length > 0 ? languageCode.lowercaseString : @"ar";
    WGFastLanguageCode = [code copy];
    [NSUserDefaults.standardUserDefaults setObject:code forKey:WGMLSelectionKey];
}

BOOL WGLocalizationEnabled(void) {
    return WGCustomLanguageCode().length > 0;
}

BOOL WGCurrentLanguageIsRTL(void) {
    NSString *code = WGCustomLanguageCode();
    return [code isEqualToString:@"ar"] || [code isEqualToString:@"fa"] ||
           [code isEqualToString:@"he"] || [code isEqualToString:@"ur"];
}

static NSDictionary<NSString *, NSString *> *WGFastTranslationTableForCode(NSString *code) {
    if (code.length == 0 || [code isEqualToString:@"en"]) return @{};
    return WGGeneratedTranslationsForLanguage(code);
}

static NSDictionary<NSString *, NSString *> *WGFastLowercaseTableForCode(NSString *code) {
    WGFastEnsureLowerCache();
    @synchronized(WGFastLowerTablesLock) {
        NSDictionary *cached = WGFastLowerTables[code ?: @""];
        if (cached) return cached;

        NSDictionary *source = WGFastTranslationTableForCode(code);
        NSMutableDictionary *lower = [NSMutableDictionary dictionaryWithCapacity:source.count];
        [source enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            (void)stop;
            NSString *lowerKey = key.lowercaseString;
            if (lowerKey.length && !lower[lowerKey]) lower[lowerKey] = value;
        }];
        NSDictionary *result = [lower copy];
        WGFastLowerTables[code ?: @""] = result;
        return result;
    }
}

static NSDictionary<NSString *, NSString *> *WGFastAliasTable(void) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ table = WGGeneratedCanonicalAliases(); });
    return table;
}

static NSDictionary<NSString *, NSString *> *WGFastLowerAliasTable(void) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSDictionary *source = WGFastAliasTable();
        NSMutableDictionary *lower = [NSMutableDictionary dictionaryWithCapacity:source.count];
        [source enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
            (void)stop;
            NSString *lowerKey = key.lowercaseString;
            if (lowerKey.length && !lower[lowerKey]) lower[lowerKey] = value;
        }];
        table = [lower copy];
    });
    return table;
}

static NSString *WGFastCanonicalEnglish(NSString *input) {
    if (input.length == 0) return input;
    NSString *canonical = WGFastAliasTable()[input];
    if (canonical.length) return canonical;
    canonical = WGFastLowerAliasTable()[input.lowercaseString];
    return canonical.length ? canonical : input;
}

#pragma mark - Arabic dynamic strings

static NSArray<NSDictionary<NSString *, id> *> *WGFastArabicRules(void) {
    static NSArray<NSDictionary<NSString *, id> *> *rules;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSArray<NSArray<NSString *> *> *raw = @[
            @[@"^Account \\\"(.+)\\\" is already added\\.$", @"الحساب «$1» مضاف مسبقاً."],
            @[@"^Restored accounts: ([0-9]+)$", @"الحسابات المستعادة: $1"],
            @[@"^([0-9]+) account\\(s\\) saved to Keychain$", @"تم حفظ $1 حساب في سلسلة المفاتيح"],
            @[@"^([0-9]+) messages will be restored and visible in the chat again\\.$", @"ستُستعاد $1 رسالة وتظهر مجدداً في المحادثة."],
            @[@"^Font changed: (.+)\\. Restart Whitegram$", @"تم تغيير الخط إلى $1. أعد تشغيل Whitegram"],
            @[@"^Font selected: (.+)\\. Restart Whitegram$", @"تم اختيار الخط $1. أعد تشغيل Whitegram"],
            @[@"^Restored ([0-9]+) messages \\(([0-9]+) new\\)\\.$", @"تمت استعادة $1 رسالة ($2 جديدة)."],
            @[@"^Restored ([0-9]+) settings\\. Restart Whitegram$", @"تمت استعادة $1 إعداد. أعد تشغيل Whitegram"],
            @[@"^Downloading ([0-9]+)%$", @"جارٍ التنزيل $1٪"],
            @[@"^([0-9]+) of ([0-9]+) engines$", @"$1 من أصل $2 محرّك"],
            @[@"^Objects found: ([0-9]+)$", @"العناصر المكتشفة: $1"],
            @[@"^Done: ([0-9]+) messages$", @"تم: $1 رسالة"],
            @[@"^Total messages: ([0-9]+)$", @"إجمالي الرسائل: $1"],
            @[@"^Wallpaper add error: code ([0-9]+)$", @"خطأ في إضافة الخلفية: الرمز $1"],
            @[@"^Restored ([0-9]+) msg\\. from backup\\.$", @"تمت استعادة $1 رسالة من النسخة الاحتياطية."],
            @[@"^Showing lyrics for (.+)$", @"عرض كلمات $1"],
            @[@"^Network error: (.+)$", @"خطأ في الشبكة: $1"],
            @[@"^Selected: (.+)$", @"المحدد: $1"],
            @[@"^Show ([0-9]+) more$", @"إظهار $1 إضافية"],
            @[@"^([0-9]+) / 8 lines$", @"$1 / 8 أسطر"],
            @[@"^([0-9]+) msg\\.$", @"$1 رسالة"],
            @[@"^Restore \\\"(.+)\\\"\\?$", @"استعادة «$1»؟"],
            @[@"^No response from the model\\.$", @"لم يردّ النموذج."],
        ];
        NSMutableArray *compiled = [NSMutableArray arrayWithCapacity:raw.count];
        for (NSArray<NSString *> *item in raw) {
            NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:item[0]
                                                                                  options:0
                                                                                    error:nil];
            if (regex) [compiled addObject:@{@"regex":regex, @"replacement":item[1]}];
        }
        rules = [compiled copy];
    });
    return rules;
}

static BOOL WGFastMayNeedArabicRegex(NSString *input) {
    if (input.length == 0) return NO;
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        prefixes = @[@"Account ", @"Restored", @"Font ", @"Downloading ", @"Objects found:",
                     @"Done:", @"Total messages:", @"Wallpaper ", @"Showing lyrics for ",
                     @"Network error:", @"Selected:", @"Show ", @"Restore ", @"No response from the model."];
    });
    for (NSString *prefix in prefixes) if ([input hasPrefix:prefix]) return YES;
    unichar c0 = [input characterAtIndex:0];
    return c0 >= '0' && c0 <= '9';
}

static NSString *WGFastApplyArabicRegex(NSString *input) {
    if (!WGFastMayNeedArabicRegex(input)) return input;
    NSRange full = NSMakeRange(0, input.length);
    for (NSDictionary<NSString *, id> *rule in WGFastArabicRules()) {
        NSRegularExpression *regex = rule[@"regex"];
        if ([regex firstMatchInString:input options:0 range:full]) {
            return [regex stringByReplacingMatchesInString:input
                                                   options:0
                                                     range:full
                                              withTemplate:rule[@"replacement"]];
        }
    }
    return input;
}

#pragma mark - Lookup

static NSString *WGFastTranslateCore(NSString *core, BOOL allowRegex) {
    if (core.length == 0) return core;
    NSString *code = WGCustomLanguageCode();

    // English is the canonical source language. Convert already-localized text
    // back through aliases, but otherwise leave source English untouched.
    if ([code isEqualToString:@"en"]) {
        return WGFastCanonicalEnglish(core);
    }

    NSDictionary *table = WGFastTranslationTableForCode(code);

    // Most Whitegram strings hit this O(1) path immediately.
    NSString *translated = table[core];
    if (translated.length) return translated;

    NSString *canonical = WGFastAliasTable()[core];
    if (canonical.length) {
        translated = table[canonical];
        if (translated.length) return translated;
    } else {
        canonical = core;
    }

    // Case-insensitive fallback is built once per selected language and only
    // consulted after exact matching fails.
    NSString *lowerCore = core.lowercaseString;
    NSDictionary *lowerTable = WGFastLowercaseTableForCode(code);
    translated = lowerTable[lowerCore];
    if (translated.length) return translated;

    NSString *lowerCanonical = WGFastLowerAliasTable()[lowerCore];
    if (lowerCanonical.length) {
        translated = table[lowerCanonical] ?: lowerTable[lowerCanonical.lowercaseString];
        if (translated.length) return translated;
        canonical = lowerCanonical;
    }

    if (canonical.length > 1) {
        unichar last = [canonical characterAtIndex:canonical.length - 1];
        if (last == ':' || last == '?' || last == '!' || last == '.') {
            NSString *base = [canonical substringToIndex:canonical.length - 1];
            NSString *baseTranslation = table[base] ?: lowerTable[base.lowercaseString];
            if (baseTranslation.length) {
                return [baseTranslation stringByAppendingString:[canonical substringFromIndex:canonical.length - 1]];
            }
        }
    }

    if (allowRegex && [code isEqualToString:@"ar"]) {
        NSString *dynamic = WGFastApplyArabicRegex(canonical);
        if (![dynamic isEqualToString:canonical]) return dynamic;
    }
    return core;
}

static NSString *WGFastTranslateStringInternal(NSString *input, BOOL allowRegex) {
    if (!WGLocalizationEnabled() || input.length == 0 || input.length > 16384) return input;

    NSCharacterSet *trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    BOOL leading = [trim characterIsMember:[input characterAtIndex:0]];
    BOOL trailing = input.length > 1 && [trim characterIsMember:[input characterAtIndex:input.length - 1]];

    // Avoid substring allocations for the overwhelmingly common case.
    if (!leading && !trailing) return WGFastTranslateCore(input, allowRegex);

    NSUInteger start = 0;
    while (start < input.length && [trim characterIsMember:[input characterAtIndex:start]]) start++;
    NSUInteger end = input.length;
    while (end > start && [trim characterIsMember:[input characterAtIndex:end - 1]]) end--;

    NSString *core = [input substringWithRange:NSMakeRange(start, end - start)];
    NSString *translated = WGFastTranslateCore(core, allowRegex);
    if ([translated isEqualToString:core]) return input;
    return [NSString stringWithFormat:@"%@%@%@",
            [input substringToIndex:start], translated, [input substringFromIndex:end]];
}

NSString *WGTranslateString(NSString *input) {
    return WGFastTranslateStringInternal(input, YES);
}

NSString *WGTranslateStringExact(NSString *input) {
    return WGFastTranslateStringInternal(input, NO);
}

static NSAttributedString *WGFastTranslateAttributed(NSAttributedString *input, BOOL exactOnly) {
    if (!WGLocalizationEnabled() || input.length == 0 || input.length > 4096) return input;
    NSString *translated = exactOnly ? WGTranslateStringExact(input.string) : WGTranslateString(input.string);
    if ([translated isEqualToString:input.string]) return input;

    __block NSDictionary<NSAttributedStringKey, id> *uniform = nil;
    __block BOOL mixed = NO;
    [input enumerateAttributesInRange:NSMakeRange(0, input.length)
                              options:0
                           usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attrs, NSRange range, BOOL *stop) {
        (void)range;
        if (!uniform) uniform = attrs ?: @{};
        else if (![uniform isEqualToDictionary:attrs ?: @{}]) { mixed = YES; *stop = YES; }
    }];
    if (mixed) return input;
    return [[NSAttributedString alloc] initWithString:translated attributes:uniform ?: @{}];
}

NSAttributedString *WGTranslateAttributedString(NSAttributedString *input) {
    return WGFastTranslateAttributed(input, NO);
}

NSAttributedString *WGTranslateAttributedStringExact(NSAttributedString *input) {
    return WGFastTranslateAttributed(input, YES);
}
