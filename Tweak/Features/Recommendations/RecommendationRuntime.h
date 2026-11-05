#import <Foundation/Foundation.h>
#import <objc/runtime.h>

NS_ASSUME_NONNULL_BEGIN

// Production recommendation patch runtime. Same block-ABI approach as the
// exploratory probe, with its own symbols so the two dylibs stay independent.
typedef id _Nullable (^YTRCDeliveryObserver)(id _Nullable response, NSNumber * _Nullable auxiliaryArgument);

// https://clang.llvm.org/docs/Block-ABI-Apple.html
FOUNDATION_EXPORT NSString * _Nullable YTRCBlockSignature(id _Nullable block);
// Wraps void (^)(id) / void (^)(id, id) / void (^)(id, bool) callbacks. The
// observer's return value is delivered to the original callback synchronously;
// unsupported signatures and noescape blocks are passed through unchanged.
FOUNDATION_EXPORT id _Nullable YTRCWrapDelivery(id _Nullable block, YTRCDeliveryObserver observer, BOOL * _Nullable wrapped);
FOUNDATION_EXPORT id _Nullable YTRCObject(id _Nullable receiver, NSString *selector);
FOUNDATION_EXPORT BOOL YTRCMethodMatches(Method _Nullable method, const char *encoding);

// Continuation tokens stay in memory only. Unknown or conflicting lineage must
// not become Home; teaser prefetches and other browse traffic stay untouched.
@interface YTRCContinuationIndex : NSObject
- (void)rememberToken:(id _Nullable)token browseID:(id _Nullable)browseID;
- (NSString *)surfaceForBrowseID:(id _Nullable)browseID token:(id _Nullable)token;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
