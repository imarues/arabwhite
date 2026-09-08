#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdlib.h>
#import "WGTranslations.h"

/*
 * Whitegram MultiLang Build70
 *
 * v7 restored translation by writing directly into Swift stored properties.
 * That is unsafe on Whitegram 12.9.2 because ImmediateTextNode.attributedText
 * is a Swift-owned field whose ownership/layout is not represented safely to
 * the Objective-C runtime. The write corrupted objects and caused crashes in
 * Settings, registration and other screens.
 *
 * v8 never reads or writes Swift ivars. Telegram's ItemList rows create their
 * visible text as immutable NSAttributedString instances. We translate exact
 * dictionary matches while those immutable strings are being constructed, then
 * keep the stable UIKit hooks for labels, buttons, titles and placeholders.
 * No NSBundle hook, no UITextView hook, no _ASDisplayView hook and no private
 * object_setIvar path are used.
 */

#pragma mark - Immutable attributed-string construction hook

static SEL WGOriginalAttributedInitSelector(void) {
    return sel_registerName("wg_nf_original_initWithString:attributes:");
}

static id WGAttributedInitWithStringAndAttributes(id self,
                                                   SEL _cmd,
                                                   NSString *string,
                                                   NSDictionary<NSAttributedStringKey, id> *attributes) {
    (void)_cmd;

    NSString *source = [string isKindOfClass:NSString.class] ? string : @"";
    NSString *translated = WGTranslateStringExact(source);
    if (!translated) {
        translated = source;
    }

    SEL originalSelector = WGOriginalAttributedInitSelector();
    return ((id (*)(id, SEL, NSString *, NSDictionary *))objc_msgSend)(self,
                                                                       originalSelector,
                                                                       translated,
                                                                       attributes);
}

static BOOL WGClassHasOwnMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    BOOL found = NO;
    for (unsigned int index = 0; index < count; index++) {
        if (method_getName(methods[index]) == selector) {
            found = YES;
            break;
        }
    }
    free(methods);
    return found;
}

static void WGInstallAttributedInitHookOnClass(Class cls) {
    if (!cls) {
        return;
    }

    SEL originalSelector = @selector(initWithString:attributes:);
    SEL aliasSelector = WGOriginalAttributedInitSelector();

    if (WGClassHasOwnMethod(cls, aliasSelector)) {
        return;
    }

    Method originalMethod = class_getInstanceMethod(cls, originalSelector);
    if (!originalMethod) {
        return;
    }

    IMP originalImplementation = method_getImplementation(originalMethod);
    const char *types = method_getTypeEncoding(originalMethod);
    if (!originalImplementation || !types) {
        return;
    }

    if (!class_addMethod(cls, aliasSelector, originalImplementation, types)) {
        return;
    }

    class_replaceMethod(cls,
                        originalSelector,
                        (IMP)WGAttributedInitWithStringAndAttributes,
                        types);
}

static void WGInstallAttributedStringHooks(void) {
    /*
     * NSAttributedString is a class cluster. Capture both the allocation class
     * and the initialized immutable concrete class before installing hooks.
     * Concrete classes are hooked first so their alias always points to Apple's
     * original initializer, never to a hook inherited from the abstract base.
     */
    NSMutableOrderedSet *classes = [NSMutableOrderedSet orderedSet];

    id allocated = [NSAttributedString alloc];
    Class allocationClass = allocated ? object_getClass(allocated) : Nil;
    NSAttributedString *sample = [allocated initWithString:@"WGArabicProbe"
                                                 attributes:@{}];
    Class sampleClass = sample ? object_getClass(sample) : Nil;

    // Hook the initialized concrete class before the allocation/placeholder
    // class. If one inherits from the other, this preserves the true original
    // initializer in each alias and prevents an alias from pointing at our hook.
    if (sampleClass) {
        [classes addObject:sampleClass];
    }
    if (allocationClass) {
        [classes addObject:allocationClass];
    }

    for (id value in classes) {
        Class cls = (Class)value;
        if (cls != NSAttributedString.class) {
            WGInstallAttributedInitHookOnClass(cls);
        }
    }
    WGInstallAttributedInitHookOnClass(NSAttributedString.class);
}

#pragma mark - Stable UIKit hooks

static void WGScheduleSafeUIKitScan(NSTimeInterval delay);

