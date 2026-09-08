#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#import "WGTranslations.h"

/*
 * LanguageWhitegram root/Texture fix
 *
 * Whitegram's main settings page is produced by the Swift function
 * whitegramSettingsController(...) -> Display.ViewController. It is not a
 * Whitegram-named UIViewController subclass, and many ItemList labels are
 * Texture/NSAttributedString-backed rather than UILabel-backed. This file uses
 * root-only Whitegram strings as a safe page marker, captures that controller,
 * installs the language globe there, and adds a second attributed-string path
 * (including initWithString:) for rows that bypass the original NodeFix hook.
 */

static char WGFixRootControllerKey;
static char WGFixRootNavigationKey;
static char WGFixLanguageButtonKey;
static __weak UIViewController *WGFixRootController = nil;
static NSTimeInterval WGFixConstructionWindowUntil = 0.0;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *WGFixCaches;
static NSMutableSet<NSString *> *WGFixInFlight;
static NSURLSession *WGFixSession;

#pragma mark - Top controller / Whitegram context

static NSArray<UIWindow *> *WGFixVisibleWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01) [result addObject:window];
            }
        }
    }
    if (result.count == 0) {
        for (UIWindow *window in app.windows) {
            if (!window.hidden && window.alpha > 0.01) [result addObject:window];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) return NSOrderedAscending;
        if (a.windowLevel < b.windowLevel) return NSOrderedDescending;
        if (a.isKeyWindow && !b.isKeyWindow) return NSOrderedAscending;
        if (!a.isKeyWindow && b.isKeyWindow) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return result;
}

static UIViewController *WGFixDeepestController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        return WGFixDeepestController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return WGFixDeepestController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        UIViewController *selected = ((UITabBarController *)controller).selectedViewController;
        if (selected) return WGFixDeepestController(selected);
    }
    for (UIViewController *child in controller.children.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGFixDeepestController(child);
    }
    return controller;
}

static UIViewController *WGFixTopController(void) {
    for (UIWindow *window in WGFixVisibleWindows()) {
        UIViewController *root = window.rootViewController;
        if (root) return WGFixDeepestController(root);
    }
    return nil;
}

static BOOL WGFixClassLooksWhitegram(UIViewController *controller) {
    if (!controller) return NO;
    NSString *name = NSStringFromClass(controller.class).lowercaseString;
    return [name containsString:@"whitegram"] ||
           [name containsString:@"wglanguage"] ||
           [name containsString:@"wgvirus"] ||
           [name containsString:@"wgcamera"] ||
           [name containsString:@"wgfont"] ||
           [name containsString:@"wgicon"] ||
           [name containsString:@"wgplugin"] ||
           [name containsString:@"wgonline"] ||
           [name containsString:@"wgprofile"] ||
           [name containsString:@"wgrestore"] ||
           [name containsString:@"wgbadge"] ||
           [name containsString:@"wgequalizer"] ||
           [name containsString:@"wgvoice"] ||
           [name containsString:@"wgsearch"] ||
           [name containsString:@"wgmap"];
}

static BOOL WGFixCurrentlyInsideWhitegram(void) {
    if ([NSDate date].timeIntervalSince1970 < WGFixConstructionWindowUntil) return YES;
    if (![NSThread isMainThread]) return NO;
    UIViewController *top = WGFixTopController();
    if (!top) return NO;
    if (WGFixClassLooksWhitegram(top)) return YES;
    UINavigationController *nav = top.navigationController;
    if (nav && [objc_getAssociatedObject(nav, &WGFixRootNavigationKey) boolValue]) return YES;
    if ([objc_getAssociatedObject(top, &WGFixRootControllerKey) boolValue]) return YES;
    return NO;
}

#pragma mark - Root markers

static BOOL WGFixIsRootMarker(NSString *text) {
    if (text.length == 0) return NO;
    static NSSet<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = [NSSet setWithArray:@[
            @"About Whitegram",
            @"Find a Whitegram option",
            @"Whitegram Features",
            @"Version, channel, developer",
            @"Avatars, message bubbles, effects",
            @"Glass panels and blur",
            @"Deleted, edited, cache",
            @"Zoom, HD sending, video messages",
            @"Checking links and files",
            @"The full list of settings",
            @"حول وايت كرام",
            @"ابحث عن خيار في وايت كرام",
            @"مميزات وايت كرام",
        ]];
    });
    return [markers containsObject:text];
}

