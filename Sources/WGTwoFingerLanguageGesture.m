#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * LanguageWhitegram — two-finger language gesture
 *
 * No visible language button is used. A two-finger single tap recognizer is
 * attached to controller views, but the handler only opens the language picker
 * when the currently visible screen is the Whitegram 7.0 features root.
 * This makes the gesture immediately available without waiting for any overlay
 * to be detected or rendered, while remaining inert everywhere else.
 */

static char WGTwoFingerRecognizerKey;
static IMP WGTwoFingerPreviousViewDidAppear = NULL;

#pragma mark - Strict Whitegram root detection at gesture time

static void WGTwoFingerCollectMarkers(UIView *view,
                                      BOOL *sawVersion,
                                      BOOL *sawWhitegram,
                                      NSUInteger *visited) {
    if (!view || *visited > 2200 || (*sawVersion && *sawWhitegram)) return;
    (*visited)++;

    NSString *text = nil;
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        text = label.attributedText.length > 0 ? label.attributedText.string : label.text;
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSAttributedString *attributed = [button attributedTitleForState:UIControlStateNormal];
        text = attributed.length > 0 ? attributed.string : [button titleForState:UIControlStateNormal];
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        text = textView.attributedText.length > 0 ? textView.attributedText.string : textView.text;
    }

    if (text.length > 0) {
        if ([text containsString:@"12.9.2 (70)"]) {
            *sawVersion = YES;
        }

        NSString *lower = text.lowercaseString;
        if ([lower containsString:@"whitegram"] ||
            [text containsString:@"وايت كرام"] ||
            [text containsString:@"وايتگرام"] ||
            [text containsString:@"Вайтграм"] ||
            [text containsString:@"Уайтграм"]) {
            *sawWhitegram = YES;
        }
    }

    for (UIView *subview in view.subviews) {
        WGTwoFingerCollectMarkers(subview, sawVersion, sawWhitegram, visited);
    }
}

static BOOL WGTwoFingerIsWhitegramFeaturesRoot(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded || !controller.view.window) return NO;

    BOOL sawVersion = NO;
    BOOL sawWhitegram = NO;
    NSUInteger visited = 0;
    WGTwoFingerCollectMarkers(controller.view, &sawVersion, &sawWhitegram, &visited);
    return sawVersion && sawWhitegram;
}

#pragma mark - Remove every legacy globe from older overlay builds

static BOOL WGIsLegacyLanguageGlobe(UIView *view) {
    if (![view isKindOfClass:UIButton.class]) return NO;
    UIButton *button = (UIButton *)view;
    if (![button.accessibilityLabel isEqualToString:@"Languages"]) return NO;

    // Match the old iKiraPlus overlay button specifically.
    CGFloat width = CGRectGetWidth(button.bounds);
    CGFloat height = CGRectGetHeight(button.bounds);
    BOOL oldSize = (fabs(width - 44.0) < 3.0 && fabs(height - 44.0) < 3.0) ||
                   (width == 0.0 && height == 0.0); // Auto Layout before first pass.
    return oldSize && button.layer.cornerRadius >= 20.0;
}

static void WGRemoveLegacyLanguageGlobesFromView(UIView *view) {
    if (!view) return;
    for (UIView *subview in [view.subviews copy]) {
        if (WGIsLegacyLanguageGlobe(subview)) {
            [subview removeFromSuperview];
            continue;
        }
        WGRemoveLegacyLanguageGlobesFromView(subview);
    }
}

static void WGRemoveLegacyLanguageGlobesEverywhere(void) {
    UIApplication *application = UIApplication.sharedApplication;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                WGRemoveLegacyLanguageGlobesFromView(window);
            }
        }
    } else {
        for (UIWindow *window in application.windows) {
            WGRemoveLegacyLanguageGlobesFromView(window);
        }
    }
}

#pragma mark - Language picker

static NSArray<NSDictionary<NSString *, NSString *> *> *WGTwoFingerLanguages(void) {
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
            @{@"code": @"tr", @"name": @"Türkçe"},
        ];
    });
    return languages;
}

