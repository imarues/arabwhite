#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * LanguageWhitegram — lean gesture-only language menu.
 *
 * No visible language control is ever created.  The recognizers live on UIWindow
 * and perform Whitegram-root detection only after the user actually performs a
 * gesture, so there is no idle scanning of Telegram Settings.
 */

static char WGLeanGestureTargetKey;

static NSArray<NSDictionary<NSString *, NSString *> *> *WGLeanLanguages(void) {
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
            @{@"code": @"tr", @"name": @"Türkçe"}
        ];
    });
    return languages;
}

static UIViewController *WGLeanDeepestController(UIViewController *controller) {
    if (!controller) return nil;
    UIViewController *presented = controller.presentedViewController;
    if (presented && !presented.isBeingDismissed) return WGLeanDeepestController(presented);
    if ([controller isKindOfClass:UINavigationController.class]) {
        return WGLeanDeepestController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return WGLeanDeepestController(((UITabBarController *)controller).selectedViewController);
    }
    for (UIViewController *child in controller.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGLeanDeepestController(child);
    }
    return controller;
}

static NSString *WGLeanVisibleText(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        return label.attributedText.length ? label.attributedText.string : label.text;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSAttributedString *attributed = [button attributedTitleForState:UIControlStateNormal];
        return attributed.length ? attributed.string : [button titleForState:UIControlStateNormal];
    }
    if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        return textView.attributedText.length ? textView.attributedText.string : textView.text;
    }
    if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        return field.text.length ? field.text : field.placeholder;
    }
    if (view.accessibilityLabel.length) return view.accessibilityLabel;
    if (view.accessibilityValue.length) return view.accessibilityValue;
    return nil;
}

typedef struct {
    BOOL sawBrand;
    BOOL sawVersion;
    NSUInteger featureHits;
    CGRect searchRect;
    BOOL hasSearchRect;
} WGLeanRootScan;

static NSArray<NSString *> *WGLeanFeatureMarkers(void) {
    static NSArray<NSString *> *sources;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sources = @[@"About Whitegram", @"Search settings", @"Appearance",
                    @"Notifications", @"Messages", @"Camera"];
    });
    NSMutableArray<NSString *> *markers = [NSMutableArray arrayWithCapacity:sources.count * 2];
    for (NSString *source in sources) {
        [markers addObject:source];
        NSString *translated = WGTranslateStringExact(source);
        if (translated.length && ![translated isEqualToString:source]) [markers addObject:translated];
    }
    return markers;
}

static BOOL WGLeanTextMatchesMarker(NSString *text, NSArray<NSString *> *markers) {
    if (!text.length) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *marker in markers) {
        if (marker.length && [lower containsString:marker.lowercaseString]) return YES;
    }
    return NO;
}

static void WGLeanScanView(UIView *view,
                           UIWindow *window,
                           NSArray<NSString *> *markers,
                           NSString *searchTitle,
                           NSString *searchSubtitle,
                           WGLeanRootScan *scan,
                           NSUInteger depth,
                           NSUInteger *visited) {
    if (!view || depth > 80 || *visited >= 1800) return;
    (*visited)++;

    NSString *text = WGLeanVisibleText(view);
    if (text.length) {
        NSString *lower = text.lowercaseString;
        if ([lower containsString:@"whitegram"] ||
            [text containsString:@"وايت كرام"] ||
            [text containsString:@"وايتگرام"] ||
            [text containsString:@"Вайтграм"] ||
            [text containsString:@"Уайтграм"]) {
            scan->sawBrand = YES;
        }
        if ([text containsString:@"12.9.2 (70)"]) scan->sawVersion = YES;
        if (WGLeanTextMatchesMarker(text, markers)) scan->featureHits++;

        BOOL searchMatch = NO;
        if (searchTitle.length && [lower containsString:searchTitle.lowercaseString]) searchMatch = YES;
        if (searchSubtitle.length && [lower containsString:searchSubtitle.lowercaseString]) searchMatch = YES;
        if (!searchMatch && ([lower containsString:@"search settings"] ||
                             [lower containsString:@"find a whitegram option"])) searchMatch = YES;
        if (searchMatch && window) {
            CGRect rect = [view convertRect:view.bounds toView:window];
            if (!CGRectIsEmpty(rect) && !CGRectIsInfinite(rect)) {
                CGFloat minY = MAX(0.0, CGRectGetMinY(rect) - 50.0);
                CGFloat maxY = MIN(CGRectGetHeight(window.bounds), CGRectGetMaxY(rect) + 50.0);
                CGRect row = CGRectMake(CGRectGetWidth(window.bounds) * 0.02,
                                        minY,
                                        CGRectGetWidth(window.bounds) * 0.96,
                                        MAX(82.0, maxY - minY));
                scan->searchRect = scan->hasSearchRect ? CGRectUnion(scan->searchRect, row) : row;
                scan->hasSearchRect = YES;
            }
        }
    }

    if (scan->sawBrand && scan->sawVersion && scan->hasSearchRect) return;
    for (UIView *subview in view.subviews) {
        WGLeanScanView(subview, window, markers, searchTitle, searchSubtitle,
                       scan, depth + 1, visited);
    }
}

