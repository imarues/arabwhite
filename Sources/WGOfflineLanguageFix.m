#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "WGTranslations.h"
#include "KnownWhitegramStrings.inc"

/*
 * LanguageWhitegram — final multi-language bridge for Whitegram 7.0 / build 70.
 *
 * Arabic is bundled and remains fully offline. For the other menu languages we
 * prefetch the build-70 Whitegram catalog immediately after app launch, in a few
 * batched HTTPS requests, and persist it in the same cache used by the older
 * runtime fallback. Texture creates immutable attributed strings; therefore this
 * file translates at attributed-string construction time, before a row is drawn.
 *
 * The globe is also pinned with a physical rightAnchor. leading/trailing swap in
 * RTL, which is why the previous trailingAnchor appeared on the left in Arabic.
 */

static NSTimeInterval WGOLFConstructionUntil = 0.0;
static BOOL WGOLFGlobeFixScheduled = NO;

static NSMutableDictionary<NSString *, NSString *> *WGOLFPrefetchCache;
static NSString *WGOLFPrefetchCode;
static NSURLSession *WGOLFPrefetchSession;
static dispatch_semaphore_t WGOLFPriorityReady;
static BOOL WGOLFPriorityFinished = NO;
static NSInteger WGOLFPendingLanes = 0;

#pragma mark - Language helpers

static BOOL WGOLFSupportedRemoteCode(NSString *code) {
    static NSSet<NSString *> *codes;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        codes = [NSSet setWithArray:@[@"fr", @"es", @"zh", @"vi", @"fa", @"pt", @"ru", @"tr"]];
    });
    return code.length > 0 && [codes containsObject:code.lowercaseString];
}

static NSString *WGOLFTargetCode(NSString *code) {
    if ([code isEqualToString:@"zh"]) return @"zh-CN";
    return code;
}

static NSString *WGOLFCacheDefaultsKey(NSString *code) {
    return [@"WGRemoteTranslationCache." stringByAppendingString:code ?: @""];
}

static NSString *WGOLFCompletionDefaultsKey(NSString *code) {
    return [NSString stringWithFormat:@"WGOfflinePrefetchComplete.build70.v3.%@", code ?: @""];
}

static void WGOLFLoadCacheForCode(NSString *code) {
    if (code.length == 0) return;
    @synchronized(NSUserDefaults.standardUserDefaults) {
        if ([WGOLFPrefetchCode isEqualToString:code] && WGOLFPrefetchCache) return;
        NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:WGOLFCacheDefaultsKey(code)];
        WGOLFPrefetchCode = [code copy];
        WGOLFPrefetchCache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
}

static NSString *WGOLFCachedTranslation(NSString *source, NSString *code) {
    if (source.length == 0 || code.length == 0) return nil;
    WGOLFLoadCacheForCode(code);
    @synchronized(WGOLFPrefetchCache) {
        NSString *value = WGOLFPrefetchCache[source];
        return value.length > 0 ? value : nil;
    }
}

static void WGOLFPersistCache(void) {
    NSString *code = WGOLFPrefetchCode;
    if (code.length == 0 || !WGOLFPrefetchCache) return;
    NSDictionary *snapshot;
    @synchronized(WGOLFPrefetchCache) {
        snapshot = [WGOLFPrefetchCache copy];
    }
    [NSUserDefaults.standardUserDefaults setObject:snapshot forKey:WGOLFCacheDefaultsKey(code)];
}

#pragma mark - Whitegram context

static BOOL WGOLFClassLooksWhitegram(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls).lowercaseString;
    if ([name containsString:@"whitegram"]) return YES;
    NSArray<NSString *> *needles = @[
        @"wgvirus", @"wgcamera", @"wgfont", @"wgicon", @"wgplugin",
        @"wgonline", @"wgprofile", @"wgrestore", @"wgbadge", @"wgequalizer",
        @"wgvoice", @"wgsearch", @"wgmap", @"wglanguage", @"wgstreak",
        @"wgappearance", @"wgsettings", @"wgfeature", @"wgbeta"
    ];
    for (NSString *needle in needles) {
        if ([name containsString:needle]) return YES;
    }
    return NO;
}