static void WGTwoFingerConfirmLanguage(UIViewController *controller,
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
                       dispatch_get_main_queue(), ^{
            exit(0);
        });
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WGTwoFingerShowLanguageMenu(UIViewController *controller) {
    if (!WGTwoFingerIsWhitegramFeaturesRoot(controller)) return;
    if (controller.presentedViewController) return;

    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Languages • اللغات"
                                                                   message:@"Whitegram Features Language"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary<NSString *, NSString *> *language in WGTwoFingerLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) {
            title = [@"✓ " stringByAppendingString:title];
        }

        [sheet addAction:[UIAlertAction actionWithTitle:title
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
            if ([code isEqualToString:current]) return;
            WGTwoFingerConfirmLanguage(controller, language);
        }]];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel • إلغاء"
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = controller.view;
        popover.sourceRect = CGRectMake(CGRectGetMidX(controller.view.bounds),
                                        CGRectGetMidY(controller.view.bounds),
                                        1.0,
                                        1.0);
        popover.permittedArrowDirections = 0;
    }

    [controller presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Gesture installation

@interface UIViewController (WGTwoFingerLanguageGesture)
- (void)wg_ikira_twoFingerLanguageTap:(UITapGestureRecognizer *)recognizer;
@end

@implementation UIViewController (WGTwoFingerLanguageGesture)
- (void)wg_ikira_twoFingerLanguageTap:(UITapGestureRecognizer *)recognizer {
    if (recognizer.state != UIGestureRecognizerStateRecognized) return;
    WGTwoFingerShowLanguageMenu(self);
}
@end

static void WGInstallTwoFingerRecognizer(UIViewController *controller) {
    if (!controller || !controller.isViewLoaded) return;
    if (objc_getAssociatedObject(controller, &WGTwoFingerRecognizerKey)) return;

    UITapGestureRecognizer *recognizer = [[UITapGestureRecognizer alloc]
        initWithTarget:controller
                action:@selector(wg_ikira_twoFingerLanguageTap:)];
    recognizer.numberOfTouchesRequired = 2;
    recognizer.numberOfTapsRequired = 1;
    recognizer.cancelsTouchesInView = NO;
    recognizer.delaysTouchesBegan = NO;
    recognizer.delaysTouchesEnded = NO;

    [controller.view addGestureRecognizer:recognizer];
    objc_setAssociatedObject(controller,
                             &WGTwoFingerRecognizerKey,
                             recognizer,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void WGTwoFingerViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (WGTwoFingerPreviousViewDidAppear) {
        ((void (*)(id, SEL, BOOL))WGTwoFingerPreviousViewDidAppear)(self, _cmd, animated);
    }

    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (!controller) return;

    // The recognizer is installed immediately. The strict Whitegram check is
    // performed only when the user taps, so there is no UI-detection delay.
    WGInstallTwoFingerRecognizer(controller);

    // The previous overlay may have attempted to create its old globe during
    // the call above. Remove it synchronously before the current run loop draws.
    WGRemoveLegacyLanguageGlobesEverywhere();
}

static void WGInstallTwoFingerLifecycleHook(void) {
    Method method = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (!method) return;

    IMP current = method_getImplementation(method);
    if (current == (IMP)WGTwoFingerViewDidAppear) return;
    WGTwoFingerPreviousViewDidAppear = current;
    method_setImplementation(method, (IMP)WGTwoFingerViewDidAppear);
}

__attribute__((constructor))
static void WGTwoFingerLanguageEntry(void) {
    @autoreleasepool {
        // WGLanguageOverlay installs its own lifecycle hook asynchronously.
        // Queue one extra main-loop hop so this wrapper is always installed
        // after it and can synchronously suppress the legacy globe.
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                WGInstallTwoFingerLifecycleHook();
                WGRemoveLegacyLanguageGlobesEverywhere();
            });
        });
    }
}
