#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL WGLocalizationEnabled(void);
FOUNDATION_EXPORT BOOL WGCurrentLanguageIsRTL(void);
FOUNDATION_EXPORT NSString * _Nullable WGCustomLanguageCode(void);
FOUNDATION_EXPORT void WGSetCustomLanguageCode(NSString * _Nullable languageCode);
FOUNDATION_EXPORT NSString *WGTranslateString(NSString *input);
FOUNDATION_EXPORT NSString *WGTranslateStringExact(NSString *input);
FOUNDATION_EXPORT NSAttributedString *WGTranslateAttributedString(NSAttributedString *input);
FOUNDATION_EXPORT NSAttributedString *WGTranslateAttributedStringExact(NSAttributedString *input);

NS_ASSUME_NONNULL_END