static UIViewController *WGOLFDeepest(UIViewController *controller) {
    if (!controller) return nil;
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) return WGOLFDeepest(presented);
    if ([controller isKindOfClass:UINavigationController.class]) {
        return WGOLFDeepest(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return WGOLFDeepest(((UITabBarController *)controller).selectedViewController);
    }
    for (UIViewController *child in controller.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGOLFDeepest(child);
    }
    return controller;
}

static NSArray<UIWindow *> *WGOLFVisibleWindows(void) {
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
    return result;
}

static UIViewController *WGOLFTopController(void) {
    UIWindow *best = nil;
    for (UIWindow *window in WGOLFVisibleWindows()) {
        if (!best || window.isKeyWindow || window.windowLevel > best.windowLevel) best = window;
    }
    return WGOLFDeepest(best.rootViewController);
}

static UIButton *WGOLFFindGlobeInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 70) return nil;
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        if ([button.accessibilityIdentifier isEqualToString:@"iKiraPlus.WhitegramLanguages"] ||
            [button.accessibilityLabel isEqualToString:@"Languages"]) {
            return button;
        }
    }
    for (UIView *subview in view.subviews) {
        UIButton *found = WGOLFFindGlobeInView(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static BOOL WGOLFControllerTreeHasGlobe(UIViewController *controller) {
    if (!controller) return NO;
    if (controller.isViewLoaded && WGOLFFindGlobeInView(controller.view, 0)) return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if (WGOLFControllerTreeHasGlobe(child)) return YES;
    }
    return NO;
}

static BOOL WGOLFIsRootMarker(NSString *text) {
    if (text.length == 0) return NO;
    static NSSet<NSString *> *markers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        markers = [NSSet setWithArray:@[
            @"About Whitegram", @"Version, channel, developer", @"Find a Whitegram option",
            @"Avatars, message bubbles, effects", @"Whitegram Features",
            @"حول وايت كرام", @"ابحث عن خيار في وايت كرام"
        ]];
    });
    return [markers containsObject:text];
}

static BOOL WGOLFInWhitegramContext(void) {
    if ([NSDate date].timeIntervalSince1970 < WGOLFConstructionUntil) return YES;
    if (![NSThread isMainThread]) return NO;

    UIViewController *top = WGOLFTopController();
    if (!top) return NO;
    if (WGOLFClassLooksWhitegram(top.class)) return YES;

    UINavigationController *nav = top.navigationController;
    if (nav) {
        for (UIViewController *item in nav.viewControllers) {
            if (WGOLFClassLooksWhitegram(item.class)) return YES;
            if (item.isViewLoaded && WGOLFFindGlobeInView(item.view, 0)) return YES;
        }
    }
    return WGOLFControllerTreeHasGlobe(top);
}

#pragma mark - Physical right-side globe

static void WGOLFPinButtonToPhysicalRight(UIButton *button) {
    UIView *container = button.superview;
    if (!button || !container) return;

    NSMutableArray<NSLayoutConstraint *> *remove = [NSMutableArray array];
    for (NSLayoutConstraint *constraint in container.constraints) {
        BOOL touches = (constraint.firstItem == button || constraint.secondItem == button);
        if (!touches) continue;
        NSLayoutAttribute a = constraint.firstAttribute;
        NSLayoutAttribute b = constraint.secondAttribute;
        BOOL horizontal = a == NSLayoutAttributeLeading || a == NSLayoutAttributeTrailing ||
                          a == NSLayoutAttributeLeft || a == NSLayoutAttributeRight ||
                          a == NSLayoutAttributeCenterX || b == NSLayoutAttributeLeading ||
                          b == NSLayoutAttributeTrailing || b == NSLayoutAttributeLeft ||
                          b == NSLayoutAttributeRight || b == NSLayoutAttributeCenterX;
        if (horizontal) [remove addObject:constraint];
    }
    if (remove.count) [NSLayoutConstraint deactivateConstraints:remove];

    NSLayoutConstraint *right = [button.rightAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.rightAnchor constant:-18.0];
    right.identifier = @"iKiraPlus.WhitegramLanguages.PhysicalRight";
    right.active = YES;
    [container bringSubviewToFront:button];
}

static void WGOLFFixGlobeNow(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WGOLFFixGlobeNow(); });
        return;
    }
    for (UIWindow *window in WGOLFVisibleWindows()) {
        UIButton *button = WGOLFFindGlobeInView(window, 0);
        if (button) WGOLFPinButtonToPhysicalRight(button);
    }
}

