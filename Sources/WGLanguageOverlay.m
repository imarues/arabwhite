#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * iKiraPlus language overlay for Whitegram 7.0 / Telegram 12.9.2 (70)
 *
 * - Arabic is forced as the first-run default, independently of iOS language.
 * - A globe button is injected only on Whitegram's main features screen.
 * - Ten languages are offered from that button.
 * - Arabic keeps the bundled verified dictionary and uses a remote fallback only
 *   for still-uncovered visible Whitegram strings.
 * - Other languages are translated on demand, cached persistently per language,
 *   and applied only inside Whitegram feature controllers. Telegram's normal UI
 *   is intentionally left alone.
 */

static NSString *const WGSelectionDefaultsKey = @"WGMultiLanguageSelection";
static char WGRootMarkerKey;
static char WGLanguageButtonKey;
static char WGAppliedLanguageKey;
static char WGAppliedTextKey;

static IMP WGPreviousViewDidAppear = NULL;
static IMP WGPreviousViewDidDisappear = NULL;
static NSHashTable<UIViewController *> *WGActiveWhitegramControllers;
static NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSString *> *> *WGRemoteCaches;
static NSMutableSet<NSString *> *WGRemoteInFlight;
static NSURLSession *WGTranslationSession;
static BOOL WGRefreshScheduled = NO;

#pragma mark - Languages

static NSArray<NSDictionary<NSString *, NSString *> *> *WGLanguages(void) {
    static NSArray<NSDictionary<NSString *, NSString *> *> *languages;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        languages = @[
            @{@"code": @"ar", @"name": @"العربية", @"english": @"Arabic"},
            @{@"code": @"en", @"name": @"English", @"english": @"English"},
            @{@"code": @"fr", @"name": @"Français", @"english": @"French"},
            @{@"code": @"es", @"name": @"Español", @"english": @"Spanish"},
            @{@"code": @"zh", @"name": @"简体中文", @"english": @"Chinese"},
            @{@"code": @"vi", @"name": @"Tiếng Việt", @"english": @"Vietnamese"},
            @{@"code": @"fa", @"name": @"فارسی", @"english": @"Persian"},
            @{@"code": @"pt", @"name": @"Português", @"english": @"Portuguese"},
            @{@"code": @"ru", @"name": @"Русский", @"english": @"Russian"},
            @{@"code": @"tr", @"name": @"Türkçe", @"english": @"Turkish"},
        ];
    });
    return languages;
}

static NSString *WGTargetCodeForGoogle(NSString *code) {
    if ([code isEqualToString:@"zh"]) return @"zh-CN";
    return code;
}

static BOOL WGCodeIsSupported(NSString *code) {
    if (code.length == 0) return NO;
    for (NSDictionary<NSString *, NSString *> *language in WGLanguages()) {
        if ([language[@"code"] isEqualToString:code]) return YES;
    }
    return NO;
}

static NSDictionary<NSString *, NSString *> *WGLanguageInfo(NSString *code) {
    for (NSDictionary<NSString *, NSString *> *language in WGLanguages()) {
        if ([language[@"code"] isEqualToString:code]) return language;
    }
    return nil;
}

#pragma mark - First-run Arabic default

static void WGEnsureArabicDefault(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults objectForKey:WGSelectionDefaultsKey] == nil) {
        WGSetCustomLanguageCode(@"ar");
    }
}

#pragma mark - Whitegram screen detection

static void WGCollectMarkers(UIView *view, BOOL *sawVersion, BOOL *sawWhitegram, NSUInteger *visited) {
    if (!view || *visited > 1800 || (*sawVersion && *sawWhitegram)) return;
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
        if ([lower containsString:@"whitegram"] || [text containsString:@"وايت كرام"] ||
            [text containsString:@"وايتگرام"] || [text containsString:@"Вайтграм"]) {
            *sawWhitegram = YES;
        }
    }

    for (UIView *subview in view.subviews) {
        WGCollectMarkers(subview, sawVersion, sawWhitegram, visited);
    }
}

