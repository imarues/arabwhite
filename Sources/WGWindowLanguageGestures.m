#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * LanguageWhitegram — robust no-button gesture access
 *
 * - No visible globe/button.
 * - Two-finger single tap is attached to UIWindow, so Texture/ScrollView layers
 *   cannot swallow it before our recognizer sees it.
 * - Backup: long-press the Search settings row / magnifier area for ~0.45s.
 * - Both paths are inert unless the visible screen is Whitegram's features root.
 */

static char WGWindowGestureTargetKey;
static BOOL WGWindowGestureInstallerScheduled = NO;

#pragma mark - Helpers

static NSArray<NSDictionary<NSString *, NSString *> *> *WGWindowLanguages(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *languages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        languages = @[
            @{@"code":@"ar", @"name":@"العربية"},
            @{@"code":@"en", @"name":@"English"},
            @{@"code":@"fr", @"name":@"Français"},
            @{@"code":@"es", @"name":@"Español"},
            @{@"code":@"zh", @"name":@"简体中文"},
            @{@"code":@"vi", @"name":@"Tiếng Việt"},
            @{@"code":@"fa", @"name":@"فارسی"},
            @{@"code":@"pt", @"name":@"Português"},
            @{@"code":@"ru", @"name":@"Русский"},
            @{@"code":@"tr", @"name":@"Türkçe"},
        ];
    });
    return languages;
}

static UIViewController *WGWindowDeepestController(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        return WGWindowDeepestController(vc.presentedViewController);
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        return WGWindowDeepestController(((UINavigationController *)vc).visibleViewController);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return WGWindowDeepestController(((UITabBarController *)vc).selectedViewController);
    }
    for (UIViewController *child in vc.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGWindowDeepestController(child);
    }
    return vc;
}

static NSString *WGWindowVisibleText(UIView *view) {
    if (!view) return nil;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.attributedText.length) return label.attributedText.string;
        if (label.text.length) return label.text;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSAttributedString *a = [button attributedTitleForState:UIControlStateNormal];
        if (a.length) return a.string;
        NSString *t = [button titleForState:UIControlStateNormal];
        if (t.length) return t;
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        if (textView.attributedText.length) return textView.attributedText.string;
        if (textView.text.length) return textView.text;
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        if (field.text.length) return field.text;
        if (field.placeholder.length) return field.placeholder;
    }

    if (view.accessibilityLabel.length) return view.accessibilityLabel;
    if (view.accessibilityValue.length) return view.accessibilityValue;
    return nil;
}

static NSArray<NSString *> *WGWindowExpectedFeatureMarkers(void) {
    static NSArray<NSString *> *sources;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sources = @[@"About Whitegram", @"Search settings", @"Appearance",
                    @"Notifications", @"Messages", @"Camera"];
    });

    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *source in sources) {
        NSString *translated = WGTranslateStringExact(source);
        if (translated.length) [result addObject:translated];
        if (![translated isEqualToString:source]) [result addObject:source];
    }
    return result;
}

typedef struct {
    BOOL sawWhitegram;
    BOOL sawVersion;
    NSUInteger featureHits;
    CGRect searchRect;
    BOOL hasSearchRect;
} WGWindowRootScan;

static BOOL WGWindowTextMatchesAnyMarker(NSString *text, NSArray<NSString *> *markers) {
    if (!text.length) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *marker in markers) {
        if (!marker.length) continue;
        NSString *markerLower = marker.lowercaseString;
        if ([lower containsString:markerLower]) return YES;
    }
    return NO;
}