static UIButton *WGFixFindExistingLanguageButton(UIView *view, NSUInteger depth) {
    if (!view || depth > 60) return nil;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if ([button.accessibilityLabel isEqualToString:@"Languages"] ||
            [button.accessibilityIdentifier isEqualToString:@"iKiraPlus.WhitegramLanguages"]) {
            return button;
        }
    }
    for (UIView *subview in view.subviews) {
        UIButton *result = WGFixFindExistingLanguageButton(subview, depth + 1);
        if (result) return result;
    }
    return nil;
}

#pragma mark - Languages / menu

static NSArray<NSDictionary<NSString *, NSString *> *> *WGFixLanguages(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *languages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        languages = @[
            @{@"code": @"ar", @"name": @"العربية"},
            @{@"code": @"en", @"name": @"English"},
            @{@"code": @"fr", @"name": @"Français"},
            @{@"code": @"es", @"name": @"Español"},
            @{@"code": @"zh", @"name": @"简体中文"},
            @{@"code": @"vi", @"name": @"Tiếng Việt"},
            @{@"code": @"fa", @"name": @"فارسی"},
            @{@"code": @"pt", @"name": @"Português"},
            @{@"code": @"ru", @"name": @"Русский"},
            @{@"code": @"tr", @"name": @"Türkçe"},
        ];
    });
    return languages;
}

static void WGFixConfirmLanguage(UIViewController *controller, NSDictionary<NSString *, NSString *> *language) {
    NSString *name = language[@"name"] ?: @"Language";
    NSString *message = [NSString stringWithFormat:@"سيتم تغيير لغة ميزات Whitegram إلى %@. اضغط موافق لإغلاق التطبيق، ثم افتحه من جديد لتطبيق اللغة.", name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تغيير اللغة"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"موافق" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        WGSetCustomLanguageCode(language[@"code"]);
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WGFixShowLanguages(UIViewController *controller, UIButton *sender) {
    if (!controller || controller.presentedViewController) return;
    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"اللغات • Languages"
                                                                   message:@"لغة ميزات Whitegram"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary<NSString *, NSString *> *language in WGFixLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (![code isEqualToString:current]) WGFixConfirmLanguage(controller, language);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء • Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sender;
        popover.sourceRect = sender.bounds;
    }
    [controller presentViewController:sheet animated:YES completion:nil];
}

@interface UIViewController (WGTextureLanguageFixActions)
- (void)wg_ikira_texture_showLanguages:(UIButton *)sender;
@end

@implementation UIViewController (WGTextureLanguageFixActions)
- (void)wg_ikira_texture_showLanguages:(UIButton *)sender {
    WGFixShowLanguages(self, sender);
}
@end

static void WGFixInstallButton(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return;
    UIButton *existing = objc_getAssociatedObject(controller, &WGFixLanguageButtonKey);
    if (!existing) existing = WGFixFindExistingLanguageButton(controller.view, 0);
    if (existing) {
        objc_setAssociatedObject(controller, &WGFixLanguageButtonKey, existing, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [controller.view bringSubviewToFront:existing];
        return;
    }

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"Languages";
    button.accessibilityIdentifier = @"iKiraPlus.WhitegramLanguages";
    button.layer.cornerRadius = 23.0;
    button.layer.masksToBounds = YES;
    button.backgroundColor = [UIColor.systemGray5Color colorWithAlphaComponent:0.96];
    button.tintColor = UIColor.labelColor;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:21.0 weight:UIImageSymbolWeightSemibold];
    UIImage *image = [UIImage systemImageNamed:@"globe" withConfiguration:configuration];
    if (image) [button setImage:image forState:UIControlStateNormal];
    else {
        [button setTitle:@"🌐" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:21.0 weight:UIFontWeightSemibold];
    }
    [button addTarget:controller action:@selector(wg_ikira_texture_showLanguages:) forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:button];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18.0],
        [button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:42.0],
        [button.widthAnchor constraintEqualToConstant:46.0],
        [button.heightAnchor constraintEqualToConstant:46.0],
    ]];
    objc_setAssociatedObject(controller, &WGFixLanguageButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [controller.view bringSubviewToFront:button];
}

