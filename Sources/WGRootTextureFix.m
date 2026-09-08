#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#import "WGTranslations.h"

static char WGRTFRootKey;
static char WGRTFNavKey;
static char WGRTFButtonKey;
static __weak UIViewController *WGRTFRootController = nil;
static NSTimeInterval WGRTFConstructionUntil = 0.0;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *WGRTFCaches;
static NSMutableSet<NSString *> *WGRTFInFlight;
static NSURLSession *WGRTFSession;

#pragma mark - Controller lookup

static UIViewController *WGRTFDeepest(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        return WGRTFDeepest(vc.presentedViewController);
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        return WGRTFDeepest(((UINavigationController *)vc).visibleViewController);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return WGRTFDeepest(((UITabBarController *)vc).selectedViewController);
    }
    for (UIViewController *child in vc.children.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGRTFDeepest(child);
    }
    return vc;
}

static UIViewController *WGRTFTopController(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
            }
        }
    }
    if (windows.count == 0) {
        for (UIWindow *window in app.windows) {
            if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
        }
    }
    UIWindow *best = nil;
    for (UIWindow *window in windows) {
        if (!best || window.isKeyWindow || window.windowLevel > best.windowLevel) best = window;
    }
    return WGRTFDeepest(best.rootViewController);
}

static BOOL WGRTFNamedWhitegramController(UIViewController *vc) {
    if (!vc) return NO;
    NSString *name = NSStringFromClass(vc.class).lowercaseString;
    if ([name containsString:@"whitegram"]) return YES;
    NSArray<NSString *> *needles = @[@"wgvirus", @"wgcamera", @"wgfont", @"wgicon", @"wgplugin",
                                     @"wgonline", @"wgprofile", @"wgrestore", @"wgbadge", @"wgequalizer",
                                     @"wgvoice", @"wgsearch", @"wgmap", @"wglanguage", @"wgstreak"];
    for (NSString *needle in needles) if ([name containsString:needle]) return YES;
    return NO;
}

static BOOL WGRTFInWhitegramContext(void) {
    if ([NSDate date].timeIntervalSince1970 < WGRTFConstructionUntil) return YES;
    if (![NSThread isMainThread]) return NO;
    UIViewController *top = WGRTFTopController();
    if (!top) return NO;
    if (WGRTFNamedWhitegramController(top)) return YES;
    if ([objc_getAssociatedObject(top, &WGRTFRootKey) boolValue]) return YES;
    UINavigationController *nav = top.navigationController;
    return nav && [objc_getAssociatedObject(nav, &WGRTFNavKey) boolValue];
}

#pragma mark - Root page detection

static BOOL WGRTFIsRootMarker(NSString *text) {
    static NSSet<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = [NSSet setWithArray:@[
            @"About Whitegram", @"Find a Whitegram option", @"Whitegram Features",
            @"Version, channel, developer", @"Avatars, message bubbles, effects",
            @"Glass panels and blur", @"Deleted, edited, cache",
            @"Zoom, HD sending, video messages", @"Checking links and files",
            @"The full list of settings", @"حول وايت كرام", @"ابحث عن خيار في وايت كرام"
        ]];
    });
    return text.length > 0 && [markers containsObject:text];
}

#pragma mark - Language button

static NSArray<NSDictionary<NSString *, NSString *> *> *WGRTFLanguages(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *list;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        list = @[
            @{@"code":@"ar", @"name":@"العربية"},
            @{@"code":@"en", @"name":@"English"},
            @{@"code":@"fr", @"name":@"Français"},
            @{@"code":@"es", @"name":@"Español"},
            @{@"code":@"zh", @"name":@"简体中文"},
            @{@"code":@"vi", @"name":@"Tiếng Việt"},
            @{@"code":@"fa", @"name":@"فارسی"},
            @{@"code":@"pt", @"name":@"Português"},
            @{@"code":@"ru", @"name":@"Русский"},
            @{@"code":@"tr", @"name":@"Türkçe"}
        ];
    });
    return list;
}

