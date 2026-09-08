#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/*
 * Hard guard: LanguageWhitegram is gesture-only.
 * Any legacy language/globe button created by older overlay code is removed
 * immediately when it enters the view hierarchy or receives its identifying
 * accessibility metadata.
 */

static IMP WGNoIconPreviousDidAddSubview = NULL;
static IMP WGNoIconPreviousSetAccessibilityLabel = NULL;
static IMP WGNoIconPreviousSetAccessibilityIdentifier = NULL;

static BOOL WGNoIconIsLanguageButton(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) return NO;
    UIButton *button = (UIButton *)view;
    NSString *label = button.accessibilityLabel ?: @"";
    NSString *identifier = button.accessibilityIdentifier ?: @"";
    if ([label isEqualToString:@"Languages"]) return YES;
    if ([identifier isEqualToString:@"iKiraPlus.WhitegramLanguages"]) return YES;
    if ([identifier.lowercaseString containsString:@"whitegramlanguages"]) return YES;
    return NO;
}

static void WGNoIconRemoveIfNeeded(UIView *view) {
    if (!WGNoIconIsLanguageButton(view)) return;
    view.hidden = YES;
    view.userInteractionEnabled = NO;
    [view removeFromSuperview];
}

static void WGNoIconPurgeTree(UIView *view) {
    if (!view) return;
    for (UIView *subview in [view.subviews copy]) {
        if (WGNoIconIsLanguageButton(subview)) {
            subview.hidden = YES;
            subview.userInteractionEnabled = NO;
            [subview removeFromSuperview];
            continue;
        }
        WGNoIconPurgeTree(subview);
    }
}

static void WGNoIconPurgeAllWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                WGNoIconPurgeTree(window);
            }
        }
    } else {
        for (UIWindow *window in app.windows) WGNoIconPurgeTree(window);
    }
}

static void WGNoIconDidAddSubview(id self, SEL _cmd, UIView *subview) {
    if (WGNoIconPreviousDidAddSubview) {
        ((void (*)(id, SEL, UIView *))WGNoIconPreviousDidAddSubview)(self, _cmd, subview);
    }
    WGNoIconRemoveIfNeeded(subview);
}

static void WGNoIconSetAccessibilityLabel(id self, SEL _cmd, NSString *label) {
    if (WGNoIconPreviousSetAccessibilityLabel) {
        ((void (*)(id, SEL, NSString *))WGNoIconPreviousSetAccessibilityLabel)(self, _cmd, label);
    }
    if ([self isKindOfClass:UIView.class]) WGNoIconRemoveIfNeeded((UIView *)self);
}

static void WGNoIconSetAccessibilityIdentifier(id self, SEL _cmd, NSString *identifier) {
    if (WGNoIconPreviousSetAccessibilityIdentifier) {
        ((void (*)(id, SEL, NSString *))WGNoIconPreviousSetAccessibilityIdentifier)(self, _cmd, identifier);
    }
    if ([self isKindOfClass:UIView.class]) WGNoIconRemoveIfNeeded((UIView *)self);
}

static void WGNoIconInstallHooks(void) {
    Method didAdd = class_getInstanceMethod(UIView.class, @selector(didAddSubview:));
    if (didAdd) {
        IMP current = method_getImplementation(didAdd);
        if (current != (IMP)WGNoIconDidAddSubview) {
            WGNoIconPreviousDidAddSubview = current;
            method_setImplementation(didAdd, (IMP)WGNoIconDidAddSubview);
        }
    }

    Method label = class_getInstanceMethod(UIView.class, @selector(setAccessibilityLabel:));
    if (label) {
        IMP current = method_getImplementation(label);
        if (current != (IMP)WGNoIconSetAccessibilityLabel) {
            WGNoIconPreviousSetAccessibilityLabel = current;
            method_setImplementation(label, (IMP)WGNoIconSetAccessibilityLabel);
        }
    }

    Method identifier = class_getInstanceMethod(UIView.class, @selector(setAccessibilityIdentifier:));
    if (identifier) {
        IMP current = method_getImplementation(identifier);
        if (current != (IMP)WGNoIconSetAccessibilityIdentifier) {
            WGNoIconPreviousSetAccessibilityIdentifier = current;
            method_setImplementation(identifier, (IMP)WGNoIconSetAccessibilityIdentifier);
        }
    }
}

__attribute__((constructor))
static void WGNoLanguageIconGuardEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            WGNoIconInstallHooks();
            WGNoIconPurgeAllWindows();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGNoIconPurgeAllWindows(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ WGNoIconPurgeAllWindows(); });

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGNoIconPurgeAllWindows();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGNoIconPurgeAllWindows();
            }];
        });
    }
}
