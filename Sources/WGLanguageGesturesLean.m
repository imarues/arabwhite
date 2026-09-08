#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * Gesture-only language picker.
 * No visible language control is created anywhere.
 * No timers, polling loops, controller swizzles or background UI scans.
 * The view hierarchy is inspected only after the user performs a language
 * gesture, which keeps normal Telegram navigation untouched.
 */

static char WGLeanGestureTargetKey;

static NSArray<NSDictionary<NSString *, NSString *> *> *WGLeanLanguages(void) {
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

static NSString *WGLeanTextForView(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        return label.attributedText.length ? label.attributedText.string : label.text;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSAttributedString *a = [button attributedTitleForState:UIControlStateNormal];
        return a.length ? a.string : [button titleForState:UIControlStateNormal];
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
    BOOL sawWhitegram;
    BOOL sawVersion;
    NSUInteger featureHits;
    BOOL hasSearchRect;
    CGRect searchRect;
} WGLeanRootScan;

static NSArray<NSString *> *WGLeanFeatureMarkers(void) {
    static NSArray<NSString *> *source;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        source = @[@"About Whitegram", @"Search settings", @"Appearance",
                   @"Notifications", @"Messages", @"Camera"];
    });
    NSMutableArray<NSString *> *markers = [NSMutableArray arrayWithCapacity:source.count * 2];
    for (NSString *item in source) {
        [markers addObject:item];
        NSString *translated = WGTranslateStringExact(item);
        if (translated.length && ![translated isEqualToString:item]) [markers addObject:translated];
    }
    return markers;
}

static BOOL WGLeanContainsAnyMarker(NSString *text, NSArray<NSString *> *markers) {
    if (!text.length) return NO;
    NSString *lower = text.lowercaseString;
    for (NSString *marker in markers) {
        if (marker.length && [lower containsString:marker.lowercaseString]) return YES;
    }
    return NO;
}

static void WGLeanScanView(UIView *view,
                           UIWindow *window,
                           NSArray<NSString *> *featureMarkers,
                           NSArray<NSString *> *searchMarkers,
                           WGLeanRootScan *scan,
                           NSUInteger depth,
                           NSUInteger *visited) {
    if (!view || depth > 80 || *visited >= 2200) return;
    (*visited)++;

    NSString *text = WGLeanTextForView(view);
    if (text.length) {
        NSString *lower = text.lowercaseString;
        if ([lower containsString:@"whitegram"] ||
            [text containsString:@"وايت كرام"] || [text containsString:@"وايتگرام"] ||
            [text containsString:@"Вайтграм"] || [text containsString:@"Уайтграм"]) {
            scan->sawWhitegram = YES;
        }
        if ([text containsString:@"12.9.2 (70)"]) scan->sawVersion = YES;
        if (WGLeanContainsAnyMarker(text, featureMarkers)) scan->featureHits++;

        if (WGLeanContainsAnyMarker(text, searchMarkers)) {
            CGRect r = [view convertRect:view.bounds toView:window];
            if (!CGRectIsEmpty(r) && !CGRectIsInfinite(r)) {
                CGFloat minY = MAX(0.0, CGRectGetMinY(r) - 42.0);
                CGFloat maxY = MIN(CGRectGetHeight(window.bounds), CGRectGetMaxY(r) + 42.0);
                CGRect row = CGRectMake(CGRectGetWidth(window.bounds) * 0.03,
                                        minY,
                                        CGRectGetWidth(window.bounds) * 0.94,
                                        MAX(72.0, maxY - minY));
                if (scan->hasSearchRect) scan->searchRect = CGRectUnion(scan->searchRect, row);
                else { scan->searchRect = row; scan->hasSearchRect = YES; }
            }
        }
    }

    for (UIView *subview in view.subviews) {
        WGLeanScanView(subview, window, featureMarkers, searchMarkers, scan, depth + 1, visited);
    }
}