static void WGWindowScanView(UIView *view,
                             UIWindow *window,
                             NSArray<NSString *> *featureMarkers,
                             NSString *searchTitle,
                             NSString *searchSubtitle,
                             WGWindowRootScan *scan,
                             NSUInteger depth,
                             NSUInteger *visited) {
    if (!view || depth > 95 || *visited > 3200) return;
    (*visited)++;

    NSString *text = WGWindowVisibleText(view);
    if (text.length) {
        NSString *lower = text.lowercaseString;
        if ([lower containsString:@"whitegram"] ||
            [text containsString:@"وايت كرام"] ||
            [text containsString:@"وايتگرام"] ||
            [text containsString:@"Вайтграм"] ||
            [text containsString:@"Уайтграм"]) {
            scan->sawWhitegram = YES;
        }
        if ([text containsString:@"12.9.2 (70)"]) scan->sawVersion = YES;
        if (WGWindowTextMatchesAnyMarker(text, featureMarkers)) scan->featureHits++;

        BOOL isSearchMarker = NO;
        if (searchTitle.length && [lower containsString:searchTitle.lowercaseString]) isSearchMarker = YES;
        if (searchSubtitle.length && [lower containsString:searchSubtitle.lowercaseString]) isSearchMarker = YES;
        if (isSearchMarker && window) {
            CGRect r = [view convertRect:view.bounds toView:window];
            if (!CGRectIsEmpty(r) && !CGRectIsInfinite(r)) {
                // Expand from the text to the entire row so the magnifier icon
                // and the title area both work as the backup trigger.
                CGFloat minY = MAX(0.0, CGRectGetMinY(r) - 44.0);
                CGFloat maxY = MIN(CGRectGetHeight(window.bounds), CGRectGetMaxY(r) + 44.0);
                CGRect row = CGRectMake(CGRectGetWidth(window.bounds) * 0.035,
                                        minY,
                                        CGRectGetWidth(window.bounds) * 0.93,
                                        MAX(74.0, maxY - minY));
                if (scan->hasSearchRect) scan->searchRect = CGRectUnion(scan->searchRect, row);
                else { scan->searchRect = row; scan->hasSearchRect = YES; }
            }
        }
    }

    for (UIView *subview in view.subviews) {
        WGWindowScanView(subview, window, featureMarkers, searchTitle, searchSubtitle,
                         scan, depth + 1, visited);
    }
}

static BOOL WGWindowIsWhitegramFeaturesRoot(UIWindow *window, CGRect *searchRectOut) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;

    NSArray<NSString *> *markers = WGWindowExpectedFeatureMarkers();
    NSString *searchTitle = WGTranslateStringExact(@"Search settings");
    NSString *searchSubtitle = WGTranslateStringExact(@"Find a Whitegram option");

    WGWindowRootScan scan = {0};
    NSUInteger visited = 0;
    WGWindowScanView(window, window, markers, searchTitle, searchSubtitle, &scan, 0, &visited);

    // Whitegram + version is the strongest root signature.  If Texture does not
    // expose the version through UIKit/accessibility, Whitegram + several known
    // feature rows is still unique enough to the feature root.
    BOOL root = scan.sawWhitegram && (scan.sawVersion || scan.featureHits >= 2);
    if (root && searchRectOut) {
        if (scan.hasSearchRect) {
            *searchRectOut = scan.searchRect;
        } else {
            // Last-resort geometry for the first Search settings row on build 70.
            CGFloat h = CGRectGetHeight(window.bounds);
            CGFloat w = CGRectGetWidth(window.bounds);
            *searchRectOut = CGRectMake(w * 0.03, h * 0.43, w * 0.94, h * 0.18);
        }
    }
    return root;
}

static BOOL WGWindowIsLegacyGlobe(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) return NO;
    UIButton *button = (UIButton *)view;
    return [button.accessibilityLabel isEqualToString:@"Languages"] ||
           [button.accessibilityIdentifier isEqualToString:@"iKiraPlus.WhitegramLanguages"];
}

static void WGWindowRemoveGlobes(UIView *view) {
    if (!view) return;
    for (UIView *subview in [view.subviews copy]) {
        if (WGWindowIsLegacyGlobe(subview)) {
            [subview removeFromSuperview];
            continue;
        }
        WGWindowRemoveGlobes(subview);
    }
}

#pragma mark - Menu