static BOOL WGControllerLooksLikeWhitegramClass(UIViewController *controller) {
    if (!controller) return NO;
    NSString *name = NSStringFromClass(controller.class);
    NSString *lower = name.lowercaseString;
    if ([lower containsString:@"whitegram"] || [lower containsString:@"wglanguage"] ||
        [lower containsString:@"wgsettings"] || [lower containsString:@"wgappearance"] ||
        [lower containsString:@"wgfeature"] || [lower containsString:@"wgbeta"]) {
        return YES;
    }
    return NO;
}

static BOOL WGControllerIsWhitegramRoot(UIViewController *controller) {
    if (!controller.isViewLoaded) return NO;
    if ([objc_getAssociatedObject(controller, &WGRootMarkerKey) boolValue]) return YES;

    BOOL sawVersion = NO;
    BOOL sawWhitegram = NO;
    NSUInteger visited = 0;
    WGCollectMarkers(controller.view, &sawVersion, &sawWhitegram, &visited);
    if (sawVersion && sawWhitegram) {
        objc_setAssociatedObject(controller, &WGRootMarkerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    return NO;
}

static BOOL WGControllerIsWhitegram(UIViewController *controller) {
    if (!controller) return NO;
    if (WGControllerIsWhitegramRoot(controller) || WGControllerLooksLikeWhitegramClass(controller)) {
        return YES;
    }

    UINavigationController *navigationController = controller.navigationController;
    if (navigationController) {
        NSArray<UIViewController *> *stack = navigationController.viewControllers;
        NSUInteger index = [stack indexOfObjectIdenticalTo:controller];
        if (index != NSNotFound) {
            for (NSUInteger i = 0; i <= index; i++) {
                UIViewController *candidate = stack[i];
                if ([objc_getAssociatedObject(candidate, &WGRootMarkerKey) boolValue] ||
                    WGControllerLooksLikeWhitegramClass(candidate)) {
                    return YES;
                }
            }
        }
    }

    UIViewController *parent = controller.parentViewController;
    if (parent && parent != controller && WGControllerLooksLikeWhitegramClass(parent)) return YES;
    UIViewController *presenter = controller.presentingViewController;
    if (presenter && WGControllerLooksLikeWhitegramClass(presenter)) return YES;
    return NO;
}

#pragma mark - Translation cache and filtering

static NSMutableDictionary<NSString *, NSString *> *WGCacheForCode(NSString *code) {
    if (!WGRemoteCaches) WGRemoteCaches = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *cache = WGRemoteCaches[code];
    if (cache) return cache;

    NSString *defaultsKey = [@"WGRemoteTranslationCache." stringByAppendingString:code ?: @""];
    NSDictionary *saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:defaultsKey];
    cache = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    WGRemoteCaches[code] = cache;
    return cache;
}

static void WGPersistCache(NSString *code) {
    NSMutableDictionary *cache = WGCacheForCode(code);
    NSString *defaultsKey = [@"WGRemoteTranslationCache." stringByAppendingString:code ?: @""];
    [NSUserDefaults.standardUserDefaults setObject:[cache copy] forKey:defaultsKey];
}

static NSUInteger WGCountCharactersInRange(NSString *text, unichar low, unichar high) {
    NSUInteger count = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c >= low && c <= high) count++;
    }
    return count;
}

static BOOL WGHasArabicScript(NSString *text) {
    return WGCountCharactersInRange(text, 0x0600, 0x06FF) > 0 ||
           WGCountCharactersInRange(text, 0x0750, 0x077F) > 0;
}

static BOOL WGHasCyrillic(NSString *text) {
    return WGCountCharactersInRange(text, 0x0400, 0x04FF) > 0;
}

static BOOL WGHasCJK(NSString *text) {
    return WGCountCharactersInRange(text, 0x4E00, 0x9FFF) > 0;
}

