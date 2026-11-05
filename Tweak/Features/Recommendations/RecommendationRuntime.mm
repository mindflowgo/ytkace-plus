#import <objc/message.h>
#import "RecommendationRuntime.h"

// https://clang.llvm.org/docs/Block-ABI-Apple.html
struct YTRCBlockLayout {
    void *isa;
    int32_t flags;
    int32_t reserved;
    void *invoke;
    const uint8_t *descriptor;
};

NSString *YTRCBlockSignature(id block) {
    if (block == nil) return nil;
    const auto *layout = (__bridge const YTRCBlockLayout *)block;
    if (!(layout->flags & (1 << 30)) || layout->descriptor == nullptr) return nil;
    const uint8_t *entry = layout->descriptor + 2 * sizeof(uintptr_t);
    if (layout->flags & (1 << 25)) entry += 2 * sizeof(void *);
    const char *signature = *reinterpret_cast<const char *const *>(entry);
    return signature != nullptr ? [NSString stringWithUTF8String:signature] : nil;
}

static BOOL YTRCIsObject(const char *type) {
    return type != nullptr && type[0] == '@' && type[1] != '?';
}

static id YTRCObserve(YTRCDeliveryObserver observer, id response, NSNumber *auxiliary) {
    @try {
        return observer(response, auxiliary) ?: response;
    } @catch (__unused NSException *exception) {
        return response;
    }
}

id YTRCWrapDelivery(id block, YTRCDeliveryObserver observer, BOOL *wrapped) {
    if (wrapped != nullptr) *wrapped = NO;
    if (block == nil) return nil;
    const auto *layout = (__bridge const YTRCBlockLayout *)block;
    if (layout->flags & (1 << 23)) return block; // Do not copy a noescape callback.
    NSString *encoding = YTRCBlockSignature(block);
    if (encoding == nil) return block;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding.UTF8String];
    if (strcmp(signature.methodReturnType, "v") != 0 || signature.numberOfArguments < 2 ||
        strcmp([signature getArgumentTypeAtIndex:0], "@?") != 0 ||
        !YTRCIsObject([signature getArgumentTypeAtIndex:1])) return block;
    id result = nil;
    if (signature.numberOfArguments == 2) {
        void (^original)(id) = block;
        result = [^(id response) { original(YTRCObserve(observer, response, nil)); } copy];
    } else if (signature.numberOfArguments == 3) {
        const char *auxiliary = [signature getArgumentTypeAtIndex:2];
        if (YTRCIsObject(auxiliary)) {
            void (^original)(id, id) = block;
            result = [^(id response, id argument) {
                original(YTRCObserve(observer, response, nil), argument);
            } copy];
        } else if (strcmp(auxiliary, "^v") == 0) {
            void (^original)(id, void *) = block;
            result = [^(id response, void *argument) {
                original(YTRCObserve(observer, response, nil), argument);
            } copy];
        } else if (strcmp(auxiliary, "B") == 0) {
            void (^original)(id, bool) = block;
            result = [^(id response, bool flag) {
                original(YTRCObserve(observer, response, @(flag)), flag);
            } copy];
        }
    }
    if (wrapped != nullptr) *wrapped = result != nil;
    return result ?: block;
}

BOOL YTRCMethodMatches(Method method, const char *encoding) {
    if (method == nullptr) return NO;
    NSMethodSignature *actual = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    NSMethodSignature *expected = [NSMethodSignature signatureWithObjCTypes:encoding];
    if (actual.numberOfArguments != expected.numberOfArguments ||
        strcmp(actual.methodReturnType, expected.methodReturnType) != 0) return NO;
    for (NSUInteger index = 0; index < actual.numberOfArguments; index++) {
        if (strcmp([actual getArgumentTypeAtIndex:index], [expected getArgumentTypeAtIndex:index]) != 0) return NO;
    }
    return YES;
}

id YTRCObject(id receiver, NSString *name) {
    if (receiver == nil) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![receiver respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [receiver methodSignatureForSelector:selector];
    if (signature.numberOfArguments != 2 || !YTRCIsObject(signature.methodReturnType)) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(receiver, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

@implementation YTRCContinuationIndex {
    NSMutableDictionary<NSString *, NSString *> *_surfaces;
    NSMutableArray<NSString *> *_order;
}
- (instancetype)init {
    self = [super init];
    if (self) { _surfaces = [NSMutableDictionary dictionary]; _order = [NSMutableArray array]; }
    return self;
}
- (void)rememberToken:(id)token browseID:(id)browseID {
    if (![token isKindOfClass:NSString.class] || [token length] == 0 || [token length] > 8192 ||
        ![browseID isKindOfClass:NSString.class] || [browseID length] == 0) return;
    NSString *surface = [browseID isEqualToString:@"FEwhat_to_watch"] ? @"home" : @"other-browse";
    @synchronized (self) {
        NSString *existing = _surfaces[token];
        if (existing != nil && ![existing isEqualToString:surface]) surface = @"unknown-browse";
        if (existing == nil) [_order addObject:token];
        _surfaces[[token copy]] = surface;
        if (_order.count > 512) { [_surfaces removeObjectForKey:_order.firstObject]; [_order removeObjectAtIndex:0]; }
    }
}
- (NSString *)surfaceForBrowseID:(id)browseID token:(id)token {
    if ([browseID isKindOfClass:NSString.class] && [browseID length] != 0)
        return [browseID isEqualToString:@"FEwhat_to_watch"] ? @"home" : @"other-browse";
    if (![token isKindOfClass:NSString.class] || [token length] == 0) return @"unknown-browse";
    @synchronized (self) { return _surfaces[token] ?: @"unknown-browse"; }
}
- (void)reset { @synchronized (self) { [_surfaces removeAllObjects]; [_order removeAllObjects]; } }
@end