static void WGWindowConfirmLanguage(UIViewController *controller,
                                    NSDictionary<NSString *, NSString *> *language) {
    NSString *name = language[@"name"] ?: @"Language";
    NSString *message = [NSString stringWithFormat:
        @"سيتم تغيير لغة ميزات Whitegram إلى %@. سيتم إغلاق التطبيق لتطبيق التغيير.\n\nWhitegram will close and use %@ after you open it again.", name, name];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تغيير اللغة • Change Language"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء • Cancel"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"موافق • OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        WGSetCustomLanguageCode(language[@"code"] ?: @"ar");
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WGWindowShowLanguages(UIWindow *window) {
    CGRect ignored = CGRectZero;
    if (!WGWindowIsWhitegramFeaturesRoot(window, &ignored)) return;

    UIViewController *controller = WGWindowDeepestController(window.rootViewController);
    if (!controller || [controller isKindOfClass:UIAlertController.class] || controller.presentedViewController) return;

    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Languages • اللغات"
                                                                   message:@"Whitegram Features Language"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary<NSString *, NSString *> *language in WGWindowLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
            if (![code isEqualToString:current]) WGWindowConfirmLanguage(controller, language);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel • إلغاء"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = window;
        popover.sourceRect = CGRectMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [controller presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Window gestures

@interface WGWindowLanguageGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@end

@implementation WGWindowLanguageGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer;
    return YES;
}

- (void)twoFingerTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || !self.window) return;
    WGWindowRemoveGlobes(self.window);
    WGWindowShowLanguages(self.window);
}

- (void)searchLongPress:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !self.window) return;

    CGRect searchRect = CGRectZero;
    if (!WGWindowIsWhitegramFeaturesRoot(self.window, &searchRect)) return;
    CGPoint point = [recognizer locationInView:self.window];
    if (!CGRectContainsPoint(searchRect, point)) return;

    WGWindowRemoveGlobes(self.window);
    WGWindowShowLanguages(self.window);
}
@end

static void WGWindowInstallOnWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return;
    WGWindowRemoveGlobes(window);
    if (objc_getAssociatedObject(window, &WGWindowGestureTargetKey)) return;

    WGWindowLanguageGestureTarget *target = [WGWindowLanguageGestureTarget new];
    target.window = window;

    UITapGestureRecognizer *twoFinger = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(twoFingerTap:)];
    twoFinger.numberOfTouchesRequired = 2;
    twoFinger.numberOfTapsRequired = 1;
    twoFinger.cancelsTouchesInView = NO;
    twoFinger.delaysTouchesBegan = NO;
    twoFinger.delaysTouchesEnded = NO;
    twoFinger.delegate = target;
    [window addGestureRecognizer:twoFinger];

    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(searchLongPress:)];
    longPress.minimumPressDuration = 0.45;
    longPress.allowableMovement = 18.0;
    longPress.cancelsTouchesInView = NO;
    longPress.delaysTouchesBegan = NO;
    longPress.delegate = target;
    [window addGestureRecognizer:longPress];

    objc_setAssociatedObject(window, &WGWindowGestureTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WGWindowInstallEverywhere(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) WGWindowInstallOnWindow(window);
        }
    } else {
        for (UIWindow *window in app.windows) WGWindowInstallOnWindow(window);
    }
}

static void WGWindowScheduleInstaller(void) {
    if (WGWindowGestureInstallerScheduled) return;
    WGWindowGestureInstallerScheduled = YES;

    __block NSUInteger remaining = 80; // ~24 seconds covers slow scene/controller creation.
    __block void (^tick)(void) = nil;
    tick = ^{
        WGWindowInstallEverywhere();
        if (remaining-- == 0) {
            WGWindowGestureInstallerScheduled = NO;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), tick);
    };
    dispatch_async(dispatch_get_main_queue(), tick);
}

__attribute__((constructor))
static void WGWindowLanguageGesturesEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            WGWindowScheduleInstaller();
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGWindowScheduleInstaller();
            }];
        });
    }
}