static void WGRTFConfirmLanguage(UIViewController *vc, NSDictionary<NSString *, NSString *> *language) {
    NSString *name = language[@"name"] ?: @"Language";
    NSString *message = [NSString stringWithFormat:@"سيتم تغيير لغة ميزات Whitegram إلى %@. اضغط موافق لإغلاق التطبيق، ثم افتحه من جديد.", name];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تغيير اللغة"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"موافق" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        WGSetCustomLanguageCode(language[@"code"]);
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [vc presentViewController:alert animated:YES completion:nil];
}

static void WGRTFShowLanguages(UIViewController *vc, UIButton *sender) {
    if (!vc || vc.presentedViewController) return;
    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"اللغات • Languages"
                                                                   message:@"لغة ميزات Whitegram"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary<NSString *, NSString *> *language in WGRTFLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (![code isEqualToString:current]) WGRTFConfirmLanguage(vc, language);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"إلغاء • Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) { popover.sourceView = sender; popover.sourceRect = sender.bounds; }
    [vc presentViewController:sheet animated:YES completion:nil];
}

@interface UIViewController (WGRTFActions)
- (void)wg_ikira_rtf_languages:(UIButton *)sender;
@end
@implementation UIViewController (WGRTFActions)
- (void)wg_ikira_rtf_languages:(UIButton *)sender { WGRTFShowLanguages(self, sender); }
@end

static UIButton *WGRTFFindGlobe(UIView *view, NSUInteger depth) {
    if (!view || depth > 60) return nil;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if ([button.accessibilityIdentifier isEqualToString:@"iKiraPlus.WhitegramLanguages"] ||
            [button.accessibilityLabel isEqualToString:@"Languages"]) return button;
    }
    for (UIView *subview in view.subviews) {
        UIButton *found = WGRTFFindGlobe(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void WGRTFInstallGlobe(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded) return;
    UIButton *button = objc_getAssociatedObject(vc, &WGRTFButtonKey);
    if (!button) button = WGRTFFindGlobe(vc.view, 0);
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.accessibilityLabel = @"Languages";
        button.accessibilityIdentifier = @"iKiraPlus.WhitegramLanguages";
        button.layer.cornerRadius = 23.0;
        button.layer.masksToBounds = YES;
        button.backgroundColor = [UIColor.systemGray5Color colorWithAlphaComponent:0.96];
        button.tintColor = UIColor.labelColor;
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightSemibold];
        UIImage *image = [UIImage systemImageNamed:@"globe" withConfiguration:cfg];
        if (image) [button setImage:image forState:UIControlStateNormal];
        else [button setTitle:@"🌐" forState:UIControlStateNormal];
        [button addTarget:vc action:@selector(wg_ikira_rtf_languages:) forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:button];
        UILayoutGuide *safe = vc.view.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18],
            [button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:42],
            [button.widthAnchor constraintEqualToConstant:46],
            [button.heightAnchor constraintEqualToConstant:46]
        ]];
    }
    objc_setAssociatedObject(vc, &WGRTFButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [vc.view bringSubviewToFront:button];
}

static void WGRTFCaptureRoot(void) {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ WGRTFCaptureRoot(); }); return; }
    UIViewController *top = WGRTFTopController();
    if (!top || [top isKindOfClass:UIAlertController.class]) return;
    if (WGRTFRootController && WGRTFRootController != top) {
        UIButton *old = objc_getAssociatedObject(WGRTFRootController, &WGRTFButtonKey);
        [old removeFromSuperview];
        objc_setAssociatedObject(WGRTFRootController, &WGRTFButtonKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(WGRTFRootController, &WGRTFRootKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    WGRTFRootController = top;
    objc_setAssociatedObject(top, &WGRTFRootKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (top.navigationController) objc_setAssociatedObject(top.navigationController, &WGRTFNavKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WGRTFInstallGlobe(top);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (WGRTFRootController == top) WGRTFInstallGlobe(top);
    });
}

static void WGRTFMarkRoot(void) {
    WGRTFConstructionUntil = [NSDate date].timeIntervalSince1970 + 2.5;
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGRTFCaptureRoot(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.48 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGRTFCaptureRoot(); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.90 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGRTFCaptureRoot(); });
    });
}

