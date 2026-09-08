#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

/* Adds the iKiraPlus Telegram handle under the Whitegram language menu subtitle. */

static IMP WGLanguageMenuPreviousFactory = NULL;

static id WGLanguageMenuFactory(id self, SEL _cmd, NSString *title, NSString *message, UIAlertControllerStyle style) {
    NSString *patchedMessage = message;
    if (style == UIAlertControllerStyleActionSheet &&
        [title isEqualToString:@"Languages • اللغات"] &&
        [message isEqualToString:@"Whitegram Features Language"]) {
        patchedMessage = @"Whitegram Features Language\nTelegram : @ikiraplus";
    }

    return ((id (*)(id, SEL, NSString *, NSString *, UIAlertControllerStyle))WGLanguageMenuPreviousFactory)(self, _cmd, title, patchedMessage, style);
}

__attribute__((constructor))
static void WGLanguageMenuBrandingEntry(void) {
    @autoreleasepool {
        Class meta = object_getClass(UIAlertController.class);
        Method method = class_getClassMethod(UIAlertController.class, @selector(alertControllerWithTitle:message:preferredStyle:));
        if (!method) return;
        IMP current = method_getImplementation(method);
        if (current == (IMP)WGLanguageMenuFactory) return;
        WGLanguageMenuPreviousFactory = current;
        method_setImplementation(method, (IMP)WGLanguageMenuFactory);
        (void)meta;
    }
}