static BOOL WGLeanIsWhitegramRoot(UIWindow *window, CGRect *searchRectOut) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;

    NSString *searchTitle = WGTranslateStringExact(@"Search settings");
    NSString *searchSubtitle = WGTranslateStringExact(@"Find a Whitegram option");
    WGLeanRootScan scan = {0};
    NSUInteger visited = 0;
    WGLeanScanView(window, window, WGLeanFeatureMarkers(), searchTitle, searchSubtitle,
                   &scan, 0, &visited);

    BOOL isRoot = scan.sawBrand && (scan.sawVersion || scan.featureHits >= 2);
    if (isRoot && searchRectOut) {
        if (scan.hasSearchRect) {
            *searchRectOut = scan.searchRect;
        } else {
            CGFloat w = CGRectGetWidth(window.bounds);
            CGFloat h = CGRectGetHeight(window.bounds);
            *searchRectOut = CGRectMake(w * 0.03, h * 0.43, w * 0.94, h * 0.18);
        }
    }
    return isRoot;
}

static void WGLeanConfirmLanguage(UIViewController *controller,
                                  NSDictionary<NSString *, NSString *> *language) {
    NSString *name = language[@"name"] ?: @"Language";
    NSString *message = [NSString stringWithFormat:
        @"سيتم تغيير لغة ميزات Whitegram إلى %@. سيتم إغلاق التطبيق لتطبيق التغيير.\n\nWhitegram will close and use %@ after you open it again.",
        name, name];
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

static void WGLeanShowLanguages(UIWindow *window) {
    if (!WGLeanIsWhitegramRoot(window, NULL)) return;
    UIViewController *controller = WGLeanDeepestController(window.rootViewController);
    if (!controller || [controller isKindOfClass:UIAlertController.class] || controller.presentedViewController) return;

    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Languages • اللغات"
                                                                   message:@"Whitegram Features Language\nTelegram : @ikiraplus"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary<NSString *, NSString *> *language in WGLeanLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
            if (![code isEqualToString:current]) WGLeanConfirmLanguage(controller, language);
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

@interface WGLeanGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@end

@implementation WGLeanGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (void)twoFingerTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized && self.window) {
        WGLeanShowLanguages(self.window);
    }
}

- (void)twoFingerHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan && self.window) {
        WGLeanShowLanguages(self.window);
    }
}

- (void)searchHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !self.window) return;
    CGRect searchRect = CGRectZero;
    if (!WGLeanIsWhitegramRoot(self.window, &searchRect)) return;
    CGPoint point = [recognizer locationInView:self.window];
    if (!CGRectContainsPoint(searchRect, point)) return;
    WGLeanShowLanguages(self.window);
}
@end

static void WGLeanInstallOnWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return;
    if (objc_getAssociatedObject(window, &WGLeanGestureTargetKey)) return;

    WGLeanGestureTarget *target = [WGLeanGestureTarget new];
    target.window = window;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target
                                                                         action:@selector(twoFingerTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = target;
    [window addGestureRecognizer:tap];

    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                       action:@selector(twoFingerHold:)];
    hold.numberOfTouchesRequired = 2;
    hold.minimumPressDuration = 0.32;
    hold.allowableMovement = 42.0;
    hold.cancelsTouchesInView = NO;
    hold.delaysTouchesBegan = NO;
    hold.delegate = target;
    [window addGestureRecognizer:hold];

    UILongPressGestureRecognizer *search = [[UILongPressGestureRecognizer alloc] initWithTarget:target
                                                                                         action:@selector(searchHold:)];
    search.minimumPressDuration = 0.45;
    search.allowableMovement = 20.0;
    search.cancelsTouchesInView = NO;
    search.delaysTouchesBegan = NO;
    search.delegate = target;
    [window addGestureRecognizer:search];

    objc_setAssociatedObject(window, &WGLeanGestureTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WGLeanInstallVisibleWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) WGLeanInstallOnWindow(window);
        }
    } else {
        for (UIWindow *window in app.windows) WGLeanInstallOnWindow(window);
    }
}

__attribute__((constructor))
static void WGLeanLanguageGesturesEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            WGLeanInstallVisibleWindows();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.70 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WGLeanInstallVisibleWindows(); });

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGLeanInstallVisibleWindows();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGLeanInstallVisibleWindows();
            }];
        });
    }
}
