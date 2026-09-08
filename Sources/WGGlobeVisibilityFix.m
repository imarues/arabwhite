#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

/*
 * LanguageWhitegram — globe visibility guard
 * Whitegram 7.0 / Telegram 12.9.2 build 70
 *
 * WGLanguageOverlay intentionally hooks UIViewController globally so it can
 * translate Whitegram feature controllers.  The language button, however,
 * must be much more narrowly scoped: it belongs only to the Whitegram features
 * root page (the page that visibly contains both "Whitegram" and build
 * "12.9.2 (70)").
 *
 * This guard deliberately does NOT use class-name guesses, navigation-stack
 * ancestry or cached root markers for button visibility.  It also removes the
 * button as soon as that root page disappears, and retries installation after
 * the page has finished drawing so slow Texture/AsyncDisplayKit layouts cannot
 * make the globe randomly disappear.
 */

static IMP WGGlobePreviousViewDidAppear = NULL;
static IMP WGGlobePreviousViewDidDisappear = NULL;
static BOOL WGGlobeHooksInstalled = NO;

#pragma mark - Strict root detection

static void WGGlobeCollectRootMarkers(UIView *view,
                                      BOOL *sawVersion,
                                      BOOL *sawWhitegram,
                                      NSUInteger *visited) {
    if (!view || *visited > 2200 || (*sawVersion && *sawWhitegram)) return;
    (*visited)++;

    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) {
        text = ((UILabel *)view).text;
    } else if ([view isKindOfClass:UIButton.class]) {
        text = [(UIButton *)view titleForState:UIControlStateNormal];
    } else if ([view isKindOfClass:UITextView.class]) {
        text = ((UITextView *)view).text;
    }

    if (text.length > 0) {
        if ([text containsString:@"12.9.2 (70)"]) {
            *sawVersion = YES;
        }

        NSString *lower = text.lowercaseString;
        if ([lower containsString:@"whitegram"] ||
            [text containsString:@"وايت كرام"] ||
            [text containsString:@"وايتگرام"] ||
            [text containsString:@"Вайтграм"]) {
            *sawWhitegram = YES;
        }
    }

    for (UIView *subview in view.subviews) {
        WGGlobeCollectRootMarkers(subview, sawVersion, sawWhitegram, visited);
    }
}

static BOOL WGGlobeIsStrictWhitegramRoot(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded || !controller.view.window) return NO;

    BOOL sawVersion = NO;
    BOOL sawWhitegram = NO;
    NSUInteger visited = 0;
    WGGlobeCollectRootMarkers(controller.view, &sawVersion, &sawWhitegram, &visited);
    return sawVersion && sawWhitegram;
}

#pragma mark - Button discovery / cleanup

static BOOL WGGlobeIsOurLanguageButton(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) return NO;
    UIButton *button = (UIButton *)view;
    return [button.accessibilityLabel isEqualToString:@"Languages"];
}

static UIButton *WGGlobeFindLanguageButton(UIView *view, NSUInteger depth) {
    if (!view || depth > 90) return nil;
    if (WGGlobeIsOurLanguageButton(view)) return (UIButton *)view;

    for (UIView *subview in view.subviews) {
        UIButton *found = WGGlobeFindLanguageButton(subview, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void WGGlobeRemoveLanguageButtons(UIView *view, UIView *allowedRoot, NSUInteger depth) {
    if (!view || depth > 90) return;

    NSArray<UIView *> *children = [view.subviews copy];
    for (UIView *subview in children) {
        if (WGGlobeIsOurLanguageButton(subview)) {
            BOOL allowed = allowedRoot && [subview isDescendantOfView:allowedRoot];
            if (!allowed) {
                [subview removeFromSuperview];
                continue;
            }
        }
        WGGlobeRemoveLanguageButtons(subview, allowedRoot, depth + 1);
    }
}

static NSArray<UIWindow *> *WGGlobeVisibleWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
            }
        }
    }

    if (windows.count == 0) {
        for (UIWindow *window in application.windows) {
            if (!window.hidden && window.alpha > 0.01) [windows addObject:window];
        }
    }
    return windows.array;
}

static void WGGlobeRemoveStraysExceptRoot(UIView *allowedRoot) {
    for (UIWindow *window in WGGlobeVisibleWindows()) {
        WGGlobeRemoveLanguageButtons(window, allowedRoot, 0);
    }
}

