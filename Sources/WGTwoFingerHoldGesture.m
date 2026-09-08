#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * LanguageWhitegram — two-finger hold add-on
 *
 * Keeps the existing light two-finger tap and search-row long press intact.
 * Adds a second window-level gesture for users who press with two fingers and
 * hold briefly. Modern iPhones do not expose 3D Touch force globally, so this
 * intentionally models a "strong press" as a short two-finger long press.
 *
 * The handler is inert everywhere except the Whitegram 7.0 features root.
 */

static char WGTwoFingerHoldTargetKey;

static NSArray<NSDictionary<NSString *, NSString *> *> *WGTwoFingerHoldLanguages(void) {
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

static UIViewController *WGTwoFingerHoldDeepest(UIViewController *vc) {
    if (!vc) return nil;
    if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        return WGTwoFingerHoldDeepest(vc.presentedViewController);
    }
    if ([vc isKindOfClass:UINavigationController.class]) {
        return WGTwoFingerHoldDeepest(((UINavigationController *)vc).visibleViewController);
    }
    if ([vc isKindOfClass:UITabBarController.class]) {
        return WGTwoFingerHoldDeepest(((UITabBarController *)vc).selectedViewController);
    }
    for (UIViewController *child in vc.childViewControllers.reverseObjectEnumerator) {
        if (child.viewIfLoaded.window) return WGTwoFingerHoldDeepest(child);
    }
    return vc;
}

static NSString *WGTwoFingerHoldVisibleText(UIView *view) {
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.attributedText.length) return label.attributedText.string;
        return label.text;
    }
    if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSAttributedString *a = [button attributedTitleForState:UIControlStateNormal];
        if (a.length) return a.string;
        return [button titleForState:UIControlStateNormal];
    }
    if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        if (textView.attributedText.length) return textView.attributedText.string;
        return textView.text;
    }
    if (view.accessibilityLabel.length) return view.accessibilityLabel;
    return nil;
}

static void WGTwoFingerHoldScan(UIView *view,
                                BOOL *sawWhitegram,
                                BOOL *sawVersion,
                                NSUInteger *featureHits,
                                NSUInteger depth,
                                NSUInteger *visited) {
    if (!view || depth > 95 || *visited > 3200 || (*sawVersion && *sawWhitegram)) return;
    (*visited)++;

    NSString *text = WGTwoFingerHoldVisibleText(view);
    if (text.length) {
        NSString *lower = text.lowercaseString;
        if ([lower containsString:@"whitegram"] ||
            [text containsString:@"وايت كرام"] ||
            [text containsString:@"وايتگرام"] ||
            [text containsString:@"Вайтграм"] ||
            [text containsString:@"Уайтграм"]) {
            *sawWhitegram = YES;
        }
        if ([text containsString:@"12.9.2 (70)"]) *sawVersion = YES;

        NSArray<NSString *> *sources = @[@"About Whitegram", @"Search settings", @"Appearance",
                                         @"Notifications", @"Messages", @"Camera"];
        for (NSString *source in sources) {
            NSString *translated = WGTranslateStringExact(source);
            if ((translated.length && [lower containsString:translated.lowercaseString]) ||
                [lower containsString:source.lowercaseString]) {
                (*featureHits)++;
                break;
            }
        }
    }

    for (UIView *subview in view.subviews) {
        WGTwoFingerHoldScan(subview, sawWhitegram, sawVersion, featureHits, depth + 1, visited);
    }
}

static BOOL WGTwoFingerHoldIsWhitegramRoot(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;
    BOOL sawWhitegram = NO;
    BOOL sawVersion = NO;
    NSUInteger featureHits = 0;
    NSUInteger visited = 0;
    WGTwoFingerHoldScan(window, &sawWhitegram, &sawVersion, &featureHits, 0, &visited);
    return sawWhitegram && (sawVersion || featureHits >= 2);
}

static void WGTwoFingerHoldConfirm(UIViewController *controller,
                                   NSDictionary<NSString *, NSString *> *language) {
    NSString *name = language[@"name"] ?: @"Language";
    NSString *message = [NSString stringWithFormat:
        @"سيتم تغيير لغة ميزات Whitegram إلى %@. سيتم إغلاق التطبيق لتطبيق التغيير.\n\nWhitegram will close and use %@ after you open it again.", name, name];

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"تغيير اللغة • Change Language"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"إلغاء • Cancel" style:UIAlertActionStyleCancel handler:nil]];
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

static void WGTwoFingerHoldShowLanguages(UIWindow *window) {
    if (!WGTwoFingerHoldIsWhitegramRoot(window)) return;

    UIViewController *controller = WGTwoFingerHoldDeepest(window.rootViewController);
    if (!controller || [controller isKindOfClass:UIAlertController.class] || controller.presentedViewController) return;

    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Languages • اللغات"
                                                                   message:@"Whitegram Features Language"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary<NSString *, NSString *> *language in WGTwoFingerHoldLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if (![code isEqualToString:current]) WGTwoFingerHoldConfirm(controller, language);
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

@interface WGTwoFingerHoldTarget : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, weak) UIWindow *window;
@end

@implementation WGTwoFingerHoldTarget
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    (void)gestureRecognizer;
    (void)otherGestureRecognizer;
    return YES;
}

- (void)twoFingerHold:(UILongPressGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateBegan || !self.window) return;
    WGTwoFingerHoldShowLanguages(self.window);
}
@end

static void WGTwoFingerHoldInstallOnWindow(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return;
    if (objc_getAssociatedObject(window, &WGTwoFingerHoldTargetKey)) return;

    WGTwoFingerHoldTarget *target = [WGTwoFingerHoldTarget new];
    target.window = window;

    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc]
        initWithTarget:target action:@selector(twoFingerHold:)];
    hold.numberOfTouchesRequired = 2;
    hold.minimumPressDuration = 0.32;
    hold.allowableMovement = 42.0;
    hold.cancelsTouchesInView = NO;
    hold.delaysTouchesBegan = NO;
    hold.delegate = target;
    [window addGestureRecognizer:hold];

    objc_setAssociatedObject(window, &WGTwoFingerHoldTargetKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WGTwoFingerHoldInstallEverywhere(void) {
    UIApplication *app = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                WGTwoFingerHoldInstallOnWindow(window);
            }
        }
    } else {
        for (UIWindow *window in app.windows) WGTwoFingerHoldInstallOnWindow(window);
    }
}

__attribute__((constructor))
static void WGTwoFingerHoldEntry(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            WGTwoFingerHoldInstallEverywhere();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WGTwoFingerHoldInstallEverywhere();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                WGTwoFingerHoldInstallEverywhere();
            });

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGTwoFingerHoldInstallEverywhere();
            }];
            [[NSNotificationCenter defaultCenter] addObserverForName:UIWindowDidBecomeVisibleNotification
                                                              object:nil
                                                               queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(__unused NSNotification *note) {
                WGTwoFingerHoldInstallEverywhere();
            }];
        });
    }
}