@interface UILabel (WGMultiLangNodeFix)
- (void)wg_nf_setText:(NSString *)text;
- (void)wg_nf_setAttributedText:(NSAttributedString *)text;
@end

@implementation UILabel (WGMultiLangNodeFix)
- (void)wg_nf_setText:(NSString *)text {
    NSString *translated = WGTranslateString(text);
    [self wg_nf_setText:translated];
    if (text && ![translated isEqualToString:text] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.textAlignment = NSTextAlignmentNatural;
    }
}

- (void)wg_nf_setAttributedText:(NSAttributedString *)text {
    NSAttributedString *translated = WGTranslateAttributedString(text);
    [self wg_nf_setAttributedText:translated];
    if (text && ![translated.string isEqualToString:text.string] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
        self.textAlignment = NSTextAlignmentNatural;
    }
}
@end

@interface UIButton (WGMultiLangNodeFix)
- (void)wg_nf_setTitle:(NSString *)title forState:(UIControlState)state;
- (void)wg_nf_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state;
@end

@implementation UIButton (WGMultiLangNodeFix)
- (void)wg_nf_setTitle:(NSString *)title forState:(UIControlState)state {
    NSString *translated = WGTranslateString(title);
    [self wg_nf_setTitle:translated forState:state];
    if (title && ![translated isEqualToString:title] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    }
}

- (void)wg_nf_setAttributedTitle:(NSAttributedString *)title forState:(UIControlState)state {
    NSAttributedString *translated = WGTranslateAttributedString(title);
    [self wg_nf_setAttributedTitle:translated forState:state];
    if (title && ![translated.string isEqualToString:title.string] && WGCurrentLanguageIsRTL()) {
        self.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    }
}
@end

@interface UITextField (WGMultiLangNodeFix)
- (void)wg_nf_setPlaceholder:(NSString *)placeholder;
@end

@implementation UITextField (WGMultiLangNodeFix)
- (void)wg_nf_setPlaceholder:(NSString *)placeholder {
    [self wg_nf_setPlaceholder:WGTranslateString(placeholder)];
}
@end

@interface UISearchBar (WGMultiLangNodeFix)
- (void)wg_nf_setPlaceholder:(NSString *)placeholder;
@end

@implementation UISearchBar (WGMultiLangNodeFix)
- (void)wg_nf_setPlaceholder:(NSString *)placeholder {
    [self wg_nf_setPlaceholder:WGTranslateString(placeholder)];
}
@end

@interface UINavigationItem (WGMultiLangNodeFix)
- (void)wg_nf_setTitle:(NSString *)title;
@end

@implementation UINavigationItem (WGMultiLangNodeFix)
- (void)wg_nf_setTitle:(NSString *)title {
    [self wg_nf_setTitle:WGTranslateString(title)];
}
@end

@interface UIViewController (WGMultiLangNodeFix)
- (void)wg_nf_setTitle:(NSString *)title;
- (void)wg_nf_viewDidAppear:(BOOL)animated;
@end

@implementation UIViewController (WGMultiLangNodeFix)
- (void)wg_nf_setTitle:(NSString *)title {
    [self wg_nf_setTitle:WGTranslateString(title)];
}

- (void)wg_nf_viewDidAppear:(BOOL)animated {
    [self wg_nf_viewDidAppear:animated];
    WGScheduleSafeUIKitScan(0.08);
}
@end

@interface UIAlertController (WGMultiLangNodeFix)
+ (instancetype)wg_nf_alertControllerWithTitle:(NSString *)title
                                        message:(NSString *)message
                                 preferredStyle:(UIAlertControllerStyle)preferredStyle;
@end

@implementation UIAlertController (WGMultiLangNodeFix)
+ (instancetype)wg_nf_alertControllerWithTitle:(NSString *)title
                                        message:(NSString *)message
                                 preferredStyle:(UIAlertControllerStyle)preferredStyle {
    return [self wg_nf_alertControllerWithTitle:WGTranslateString(title)
                                        message:WGTranslateString(message)
                                 preferredStyle:preferredStyle];
}
@end

@interface UIBarButtonItem (WGMultiLangNodeFix)
- (instancetype)wg_nf_initWithTitle:(NSString *)title
                              style:(UIBarButtonItemStyle)style
                             target:(id)target
                             action:(SEL)action;
@end