#pragma mark - Missing Arabic + remote cache

static NSDictionary<NSString *, NSString *> *WGRTFArabicExtra(void) {
    static NSDictionary<NSString *, NSString *> *table;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        table = @{
            @"Lets you scan received files with VirusTotal from the message menu. Requires your own API key.": @"يتيح لك فحص الملفات المستلمة عبر VirusTotal من قائمة الرسالة. يتطلب مفتاح API خاصاً بك.",
            @"Your VirusTotal API key — file scanning does not work without it.": @"مفتاح VirusTotal API الخاص بك — لن يعمل فحص الملفات من دونه.",
            @"Video wallpaper across the interface: Not Selected": @"خلفية فيديو في كامل الواجهة: غير محددة",
            @"Video wallpaper across the interface": @"خلفية فيديو في كامل الواجهة",
            @"Not Selected": @"غير محدد",
            @"Shrinks avatars and paddings in the chat list so more chats fit on screen. Not compatible with the new chat list style.": @"يقلّل حجم الصور الشخصية والمسافات في قائمة المحادثات لعرض محادثات أكثر على الشاشة. غير متوافق مع نمط قائمة المحادثات الجديد."
        };
    });
    return table;
}

static BOOL WGRTFIgnoreSource(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return YES;
    NSString *v = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (v.length < 2 || v.length > 1800) return YES;
    if ([v hasPrefix:@"http://"] || [v hasPrefix:@"https://"] || [v hasPrefix:@"tg://"]) return YES;
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i=0;i<v.length;i++) if ([letters characterIsMember:[v characterAtIndex:i]]) return NO;
    return YES;
}

static NSMutableDictionary<NSString *, NSString *> *WGRTFCache(NSString *code) {
    if (!WGRTFCaches) WGRTFCaches = [NSMutableDictionary dictionary];
    NSMutableDictionary *cache = WGRTFCaches[code];
    if (cache) return cache;
    NSString *key = [@"WGRemoteTranslationCache." stringByAppendingString:code ?: @""];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:key];
    cache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    WGRTFCaches[code] = cache;
    return cache;
}

static NSString *WGRTFParseGoogle(NSData *data) {
    id root = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
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

static void WGRTFQueueRemote(NSString *source, NSString *code) {
    if (![NSThread isMainThread] || WGRTFIgnoreSource(source) || code.length == 0) return;
    if (WGRTFCache(code)[source].length > 0) return;
    if (!WGRTFInFlight) WGRTFInFlight = [NSMutableSet set];
    if (WGRTFInFlight.count >= 12) return;
    NSString *flight = [NSString stringWithFormat:@"%@\u241f%@", code, source];
    if ([WGRTFInFlight containsObject:flight]) return;
    [WGRTFInFlight addObject:flight];
    if (!WGRTFSession) {
        NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        cfg.timeoutIntervalForRequest = 8;
        cfg.timeoutIntervalForResource = 10;
        WGRTFSession = [NSURLSession sessionWithConfiguration:cfg];
    }
    NSString *target = [code isEqualToString:@"zh"] ? @"zh-CN" : code;
    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:target],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
        [NSURLQueryItem queryItemWithName:@"q" value:source]
    ];
    NSURL *url = components.URL;
    if (!url) { [WGRTFInFlight removeObject:flight]; return; }
    NSURLSessionDataTask *task = [WGRTFSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        NSString *translated = error ? nil : WGRTFParseGoogle(data);
        dispatch_async(dispatch_get_main_queue(), ^{
            [WGRTFInFlight removeObject:flight];
            if (translated.length > 0) {
                WGRTFCache(code)[source] = translated;
                NSString *key = [@"WGRemoteTranslationCache." stringByAppendingString:code];
                [NSUserDefaults.standardUserDefaults setObject:[WGRTFCache(code) copy] forKey:key];
            }
        });
    }];
    [task resume];
}