static void WGOLFScheduleGlobeFix(void) {
    if (WGOLFGlobeFixScheduled) return;
    WGOLFGlobeFixScheduled = YES;
    for (NSNumber *delay in @[@0.08, @0.20, @0.42, @0.72, @1.10]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGOLFFixGlobeNow();
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGOLFGlobeFixScheduled = NO;
    });
}

#pragma mark - Batched runtime prefetch

static NSArray<NSString *> *WGOLFPriorityStrings(void) {
    return @[
        @"About Whitegram", @"Version, channel, developer",
        @"Search settings", @"Find a Whitegram option",
        @"Appearance", @"Avatars, message bubbles, effects",
        @"Notifications", @"Local notifications",
        @"Liquid Glass", @"Glass panels and blur",
        @"Messages", @"Deleted, edited, cache",
        @"Camera", @"Zoom, HD sending, video messages",
        @"Spy", @"Hide online, reads and typing",
        @"Protection", @"Content and call protection",
        @"Info Display", @"ID, data centre, creation date",
        @"Menu Sections", @"What to show in the Telegram menu",
        @"Navigation Tabs", @"The bottom bar and its tabs",
        @"Local Stars", @"Your own star balance on screen",
        @"Custom Font", @"A custom font for the whole app",
        @"Keychain", @"Saving logins to the Keychain",
        @"Translation", @"Translating incoming and outgoing",
        @"Enhanced Traffic", @"Masking Telegram traffic",
        @"VirusTotal", @"Checking links and files",
        @"Voice Changer", @"Changing your voice in recordings",
        @"More", @"All Settings", @"The full list of settings"
    ];
}

static BOOL WGOLFHasFormatPlaceholder(NSString *source) {
    if (source.length == 0) return NO;
    NSRange percent = [source rangeOfString:@"%"];
    return percent.location != NSNotFound;
}

static NSString *WGOLFSafeBatchSource(NSString *source) {
    return [[source stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
            stringByReplacingOccurrencesOfString:@"\n" withString:@"__WGNL__"];
}

static NSString *WGOLFRestoreBatchSource(NSString *source) {
    return [source stringByReplacingOccurrencesOfString:@"__WGNL__" withString:@"\n"];
}

static NSArray<NSArray<NSString *> *> *WGOLFBuildBatches(void) {
    NSMutableOrderedSet<NSString *> *ordered = [NSMutableOrderedSet orderedSet];
    for (NSString *source in WGOLFPriorityStrings()) {
        if (!WGOLFHasFormatPlaceholder(source)) [ordered addObject:source];
    }
    for (NSString *source in WGGeneratedKnownWhitegramStrings()) {
        if (source.length > 1 && !WGOLFHasFormatPlaceholder(source)) [ordered addObject:source];
    }

    NSMutableArray<NSArray<NSString *> *> *batches = [NSMutableArray array];
    NSMutableArray<NSString *> *priority = [NSMutableArray array];
    NSUInteger priorityCount = MIN(WGOLFPriorityStrings().count, ordered.count);
    for (NSUInteger i = 0; i < priorityCount; i++) [priority addObject:ordered[i]];
    if (priority.count) [batches addObject:[priority copy]];

    NSUInteger start = priorityCount;
    const NSUInteger normalBatch = 24;
    while (start < ordered.count) {
        NSUInteger count = MIN(normalBatch, ordered.count - start);
        NSMutableArray<NSString *> *batch = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) [batch addObject:ordered[start + i]];
        [batches addObject:[batch copy]];
        start += count;
    }
    return batches;
}

static NSString *WGOLFParseGoogleData(NSData *data) {
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

static NSDictionary<NSString *, NSString *> *WGOLFDecodeBatch(NSString *blob, NSArray<NSString *> *sources) {
    if (blob.length == 0 || sources.count == 0) return @{};
    NSMutableDictionary<NSString *, NSString *> *result = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < sources.count; i++) {
        NSString *marker = [NSString stringWithFormat:@"__WGID%03lu__", (unsigned long)i];
        NSRange markerRange = [blob rangeOfString:marker];
        if (markerRange.location == NSNotFound) continue;
        NSUInteger start = NSMaxRange(markerRange);
        NSUInteger end = blob.length;
        if (i + 1 < sources.count) {
            NSString *nextMarker = [NSString stringWithFormat:@"__WGID%03lu__", (unsigned long)(i + 1)];
            NSRange next = [blob rangeOfString:nextMarker options:0 range:NSMakeRange(start, blob.length - start)];
            if (next.location != NSNotFound) end = next.location;
        }
        if (end <= start) continue;
        NSString *value = [blob substringWithRange:NSMakeRange(start, end - start)];
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\r\n:-"]];
        value = WGOLFRestoreBatchSource(value);
        if (value.length > 0 && ![value isEqualToString:sources[i]]) result[sources[i]] = value;
    }
    return result;
}