static BOOL WGHasLatinLetters(NSString *text) {
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        if (c < 0x0250 && [letters characterIsMember:c]) return YES;
    }
    return NO;
}

static BOOL WGShouldIgnoreSource(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return YES;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length < 2 || trimmed.length > 1800) return YES;
    if ([trimmed hasPrefix:@"http://"] || [trimmed hasPrefix:@"https://"] || [trimmed hasPrefix:@"tg://"]) return YES;

    BOOL hasLetter = NO;
    NSCharacterSet *letters = NSCharacterSet.letterCharacterSet;
    for (NSUInteger i = 0; i < trimmed.length; i++) {
        if ([letters characterIsMember:[trimmed characterAtIndex:i]]) {
            hasLetter = YES;
            break;
        }
    }
    return !hasLetter;
}

static NSDictionary<NSString *, NSString *> *WGArabicFallbacks(void) {
    static NSDictionary<NSString *, NSString *> *fallbacks;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fallbacks = @{
            @"Video wallpaper across the interface: Not Selected": @"خلفية فيديو في كامل الواجهة: غير محددة",
            @"Video wallpaper across the interface": @"خلفية فيديو في كامل الواجهة",
            @"Not Selected": @"غير محدد",
            @"Shrinks avatars and paddings in the chat list so more chats fit on screen. Not compatible with the new chat list style.": @"يقلّل حجم الصور الشخصية والمسافات في قائمة المحادثات لعرض محادثات أكثر على الشاشة. غير متوافق مع نمط قائمة المحادثات الجديد.",
        };
    });
    return fallbacks;
}

static NSString *WGImmediateTranslationForSource(NSString *source, NSString *code) {
    if (source.length == 0 || code.length == 0) return nil;

    if ([code isEqualToString:@"ar"]) {
        NSString *fallback = WGArabicFallbacks()[source];
        if (fallback.length > 0) return fallback;

        NSString *bundled = WGTranslateString(source);
        if (bundled.length > 0 && ![bundled isEqualToString:source]) return bundled;
        if (WGHasArabicScript(source)) return source;
    } else if ([code isEqualToString:@"en"]) {
        if (WGHasLatinLetters(source) && !WGHasCyrillic(source) && !WGHasArabicScript(source) && !WGHasCJK(source)) {
            return source;
        }
    } else if ([code isEqualToString:@"zh"] && WGHasCJK(source)) {
        return source;
    }

    NSString *cached = WGCacheForCode(code)[source];
    return cached.length > 0 ? cached : nil;
}

static NSString *WGGoogleTranslatedTextFromData(NSData *data) {
    if (data.length == 0) return nil;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSArray.class] || [(NSArray *)root count] == 0) return nil;
    id segmentsObject = ((NSArray *)root)[0];
    if (![segmentsObject isKindOfClass:NSArray.class]) return nil;

    NSMutableString *result = [NSMutableString string];
    for (id segmentObject in (NSArray *)segmentsObject) {
        if (![segmentObject isKindOfClass:NSArray.class] || [(NSArray *)segmentObject count] == 0) continue;
        id piece = ((NSArray *)segmentObject)[0];
        if ([piece isKindOfClass:NSString.class]) [result appendString:piece];
    }
    return result.length > 0 ? result : nil;
}

static void WGScheduleRefresh(void);