@implementation UIBarButtonItem (WGMultiLangNodeFix)
- (instancetype)wg_nf_initWithTitle:(NSString *)title
                              style:(UIBarButtonItemStyle)style
                             target:(id)target
                             action:(SEL)action {
    return [self wg_nf_initWithTitle:WGTranslateString(title)
                               style:style
                              target:target
                              action:action];
}
@end

#pragma mark - Safe UIKit-only fallback scan

static NSUInteger WGTranslateUIKitView(UIView *view) {
    NSUInteger changes = 0;

    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        if (label.attributedText.length > 0) {
            NSAttributedString *translated = WGTranslateAttributedString(label.attributedText);
            if (![translated.string isEqualToString:label.attributedText.string]) {
                label.attributedText = translated;
                if (WGCurrentLanguageIsRTL()) {
                    label.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
                    label.textAlignment = NSTextAlignmentNatural;
                }
                changes++;
            }
        } else if (label.text.length > 0) {
            NSString *translated = WGTranslateString(label.text);
            if (![translated isEqualToString:label.text]) {
                label.text = translated;
                if (WGCurrentLanguageIsRTL()) {
                    label.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
                    label.textAlignment = NSTextAlignmentNatural;
                }
                changes++;
            }
        }
    } else if ([view isKindOfClass:UITextField.class]) {
        UITextField *field = (UITextField *)view;
        if (field.placeholder.length > 0) {
            NSString *translated = WGTranslateString(field.placeholder);
            if (![translated isEqualToString:field.placeholder]) {
                field.placeholder = translated;
                changes++;
            }
        }
    } else if ([view isKindOfClass:UISearchBar.class]) {
        UISearchBar *searchBar = (UISearchBar *)view;
        if (searchBar.placeholder.length > 0) {
            NSString *translated = WGTranslateString(searchBar.placeholder);
            if (![translated isEqualToString:searchBar.placeholder]) {
                searchBar.placeholder = translated;
                changes++;
            }
        }
    }

    return changes;
}

static NSUInteger WGScanUIKitTree(UIView *view, NSUInteger depth, NSUInteger *visited) {
    if (!view || depth > 80 || *visited > 2200) {
        return 0;
    }

    (*visited)++;
    NSUInteger changes = WGTranslateUIKitView(view);
    for (UIView *subview in view.subviews) {
        changes += WGScanUIKitTree(subview, depth + 1, visited);
    }
    return changes;
}

static NSArray<UIWindow *> *WGVisibleWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in application.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) {
                continue;
            }
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (!window.hidden && window.alpha > 0.01) {
                    [windows addObject:window];
                }
            }
        }
    }

    if (windows.count == 0) {
        for (UIWindow *window in application.windows) {
            if (!window.hidden && window.alpha > 0.01) {
                [windows addObject:window];
            }
        }
    }

    return windows.array;
}

static BOOL WGSafeScanPending = NO;

static void WGRunSafeUIKitScan(void) {
    if (!WGLocalizationEnabled()) {
        return;
    }

    NSUInteger visited = 0;
    for (UIWindow *window in WGVisibleWindows()) {
        WGScanUIKitTree(window, 0, &visited);
    }
}

static void WGScheduleSafeUIKitScan(NSTimeInterval delay) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            WGScheduleSafeUIKitScan(delay);
        });
        return;
    }

    if (WGSafeScanPending) {
        return;
    }
    WGSafeScanPending = YES;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WGRunSafeUIKitScan();
        WGSafeScanPending = NO;
    });
}

#pragma mark - Swizzle installation

static void WGSwizzle(Class cls, SEL original, SEL replacement) {
    Method originalMethod = class_getInstanceMethod(cls, original);
    Method replacementMethod = class_getInstanceMethod(cls, replacement);
    if (!originalMethod || !replacementMethod) {
        return;
    }

    BOOL added = class_addMethod(cls,
                                 original,
                                 method_getImplementation(replacementMethod),
                                 method_getTypeEncoding(replacementMethod));
    if (added) {
        class_replaceMethod(cls,
                            replacement,
                            method_getImplementation(originalMethod),
                            method_getTypeEncoding(originalMethod));
    } else {
        method_exchangeImplementations(originalMethod, replacementMethod);
    }
}

static void WGSwizzleClass(Class cls, SEL original, SEL replacement) {
    WGSwizzle(object_getClass(cls), original, replacement);
}

