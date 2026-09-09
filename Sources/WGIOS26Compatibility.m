#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "WGTranslations.h"

/*
 * iOS 26 compatibility path.
 *
 * Do not mutate the NSAttributedString class-cluster during dylib constructors.
 * On iOS 26 the concrete/placeholder classes may differ from earlier systems;
 * chaining aliases across the allocation class, concrete class and abstract base
 * can recurse or call an invalid inherited implementation before UIApplication
 * finishes launching.
 *
 * This path waits until the app has launched, then installs:
 *   1) one direct-IMP hook on the NSAttributedString allocation class only;
 *   2) public UIKit setter hooks using ordinary method_exchangeImplementations.
 *
 * No recursive view scan, no private ivars, no network work and no polling.
 */

static BOOL WG26Installed = NO;
static IMP WG26AttributedOriginalIMP = NULL;
static Class WG26AttributedAllocationClass = Nil;

#pragma mark - Safe attributed-string hook

static id WG26AttributedInit(id self,
                             SEL _cmd,
                             NSString *string,
                             NSDictionary<NSAttributedStringKey, id> *attributes) {
    IMP original = WG26AttributedOriginalIMP;
    if (!original) return nil;

    NSString *source = [string isKindOfClass:NSString.class] ? string : @"";
    NSString *translated = WGTranslateStringExact(source);
    if (!translated) translated = source;

    return ((id (*)(id, SEL, NSString *, NSDictionary *))original)(self,
                                                                   _cmd,
                                                                   translated,
                                                                   attributes);
}

static void WG26InstallAttributedHook(void) {
    if (WG26AttributedOriginalIMP) return;

    id allocated = [NSAttributedString alloc];
    Class cls = allocated ? object_getClass(allocated) : Nil;
    if (!cls) return;

    SEL selector = @selector(initWithString:attributes:);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (!original || !types || original == (IMP)WG26AttributedInit) return;

    /*
     * class_replaceMethod adds an override when the allocation class inherits
     * the initializer, instead of modifying Foundation's superclass method.
     * The captured IMP is called directly, so there is no alias-selector chain.
     */
    WG26AttributedOriginalIMP = original;
    WG26AttributedAllocationClass = cls;
    class_replaceMethod(cls, selector, (IMP)WG26AttributedInit, types);
}

#pragma mark - Public UIKit hooks

@interface UILabel (WG26Localization)
- (void)wg26_setText:(NSString *)text;
- (void)wg26_setAttributedText:(NSAttributedString *)text;
@end
@implementation UILabel (WG26Localization)
- (void)wg26_setText:(NSString *)text {
    NSString *translated = WGTranslateStringExact(text);
    [self wg26_setText:translated];
    if (text && ![translated isEqualToString:text] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.textAlignment = NSTextAlignmentNatural;
    }
}
- (void)wg26_setAttributedText:(NSAttributedString *)text {
    NSAttributedString *translated = WGTranslateAttributedStringExact(text);
    [self wg26_setAttributedText:translated];
    if (text && ![translated.string isEqualToString:text.string] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.textAlignment = NSTextAlignmentNatural;
    }
}
@end

@interface UIButton (WG26Localization)
- (void)wg26_setTitle:(NSString *)title forState:(UIControlState)state;
- (void)wg26_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state;
@end
@implementation UIButton (WG26Localization)
- (void)wg26_setTitle:(NSString *)title forState:(UIControlState)state {
    NSString *translated = WGTranslateStringExact(title);
    [self wg26_setTitle:translated forState:state];
    if (title && ![translated isEqualToString:title] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    }
}
- (void)wg26_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    NSAttributedString *translated = WGTranslateAttributedStringExact(title);
    [self wg26_setAttributedTitle:translated forState:state];
    if (title && ![translated.string isEqualToString:title.string] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    }
}
@end

@interface UITextField (WG26Localization)
- (void)wg26_setPlaceholder:(NSString *)placeholder;
@end
@implementation UITextField (WG26Localization)
- (void)wg26_setPlaceholder:(NSString *)placeholder {
    [self wg26_setPlaceholder:WGTranslateStringExact(placeholder)];
}
@end

@interface UISearchBar (WG26Localization)
- (void)wg26_setPlaceholder:(NSString *)placeholder;
@end
@implementation UISearchBar (WG26Localization)
- (void)wg26_setPlaceholder:(NSString *)placeholder {
    [self wg26_setPlaceholder:WGTranslateStringExact(placeholder)];
}
@end