static void WGOLFSignalPriorityIfNeeded(BOOL priorityBatch) {
    if (!priorityBatch || WGOLFPriorityFinished) return;
    @synchronized(NSUserDefaults.standardUserDefaults) {
        if (WGOLFPriorityFinished) return;
        WGOLFPriorityFinished = YES;
        if (WGOLFPriorityReady) dispatch_semaphore_signal(WGOLFPriorityReady);
    }
}

static void WGOLFFinishLane(NSString *code) {
    @synchronized(NSUserDefaults.standardUserDefaults) {
        WGOLFPendingLanes--;
        if (WGOLFPendingLanes <= 0) {
            WGOLFPersistCache();
            if (WGOLFPrefetchCache.count >= 500) {
                [NSUserDefaults.standardUserDefaults setBool:YES forKey:WGOLFCompletionDefaultsKey(code)];
            }
        }
    }
}

static void WGOLFSendBatchLane(NSArray<NSArray<NSString *> *> *batches,
                               NSUInteger batchIndex,
                               NSUInteger stride,
                               NSString *code) {
    if (batchIndex >= batches.count) {
        WGOLFFinishLane(code);
        return;
    }

    NSArray<NSString *> *sources = batches[batchIndex];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:sources.count];
    for (NSUInteger i = 0; i < sources.count; i++) {
        NSString *marker = [NSString stringWithFormat:@"__WGID%03lu__", (unsigned long)i];
        [lines addObject:[NSString stringWithFormat:@"%@ %@", marker, WGOLFSafeBatchSource(sources[i])]];
    }
    NSString *query = [lines componentsJoinedByString:@"\n"];

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"en"],
        [NSURLQueryItem queryItemWithName:@"tl" value:WGOLFTargetCode(code)],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"]
    ];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:components.URL];
    request.HTTPMethod = @"POST";
    NSString *body = [@"q=" stringByAppendingString:[query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @""];
    request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/x-www-form-urlencoded; charset=UTF-8" forHTTPHeaderField:@"Content-Type"];
    request.timeoutInterval = 12.0;

    BOOL priorityBatch = batchIndex == 0;
    NSURLSessionDataTask *task = [WGOLFPrefetchSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        if (!error) {
            NSString *blob = WGOLFParseGoogleData(data);
            NSDictionary<NSString *, NSString *> *decoded = WGOLFDecodeBatch(blob, sources);
            if (decoded.count) {
                @synchronized(WGOLFPrefetchCache) {
                    [WGOLFPrefetchCache addEntriesFromDictionary:decoded];
                }
                WGOLFPersistCache();
            }
        }
        WGOLFSignalPriorityIfNeeded(priorityBatch);
        WGOLFSendBatchLane(batches, batchIndex + stride, stride, code);
    }];
    [task resume];
}

static void WGOLFStartPrefetchIfNeeded(void) {
    NSString *code = WGCustomLanguageCode().lowercaseString;
    if (!WGOLFSupportedRemoteCode(code)) return;
    WGOLFLoadCacheForCode(code);

    BOOL complete = [NSUserDefaults.standardUserDefaults boolForKey:WGOLFCompletionDefaultsKey(code)];
    if (complete && WGOLFPrefetchCache.count >= 500) {
        WGOLFPriorityFinished = YES;
        if (WGOLFPriorityReady) dispatch_semaphore_signal(WGOLFPriorityReady);
        return;
    }

    if (!WGOLFPrefetchSession) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.timeoutIntervalForRequest = 12.0;
        config.timeoutIntervalForResource = 18.0;
        WGOLFPrefetchSession = [NSURLSession sessionWithConfiguration:config];
    }

    NSArray<NSArray<NSString *> *> *batches = WGOLFBuildBatches();
    if (batches.count == 0) return;
    NSUInteger lanes = MIN((NSUInteger)4, batches.count);
    WGOLFPendingLanes = (NSInteger)lanes;
    for (NSUInteger lane = 0; lane < lanes; lane++) {
        WGOLFSendBatchLane(batches, lane, lanes, code);
    }
}