static void WGInstallUIKitHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WGSwizzle(UILabel.class, @selector(setText:), @selector(wg_nf_setText:));
        WGSwizzle(UILabel.class, @selector(setAttributedText:), @selector(wg_nf_setAttributedText:));
        WGSwizzle(UIButton.class, @selector(setTitle:forState:), @selector(wg_nf_setTitle:forState:));
        WGSwizzle(UIButton.class,
                  @selector(setAttributedTitle:forState:),
                  @selector(wg_nf_setAttributedTitle:forState:));
        WGSwizzle(UITextField.class, @selector(setPlaceholder:), @selector(wg_nf_setPlaceholder:));
        WGSwizzle(UISearchBar.class, @selector(setPlaceholder:), @selector(wg_nf_setPlaceholder:));
        WGSwizzle(UINavigationItem.class, @selector(setTitle:), @selector(wg_nf_setTitle:));
        WGSwizzle(UIViewController.class, @selector(setTitle:), @selector(wg_nf_setTitle:));
        WGSwizzle(UIViewController.class, @selector(viewDidAppear:), @selector(wg_nf_viewDidAppear:));
        WGSwizzleClass(UIAlertController.class,
                       @selector(alertControllerWithTitle:message:preferredStyle:),
                       @selector(wg_nf_alertControllerWithTitle:message:preferredStyle:));
        WGSwizzle(UIBarButtonItem.class,
                  @selector(initWithTitle:style:target:action:),
                  @selector(wg_nf_initWithTitle:style:target:action:));
    });
}


#pragma mark - Whitegram language picker extension

/*
 * Whitegram 7.0 already ships Russian, Ukrainian and English. Rather than
 * replacing that picker, add the iKiraPlus locale after Whitegram's own rows.
 * The class is Swift-private, so it is found by its stable suffix and only its
 * public UITableView delegate/data-source methods are interposed. No Swift
 * storage or private ivars are touched.
 */

typedef NSInteger (*WGPickerRowsIMP)(id, SEL, UITableView *, NSInteger);
typedef UITableViewCell *(*WGPickerCellIMP)(id, SEL, UITableView *, NSIndexPath *);
typedef void (*WGPickerSelectIMP)(id, SEL, UITableView *, NSIndexPath *);

static WGPickerRowsIMP WGPickerOriginalRows = NULL;
static WGPickerCellIMP WGPickerOriginalCell = NULL;
static WGPickerSelectIMP WGPickerOriginalSelect = NULL;
static Class WGPickerClass = Nil;

static NSInteger WGPickerRows(id self, SEL _cmd, UITableView *tableView, NSInteger section) {
    NSInteger base = WGPickerOriginalRows ? WGPickerOriginalRows(self, _cmd, tableView, section) : 0;
    if (section == 0 && base >= 3) {
        return base + 1;
    }
    return base;
}

static UITableViewCell *WGPickerArabicCell(UITableView *tableView,
                                           UITableViewCell *templateCell) {
    UITableViewCell *cell = templateCell;
    if (!cell || !cell.textLabel) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                       reuseIdentifier:nil];
    }

    cell.textLabel.text = @"العربية";
    cell.detailTextLabel.text = @"Arabic • iKiraPlus";
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.detailTextLabel.textAlignment = NSTextAlignmentNatural;
    cell.semanticContentAttribute = UISemanticContentAttributeForceRightToLeft;
    cell.accessoryType = [[WGCustomLanguageCode() lowercaseString] isEqualToString:@"ar"]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