static void WGQueueRemoteTranslation(NSString *source, NSString *code) {
    if (source.length == 0 || !WGCodeIsSupported(code) || WGShouldIgnoreSource(source)) return;

    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WGQueueRemoteTranslation(source, code); });
        return;
    }

    if (WGImmediateTranslationForSource(source, code).length > 0) return;
    if (!WGRemoteInFlight) WGRemoteInFlight = [NSMutableSet set];
    if (WGRemoteInFlight.count >= 8) return;

    NSString *flightKey = [NSString stringWithFormat:@"%@\u241F%@", code, source];
    if ([WGRemoteInFlight containsObject:flightKey]) return;
    [WGRemoteInFlight addObject:flightKey];

    if (!WGTranslationSession) {
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest = 9.0;
        configuration.timeoutIntervalForResource = 12.0;
        WGTranslationSession = [NSURLSession sessionWithConfiguration:configuration];
    }

    NSURLComponents *components = [NSURLComponents componentsWithString:@"https://translate.googleapis.com/translate_a/single"];
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"client" value:@"gtx"],
        [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"],
        [NSURLQueryItem queryItemWithName:@"tl" value:WGTargetCodeForGoogle(code)],
        [NSURLQueryItem queryItemWithName:@"dt" value:@"t"],
        [NSURLQueryItem queryItemWithName:@"q" value:source],
    ];
    NSURL *url = components.URL;
    if (!url) {
        [WGRemoteInFlight removeObject:flightKey];
        return;
    }

    NSURLSessionDataTask *task = [WGTranslationSession dataTaskWithURL:url
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        (void)response;
        NSString *translated = error ? nil : WGGoogleTranslatedTextFromData(data);
        dispatch_async(dispatch_get_main_queue(), ^{
            [WGRemoteInFlight removeObject:flightKey];
            if (translated.length > 0 && ![translated isEqualToString:source]) {
                WGCacheForCode(code)[source] = translated;
                WGPersistCache(code);
            } else if ([code isEqualToString:@"en"] && !WGHasCyrillic(source) && !WGHasArabicScript(source) && !WGHasCJK(source)) {
                WGCacheForCode(code)[source] = source;
                WGPersistCache(code);
            }
            WGScheduleRefresh();
        });
    }];
    [task resume];
}

#pragma mark - Applying translations to visible Whitegram UI

static void WGApplyDirectionToView(UIView *view, NSString *code) {
    BOOL rtl = [code isEqualToString:@"ar"] || [code isEqualToString:@"fa"];
    if (rtl) {
        view.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        if ([view isKindOfClass:UILabel.class]) ((UILabel *)view).textAlignment = NSTextAlignmentNatural;
        if ([view isKindOfClass:UITextView.class]) ((UITextView *)view).textAlignment = NSTextAlignmentNatural;
    } else {
        view.semanticContentAttribute = UISemanticContentAttributeForceLeftToRight;
    }
}

static BOOL WGObjectAlreadyHasAppliedText(id object, NSString *text, NSString *code) {
    NSString *appliedCode = objc_getAssociatedObject(object, &WGAppliedLanguageKey);
    NSString *appliedText = objc_getAssociatedObject(object, &WGAppliedTextKey);
    return [appliedCode isEqualToString:code] && [appliedText isEqualToString:text];
}

static void WGRememberAppliedText(id object, NSString *text, NSString *code) {
    if (!object || !text || !code) return;
    objc_setAssociatedObject(object, &WGAppliedLanguageKey, code, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(object, &WGAppliedTextKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static void WGHandleStringForObject(NSString *source,
                                    id object,
                                    NSString *code,
                                    void (^apply)(NSString *translated)) {
    if (source.length == 0 || WGShouldIgnoreSource(source)) return;
    if (WGObjectAlreadyHasAppliedText(object, source, code)) return;

    NSString *translated = WGImmediateTranslationForSource(source, code);
    if (translated.length > 0) {
        if (![translated isEqualToString:source]) {
            apply(translated);
            WGRememberAppliedText(object, translated, code);
        } else {
            WGRememberAppliedText(object, source, code);
        }
        return;
    }

    WGQueueRemoteTranslation(source, code);
}

static void WGProcessView(UIView *view, NSString *code, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 90 || *visited > 2600) return;
    (*visited)++;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        NSString *source = label.text;
        WGHandleStringForObject(source, label, code, ^(NSString *translated) {
            label.text = translated;
            WGApplyDirectionToView(label, code);
        });
    } else if ([view isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)view;
        NSString *source = [button titleForState:UIControlStateNormal];
        WGHandleStringForObject(source, button, code, ^(NSString *translated) {
            [button setTitle:translated forState:UIControlStateNormal];
            WGApplyDirectionToView(button, code);
        });
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        NSString *source = field.placeholder;
        WGHandleStringForObject(source, field, code, ^(NSString *translated) {
            field.placeholder = translated;
            WGApplyDirectionToView(field, code);
        });
    } else if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *searchBar = (UISearchBar *)view;
        NSString *source = searchBar.placeholder;
        WGHandleStringForObject(source, searchBar, code, ^(NSString *translated) {
            searchBar.placeholder = translated;
            WGApplyDirectionToView(searchBar, code);
        });
    } else if ([view isKindOfClass:UITextView.class]) {
        UITextView *textView = (UITextView *)view;
        if (!textView.editable) {
            NSString *source = textView.text;
            WGHandleStringForObject(source, textView, code, ^(NSString *translated) {
                textView.text = translated;
                WGApplyDirectionToView(textView, code);
            });
        }
    }

    for (UIView *subview in view.subviews) {
        WGProcessView(subview, code, depth + 1, visited);
    }
}

