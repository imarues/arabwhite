#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "WGTranslations.h"

/*
 * Final multilingual bridge for Whitegram 7.0 / build 70.
 *
 * The earlier runtime fallback could translate Arabic immediately because Arabic
 * was bundled, while the other languages depended on asynchronous HTTP. Texture
 * creates immutable attributed strings, so an HTTP result arriving later could
 * not repaint the already-created row. This bridge consumes the generated
 * offline locale packs at attributed-string construction time, before Texture
 * owns the string. It also pins the globe to the physical right edge; leading /
 * trailing anchors swap sides in Arabic/Persian RTL layouts.
 */

static NSTimeInterval WGOLFConstructionUntil = 0.0;
static BOOL WGOLFGlobeFixScheduled = NO;

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
    NSArray<UIViewController *> *children = controller.childViewControllers;
    for (UIViewController *child in children.reverseObjectEnumerator) {
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
            @"About Whitegram",
            @"Version, channel, developer",
            @"Find a Whitegram option",
            @"Avatars, message bubbles, effects",
            @"Whitegram Features",
            @"حول وايت كرام",
            @"ابحث عن خيار في وايت كرام"
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
        NSLayoutAttribute attr1 = constraint.firstAttribute;
        NSLayoutAttribute attr2 = constraint.secondAttribute;
        BOOL horizontal = attr1 == NSLayoutAttributeLeading || attr1 == NSLayoutAttributeTrailing ||
                          attr1 == NSLayoutAttributeLeft || attr1 == NSLayoutAttributeRight ||
                          attr1 == NSLayoutAttributeCenterX || attr2 == NSLayoutAttributeLeading ||
                          attr2 == NSLayoutAttributeTrailing || attr2 == NSLayoutAttributeLeft ||
                          attr2 == NSLayoutAttributeRight || attr2 == NSLayoutAttributeCenterX;
        if (horizontal) [remove addObject:constraint];
    }
    if (remove.count) [NSLayoutConstraint deactivateConstraints:remove];

    BOOL alreadyPinned = NO;
    for (NSLayoutConstraint *constraint in container.constraints) {
        if (constraint.firstItem == button && constraint.firstAttribute == NSLayoutAttributeRight) {
            alreadyPinned = YES;
            break;
        }
    }
    if (!alreadyPinned) {
        NSLayoutConstraint *right = [button.rightAnchor constraintEqualToAnchor:container.safeAreaLayoutGuide.rightAnchor constant:-18.0];
        right.identifier = @"iKiraPlus.WhitegramLanguages.PhysicalRight";
        right.active = YES;
    }
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
    NSArray<NSNumber *> *delays = @[@0.10, @0.28, @0.55, @0.90, @1.40];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGOLFFixGlobeNow();
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGOLFGlobeFixScheduled = NO;
    });
}

#pragma mark - Offline attributed-string translation

static NSString *WGOLFTranslate(NSString *source) {
    if (![source isKindOfClass:NSString.class] || source.length == 0) return source;

    if (WGOLFIsRootMarker(source)) {
        WGOLFConstructionUntil = [NSDate date].timeIntervalSince1970 + 3.0;
        WGOLFScheduleGlobeFix();
    }
    if (!WGOLFInWhitegramContext()) return source;

    NSString *code = WGCustomLanguageCode().lowercaseString;
    if (code.length == 0 || [code isEqualToString:@"en"]) return source;

    // Unlike the previous async-only fallback, WGTranslateString now has a
    // generated table for every menu language in this build. Translation is
    // therefore available synchronously while Texture constructs each row.
    NSString *translated = WGTranslateString(source);
    return translated.length > 0 ? translated : source;
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.55 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGOLFInstallAttributedHooks();
            WGOLFFixGlobeNow();
        });
    }
}