static UITableViewCell *WGPickerCell(id self,
                                     SEL _cmd,
                                     UITableView *tableView,
                                     NSIndexPath *indexPath) {
    NSInteger base = 0;
    if (WGPickerOriginalRows) {
        base = WGPickerOriginalRows(self,
                                    @selector(tableView:numberOfRowsInSection:),
                                    tableView,
                                    indexPath.section);
    }

    if (indexPath.section == 0 && base >= 3 && indexPath.row == base) {
        // Ask Whitegram for an English-row cell first so fonts, separators and
        // dark/light styling are exactly the same as the built-in rows.
        NSIndexPath *englishPath = [NSIndexPath indexPathForRow:base - 1 inSection:indexPath.section];
        UITableViewCell *templateCell = WGPickerOriginalCell
            ? WGPickerOriginalCell(self, _cmd, tableView, englishPath)
            : nil;
        return WGPickerArabicCell(tableView, templateCell);
    }

    UITableViewCell *cell = WGPickerOriginalCell
        ? WGPickerOriginalCell(self, _cmd, tableView, indexPath)
        : [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];

    // Whitegram owns the checkmarks for its built-in languages. If a custom
    // language is active, none of those rows should look selected.
    if ([WGCustomLanguageCode() length] > 0) {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

static void WGPickerDidSelect(id self,
                              SEL _cmd,
                              UITableView *tableView,
                              NSIndexPath *indexPath) {
    NSInteger base = 0;
    if (WGPickerOriginalRows) {
        base = WGPickerOriginalRows(self,
                                    @selector(tableView:numberOfRowsInSection:),
                                    tableView,
                                    indexPath.section);
    }

    if (indexPath.section == 0 && base >= 3 && indexPath.row == base) {
        /*
         * Whitegram's last built-in row is English in build 70. Select it
         * internally so dynamic source text is English, then enable our Arabic
         * overlay. Exact Russian/Ukrainian aliases are still supported for
         * already-created rows and for future ordering changes.
         */
        NSIndexPath *englishPath = [NSIndexPath indexPathForRow:base - 1 inSection:indexPath.section];
        if (WGPickerOriginalSelect) {
            WGPickerOriginalSelect(self, _cmd, tableView, englishPath);
        }
        WGSetCustomLanguageCode(@"ar");
        dispatch_async(dispatch_get_main_queue(), ^{
            [tableView reloadData];
            WGScheduleSafeUIKitScan(0.02);
        });
        return;
    }

    // Selecting Russian/Ukrainian/English returns full control to Whitegram.
    WGSetCustomLanguageCode(nil);
    if (WGPickerOriginalSelect) {
        WGPickerOriginalSelect(self, _cmd, tableView, indexPath);
    }
}

static Class WGFindWhitegramLanguagePickerClass(void) {
    int count = objc_getClassList(NULL, 0);
    if (count <= 0) {
        return Nil;
    }

    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    if (!classes) {
        return Nil;
    }

    count = objc_getClassList(classes, count);
    Class result = Nil;
    NSString *suffix = @"WGLanguagePickerViewController";
    for (int index = 0; index < count; index++) {
        const char *rawName = class_getName(classes[index]);
        if (!rawName) {
            continue;
        }
        NSString *name = [NSString stringWithUTF8String:rawName];
        if ([name hasSuffix:suffix]) {
            result = classes[index];
            break;
        }
    }
    free(classes);
    return result;
}

static BOOL WGInstallWhitegramLanguagePickerHook(void) {
    if (WGPickerClass) {
        return YES;
    }

    Class cls = WGFindWhitegramLanguagePickerClass();
    if (!cls) {
        return NO;
    }

    SEL rowsSel = @selector(tableView:numberOfRowsInSection:);
    SEL cellSel = @selector(tableView:cellForRowAtIndexPath:);
    SEL selectSel = @selector(tableView:didSelectRowAtIndexPath:);
    Method rowsMethod = class_getInstanceMethod(cls, rowsSel);
    Method cellMethod = class_getInstanceMethod(cls, cellSel);
    Method selectMethod = class_getInstanceMethod(cls, selectSel);
    if (!rowsMethod || !cellMethod || !selectMethod) {
        return NO;
    }

    WGPickerOriginalRows = (WGPickerRowsIMP)method_getImplementation(rowsMethod);
    WGPickerOriginalCell = (WGPickerCellIMP)method_getImplementation(cellMethod);
    WGPickerOriginalSelect = (WGPickerSelectIMP)method_getImplementation(selectMethod);

    method_setImplementation(rowsMethod, (IMP)WGPickerRows);
    method_setImplementation(cellMethod, (IMP)WGPickerCell);
    method_setImplementation(selectMethod, (IMP)WGPickerDidSelect);
    WGPickerClass = cls;
    return YES;
}

static void WGInstallWhitegramLanguagePickerHookWithRetry(NSUInteger attempt) {
    if (WGInstallWhitegramLanguagePickerHook() || attempt >= 12) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WGInstallWhitegramLanguagePickerHookWithRetry(attempt + 1);
    });
}

#pragma mark - Entry point

__attribute__((constructor))
static void WGMultiLangEntryPoint(void) {
    @autoreleasepool {
        WGInstallAttributedStringHooks();
        WGInstallUIKitHooks();

        dispatch_async(dispatch_get_main_queue(), ^{
            WGInstallWhitegramLanguagePickerHookWithRetry(0);
            WGScheduleSafeUIKitScan(0.30);
        });
    }
}