@interface UINavigationItem (WG26Localization)
- (void)wg26_setTitle:(NSString *)title;
@end
@implementation UINavigationItem (WG26Localization)
- (void)wg26_setTitle:(NSString *)title {
    [self wg26_setTitle:WGTranslateStringExact(title)];
}
@end

@interface UIViewController (WG26Localization)
- (void)wg26_setTitle:(NSString *)title;
@end
@implementation UIViewController (WG26Localization)
- (void)wg26_setTitle:(NSString *)title {
    [self wg26_setTitle:WGTranslateStringExact(title)];
}
@end

@interface UIAlertController (WG26Localization)
+ (instancetype)wg26_alertControllerWithTitle:(NSString *)title
                                       message:(NSString *)message
                                preferredStyle:(UIAlertControllerStyle)preferredStyle;
@end
@implementation UIAlertController (WG26Localization)
+ (instancetype)wg26_alertControllerWithTitle:(NSString *)title
                                       message:(NSString *)message
                                preferredStyle:(UIAlertControllerStyle)preferredStyle {
    return [self wg26_alertControllerWithTitle:WGTranslateStringExact(title)
                                       message:WGTranslateStringExact(message)
                                preferredStyle:preferredStyle];
}
@end

@interface UIBarButtonItem (WG26Localization)
- (instancetype)wg26_initWithTitle:(NSString *)title
                             style:(UIBarButtonItemStyle)style
                            target:(id)target
                            action:(SEL)action;
@end
@implementation UIBarButtonItem (WG26Localization)
- (instancetype)wg26_initWithTitle:(NSString *)title
                             style:(UIBarButtonItemStyle)style
                            target:(id)target
                            action:(SEL)action {
    return [self wg26_initWithTitle:WGTranslateStringExact(title)
                              style:style
                             target:target
                             action:action];
}
@end

static void WG26SwizzleInstance(Class cls, SEL original, SEL replacement) {
    Method a = class_getInstanceMethod(cls, original);
    Method b = class_getInstanceMethod(cls, replacement);
    if (!a || !b) return;

    BOOL added = class_addMethod(cls,
                                 original,
                                 method_getImplementation(b),
                                 method_getTypeEncoding(b));
    if (added) {
        class_replaceMethod(cls,
                            replacement,
                            method_getImplementation(a),
                            method_getTypeEncoding(a));
    } else {
        method_exchangeImplementations(a, b);
    }
}

static void WG26SwizzleClass(Class cls, SEL original, SEL replacement) {
    WG26SwizzleInstance(object_getClass(cls), original, replacement);
}

static void WG26InstallUIKitHooks(void) {
    WG26SwizzleInstance(UILabel.class, @selector(setText:), @selector(wg26_setText:));
    WG26SwizzleInstance(UILabel.class, @selector(setAttributedText:), @selector(wg26_setAttributedText:));
    WG26SwizzleInstance(UIButton.class, @selector(setTitle:forState:), @selector(wg26_setTitle:forState:));
    WG26SwizzleInstance(UIButton.class, @selector(setAttributedTitle:forState:), @selector(wg26_setAttributedTitle:forState:));
    WG26SwizzleInstance(UITextField.class, @selector(setPlaceholder:), @selector(wg26_setPlaceholder:));
    WG26SwizzleInstance(UISearchBar.class, @selector(setPlaceholder:), @selector(wg26_setPlaceholder:));
    WG26SwizzleInstance(UINavigationItem.class, @selector(setTitle:), @selector(wg26_setTitle:));
    WG26SwizzleInstance(UIViewController.class, @selector(setTitle:), @selector(wg26_setTitle:));
    WG26SwizzleClass(UIAlertController.class,
                     @selector(alertControllerWithTitle:message:preferredStyle:),
                     @selector(wg26_alertControllerWithTitle:message:preferredStyle:));
    WG26SwizzleInstance(UIBarButtonItem.class,
                        @selector(initWithTitle:style:target:action:),
                        @selector(wg26_initWithTitle:style:target:action:));
}

static void WG26InstallNow(void) {
    if (WG26Installed) return;
    WG26Installed = YES;

    WG26InstallAttributedHook();
    WG26InstallUIKitHooks();
}

void WGIOS26InstallCompatibilityHooksLater(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = UIApplication.sharedApplication;
        if (app.applicationState != UIApplicationStateInactive) {
            WG26InstallNow();
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
            WG26InstallNow();
        }];
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                          object:nil
                                                           queue:NSOperationQueue.mainQueue
                                                      usingBlock:^(__unused NSNotification *note) {
            WG26InstallNow();
        }];

        /* Fallback for injection/load orders where launch notification already fired. */
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.75 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ WG26InstallNow(); });
    });
}