static void WGReloadListsInView(UIView *view, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 70 || *visited > 1800) return;
    (*visited)++;
    if ([view isKindOfClass:UITableView.class]) {
        [(UITableView *)view reloadData];
    } else if ([view isKindOfClass:UICollectionView.class]) {
        [(UICollectionView *)view reloadData];
    }
    for (UIView *subview in view.subviews) {
        WGReloadListsInView(subview, depth + 1, visited);
    }
}

static void WGTranslateController(UIViewController *controller, BOOL reloadLists) {
    if (!controller || !controller.isViewLoaded || !WGControllerIsWhitegram(controller)) return;
    NSString *code = WGCustomLanguageCode().lowercaseString;
    if (!WGCodeIsSupported(code)) return;

    if (controller.title.length > 0) {
        NSString *source = controller.title;
        WGHandleStringForObject(source, controller.navigationItem, code, ^(NSString *translated) {
            controller.title = translated;
            controller.navigationItem.title = translated;
        });
    }

    NSUInteger visited = 0;
    WGProcessView(controller.view, code, 0, &visited);
    if (reloadLists) {
        NSUInteger listVisited = 0;
        WGReloadListsInView(controller.view, 0, &listVisited);
    }
}

static void WGRefreshVisibleWhitegramScreens(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WGRefreshVisibleWhitegramScreens(); });
        return;
    }
    for (UIViewController *controller in WGActiveWhitegramControllers.allObjects) {
        WGTranslateController(controller, YES);
    }
}

static void WGScheduleRefresh(void) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ WGScheduleRefresh(); });
        return;
    }
    if (WGRefreshScheduled) return;
    WGRefreshScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WGRefreshScheduled = NO;
        WGRefreshVisibleWhitegramScreens();
    });
}

#pragma mark - Language button and menu

