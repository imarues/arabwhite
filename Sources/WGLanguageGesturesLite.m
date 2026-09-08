#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * LanguageWhitegram — lightweight gesture-only language menu.
 *
 * No visible language button is ever created.
 * No timers, display links, controller lifecycle hooks, or background UI scans.
 * The view tree is inspected only after the user performs one of the supported
 * gestures, and the picker opens only on the Whitegram 12.9.2 (70) root page.
 */

static char WGLiteTargetKey;

static NSArray<NSDictionary<NSString *, NSString *> *> *WGLiteLanguages(void) {
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

static UIViewController *WGLiteDeepestController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController && !controller.presentedViewController.isBeingDismissed) {
        return WGLiteDeepestController(controller.presentedViewController);
    }
    if ([controller isKindOfClass:UINavigationController.class]) {
        return WGLiteDeepestController(((UINavigationController *)controller).visibleViewController);
    }
    if ([controller isKindOfClass:UITabBarController.class]) {
        return WGLiteDeepestController(((UITabBarController *)controller).selectedViewController);
    }
    for (UIViewController *child in controller.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGLiteDeepestController(child);
    }
    return controller;
}

static NSString *WGLiteVisibleText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.attributedText.length) return label.attributedText.string;
        return label.text;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSAttributedString *attributed = [button attributedTitleForState:UIControlStateNormal];
        if (attributed.length) return attributed.string;
        return [button titleForState:UIControlStateNormal];
    }
    if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        if (textView.attributedText.length) return textView.attributedText.string;
        return textView.text;
    }
    if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        if (field.text.length) return field.text;
        return field.placeholder;
    }
    if (view.accessibilityLabel.length) return view.accessibilityLabel;
    return nil;
}

typedef struct {
    BOOL sawWhitegram;
    BOOL sawVersion;
    BOOL hasSearchRect;
    CGRect searchRect;
} WGLiteScanResult;

static BOOL WGLiteTextIsWhitegram(NSString *text) {
    if (!text.length) return NO;
    NSString *lower = text.lowercaseString;
    return [lower containsString:@"whitegram"] ||
           [text containsString:@"وايت كرام"] ||
           [text containsString:@"وايتگرام"] ||
           [text containsString:@"Вайтграм"] ||
           [text containsString:@"Уайтграм"];
}

static BOOL WGLiteTextIsSearchMarker(NSString *text) {
    if (!text.length) return NO;
    static NSArray<NSString *> *sourceMarkers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sourceMarkers = @[@"Search settings", @"Find a Whitegram option"];
    });

    NSString *lower = text.lowercaseString;
    for (NSString *source in sourceMarkers) {
        if ([lower containsString:source.lowercaseString]) return YES;
        NSString *translated = WGTranslateStringExact(source);
        if (translated.length && [lower containsString:translated.lowercaseString]) return YES;
    }
    return NO;
}

static void WGLiteScanView(UIView *view,
                           UIWindow *window,
                           BOOL needSearchRect,
                           WGLiteScanResult *result,
                           NSUInteger depth,
                           NSUInteger *visited) {
    if (!view || depth > 80 || *visited > 1400) return;
    if (result->sawWhitegram && result->sawVersion && (!needSearchRect || result->hasSearchRect)) return;
    (*visited)++;

    NSString *text = WGLiteVisibleText(view);
    if (text.length) {
        if (!result->sawWhitegram && WGLiteTextIsWhitegram(text)) result->sawWhitegram = YES;
        if (!result->sawVersion && [text containsString:@"12.9.2 (70)"]) result->sawVersion = YES;

        if (needSearchRect && !result->hasSearchRect && WGLiteTextIsSearchMarker(text)) {
            CGRect rect = [view convertRect:view.bounds toView:window];
            if (!CGRectIsEmpty(rect) && !CGRectIsInfinite(rect)) {
                CGFloat minY = MAX(0.0, CGRectGetMinY(rect) - 44.0);
                CGFloat maxY = MIN(CGRectGetHeight(window.bounds), CGRectGetMaxY(rect) + 44.0);
                result->searchRect = CGRectMake(CGRectGetWidth(window.bounds) * 0.025,
                                                minY,
                                                CGRectGetWidth(window.bounds) * 0.95,
                                                MAX(78.0, maxY - minY));
                result->hasSearchRect = YES;
            }
        }
    }

    for (UIView *subview in view.subviews) {
        WGLiteScanView(subview, window, needSearchRect, result, depth + 1, visited);
    }
}

static BOOL WGLiteIsWhitegramRoot(UIWindow *window, BOOL needSearchRect, CGRect *searchRectOut) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;
    WGLiteScanResult result = {0};
    NSUInteger visited = 0;
    WGLiteScanView(window, window, needSearchRect, &result, 0, &visited);

    BOOL isRoot = result.sawWhitegram && result.sawVersion;
    if (isRoot && needSearchRect && searchRectOut) {
        if (result.hasSearchRect) {
            *searchRectOut = result.searchRect;
        } else {
            // Safe fallback for the Search settings card on Whitegram build 70.
            CGFloat width = CGRectGetWidth(window.bounds);
            CGFloat height = CGRectGetHeight(window.bounds);
            *searchRectOut = CGRectMake(width * 0.025, height * 0.42, width * 0.95, height * 0.20);
        }
    }
    return isRoot;
}

static void WGLiteConfirmLanguage(UIViewController *controller,
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
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ exit(0); });
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WGLiteShowLanguages(UIWindow *window) {
    if (!WGLiteIsWhitegramRoot(window, NO, NULL)) return;

    UIViewController *controller = WGLiteDeepestController(window.rootViewController);
    if (!controller || [controller isKindOfClass:UIAlertController.class] || controller.presentedViewController) return;

    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Languages • اللغات"
                                                                   message:@"Whitegram Features Language\nTelegram : @ikiraplus"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary<NSString *, NSString *> *language in WGLiteLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
            if (![code isEqualToString:current]) WGLiteConfirmLanguage(controller, language);
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

@interface WGLiteLanguageTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@end

@implementation WGLiteLanguageTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (void)twoFingerTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized || !self.window) return;
    WGLiteShowLanguages(self.window);
}

- (void)twoFingerHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !self.window) return;
    WGLiteShowLanguages(self.window);
}

- (void)searchHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !self.window) return;
    CGRect searchRect = CGRectZero;
    if (!WGLiteIsWhitegramRoot(self.window, YES, &searchRect)) return;
    CGPoint point = [recognizer locationInView:self.window];
    if (!CGRectContainsPoint(searchRect, point)) return;
    WGLiteShowLanguages(self.window);
}
@end

static void WGLiteInstallOnWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return;
    if (objc_getAssociatedObject(window, &WGLiteTargetKey)) return;

    WGLiteLanguageTarget *target = [WGLiteLanguageTarget new];
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
    searchHold.minimumPressDuration = 0.45;
    searchHold.allowableMovement = 22.0;
    searchHold.cancelsTouchesInView = NO;
    searchHold.delaysTouchesBegan = NO;
    searchHold.delegate = target;
    [window addGestureRecognizer:searchHold];

    objc_setAssociatedObject(window, &WGLiteTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WGLiteInstallEverywhere(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) WGLiteInstallOnWindow(window);
        }
    } else {
        for (UIWindow *window in app.windows) WGLiteInstallOnWindow(window);
    }
}

__attribute__((constructor))
static void WGLiteLanguageEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            WGLiteInstallEverywhere();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WGLiteInstallEverywhere(); });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.20 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ WGLiteInstallEverywhere(); });

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGLiteInstallEverywhere();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGLiteInstallEverywhere();
            }];
        });
    }
}