#pragma mark - Reliable root-only installation

static void WGGlobeCreateButtonIfNeeded(UIViewController *controller) {
    if (!WGGlobeIsStrictWhitegramRoot(controller)) return;

    // The original overlay may already have created its button.  Reuse it.
    UIButton *existing = WGGlobeFindLanguageButton(controller.view, 0);
    if (existing) {
        existing.hidden = NO;
        existing.userInteractionEnabled = YES;
        [controller.view bringSubviewToFront:existing];
        WGGlobeRemoveStraysExceptRoot(controller.view);
        return;
    }

    SEL action = sel_registerName("wg_ikira_showLanguageMenu:");
    if (![controller respondsToSelector:action]) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.accessibilityLabel = @"Languages";
    button.layer.cornerRadius = 22.0;
    button.layer.masksToBounds = YES;
    button.backgroundColor = [UIColor.systemGray5Color colorWithAlphaComponent:0.94];
    button.tintColor = UIColor.labelColor;

    UIImage *image = [UIImage systemImageNamed:@"globe"
                              withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                                                                 weight:UIImageSymbolWeightSemibold]];
    if (image) {
        [button setImage:image forState:UIControlStateNormal];
    } else {
        [button setTitle:@"🌐" forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:21.0];
    }

    [button addTarget:controller action:action forControlEvents:UIControlEventTouchUpInside];
    [controller.view addSubview:button];

    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18.0],
        [button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0],
    ]];

    [controller.view bringSubviewToFront:button];
    WGGlobeRemoveStraysExceptRoot(controller.view);
}

static void WGGlobeReconcileController(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) {
        WGGlobeRemoveStraysExceptRoot(nil);
        return;
    }

    if (WGGlobeIsStrictWhitegramRoot(controller)) {
        WGGlobeCreateButtonIfNeeded(controller);
    } else {
        // Any normal Telegram page or Whitegram sub-page must have no globe.
        WGGlobeRemoveStraysExceptRoot(nil);
    }
}

static void WGGlobeScheduleReconcile(UIViewController *controller, NSTimeInterval delay) {
    __weak UIViewController *weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIViewController *strongController = weakController;
        if (!strongController || !strongController.view.window) return;
        WGGlobeReconcileController(strongController);
    });
}

#pragma mark - Lifecycle guard

static void WGGlobeViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (WGGlobePreviousViewDidAppear) {
        ((void (*)(id, SEL, BOOL))WGGlobePreviousViewDidAppear)(self, _cmd, animated);
    }

    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (!controller) return;

    // First clean immediately. Then retry after Texture/Swift rows have laid out.
    WGGlobeReconcileController(controller);
    WGGlobeScheduleReconcile(controller, 0.08);
    WGGlobeScheduleReconcile(controller, 0.28);
    WGGlobeScheduleReconcile(controller, 0.70);
}

static void WGGlobeViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (WGGlobePreviousViewDidDisappear) {
        ((void (*)(id, SEL, BOOL))WGGlobePreviousViewDidDisappear)(self, _cmd, animated);
    }

    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (controller && controller.isViewLoaded) {
        WGGlobeRemoveLanguageButtons(controller.view, nil, 0);
    }

    // Also purge a wrongly attached button from any persistent Telegram
    // container/root controller that did not itself disappear.
    dispatch_async(dispatch_get_main_queue(), ^{
        WGGlobeRemoveStraysExceptRoot(nil);
    });
}

static void WGGlobeInstallHooks(void) {
    if (WGGlobeHooksInstalled) return;
    WGGlobeHooksInstalled = YES;

    Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (appear) {
        WGGlobePreviousViewDidAppear = method_getImplementation(appear);
        method_setImplementation(appear, (IMP)WGGlobeViewDidAppear);
    }

    Method disappear = class_getInstanceMethod(UIViewController.class, @selector(viewDidDisappear:));
    if (disappear) {
        WGGlobePreviousViewDidDisappear = method_getImplementation(disappear);
        method_setImplementation(disappear, (IMP)WGGlobeViewDidDisappear);
    }
}

__attribute__((constructor))
static void WGGlobeVisibilityFixEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            // Install after WGLanguageOverlay's queued lifecycle hook whenever
            // possible. If the order is reversed, both implementations still
            // chain because each captures the current IMP before replacing it.
            WGGlobeInstallHooks();
            WGGlobeRemoveStraysExceptRoot(nil);
        });
    }
}