static void WGFixCaptureRootController(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WGFixCaptureRootController(); });
        return;
    }
    UIViewController *top = WGFixTopController();
    if (!top || [top isKindOfClass:UIAlertController.class]) return;

    if (WGFixRootController && WGFixRootController != top) {
        UIButton *oldButton = objc_getAssociatedObject(WGFixRootController, &WGFixLanguageButtonKey);
        [oldButton removeFromSuperview];
        objc_setAssociatedObject(WGFixRootController, &WGFixLanguageButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(WGFixRootController, &WGFixRootControllerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    WGFixRootController = top;
    objc_setAssociatedObject(top, &WGFixRootControllerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (top.navigationController) {
        objc_setAssociatedObject(top.navigationController, &WGFixRootNavigationKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    WGFixInstallButton(top);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (WGFixRootController == top) {
            UIButton *button = objc_getAssociatedObject(top, &WGFixLanguageButtonKey);
            if (button.superview) [top.view bringSubviewToFront:button];
        }
    });
}

static void WGFixMarkRootConstruction(void) {
    WGFixConstructionWindowUntil = [NSDate date].timeIntervalSince1970 + 2.5;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGFixCaptureRootController(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.48 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGFixCaptureRootController(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGFixCaptureRootController(); });
    });
}

#pragma mark - Extra Arabic strings

static NSDictionary<NSString *, NSString *> *WGFixArabicFallbacks(void) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @"Lets you scan received files with VirusTotal from the message menu. Requires your own API key.": @"يتيح لك فحص الملفات المستلمة عبر VirusTotal من قائمة الرسالة. يتطلب مفتاح API خاصاً بك.",
            @"Your VirusTotal API key — file scanning does not work without it.": @"مفتاح VirusTotal API الخاص بك — لن يعمل فحص الملفات من دونه.",
            @"Video wallpaper across the interface: Not Selected": @"خلفية فيديو في كامل الواجهة: غير محددة",
            @"Video wallpaper across the interface": @"خلفية فيديو في كامل الواجهة",
            @"Not Selected": @"غير محدد",
            @"Shrinks avatars and paddings in the chat list so more chats fit on screen. Not compatible with the new chat list style.": @"يقلّل حجم الصور الشخصية والمسافات في قائمة المحادثات لعرض محادثات أكثر على الشاشة. غير متوافق مع نمط قائمة المحادثات الجديد.",
        };
    });
    return table;
}

#pragma mark - Shared remote cache for extra languages / uncovered rows

static BOOL WGFixShouldIgnore(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return YES;
    NSString *value = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length < 2 || value.length > 1800) return YES;
    if ([value hasPrefix:@"http://"] || [value hasPrefix:@"https://"] || [value hasPrefix:@"tg://"]) return YES;
    BOOL hasLetter = NO;
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i = 0; i < value.length; i++) {
        if ([letters characterIsMember:[value characterAtIndex:i]]) { hasLetter = YES; break; }
    }
    return !hasLetter;
}

static NSMutableDictionary<NSString *, NSString *> *WGFixCache(NSString *code) {
    if (!WGFixCaches) WGFixCaches = [NSMutableDictionary dictionary];
    NSMutableDictionary *cache = WGFixCaches[code];
    if (cache) return cache;
    NSString *key = [@"WGRemoteTranslationCache." stringByAppendingString:code ?: @""];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:key];
    cache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    WGFixCaches[code] = cache;
    return cache;
}

static NSString *WGFixGoogleTarget(NSString *code) {
    return [code isEqualToString:@"zh"] ? @"zh-CN" : code;
}

static NSString *WGFixParseGoogle(NSData *data) {
    if (data.length == 0) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSArray.class] || [(NSArray *)root count] == 0) return nil;
    id segments = ((NSArray *)root)[0];
    if (![segments isKindOfClass:NSArray.class]) return nil;
    NSMutableString *result = [NSMutableString string];
    for (id segment in (NSArray *)segments) {
        if (![segment isKindOfClass:NSArray.class] || [(NSArray *)segment count] == 0) continue;
        id piece = ((NSArray *)segment)[0];
        if ([piece isKindOfClass:NSString.class]) [result appendString:piece];
    }
    return result.length ? result : nil;
}

static void WGFixNudgeCurrentScreen(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WGFixNudgeCurrentScreen(); });
        return;
    }
    UIViewController *top = WGFixTopController();
    if (!top.isViewLoaded) return;
    [top.view setNeedsLayout];
    [top.view layoutIfNeeded];
}

static void WGFixQueueRemote(NSString *source, NSString *code) {
    if (WGFixShouldIgnore(source) || code.length == 0) return;
    if (![NSThread isMainThread]) return;
    if (WGFixCache(code)[source].length > 0) return;
    if (!WGFixInFlight) WGFixInFlight = [NSMutableSet set];
    if (WGFixInFlight.count >= 12) return;
    NSString *flight = [NSString stringWithFormat:@"%@\u241f%@", code, source];
    if ([WGFixInFlight containsObject:flight]) return;
    [WGFixInFlight addObject:flight];

    if (!WGFixSession) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 8.0;
        config.timeoutIntervalForResource = 10.0;
        WGFixSession = [NSURLSession sessionWithConfiguration:config];
    }
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:WGFixGoogleTarget(code)],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
        [NSURLQueryItem queryItemWithName:@"q" value:source],
    ];
    NSURL *url = components.URL;
    if (!url) { [WGFixInFlight removeObject:flight]; return; }

    [[[WGFixSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        NSString *translated = error ? nil : WGFixParseGoogle(data);
        dispatch_async(dispatch_get_main_queue(), ^{
            [WGFixInFlight removeObject:flight];
            if (translated.length > 0) {
                WGFixCache(code)[source] = translated;
                NSString *key = [@"WGRemoteTranslationCache." stringByAppendingString:code];
                [NSUserDefaults.standardUserDefaults setObject:[WGFixCache(code) copy] forKey:key];
                WGFixNudgeCurrentScreen();
            }
        });
    }] retain] autorelease] resume];
}