#pragma mark - Attributed-string translation

static NSString *WGOLFTranslate(NSString *source) {
    if (![source isKindOfClass:NSString.class] || source.length == 0) return source;

    BOOL rootMarker = WGOLFIsRootMarker(source);
    if (rootMarker) {
        WGOLFConstructionUntil = [NSDate date].timeIntervalSince1970 + 3.0;
        WGOLFScheduleGlobeFix();
    }
    if (!WGOLFInWhitegramContext()) return source;

    NSString *code = WGCustomLanguageCode().lowercaseString;
    if (code.length == 0 || [code isEqualToString:@"en"]) return source;

    NSString *bundled = WGTranslateString(source);
    if (bundled.length > 0 && ![bundled isEqualToString:source]) return bundled;

    if (WGOLFSupportedRemoteCode(code)) {
        // If the user opens Whitegram immediately after relaunch, allow the first
        // priority batch a short head start. This happens only once and prevents
        // the main feature page from being permanently created in English.
        if (rootMarker && !WGOLFPriorityFinished && WGOLFPriorityReady) {
            dispatch_semaphore_wait(WGOLFPriorityReady, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)));
        }
        NSString *cached = WGOLFCachedTranslation(source, code);
        if (cached.length > 0) return cached;
    }
    return source;
}

static BOOL WGOLFOwnsSelector(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static SEL WGOLFAliasOne(void) {
    return sel_registerName("wg_ikira_offline_original_initWithString:");
}

static SEL WGOLFAliasAttrs(void) {
    return sel_registerName("wg_ikira_offline_original_initWithString:attributes:");
}

static id WGOLFInitOne(id self, SEL _cmd, NSString *string) {
    (void)_cmd;
    NSString *translated = WGOLFTranslate(string ?: @"");
    return ((id (*)(id, SEL, NSString *))objc_msgSend)(self, WGOLFAliasOne(), translated ?: string);
}

static id WGOLFInitAttrs(id self, SEL _cmd, NSString *string, NSDictionary<NSAttributedStringKey, id> *attributes) {
    (void)_cmd;
    NSString *translated = WGOLFTranslate(string ?: @"");
    return ((id (*)(id, SEL, NSString *, NSDictionary *))objc_msgSend)(self, WGOLFAliasAttrs(), translated ?: string, attributes);
}

static void WGOLFHookSelector(Class cls, SEL original, SEL alias, IMP replacement) {
    if (!cls || WGOLFOwnsSelector(cls, alias)) return;
    Method method = class_getInstanceMethod(cls, original);
    if (!method) return;
    IMP current = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!current || !types) return;
    if (!class_addMethod(cls, alias, current, types)) return;
    class_replaceMethod(cls, original, replacement, types);
}

static void WGOLFInstallAttributedHooks(void) {
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];

    id immutableAlloc = [NSAttributedString alloc];
    NSAttributedString *immutableSample = [immutableAlloc initWithString:@"WGOfflineProbe"];
    if (immutableSample) [classes addObject:object_getClass(immutableSample)];
    if (immutableAlloc) [classes addObject:object_getClass(immutableAlloc)];

    id mutableAlloc = [NSMutableAttributedString alloc];
    NSMutableAttributedString *mutableSample = [mutableAlloc initWithString:@"WGOfflineMutableProbe"];
    if (mutableSample) [classes addObject:object_getClass(mutableSample)];
    if (mutableAlloc) [classes addObject:object_getClass(mutableAlloc)];

    [classes addObject:NSAttributedString.class];
    [classes addObject:NSMutableAttributedString.class];

    for (id value in classes) {
        Class cls = (Class)value;
        WGOLFHookSelector(cls, @selector(initWithString:), WGOLFAliasOne(), (IMP)WGOLFInitOne);
        WGOLFHookSelector(cls, @selector(initWithString:attributes:), WGOLFAliasAttrs(), (IMP)WGOLFInitAttrs);
    }
}

__attribute__((constructor))
static void WGOfflineLanguageFixEntry(void) {
    @autoreleasepool {
        WGOLFPriorityReady = dispatch_semaphore_create(0);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGOLFStartPrefetchIfNeeded();
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGOLFInstallAttributedHooks();
            WGOLFFixGlobeNow();
        });
    }
}