static BOOL WGLeanIsWhitegramRoot(UIWindow *window, CGRect *searchRectOut) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;

    NSString *searchTitle = @"Search settings";
    NSString *searchSubtitle = @"Find a Whitegram option";
    NSString *translatedTitle = WGTranslateStringExact(searchTitle);
    NSString *translatedSubtitle = WGTranslateStringExact(searchSubtitle);
    NSMutableArray<NSString *> *searchMarkers = [NSMutableArray arrayWithObjects:searchTitle, searchSubtitle, nil];
    if (translatedTitle.length && ![translatedTitle isEqualToString:searchTitle]) [searchMarkers addObject:translatedTitle];
    if (translatedSubtitle.length && ![translatedSubtitle isEqualToString:searchSubtitle]) [searchMarkers addObject:translatedSubtitle];

    WGLeanRootScan scan = {0};
    NSUInteger visited = 0;
    WGLeanScanView(window, window, WGLeanFeatureMarkers(), searchMarkers, &scan, 0, &visited);

    BOOL isRoot = scan.sawWhitegram && (scan.sawVersion || scan.featureHits >= 2);
    if (isRoot && searchRectOut) {
        if (scan.hasSearchRect) *searchRectOut = scan.searchRect;
        else {
            CGFloat w = CGRectGetWidth(window.bounds);
            CGFloat h = CGRectGetHeight(window.bounds);
            *searchRectOut = CGRectMake(w * 0.03, h * 0.42, w * 0.94, h * 0.18);
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
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء • Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"موافق • OK"
                                              style:UIAlertActionStyleDefault
                                            handler:^(__unused UIAlertAction *action) {
        WGSetCustomLanguageCode(language[@"code"] ?: @"ar");
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
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
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel • إلغاء" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = window;
        popover.sourceRect = CGRectMake(CGRectGetMidX(window.bounds), CGRectGetMidY(window.bounds), 1.0, 1.0);
        popover.permittedArrowDirections = 0;
    }
    [controller presentViewController:sheet animated:YES completion:nil];
}

@interface WGLeanLanguageGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@end

@implementation WGLeanLanguageGestureTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer; (void)otherGestureRecognizer;
    return YES;
}

- (void)twoFingerTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateRecognized && self.window) WGLeanShowLanguages(self.window);
}

- (void)twoFingerHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state == UIGestureRecognizerStateBegan && self.window) WGLeanShowLanguages(self.window);
}

- (void)searchHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !self.window) return;
    CGRect searchRect = CGRectZero;
    if (!WGLeanIsWhitegramRoot(self.window, &searchRect)) return;
    CGPoint point = [recognizer locationInView:self.window];
    if (CGRectContainsPoint(searchRect, point)) WGLeanShowLanguages(self.window);
}
@end

static void WGLeanInstallOnWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return;
    if (objc_getAssociatedObject(window, &WGLeanGestureTargetKey)) return;

    WGLeanLanguageGestureTarget *target = [WGLeanLanguageGestureTarget new];
    target.window = window;

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:target action:@selector(twoFingerTap:)];
    tap.numberOfTouchesRequired = 2;
    tap.numberOfTapsRequired = 1;
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = target;
    [window addGestureRecognizer:tap];

    UILongPressGestureRecognizer *twoHold = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(twoFingerHold:)];
    twoHold.numberOfTouchesRequired = 2;
    twoHold.minimumPressDuration = 0.32;
    twoHold.allowableMovement = 42.0;
    twoHold.cancelsTouchesInView = NO;
    twoHold.delaysTouchesBegan = NO;
    twoHold.delegate = target;
    [window addGestureRecognizer:twoHold];

    UILongPressGestureRecognizer *searchHold = [[UILongPressGestureRecognizer alloc] initWithTarget:target action:@selector(searchHold:)];
    searchHold.numberOfTouchesRequired = 1;
    searchHold.minimumPressDuration = 0.45;
    searchHold.allowableMovement = 20.0;
    searchHold.cancelsTouchesInView = NO;
    searchHold.delaysTouchesBegan = NO;
    searchHold.delegate = target;
    [window addGestureRecognizer:searchHold];

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
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(NSNotification *note) {
                if ([note.object isKindOfClass:UIWindow.class]) WGLeanInstallOnWindow((UIWindow *)note.object);
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGLeanInstallVisibleWindows();
            }];
        });
    }
}