#pragma mark - Attributed-string interception

static NSString *WGFixTranslateSource(NSString *source) {
    if (![source isKindOfClass:NSString.class] || source.length == 0) return source;
    if (WGFixIsRootMarker(source)) WGFixMarkRootConstruction();
    if (!WGFixCurrentlyInsideWhitegram()) return source;

    NSString *code = WGCustomLanguageCode().lowercaseString ?: @"ar";
    if ([code isEqualToString:@"en"]) return source;

    if ([code isEqualToString:@"ar"]) {
        NSString *extra = WGFixArabicFallbacks()[source];
        if (extra.length > 0) return extra;
        NSString *bundled = WGTranslateString(source);
        if (bundled.length > 0 && ![bundled isEqualToString:source]) return bundled;
    }

    NSString *cached = WGFixCache(code)[source];
    if (cached.length > 0) return cached;
    WGFixQueueRemote(source, code);
    return source;
}

static BOOL WGFixClassOwnsSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { found = YES; break; }
    }
    free(methods);
    return found;
}

static SEL WGFixAliasOne(void) { return sel_registerName("wg_ikira_texture_original_initWithString:"); }
static SEL WGFixAliasAttrs(void) { return sel_registerName("wg_ikira_texture_original_initWithString:attributes:"); }

static id WGFixInitOne(id self, SEL _cmd, NSString *string) {
    (void)_cmd;
    NSString *translated = WGFixTranslateSource(string ?: @"");
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(self, WGFixAliasOne(), translated ?: string);
}

static id WGFixInitAttrs(id self, SEL _cmd, NSString *string, NSDictionary<NSAttributedStringKey, id> *attributes) {
    (void)_cmd;
    NSString *translated = WGFixTranslateSource(string ?: @"");
    return ((id (*)(id, SEL, NSString *, NSDictionary *))objc_msgSend)(self, WGFixAliasAttrs(), translated ?: string, attributes);
}

static void WGFixHookSelectorOnClass(Class cls, SEL original, SEL alias, IMP replacement) {
    if (!cls || WGFixClassOwnsSelector(cls, alias)) return;
    Method method = class_getInstanceMethod(cls, original);
    if (!method) return;
    IMP current = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!current || !types) return;
    if (!class_addMethod(cls, alias, current, types)) return;
    class_replaceMethod(cls, original, replacement, types);
}

static void WGFixInstallAttributedHooks(void) {
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];

    id immutableAlloc = [NSAttributedString alloc];
    NSAttributedString *immutableSample = [immutableAlloc initWithString:@"WGTextureProbe"];
    if (immutableSample) [classes addObject:object_getClass(immutableSample)];
    if (immutableAlloc) [classes addObject:object_getClass(immutableAlloc)];

    id mutableAlloc = [NSMutableAttributedString alloc];
    NSMutableAttributedString *mutableSample = [mutableAlloc initWithString:@"WGTextureMutableProbe"];
    if (mutableSample) [classes addObject:object_getClass(mutableSample)];
    if (mutableAlloc) [classes addObject:object_getClass(mutableAlloc)];

    [classes addObject:NSAttributedString.class];
    [classes addObject:NSMutableAttributedString.class];

    for (id value in classes) {
        Class cls = (Class)value;
        WGFixHookSelectorOnClass(cls, @selector(initWithString:), WGFixAliasOne(), (IMP)WGFixInitOne);
        WGFixHookSelectorOnClass(cls, @selector(initWithString:attributes:), WGFixAliasAttrs(), (IMP)WGFixInitAttrs);
    }
}

#pragma mark - Entry

__attribute__((constructor))
static void WGTextureLanguageFixEntry(void) {
    @autoreleasepool {
        WGFixCaches = [NSMutableDictionary dictionary];
        WGFixInFlight = [NSMutableSet set];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGFixInstallAttributedHooks();
        });
    }
}
