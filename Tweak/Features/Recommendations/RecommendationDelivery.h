#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// One response delivery transforms or falls back exactly once. The claim
// methods return YES only for the first caller; all later callers must stand
// down so a late server reply can never double-deliver.
@interface YTRCDeliveryState : NSObject
- (instancetype)initWithRequestIdentifier:(NSString *)requestId NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@property(readonly, copy) NSString *requestId;
- (BOOL)claimReplacement;
- (BOOL)claimOriginal;
- (BOOL)claimInFlightDecrement;
- (BOOL)isResolved;
@end

// Content fingerprints of recently transformed payloads. The first wrapper
// layer to see a fetch transforms it; the same bytes surfacing at a second
// hooked layer (or an identical re-fetch, e.g. pull-to-refresh with unchanged
// content) within the per-call TTL is delivered unchanged. Thread-safe.
@interface YTRCRecentPayloads : NSObject
- (instancetype)initWithCapacity:(NSUInteger)capacity NS_DESIGNATED_INITIALIZER;
- (instancetype)init;
// YES when the fingerprint has no unexpired entry (caller transforms); NO when
// it is a recent duplicate. Each caller passes its category's TTL.
- (BOOL)shouldTransform:(NSString *)fingerprint ttl:(NSTimeInterval)ttl;
- (void)clear;
@end

NS_ASSUME_NONNULL_END