static NSString *WGRTFTranslate(NSString *source) {
    if (![source isKindOfClass:NSString.class] || source.length == 0) return source;
    if (WGRTFIsRootMarker(source)) WGRTFMarkRoot();
    if (!WGRTFInWhitegramContext()) return source;
    NSString *code = WGCustomLanguageCode().lowercaseString ?: @"ar";
    if ([code isEqualToString:@"en"]) return source;
    if ([code isEqualToString:@"ar"]) {
        NSString *extra = WGRTFArabicExtra()[source];
        if (extra.length) return extra;
        NSString *bundled = WGTranslateString(source);
        if (bundled.length && ![bundled isEqualToString:source]) return bundled;
    }
    NSString *cached = WGRTFCache(code)[source];
    if (cached.length) return cached;
    WGRTFQueueRemote(source, code);
    return source;
}

#pragma mark - NSAttributedString hooks

static SEL WGRTFAliasOne(void) { return sel_registerName("wg_ikira_rtf_original_initWithString:"); }
static SEL WGRTFAliasAttrs(void) { return sel_registerName("wg_ikira_rtf_original_initWithString:attributes:"); }

static BOOL WGRTFOwnMethod(Class cls, SEL sel) {
    unsigned int count=0; Method *methods=class_copyMethodList(cls,&count); BOOL found=NO;
    for (unsigned int i=0;i<count;i++) if (method_getName(methods[i])==sel) { found=YES; break; }
    free(methods); return found;
}

static id WGRTFInitOne(id self, SEL _cmd, NSString *string) {
    (void)_cmd;
    NSString *translated = WGRTFTranslate(string ?: @"");
    return ((id(*)(id,SEL,NSString *))objc_msgSend)(self, WGRTFAliasOne(), translated ?: string);
}

static id WGRTFInitAttrs(id self, SEL _cmd, NSString *string, NSDictionary<NSAttributedStringKey,id> *attributes) {
    (void)_cmd;
    NSString *translated = WGRTFTranslate(string ?: @"");
    return ((id(*)(id,SEL,NSString *,NSDictionary *))objc_msgSend)(self, WGRTFAliasAttrs(), translated ?: string, attributes);
}

static void WGRTFHook(Class cls, SEL original, SEL alias, IMP replacement) {
    if (!cls || WGRTFOwnMethod(cls, alias)) return;
    Method method = class_getInstanceMethod(cls, original);
    if (!method) return;
    IMP current = method_getImplementation(method); const char *types = method_getTypeEncoding(method);
    if (!current || !types || !class_addMethod(cls, alias, current, types)) return;
    class_replaceMethod(cls, original, replacement, types);
}

static void WGRTFInstallHooks(void) {
    NSMutableOrderedSet *classes=[NSMutableOrderedSet orderedSet];
    id a=[NSAttributedString alloc]; NSAttributedString *s=[a initWithString:@"WGRTFProbe"];
    if (s) [classes addObject:object_getClass(s)]; if (a) [classes addObject:object_getClass(a)];
    id ma=[NSMutableAttributedString alloc]; NSMutableAttributedString *ms=[ma initWithString:@"WGRTFMutableProbe"];
    if (ms) [classes addObject:object_getClass(ms)]; if (ma) [classes addObject:object_getClass(ma)];
    [classes addObject:NSAttributedString.class]; [classes addObject:NSMutableAttributedString.class];
    for (id value in classes) {
        Class cls=(Class)value;
        WGRTFHook(cls,@selector(initWithString:),WGRTFAliasOne(),(IMP)WGRTFInitOne);
        WGRTFHook(cls,@selector(initWithString:attributes:),WGRTFAliasAttrs(),(IMP)WGRTFInitAttrs);
    }
}

__attribute__((constructor))
static void WGRootTextureFixEntry(void) {
    @autoreleasepool {
        WGRTFCaches=[NSMutableDictionary dictionary];
        WGRTFInFlight=[NSMutableSet set];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.25*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ WGRTFInstallHooks(); });
    }
}
