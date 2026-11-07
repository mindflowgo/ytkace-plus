#import <os/lock.h>
#import "RecommendationDelivery.h"

@implementation YTRCDeliveryState {
    os_unfair_lock _lock;
    BOOL _resolved;
    BOOL _inFlightDecremented;
}
- (instancetype)initWithRequestIdentifier:(NSString *)requestId {
    self = [super init];
    if (self) { _lock = OS_UNFAIR_LOCK_INIT; _requestId = [requestId copy]; }
    return self;
}
- (BOOL)claimWithSelector:(BOOL (^)(void))claim {
    os_unfair_lock_lock(&_lock);
    BOOL won = NO;
    if (!_resolved) { won = claim(); _resolved = _resolved || won; }
    os_unfair_lock_unlock(&_lock);
    return won;
}
- (BOOL)claimReplacement { return [self claimWithSelector:^{ return YES; }]; }
- (BOOL)claimOriginal { return [self claimWithSelector:^{ return YES; }]; }
- (BOOL)claimInFlightDecrement {
    os_unfair_lock_lock(&_lock);
    BOOL won = !_inFlightDecremented;
    _inFlightDecremented = YES;
    os_unfair_lock_unlock(&_lock);
    return won;
}
- (BOOL)isResolved {
    os_unfair_lock_lock(&_lock);
    BOOL resolved = _resolved;
    os_unfair_lock_unlock(&_lock);
    return resolved;
}
@end

@implementation YTRCRecentPayloads {
    os_unfair_lock _lock;
    NSMutableDictionary<NSString *, NSDate *> *_expires; // fingerprint -> expiry
    NSMutableArray<NSString *> *_order;
    NSUInteger _capacity;
}
- (instancetype)initWithCapacity:(NSUInteger)capacity {
    self = [super init];
    if (self) {
        _lock = OS_UNFAIR_LOCK_INIT;
        _expires = [NSMutableDictionary dictionary];
        _order = [NSMutableArray array];
        _capacity = capacity > 0 ? capacity : 128;
    }
    return self;
}
- (instancetype)init { return [self initWithCapacity:128]; }
- (BOOL)shouldTransform:(NSString *)fingerprint ttl:(NSTimeInterval)ttl {
    if (fingerprint.length == 0) return NO;
    NSDate *now = [NSDate date];
    os_unfair_lock_lock(&_lock);
    NSDate *expiry = _expires[fingerprint];
    BOOL duplicate = expiry != nil && [now timeIntervalSinceDate:expiry] < 0;
    if (!duplicate) {
        if (expiry != nil) [_order removeObject:fingerprint];
        _expires[fingerprint] = [now dateByAddingTimeInterval:ttl > 0 ? ttl : 20.0];
        [_order addObject:fingerprint];
        while (_order.count > _capacity) {
            [_expires removeObjectForKey:_order.firstObject];
            [_order removeObjectAtIndex:0];
        }
    }
    os_unfair_lock_unlock(&_lock);
    return !duplicate;
}
- (void)clear {
    os_unfair_lock_lock(&_lock);
    [_expires removeAllObjects];
    [_order removeAllObjects];
    os_unfair_lock_unlock(&_lock);
}
@end