static void WGPresentLanguageConfirmation(UIViewController *controller,
                                          NSDictionary<NSString *, NSString *> *language) {
    NSString *name = language[@"name"] ?: language[@"english"] ?: @"Language";
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
        NSString *code = language[@"code"];
        WGSetCustomLanguageCode(code);
        [NSUserDefaults.standardUserDefaults synchronize];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.18 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            exit(0);
        });
    }]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void WGShowLanguageMenu(UIViewController *controller, UIButton *sender) {
    if (!controller || controller.presentedViewController) return;
    NSString *current = WGCustomLanguageCode().lowercaseString ?: @"ar";

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Languages • اللغات"
                                                                   message:@"Whitegram Features Language"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary<NSString *, NSString *> *language in WGLanguages()) {
        NSString *code = language[@"code"];
        NSString *title = language[@"name"];
        if ([code isEqualToString:current]) title = [@"✓ " stringByAppendingString:title];
        [sheet addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            if ([code isEqualToString:current]) return;
            WGPresentLanguageConfirmation(controller, language);
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel • إلغاء" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = sheet.popoverPresentationController;
    if (popover) {
        popover.sourceView = sender;
        popover.sourceRect = sender.bounds;
    }
    [controller presentViewController:sheet animated:YES completion:nil];
}

@interface UIViewController (WGLanguageOverlayActions)
- (void)wg_ikira_showLanguageMenu:(UIButton *)sender;
@end

@implementation UIViewController (WGLanguageOverlayActions)
- (void)wg_ikira_showLanguageMenu:(UIButton *)sender {
    WGShowLanguageMenu(self, sender);
}
@end

static void WGInstallLanguageButtonIfNeeded(UIViewController *controller) {
    if (!WGControllerIsWhitegramRoot(controller) || !controller.isViewLoaded) return;

    UIButton *existing = objc_getAssociatedObject(controller, &WGLanguageButtonKey);
    if (existing) {
        [controller.view bringSubviewToFront:existing];
        return;
    }

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
    [button addTarget:controller action:@selector(wg_ikira_showLanguageMenu:) forControlEvents:UIControlEventTouchUpInside];

    [controller.view addSubview:button];
    UILayoutGuide *safe = controller.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-18.0],
        [button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12.0],
        [button.widthAnchor constraintEqualToConstant:44.0],
        [button.heightAnchor constraintEqualToConstant:44.0],
    ]];
    objc_setAssociatedObject(controller, &WGLanguageButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [controller.view bringSubviewToFront:button];
}

#pragma mark - UIViewController lifecycle hook

static void WGOverlayViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (WGPreviousViewDidAppear) {
        ((void (*)(id, SEL, BOOL))WGPreviousViewDidAppear)(self, _cmd, animated);
    }

    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (!controller) return;

    if (WGControllerIsWhitegram(controller)) {
        if (!WGActiveWhitegramControllers) WGActiveWhitegramControllers = [NSHashTable weakObjectsHashTable];
        [WGActiveWhitegramControllers addObject:controller];
        WGInstallLanguageButtonIfNeeded(controller);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGTranslateController(controller, NO);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WGTranslateController(controller, NO);
        });
    }
}

static void WGOverlayViewDidDisappear(id self, SEL _cmd, BOOL animated) {
    if (WGPreviousViewDidDisappear) {
        ((void (*)(id, SEL, BOOL))WGPreviousViewDidDisappear)(self, _cmd, animated);
    }
    UIViewController *controller = [self isKindOfClass:UIViewController.class] ? self : nil;
    if (controller) [WGActiveWhitegramControllers removeObject:controller];
}

static void WGInstallControllerHooks(void) {
    Method appear = class_getInstanceMethod(UIViewController.class, @selector(viewDidAppear:));
    if (appear) {
        IMP current = method_getImplementation(appear);
        if (current != (IMP)WGOverlayViewDidAppear) {
            WGPreviousViewDidAppear = current;
            method_setImplementation(appear, (IMP)WGOverlayViewDidAppear);
        }
    }

    Method disappear = class_getInstanceMethod(UIViewController.class, @selector(viewDidDisappear:));
    if (disappear) {
        IMP current = method_getImplementation(disappear);
        if (current != (IMP)WGOverlayViewDidDisappear) {
            WGPreviousViewDidDisappear = current;
            method_setImplementation(disappear, (IMP)WGOverlayViewDidDisappear);
        }
    }
}

#pragma mark - Entry

__attribute__((constructor))
static void WGLanguageOverlayEntry(void) {
    @autoreleasepool {
        WGEnsureArabicDefault();
        WGActiveWhitegramControllers = [NSHashTable weakObjectsHashTable];
        WGRemoteInFlight = [NSMutableSet set];

        // Install after the base NodeFix hooks so this layer chains through them.
        dispatch_async(dispatch_get_main_queue(), ^{
            WGInstallControllerHooks();
        });
    }
}
