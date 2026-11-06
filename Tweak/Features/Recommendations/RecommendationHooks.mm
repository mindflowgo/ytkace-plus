// Production recommendation patch. Original YouTube response -> configured
// server -> validated replacement -> YouTube's normal consumer; original
// delivered on any failure. Boundaries verified by probe Sessions 3-5:
//   Home initial + continuations .. YTAppBrowseService makeRequest responseBlock
//   Watch initial ................. YTWatchService coordinator completion blocks
//   Watch continuations ........... YTAppWatchNextService layers (content deduped)
#import "RecommendationRuntime.h"
#import "RecommendationCodec.h"
#import "RecommendationClient.h"
#import "RecommendationDelivery.h"
#import "AITranscriptHook.h"
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <stdatomic.h>

static NSString *const EnabledKey = @"YTKACE.Recommendations.Enabled";
static NSString *const RecommendKey = @"YTKACE.Recommendations.RecommendEnabled";
static NSString *const SubsKey = @"YTKACE.Recommendations.SubsHistoryEnabled";
static NSString *const SearchKey = @"YTKACE.Recommendations.SearchEnabled";
static NSString *const DiagnosticsKey = @"YTKACE.Recommendations.Diagnostics";
static NSString *const MarkerFieldKey = @"YTKACE.Recommendations.MarkerField";
static NSString *const MaxInFlightKey = @"YTKACE.Recommendations.MaxInFlight";
static const void *WrappedKey = &WrappedKey;
static const void *ButtonKey = &ButtonKey;
static const void *MenuRowKey = &MenuRowKey;
static const void *CogAnchorKey = &CogAnchorKey;
static const void *CogConstraintsKey = &CogConstraintsKey;

enum {
    CounterRecommendDeliveries, CounterSubsDeliveries, CounterSearchDeliveries,
    CounterTransformsSent, CounterReplacementsDelivered, CounterFallbackDelivered,
    CounterSkippedDedupe, CounterSkippedMarker, CounterSkippedCap, CounterCount
};
static atomic_ullong Counters[CounterCount];
static atomic_llong InFlightDeliveries;
static void YTRCBump(int counter) { atomic_fetch_add(&Counters[counter], 1ULL); }
static unsigned long long YTRCCounter(int counter) { return atomic_load(&Counters[counter]); }

static BOOL YTRCEnabled(NSString *key) {
    return [NSUserDefaults.standardUserDefaults boolForKey:key];
}

// Three feed categories share the delivery pipeline; each has its own toggle:
//   recommend — YouTube-chosen lists: Home, category chips, watch page +
//               related list, other/unresolved browse
//   subs      — user-behaviour-owned lists: FEsubscriptions, FEhistory, teasers
//   search    — search results
// "Video stats" (play time / watch tracking) is a reserved future category.
static NSString *YTRCCategoryForSurface(NSString *surface) {
    if (![surface isKindOfClass:NSString.class] || surface.length == 0) return @"recommend";
    if ([surface isEqualToString:@"search"]) return @"search";
    if ([surface isEqualToString:@"FEsubscriptions"] ||
        [surface isEqualToString:@"FEhistory"] ||
        [surface isEqualToString:@"browse-teaser"]) return @"subs";
    return @"recommend"; // home, watch, FE*, channel pages, browse-unknown
}

static BOOL YTRCCategoryEnabled(NSString *surface) {
    if (!YTRCEnabled(EnabledKey)) return NO;
    NSString *category = YTRCCategoryForSurface(surface);
    if ([category isEqualToString:@"search"]) return YTRCEnabled(SearchKey);
    if ([category isEqualToString:@"subs"]) return YTRCEnabled(SubsKey);
    return YTRCEnabled(RecommendKey);
}

// Identical re-fetches (e.g. pull-to-refresh with unchanged content) and the
// same bytes surfacing at a second hooked layer skip the server within the
// TTL. Recommend + subs pages change rarely; search is user-driven.
static NSTimeInterval YTRCDedupeTTL(NSString *surface) {
    return [YTRCCategoryForSurface(surface) isEqualToString:@"search"] ? 20.0 : 300.0;
}

static NSUInteger YTRCMarkerField(void) {
    NSInteger field = [NSUserDefaults.standardUserDefaults integerForKey:MarkerFieldKey];
    return field > 0 ? (NSUInteger)field : 90001;
}

static NSUInteger YTRCMaxInFlight(void) {
    NSInteger value = [NSUserDefaults.standardUserDefaults integerForKey:MaxInFlightKey];
    return value > 0 ? (NSUInteger)value : 8;
}

// Diagnostics: bounded metadata ring, payloads never recorded.
static dispatch_queue_t YTRCLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("ytkace.recommendations.log", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static NSMutableArray<NSDictionary *> *LogEvents;

void YTRCLog(NSDictionary *event) {
    if (!YTRCEnabled(DiagnosticsKey)) return;
    NSMutableDictionary *record = [event mutableCopy];
    record[@"time"] = @([NSDate.date timeIntervalSince1970]);
    dispatch_async(YTRCLogQueue(), ^{
        if (LogEvents == nil) LogEvents = [NSMutableArray array];
        [LogEvents addObject:record];
        if (LogEvents.count > 200) [LogEvents removeObjectsInRange:NSMakeRange(0, LogEvents.count - 200)];
    });
}

static YTRCContinuationIndex *YTRCContinuations(void) {
    static YTRCContinuationIndex *index;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ index = [YTRCContinuationIndex new]; });
    return index;
}

// ---------- Delivery pipeline ----------

// The last delivered initial watch response's serialized bytes. The AI
// Overview ("Ask") suggestion tokens ride it (base64url protobuf `kta-…`
// strings embedding the video id and prompt text). Writes come from delivery
// threads; lock-guarded.
static id YTRCWatchPayloadLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static NSData *YTRCWatchPayloadData = nil;
static NSString *YTRCWatchPayloadVideoId = nil;

static void YTRCRememberWatchPayload(NSData *payload, NSString *videoId) {
    @synchronized (YTRCWatchPayloadLock()) {
        YTRCWatchPayloadData = payload;
        YTRCWatchPayloadVideoId = [videoId copy];
    }
}

NSData *YTRCCurrentWatchPayload(NSString **videoId) {
    @synchronized (YTRCWatchPayloadLock()) {
        if (videoId != nullptr) *videoId = [YTRCWatchPayloadVideoId copy];
        return YTRCWatchPayloadData;
    }
}

static NSString *YTRCActiveVideoId = nil;

NSString *YTRCCurrentVideoId(void) {
    return YTRCActiveVideoId;
}

@interface YTRCDeliveryContext : NSObject
@property(nonatomic, copy) NSString *requestId;
@property(nonatomic, copy) NSString *surface;      // home | watch
@property(nonatomic, copy) NSString *phase;        // initial | refresh | continuation
@property(nonatomic, copy, nullable) NSString *videoId;
@property(nonatomic, copy) NSString *responseType; // diagnostic only
@property(nonatomic, copy) NSString *hookClass;
@property(nonatomic, copy, nullable) NSDictionary *requestContext; // serialized request + flat fields
@property(nonatomic, assign) BOOL initialDelivery; // coordinator/watch-initial accounting
@property(nonatomic, assign) unsigned long long feedType; // tabbed-Home category identifier
@end

@implementation YTRCDeliveryContext
@end

static YTRCRecentPayloads *YTRCRecent(void) {
    static YTRCRecentPayloads *recent;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ recent = [[YTRCRecentPayloads alloc] initWithCapacity:256]; });
    return recent;
}

static dispatch_queue_t YTRCWorkQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("ytkace.recommendations.work", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// Serializes the response on the delivering thread, then either hands the
// delivery straight back (disabled, dedupe, marker, cap, codec failure) or
// posts the bytes to the server and delivers once on the main queue: the
// validated replacement, or the retained original on any failure.
// expectedClass is the admission gate; empty accepts whatever class the
// boundary delivers (for boundaries whose response type is not pinned yet).
// Replacements are parsed into the observed response's own class, so the
// delivered object always matches what the original callback expected.
static void YTRCProcessDelivery(YTRCDeliveryContext *context, id response,
                                NSString *expectedClass, dispatch_block_t deliverNow) {
    if (context == nil || response == nil) {
        deliverNow();
        return;
    }
    NSString *observedClass = NSStringFromClass([response class]);
    if (expectedClass.length != 0 && ![expectedClass isEqualToString:observedClass]) {
        // Wrong guess about this boundary: visible in diagnostics, original delivered.
        YTRCLog(@{@"event": @"delivery", @"requestId": context.requestId, @"surface": context.surface,
                  @"phase": context.phase, @"decision": @"class-mismatch",
                  @"expectedClass": expectedClass, @"observedClass": observedClass});
        deliverNow();
        return;
    }
    context.responseType = observedClass;
    NSString *category = YTRCCategoryForSurface(context.surface);
    YTRCBump([category isEqualToString:@"subs"] ? CounterSubsDeliveries
        : ([category isEqualToString:@"search"] ? CounterSearchDeliveries : CounterRecommendDeliveries));
    NSError *error = nil;
    NSData *payload = YTRCSerializeMessage(response, 16 * 1024 * 1024, &error);
    if (payload == nil || payload.length == 0) {
        YTRCLog(@{@"event": @"delivery", @"requestId": context.requestId, @"surface": context.surface,
                  @"phase": context.phase, @"decision": @"original-serialize-failed",
                  @"error": YTRCErrorString(error) ?: @"empty"});
        deliverNow();
        return;
    }
    if ([context.surface isEqualToString:@"watch"] && [context.phase isEqualToString:@"initial"])
        YTRCRememberWatchPayload(payload, context.videoId);
    NSString *fingerprint = YTRCSha256Prefix(payload);
    if (![YTRCRecent() shouldTransform:fingerprint ttl:YTRCDedupeTTL(context.surface)]) {
        YTRCBump(CounterSkippedDedupe);
        YTRCLog(@{@"event": @"delivery", @"requestId": context.requestId, @"surface": context.surface,
                  @"phase": context.phase, @"bytes": @(payload.length), @"decision": @"duplicate-passthrough"});
        deliverNow();
        return;
    }
    if (YTRCPayloadHasMarker(payload, YTRCMarkerField())) {
        // An upstream layer already server-replaced this payload.
        YTRCBump(CounterSkippedMarker);
        YTRCLog(@{@"event": @"delivery", @"requestId": context.requestId, @"surface": context.surface,
                  @"phase": context.phase, @"bytes": @(payload.length), @"decision": @"marker-passthrough"});
        deliverNow();
        return;
    }
    long long inFlight = atomic_load(&InFlightDeliveries);
    if (inFlight >= (long long)YTRCMaxInFlight()) {
        YTRCBump(CounterSkippedCap);
        YTRCLog(@{@"event": @"delivery", @"requestId": context.requestId, @"surface": context.surface,
                  @"phase": context.phase, @"bytes": @(payload.length), @"decision": @"in-flight-cap"});
        deliverNow();
        return;
    }
    atomic_fetch_add(&InFlightDeliveries, 1LL);
    YTRCBump(CounterTransformsSent);
    YTRCLog(@{@"event": @"transform-sent", @"requestId": context.requestId, @"surface": context.surface,
              @"phase": context.phase, @"bytes": @(payload.length), @"responseType": context.responseType,
              @"fingerprint": fingerprint,
              @"feedType": context.feedType != 0 ? @(context.feedType) : [NSNull null]});

    YTRCDeliveryState *state = [[YTRCDeliveryState alloc] initWithRequestIdentifier:context.requestId];
    dispatch_async(YTRCWorkQueue(), ^{
        YTRCRequestTransform(payload, context.surface, context.phase, context.videoId,
                             context.requestContext, context.responseType,
            ^(YTRCTransformReply *reply, NSError *transformError) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    atomic_fetch_sub(&InFlightDeliveries, 1LL);
                    BOOL wantReplacement = reply != nil && [reply.action isEqualToString:YTRCActionReplace()];
                    id replacement = nil;
                    NSError *failure = transformError;
                    if (wantReplacement) {
                        NSError *parseError = nil;
                        replacement = YTRCParseMessage(reply.payload, [response class], &parseError);
                        if (replacement == nil) {
                            wantReplacement = NO;
                            failure = parseError;
                        }
                    }
                    BOOL markerSeen = wantReplacement && YTRCPayloadHasMarker(reply.payload, YTRCMarkerField());
                    if (wantReplacement && [state claimReplacement]) {
                        YTRCBump(CounterReplacementsDelivered);
                        YTRCLog(@{@"event": @"delivered", @"requestId": context.requestId,
                                  @"outcome": @"replacement", @"markerSeen": @(markerSeen),
                                  @"bytes": @(reply.payload.length)});
                        deliverNow();
                        return;
                    }
                    if ([state claimOriginal]) {
                        // Server failure, protocol violation, parse failure, or an
                        // explicit passthrough reply: YouTube gets the original bytes.
                        YTRCBump(CounterFallbackDelivered);
                        YTRCLog(@{@"event": @"delivered", @"requestId": context.requestId,
                                  @"outcome": @"original",
                                  @"reason": wantReplacement ? @"late-delivery" : (YTRCErrorString(failure) ?: @"passthrough")});
                        deliverNow();
                        return;
                    }
                    // Terminal already reached on another queue: stand down.
                });
            });
    });
}

// ---------- Callback wrapping ----------

static NSString *YTRCPhase(NSString *continuation, BOOL refresh) {
    return continuation.length != 0 ? @"continuation" : (refresh ? @"refresh" : @"initial");
}

// Wraps a void (^)(id[, id|bool]) callback with the transform pipeline.
// The response and its auxiliary argument pass through verbatim on the
// immediate path; the async path delivers on the main queue.
static id YTRCWrapForTransform(id block, NSString *surface, NSString *expectedClass,
                               YTRCDeliveryContext *(^contextProvider)(void), BOOL *wrapped) {
    if (wrapped != nullptr) *wrapped = NO;
    if (block == nil || !YTRCCategoryEnabled(surface)) return block;
    if (objc_getAssociatedObject(block, WrappedKey) != nil) return block;
    NSString *encoding = YTRCBlockSignature(block);
    if (encoding == nil) {
        YTRCLog(@{@"event": @"wrap", @"expectedClass": expectedClass,
                  @"outcome": @"signature-unavailable"});
        return block;
    }
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding.UTF8String];
    if (strcmp(signature.methodReturnType, "v") != 0 || signature.numberOfArguments < 2 ||
        strcmp([signature getArgumentTypeAtIndex:0], "@?") != 0) {
        YTRCLog(@{@"event": @"wrap", @"expectedClass": expectedClass,
                  @"outcome": @"unsupported-signature", @"signature": encoding});
        return block;
    }
    const char *arg1 = [signature getArgumentTypeAtIndex:1];
    if (arg1[0] != '@' || (arg1[0] == '@' && arg1[1] == '?')) {
        YTRCLog(@{@"event": @"wrap", @"expectedClass": expectedClass,
                  @"outcome": @"unsupported-signature", @"signature": encoding});
        return block;
    }

    id result = nil;
    if (signature.numberOfArguments == 2) {
        void (^original)(id) = block;
        result = [^(id response) {
            YTRCDeliveryContext *context = contextProvider();
            YTRCProcessDelivery(context, response, expectedClass, ^{ original(response); });
        } copy];
    } else if (signature.numberOfArguments == 3) {
        const char *auxiliary = [signature getArgumentTypeAtIndex:2];
        if (auxiliary[0] == '@' && auxiliary[1] != '?') {
            void (^original)(id, id) = block;
            result = [^(id response, id argument) {
                YTRCDeliveryContext *context = contextProvider();
                YTRCProcessDelivery(context, response, expectedClass, ^{ original(response, argument); });
            } copy];
        } else if (strcmp(auxiliary, "B") == 0) {
            void (^original)(id, bool) = block;
            result = [^(id response, bool flag) {
                YTRCDeliveryContext *context = contextProvider();
                YTRCProcessDelivery(context, response, expectedClass, ^{ original(response, flag); });
            } copy];
        } else if (strcmp(auxiliary, "^v") == 0) {
            void (^original)(id, void *) = block;
            result = [^(id response, void *argument) {
                YTRCDeliveryContext *context = contextProvider();
                YTRCProcessDelivery(context, response, expectedClass, ^{ original(response, argument); });
            } copy];
        }
    }
    if (result == nil) {
        YTRCLog(@{@"event": @"wrap", @"expectedClass": expectedClass,
                  @"outcome": @"unsupported-signature", @"signature": encoding});
        return block;
    }
    if (wrapped != nullptr) *wrapped = YES;
    objc_setAssociatedObject(result, WrappedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return result;
}

// ---------- YTKACE settings integration ----------
// The released YTKACE renders its native settings section by committing
// YTSettingsSectionItems through YTSettingsViewController's
// setSectionItems:forCategory:... . We splice a "RECOMMENDATIONS SERVER"
// section (URL + Auth-Token inputs) into that commit, before its inert
// footer. No YTKACE source is touched; the hook is ABI-checked and fails
// closed. The rows read/write the same preference keys as the recommendations
// settings panel.

static IMP OriginalSettingsItems;
static const NSUInteger YTRCYTKACECategory = 0x796b6361; // Must match released YTKACE's native settings category.
static NSString * const YTRCHeadingIdentifier = @"YTRCRecHeadingItem";
static NSString * const YTRCURLItemIdentifier = @"YTRCRecServerURLItem";
static NSString * const YTRCTokenItemIdentifier = @"YTRCRecServerTokenItem";

static UIViewController *YTRCPresentingController(id cell) {
    UIResponder *responder = cell;
    while (responder != nil && ![responder isKindOfClass:UIViewController.class])
        responder = responder.nextResponder;
    if (responder != nil) return (UIViewController *)responder;
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        root = ((UIWindowScene *)scene).windows.firstObject.rootViewController ?: root;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (root == nil) root = UIApplication.sharedApplication.windows.firstObject.rootViewController;
#pragma clang diagnostic pop
    while (root.presentedViewController != nil) root = root.presentedViewController;
    return root;
}

static void YTRCMakeItemInert(id item) {
    if (item == nil) return;
    for (NSString *name in @[@"setInkEnabled:", @"setEnabled:", @"setSettingEnabled:"]) {
        SEL selector = NSSelectorFromString(name);
        if ([item respondsToSelector:selector]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(item, selector, NO);
        }
    }
}

// A section heading row in YTKACE's style: inert item whose title description
// carries the caption.
static id YTRCSettingsHeadingItem(NSString *heading) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL described = NSSelectorFromString(
        @"itemWithTitle:titleDescription:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (itemClass == Nil || ![itemClass respondsToSelector:described]) return nil;
    id item = ((id (*)(id, SEL, id, id, id, id, id))objc_msgSend)(
        itemClass, described, nil, heading, YTRCHeadingIdentifier, nil, nil);
    YTRCMakeItemInert(item);
    return item;
}

// An input row: detail text shows the stored value; tapping opens an alert
// with a text field and saves straight to the shared preference key.
static id YTRCSettingsValueItem(NSString *title, NSString *identifier,
                                NSString *preferenceKey, BOOL secureEntry) {
    Class itemClass = NSClassFromString(@"YTSettingsSectionItem");
    SEL plain = NSSelectorFromString(
        @"itemWithTitle:accessibilityIdentifier:detailTextBlock:selectBlock:");
    if (itemClass == Nil || ![itemClass respondsToSelector:plain]) return nil;
    NSString *(^detail)(void) = ^NSString *{
        id stored = [NSUserDefaults.standardUserDefaults objectForKey:preferenceKey];
        NSString *value = [stored isKindOfClass:NSString.class] ? stored : @"";
        if (secureEntry) return value.length != 0 ? @"••••••••" : @"Not set";
        return value.length != 0 ? value : @"Not set";
    };
    BOOL (^select)(id, NSUInteger) = ^BOOL(id cell, __unused NSUInteger index) {
        // This runs inside YouTube's process; a presentation failure must fail
        // soft instead of taking the app down.
        @try {
            UIViewController *presenter = YTRCPresentingController(cell);
            if (presenter == nil) return NO;
            id stored = [NSUserDefaults.standardUserDefaults objectForKey:preferenceKey];
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                message:secureEntry ? @"Sent as an Authorization: Bearer header when set."
                                    : @"Base URL only (no path). The patch appends /yt-browse and /yt-next."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
                field.text = [stored isKindOfClass:NSString.class] ? stored : @"";
                field.placeholder = secureEntry ? @"token" : @"https://server.example";
                field.autocorrectionType = UITextAutocorrectionTypeNo;
                field.autocapitalizationType = UITextAutocapitalizationTypeNone;
                field.clearButtonMode = UITextFieldViewModeWhileEditing;
                field.secureTextEntry = secureEntry;
            }];
            [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
            [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    NSString *value = alert.textFields.firstObject.text ?: @"";
                    value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                    [NSUserDefaults.standardUserDefaults setObject:value forKey:preferenceKey];
                    if (!secureEntry) [YTRCRecent() clear];
                    YTRCLog(@{@"event": @"setting", @"key": preferenceKey,
                              @"configured": @(value.length != 0)});
                }]];
            [presenter presentViewController:alert animated:YES completion:nil];
            return YES; // Reloads the section, so the detail text re-reads the value.
        } @catch (NSException *exception) {
            YTRCLog(@{@"event": @"settings-integration", @"outcome": @"select-exception",
                      @"name": exception.name});
            return NO;
        }
    };
    return ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(
        itemClass, plain, title, identifier, [detail copy], [select copy]);
}

static BOOL YTRCItemHasIdentifier(id item, NSString *wanted) {
    if (![item respondsToSelector:@selector(accessibilityIdentifier)]) return NO;
    @try {
        return [((id (*)(id, SEL))objc_msgSend)(item, @selector(accessibilityIdentifier)) isEqualToString:wanted];
    } @catch (NSException *exception) {
        return NO;
    }
}

static NSArray *YTRCExtendSettingsItems(NSArray *items) {
    if (![items isKindOfClass:NSArray.class]) return items;
    for (id item in items) {
        if (YTRCItemHasIdentifier(item, YTRCHeadingIdentifier)) return items; // already extended
    }
    id heading = YTRCSettingsHeadingItem(@"RECOMMENDATIONS SERVER");
    id urlRow = YTRCSettingsValueItem(@"URL", YTRCURLItemIdentifier,
                                      @"YTKACE.Recommendations.ServerURL", NO);
    id tokenRow = YTRCSettingsValueItem(@"Auth-Token", YTRCTokenItemIdentifier,
                                        @"YTKACE.Recommendations.ServerToken", YES);
    NSMutableArray *additions = [NSMutableArray array];
    for (id item in @[heading, urlRow, tokenRow]) {
        if (item != nil) [additions addObject:item];
    }
    if (additions.count != 3) return items; // YTSettingsSectionItem unavailable: fail closed.
    NSMutableArray *merged = [items mutableCopy];
    NSUInteger insertion = merged.count;
    if (merged.count > 0 && YTRCItemHasIdentifier(merged.lastObject, @"YTKACEInertItem")) {
        insertion = merged.count - 1; // Keep YTKACE's inert footer last.
    }
    [merged insertObjects:additions
                atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(insertion, additions.count)]];
    return merged;
}

static void YTRCSettingsItems(id receiver, SEL selector, id items, unsigned long long category,
                              id title, id icon, id description, BOOL headerHidden) {
    if (category == YTRCYTKACECategory) {
        @try {
            items = YTRCExtendSettingsItems(items);
        } @catch (NSException *exception) {
            YTRCLog(@{@"event": @"settings-integration", @"outcome": @"exception",
                      @"name": exception.name});
        }
    }
    ((void (*)(id, SEL, id, unsigned long long, id, id, id, BOOL))OriginalSettingsItems)(
        receiver, selector, items, category, title, icon, description, headerHidden);
}

// ---------- Active video tracking ----------
// The watch-page menu's Save action posts the currently playing video id.
// Captured at every playback activation and watch-page fetch (both verified
// boundaries), written from any thread, read on the main thread only.
static void YTRCSetActiveVideoId(NSString *videoId) {
    if (videoId.length == 0) return;
    void (^store)(void) = ^{ YTRCActiveVideoId = [videoId copy]; };
    if ([NSThread isMainThread]) store();
    else dispatch_async(dispatch_get_main_queue(), store);
}

// ---------- Transcript gathering (Save flow) ----------
// Captions are fetched the way the released YTKACE does it, which is proven
// on this exact app build: the player's active video exposes its available
// caption tracks, each carrying a signed baseUrl; appending fmt=json3 turns
// it into a plain JSON transcript endpoint that needs no additional auth (the
// URL's signature is the credential). The in-app YTTranscriptService path was
// abandoned: it silently stalls without full account/attestation plumbing
// (observed as status=timeout on device). This path also does not depend on
// the recommendation toggles, since it never reads the intercepted responses.

// Weak references captured at every playback activation: the player view
// controller and the activated video object. Save probes them on demand.
static __weak id YTRCPlayerObject = nil;
static __weak id YTRCActiveVideoObject = nil;
static void YTRCSetActiveVideo(id player, id video) {
    if (player != nil) YTRCPlayerObject = player;
    if (video != nil) YTRCActiveVideoObject = video;
}

// Safe selector probe: returns nil unless the receiver responds (receiver may
// be a JSON dictionary or any object, so never rely on class checks).
static id YTRCTranscriptProbe(id object, NSArray<NSString *> *names) {
    if (object == nil) return nil;
    for (NSString *name in names) {
        SEL selector = NSSelectorFromString(name);
        if (![object respondsToSelector:selector]) continue;
        @try {
            id value = ((id (*)(id, SEL))objc_msgSend)(object, selector);
            if (value != nil) return value;
        } @catch (NSException *exception) {
        }
    }
    return nil;
}

static NSArray *YTRCActiveCaptionTracks(void) {
    id video = YTRCActiveVideoObject ?: YTRCTranscriptProbe(YTRCPlayerObject, @[@"activeVideo"]);
    id tracks = YTRCTranscriptProbe(video, @[@"availableCaptionTracks"]);
    if (![tracks isKindOfClass:NSArray.class] || [tracks count] == 0)
        tracks = YTRCTranscriptProbe(YTRCPlayerObject, @[@"availableCaptionTracks"]);
    return [tracks isKindOfClass:NSArray.class] && [tracks count] != 0 ? tracks : nil;
}

// Track URL: baseUrl/baseURL/URL (NSURL or string), with fmt=json3 replacing
// any existing fmt parameter so the response is the JSON transcript format.
static NSURL *YTRCCaptionTrackJSONURL(id track) {
    id value = YTRCTranscriptProbe(track, @[@"baseUrl", @"baseURL", @"URL", @"url"]);
    NSURL *url = [value isKindOfClass:NSURL.class] ? value
        : ([value isKindOfClass:NSString.class] ? [NSURL URLWithString:value] : nil);
    if (url == nil) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (components == nil) return url;
    NSMutableArray<NSURLQueryItem *> *items = [NSMutableArray array];
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"fmt"]) continue;
        [items addObject:item];
    }
    [items addObject:[NSURLQueryItem queryItemWithName:@"fmt" value:@"json3"]];
    components.queryItems = items;
    return components.URL ?: url;
}

// Transcript presence cache: fetched json3 bytes per video. Save checks here
// first and only fetches when the transcript is genuinely missing; repeated
// saves of the same video post instantly.
static NSData *YTRCTranscriptBytesCache = nil;
static NSString *YTRCTranscriptBytesVideoId = nil;

// Fetches the caption transcript for the active video. `completion` (main
// thread, exactly once) carries the json3 bytes or nil, plus a short status
// string forwarded to the server with the save (visible in the server log).
static void YTRCFetchTranscript(NSString *videoId, void (^completion)(NSData *, NSString *)) {
    __block BOOL finished = NO;
    void (^done)(NSData *, NSString *) = ^(NSData *bytes, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            completion(bytes, status);
        });
    };
    if (videoId.length != 0 && [videoId isEqualToString:YTRCTranscriptBytesVideoId] &&
        YTRCTranscriptBytesCache.length != 0) {
        YTRCLog(@{@"event": @"transcript", @"outcome": @"cached"});
        done(YTRCTranscriptBytesCache, @"cached");
        return;
    }
    NSArray *tracks = YTRCActiveCaptionTracks();
    if (tracks == nil) {
        YTRCLog(@{@"event": @"transcript", @"outcome": @"no-caption-tracks"});
        done(nil, @"no-caption-tracks");
        return;
    }
    NSURL *url = YTRCCaptionTrackJSONURL(tracks.firstObject);
    if (url == nil) {
        YTRCLog(@{@"event": @"transcript", @"outcome": @"no-caption-url"});
        done(nil, @"no-caption-url");
        return;
    }
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 10.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:nil delegateQueue:[NSOperationQueue new]];
    [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        [session finishTasksAndInvalidate];
        if (error != nil) {
            YTRCLog(@{@"event": @"transcript", @"outcome": @"fetch-failed",
                      @"error": error.localizedDescription});
            done(nil, [@"fetch-failed:" stringByAppendingString:error.localizedDescription ?: @"unknown"]);
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode != 200 || data.length == 0) {
            YTRCLog(@{@"event": @"transcript", @"outcome": @"fetch-failed",
                      @"status": @(http.statusCode)});
            done(nil, [NSString stringWithFormat:@"fetch-failed:HTTP %ld", (long)http.statusCode]);
            return;
        }
        YTRCTranscriptBytesVideoId = [videoId copy];
        YTRCTranscriptBytesCache = data;
        YTRCLog(@{@"event": @"transcript", @"outcome": @"fetched", @"bytes": @(data.length)});
        done(data, @"fetched");
    }] resume];
}

// AI Overview and Gemini Prompting implementation is modularized in AITranscriptHook.{h,mm}

// ---------- Playback observation (client-side, observation-only) ----------
// YTPlayerViewController playback boundaries verified in the 21.33.6 class
// dump. These hooks only report; they never modify playback. Events go to the
// server's /yt-playback endpoint and are logged alongside fetch events, which
// removes the need for fetch-based start/stop inference.

static IMP OriginalPlaybackActivate;
static IMP OriginalPlaybackFinish;
static IMP OriginalPlaybackPause;

// Video ids reach us in several wrapper shapes; probe defensively.
static NSString *YTRCVideoIDFromObject(id object) {
    if (object == nil) return nil;
    for (NSString *name in @[@"videoId", @"videoID"]) {
        id value = YTRCObject(object, name);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] == 11) return value;
    }
    for (NSString *wrapper in @[@"contentVideo", @"singleVideo", @"video"]) {
        id nested = YTRCObject(object, wrapper);
        if (nested != nil) {
            NSString *found = YTRCVideoIDFromObject(nested);
            if (found.length != 0) return found;
        }
    }
    return nil;
}

static BOOL YTRCBoolProperty(id object, NSString *name) {
    if (object == nil || ![object respondsToSelector:NSSelectorFromString(name)]) return NO;
    NSMethodSignature *signature = [object methodSignatureForSelector:NSSelectorFromString(name)];
    if (signature.numberOfArguments != 2 || strcmp(signature.methodReturnType, "B") != 0) return NO;
    @try {
        return ((BOOL (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
    } @catch (NSException *exception) {
        return NO;
    }
}

static void YTRCPlaybackActivate(id receiver, SEL selector, id controller, id video, id playbackData) {
    // Id + object capture runs ungated: the menu's Save works regardless of
    // the recommendation toggles.
    NSString *videoId = YTRCVideoIDFromObject(playbackData) ?: YTRCVideoIDFromObject(video);
    YTRCSetActiveVideoId(videoId);
    YTRCSetActiveVideo(receiver, video);
    if (YTRCEnabled(EnabledKey)) {
        YTRCSendPlaybackEvent(@"activate", videoId, @{
            @"ad": @(YTRCBoolProperty(receiver, @"isPlayingAd")),
            @"videoClass": NSStringFromClass([video class]) ?: @"nil",
            @"dataClass": NSStringFromClass([playbackData class]) ?: @"nil"});
        YTRCLog(@{@"event": @"playback", @"kind": @"activate", @"videoId": videoId ?: @"unknown"});
    }
    ((void (*)(id, SEL, id, id, id))OriginalPlaybackActivate)(receiver, selector, controller, video, playbackData);
}

static void YTRCPlaybackFinish(id receiver, SEL selector, id controller) {
    if (YTRCEnabled(EnabledKey)) {
        YTRCSendPlaybackEvent(@"finish", nil, @{@"controllerClass": NSStringFromClass([controller class]) ?: @"nil"});
    }
    ((void (*)(id, SEL, id))OriginalPlaybackFinish)(receiver, selector, controller);
}

static void YTRCPlaybackPause(id receiver, SEL selector, int reason) {
    if (YTRCEnabled(EnabledKey)) {
        YTRCSendPlaybackEvent(@"pause", nil, @{@"reason": @(reason)});
    }
    ((void (*)(id, SEL, int))OriginalPlaybackPause)(receiver, selector, reason);
}

// Shorts feed: the vertical reel player fetches batches of shorts through the
// watch-sequence service (equivalent of /reel/reel_watch_sequence). Response
// type is not pinned, so the class gate is open and replacements parse into
// the observed class.
static IMP OriginalReelSequence;
static IMP OriginalReelSequenceRetry;

static void YTRCReelSequence(id receiver, SEL selector, id request, id responseBlock, id errorBlock) {
    id wrapped = responseBlock;
    if (YTRCCategoryEnabled(@"shorts")) {
        id continuation = YTRCObject(request, @"continuation");
        NSString *phase = YTRCPhase([continuation isKindOfClass:NSString.class] ? continuation : @"", NO);
        NSDictionary *requestContext = YTRCCaptureRequestContext(request);
        YTRCDeliveryContext *(^provider)(void) = ^{
            YTRCDeliveryContext *context = [YTRCDeliveryContext new];
            context.requestId = NSUUID.UUID.UUIDString;
            context.surface = @"shorts";
            context.phase = phase;
            context.hookClass = NSStringFromClass([receiver class]);
            context.requestContext = requestContext;
            return context;
        };
        wrapped = YTRCWrapForTransform(responseBlock, @"shorts", @"", provider, nullptr);
    }
    ((void (*)(id, SEL, id, id, id))OriginalReelSequence)(receiver, selector, request, wrapped, errorBlock);
}

static void YTRCReelSequenceRetry(id receiver, SEL selector, id request, BOOL retryEnabled,
                                  id responseBlock, id errorBlock) {
    id wrapped = responseBlock;
    if (YTRCCategoryEnabled(@"shorts")) {
        id continuation = YTRCObject(request, @"continuation");
        NSString *phase = YTRCPhase([continuation isKindOfClass:NSString.class] ? continuation : @"", NO);
        NSDictionary *requestContext = YTRCCaptureRequestContext(request);
        YTRCDeliveryContext *(^provider)(void) = ^{
            YTRCDeliveryContext *context = [YTRCDeliveryContext new];
            context.requestId = NSUUID.UUID.UUIDString;
            context.surface = @"shorts";
            context.phase = phase;
            context.hookClass = NSStringFromClass([receiver class]);
            context.requestContext = requestContext;
            return context;
        };
        wrapped = YTRCWrapForTransform(responseBlock, @"shorts", @"", provider, nullptr);
    }
    ((void (*)(id, SEL, id, BOOL, id, id))OriginalReelSequenceRetry)(
        receiver, selector, request, retryEnabled, wrapped, errorBlock);
}

// ---------- Player-controls launcher (interface; implementation at file bottom) ----------
// The launcher is a semi-transparent button inside the main player's controls
// overlay (the forward/backward/fullscreen chrome that appears when the video
// is tapped), placed to the LEFT of the fullscreen control. Tapping it expands
// the {Save | Save w/ AI | Settings} menu upward. It exists nowhere else.

@interface YTRCLauncher : NSObject
+ (void)overlay:(UIView *)overlay;      // create/refresh the button in a controls overlay (layout hook)
+ (void)setVisible:(BOOL)visible;       // sync with controls visibility (visibility hooks)
+ (void)toggle:(UIButton *)sender;
+ (void)show:(UIButton *)sender;
+ (void)showAiResult:(NSString *)text fromButton:(UIButton *)button;
+ (void)showAiGuidance:(NSString *)status fromButton:(UIButton *)button;
+ (void)rowTapped:(UIButton *)row;
+ (void)backdropTapped;
@end

static void YTRCMenuDismiss(void);

// Observation wrapper for the InnerTube continuation callbacks whose block
// shapes are multi-argument and therefore not transformable. The AI Overview
// panel (sparkle button on the watch page) fetches through exactly these:
//   (NSArray *, NSUInteger, id)             v32@?0@"NSArray"8Q16@24
//   (NSArray *, NSUInteger, id, NSData *)   v40@?0@"NSArray"8Q16@24@"NSData"32
// Records item classes + capped payloads so the AI request/response shape can
// be inspected; the app's delivery is untouched.
static id YTRCCaptureArrayCallback(id block, NSString *tag) {
    if (block == nil) return block;
    NSString *encoding = YTRCBlockSignature(block);
    if (encoding.length == 0) return block;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding.UTF8String];
    if (strcmp(signature.methodReturnType, "v") != 0) return block;
    NSUInteger count = signature.numberOfArguments;
    if (count != 4 && count != 5) return block;
    if ([signature getArgumentTypeAtIndex:1][0] != '@' || strcmp([signature getArgumentTypeAtIndex:2], "Q") != 0 ||
        [signature getArgumentTypeAtIndex:3][0] != '@') return block;
    void (^capture)(NSArray *) = ^(NSArray *items) {
        if (![items isKindOfClass:NSArray.class]) return;
        NSMutableArray<NSDictionary *> *summary = [NSMutableArray array];
        NSUInteger index = 0;
        for (id item in items) {
            if (index++ >= 8) break;
            NSError *error = nil;
            NSData *bytes = YTRCSerializeMessage(item, 512 * 1024, &error);
            if (bytes.length == 0) continue;
            YTAICollectCaptureItem(bytes);
            NSData *capped = bytes.length > 16384 ? [bytes subdataWithRange:NSMakeRange(0, 16384)] : bytes;
            [summary addObject:@{@"class": NSStringFromClass([item class]) ?: @"?",
                                 @"bytes": @(bytes.length),
                                 @"payload": [capped base64EncodedStringWithOptions:0]}];
        }
        YTRCLog(@{@"event": @"continuation-capture", @"tag": tag, @"items": summary});
    };
    if (count == 4) {
        void (^original)(NSArray *, NSUInteger, id) = block;
        return [^(NSArray *items, NSUInteger itemIndex, id argument) {
            capture(items);
            original(items, itemIndex, argument);
        } copy];
    }
    void (^original)(NSArray *, NSUInteger, id, NSData *) = block;
    return [^(NSArray *items, NSUInteger itemIndex, id argument, NSData *data) {
        if (data.length != 0)
            YTRCLog(@{@"event": @"continuation-capture", @"tag": tag, @"dataBytes": @(data.length),
                      @"dataPrefix": [[data base64EncodedStringWithOptions:0] substringToIndex:
                          MIN((NSUInteger)160, [data base64EncodedStringWithOptions:0].length)]});
        capture(items);
        original(items, itemIndex, argument, data);
    } copy];
}

// ---------- Hooks ----------

static IMP OriginalBrowse;
static IMP OriginalBrowseID;
static IMP OriginalBrowseCache;
static IMP OriginalFeedContinuation;
static IMP OriginalTeaserContinuation;
static IMP OriginalTeaserContinuationShort;
static IMP OriginalAppSearch;
static IMP OriginalSearchImpl;
static IMP OriginalWatchCompletion;
static IMP OriginalWatchValue;
static IMP OriginalAppWatchShort;
static IMP OriginalAppWatchTimeout;
static IMP OriginalAppWatchFallback;
static IMP OriginalImplWatchShort;
static IMP OriginalImplWatchTimeout;
static IMP OriginalCompositeWatch;
static IMP OriginalPanelStreamingRequest;
static IMP OriginalPanelCancel;
static IMP OriginalAssistantRequest;
static IMP OriginalAssistantRequestTimeout;

// ---------- AI panel service trace (observation-only) ----------
// YTStreamingPanelServiceImpl is the concrete service behind the app-scoped
// proxy for AI panel continuations. Its handlers firing (or not) and any
// cancellation distinguishes dispatch failure from lost response forwarding.
static id YTRCPanelCaptureHandler(id block, NSString *kind);

static id YTRCPanelStreamingRequest(id receiver, SEL selector, id request, BOOL refresh,
                                    double timeout, int engagementType,
                                    id valueHandler, id completionHandler) {
    @try {
        NSError *error = nil;
        NSData *bytes = YTRCSerializeMessage(request, 256 * 1024, &error);
        BOOL hasToken = bytes.length != 0 &&
            [bytes rangeOfData:[@"kta-" dataUsingEncoding:NSUTF8StringEncoding]
                       options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
        YTRCLog(@{@"event": @"panel-request",
                  @"requestClass": NSStringFromClass([request class]) ?: @"?",
                  @"bytes": @(bytes.length),
                  @"hasToken": @(hasToken),
                  @"engagementType": @(engagementType),
                  @"refresh": @(refresh),
                  @"timeout": @(timeout)});
    } @catch (NSException *exception) {
    }
    id wrappedValue = YTRCPanelCaptureHandler(valueHandler, @"value");
    id wrappedCompletion = YTRCPanelCaptureHandler(completionHandler, @"completion");
    return ((id (*)(id, SEL, id, BOOL, double, int, id, id))OriginalPanelStreamingRequest)(
        receiver, selector, request, refresh, timeout, engagementType, wrappedValue, wrappedCompletion);
}

static void YTRCPanelCancel(id receiver, SEL selector, id token) {
    YTRCLog(@{@"event": @"panel-cancel",
              @"tokenPrefix": [token isKindOfClass:NSString.class]
                  ? [(NSString *)token substringToIndex:MIN((NSUInteger)48, [(NSString *)token length])]
                  : @"(nil)"});
    ((void (*)(id, SEL, id))OriginalPanelCancel)(receiver, selector, token);
}

// ---------- YouTube Assistant (AI) capture (observation-only) ----------
// The AI/"Ask" surface is server-gated, so instead of hardcoding a UI path
// this records the request/response stream the first time the feature is used
// manually. That reveals the exact request shape (and its query field), and
// stashes the live, account-configured YTAssistantServiceImpl instance for
// later replay. The app's own traffic is untouched.
static __weak id YTRCAssistantServiceInstance = nil;
static NSData *YTRCLastAssistantRequestBytes = nil;
static NSData *YTRCLastAssistantResponseBytes = nil;

static id YTRCPanelCaptureHandler(id block, NSString *kind) {
    if (block == nil) return nil;
    NSString *encoding = YTRCBlockSignature(block);
    if (encoding.length == 0) return block;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding.UTF8String];
    if (strcmp(signature.methodReturnType, "v") != 0 || signature.numberOfArguments < 2 ||
        strcmp([signature getArgumentTypeAtIndex:0], "@?") != 0) return block;
    void (^logFire)(id) = ^(id argument) {
        NSError *error = nil;
        NSData *bytes = argument != nil ? YTRCSerializeMessage(argument, 512 * 1024, &error) : nil;
        if (bytes.length != 0) {
            YTAICollectCaptureItem(bytes);
        }
        YTRCLog(@{@"event": @"panel-handler", @"kind": kind,
                  @"argClass": argument != nil ? (NSStringFromClass([argument class]) ?: @"?") : @"(nil)",
                  @"bytes": @(bytes.length)});
    };
    if (signature.numberOfArguments == 2) {
        void (^original)(id) = block;
        return [^(id argument) { logFire(argument); original(argument); } copy];
    }
    if (signature.numberOfArguments == 3) {
        const char *auxiliary = [signature getArgumentTypeAtIndex:2];
        if (auxiliary[0] == '@' && auxiliary[1] != '?') {
            void (^original)(id, id) = block;
            return [^(id argument, id extra) {
                logFire(argument);
                if (extra != nil) logFire(extra);
                original(argument, extra);
            } copy];
        }
        if (strcmp(auxiliary, "B") == 0) {
            void (^original)(id, bool) = block;
            return [^(id argument, bool flag) { logFire(argument); original(argument, flag); } copy];
        }
    }
    YTRCLog(@{@"event": @"panel-handler", @"kind": kind,
              @"signature": @"unsupported", @"encoding": encoding});
    return block;
}

static void YTRCCaptureAssistantObject(NSString *event, id object, NSData *__strong *store) {
    if (object == nil) return;
    NSError *error = nil;
    NSData *bytes = YTRCSerializeMessage(object, 1024 * 1024, &error);
    if (bytes.length == 0) return;
    *store = bytes;
    YTAICollectCaptureItem(bytes);
    NSData *capped = bytes.length > 24576 ? [bytes subdataWithRange:NSMakeRange(0, 24576)] : bytes;
    YTRCLog(@{@"event": event, @"class": NSStringFromClass([object class]) ?: @"?",
              @"bytes": @(bytes.length), @"truncated": @(bytes.length > capped.length),
              @"payload": [capped base64EncodedStringWithOptions:0]});
}

// Wraps the service's response block (arity detected from its signature, so a
// variant shape is passed through untouched instead of being mis-called).
static id YTRCAssistantWrappedResponse(id block) {
    if (block == nil) return nil;
    NSString *encoding = YTRCBlockSignature(block);
    if (encoding.length == 0) return block;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:encoding.UTF8String];
    if (strcmp(signature.methodReturnType, "v") != 0 || signature.numberOfArguments < 2 ||
        strcmp([signature getArgumentTypeAtIndex:0], "@?") != 0) return block;
    if (signature.numberOfArguments == 2) {
        void (^original)(id) = block;
        return [^(id response) {
            YTRCCaptureAssistantObject(@"assistant-response", response, &YTRCLastAssistantResponseBytes);
            original(response);
        } copy];
    }
    if (signature.numberOfArguments == 3) {
        const char *auxiliary = [signature getArgumentTypeAtIndex:2];
        if (auxiliary[0] == '@' && auxiliary[1] != '?') {
            void (^original)(id, id) = block;
            return [^(id response, id argument) {
                YTRCCaptureAssistantObject(@"assistant-response", response, &YTRCLastAssistantResponseBytes);
                original(response, argument);
            } copy];
        }
        if (strcmp(auxiliary, "B") == 0) {
            void (^original)(id, bool) = block;
            return [^(id response, bool flag) {
                YTRCCaptureAssistantObject(@"assistant-response", response, &YTRCLastAssistantResponseBytes);
                original(response, flag);
            } copy];
        }
        if (strcmp(auxiliary, "^v") == 0) {
            void (^original)(id, void *) = block;
            return [^(id response, void *argument) {
                YTRCCaptureAssistantObject(@"assistant-response", response, &YTRCLastAssistantResponseBytes);
                original(response, argument);
            } copy];
        }
    }
    return block;
}

// One-shot snapshot of the AI ("Ask") UI structure at the moment the service
// first fires: presented controller chain plus a bounded view-tree dump with
// editable fields, identifiers, labels and frames. This is what the replay
// implementation is built from (input field + send button + panel class).
static void YTRCDumpAssistantUI(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows)
            if (candidate.isKeyWindow) window = candidate;
    }
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (UIViewController *controller = window.rootViewController;
         controller != nil && chain.count < 8; controller = controller.presentedViewController)
        [chain addObject:NSStringFromClass(controller.class)];
    NSMutableArray<NSString *> *views = [NSMutableArray array];
    __block NSUInteger budget = 150;
    __block __weak void (^weakWalk)(UIView *, NSUInteger);
    void (^walk)(UIView *, NSUInteger) = ^(UIView *view, NSUInteger depth) {
        if (view == nil || depth > 9 || budget == 0) return;
        budget--;
        BOOL editable = [view isKindOfClass:UITextView.class] || [view isKindOfClass:UITextField.class];
        NSString *identifier = view.accessibilityIdentifier ?: @"";
        NSString *label = view.accessibilityLabel ?: @"";
        if (editable || identifier.length != 0 || label.length != 0 || [view isKindOfClass:UIControl.class]) {
            [views addObject:[NSString stringWithFormat:@"%@%s id=%@ label=%@ frame=%@",
                NSStringFromClass(view.class), editable ? " [EDITABLE]" : "",
                identifier, label, NSStringFromCGRect(view.frame)]];
        }
        for (UIView *subview in view.subviews) weakWalk(subview, depth + 1);
    };
    weakWalk = walk;
    walk(window, 0);
    YTRCLog(@{@"event": @"assistant-ui", @"chain": chain, @"views": views});
}

static void YTRCAssistantCapture(id receiver, id request) {
    YTRCAssistantServiceInstance = receiver;
    YTRCCaptureAssistantObject(@"assistant-request", request, &YTRCLastAssistantRequestBytes);
    static BOOL dumpedUI = NO;
    if (!dumpedUI) {
        dumpedUI = YES;
        dispatch_async(dispatch_get_main_queue(), ^{ YTRCDumpAssistantUI(); });
    }
}

static void YTRCAssistantRequest(id receiver, SEL selector, id request, BOOL refresh,
                                 id responseBlock, id errorBlock) {
    YTRCAssistantCapture(receiver, request);
    ((void (*)(id, SEL, id, BOOL, id, id))OriginalAssistantRequest)(
        receiver, selector, request, refresh, YTRCAssistantWrappedResponse(responseBlock), errorBlock);
}

static void YTRCAssistantRequestTimeout(id receiver, SEL selector, id request, BOOL refresh,
                                        id responseBlock, id errorBlock, double timeout) {
    YTRCAssistantCapture(receiver, request);
    ((void (*)(id, SEL, id, BOOL, id, id, double))OriginalAssistantRequestTimeout)(
        receiver, selector, request, refresh, YTRCAssistantWrappedResponse(responseBlock),
        errorBlock, timeout);
}
static IMP OriginalControlsOverlayLayout;
static IMP OriginalVideoOverlayLayout;
static IMP OriginalControlsSetOverlayVisible;
static IMP OriginalVideoSetControlsVisible;

// Player-controls overlay: layoutSubviews hosts/positions the launcher button
// (the same host class the released YTKACE uses for its overlay buttons); the
// visibility selectors keep the button — and any open menu — in sync with the
// tap-the-video chrome. All three selectors are implemented directly on their
// class in the target build (ABI-checked); each install fails closed
// independently, so a YouTube update that drops one leaves the others working.
static void YTRCControlsOverlayLayout(id receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalControlsOverlayLayout)(receiver, selector);
    [YTRCLauncher overlay:(UIView *)receiver];
}

static void YTRCVideoOverlayLayout(id receiver, SEL selector) {
    ((void (*)(id, SEL))OriginalVideoOverlayLayout)(receiver, selector);
    [YTRCLauncher overlay:(UIView *)receiver];
}

static void YTRCControlsSetOverlayVisible(id receiver, SEL selector, BOOL visible) {
    ((void (*)(id, SEL, BOOL))OriginalControlsSetOverlayVisible)(receiver, selector, visible);
    [YTRCLauncher setVisible:visible];
}

static void YTRCVideoSetControlsVisible(id receiver, SEL selector, BOOL visible) {
    ((void (*)(id, SEL, BOOL))OriginalVideoSetControlsVisible)(receiver, selector, visible);
    [YTRCLauncher setVisible:visible];
}

// Every browse-family response goes to the server: FEwhat_to_watch surfaces
// as "home", other browse IDs (FEsubscriptions, FEhistory, FEshorts, channel
// pages, …) surface under their own browse ID, and unresolved continuations
// surface as "browse-unknown". All map to the /yt-browse endpoint. The ~105 B
// Home stub block passes through untouched; only real bodies are transformed.
static void YTRCBrowse(id receiver, SEL selector, id request, BOOL refresh, id reload,
                       id initialBlock, id responseBlock, id errorBlock) {
    NSString *surface = @"browse-unknown";
    id browseID = YTRCObject(request, @"browseId");
    id continuation = YTRCObject(request, @"continuation");
    if ([browseID isKindOfClass:NSString.class] && [browseID length] != 0) {
        surface = [browseID isEqualToString:@"FEwhat_to_watch"] ? @"home" : browseID;
    } else if ([continuation isKindOfClass:NSString.class] && [(NSString *)continuation length] != 0) {
        NSString *resolved = [YTRCContinuations() surfaceForBrowseID:nil token:continuation];
        surface = [resolved isEqualToString:@"home"] ? @"home" : resolved; // home | other-browse | unknown-browse
    }
    if (!YTRCCategoryEnabled(surface)) {
        YTRCLog(@{@"event": @"browse-entry", @"surface": surface,
                  @"phase": YTRCPhase([continuation isKindOfClass:NSString.class] ? continuation : @"", refresh),
                  @"hookClass": NSStringFromClass([receiver class]),
                  @"hasBrowseId": @(browseID != nil), @"hasContinuation": @(continuation != nil),
                  @"decision": @"category-disabled-passthrough"});
        ((void (*)(id, SEL, id, BOOL, id, id, id, id))OriginalBrowse)(receiver, selector,
            request, refresh, reload, initialBlock, responseBlock, errorBlock);
        return;
    }
    NSString *phase = YTRCPhase([continuation isKindOfClass:NSString.class] ? continuation : @"", refresh);
    NSDictionary *requestContext = YTRCCaptureRequestContext(request);
    YTRCDeliveryContext *(^contextProvider)(void) = ^{
        YTRCDeliveryContext *context = [YTRCDeliveryContext new];
        context.requestId = NSUUID.UUID.UUIDString;
        context.surface = surface;
        context.phase = phase;
        context.hookClass = NSStringFromClass([receiver class]);
        context.requestContext = requestContext;
        return context;
    };
    ((void (*)(id, SEL, id, BOOL, id, id, id, id))OriginalBrowse)(receiver, selector,
        request, refresh, reload, initialBlock, YTRCWrapForTransform(responseBlock, surface, @"",
            contextProvider, nullptr), errorBlock);
}

// The tabbed Home redesign fetches each category tab ([All] [Podcasts] [News])
// through the InnerTube feed controller, not YTAppBrowseService: one request
// per tab with an initial-page block and a continuation block. The response is
// the same YTIBrowseResponse. Teaser prefetches use different selectors on
// this class (hooked separately, gated by the Subs/History toggle).
static void YTRCFeedContinuation(id receiver, SEL selector, unsigned long long feedType,
                                 id initialBlock, id block, id errorResponseBlock) {
    // Capture runs ungated (diagnostic only): the AI Overview panel fetches
    // through these callbacks for some layouts.
    YTAICaptureFeedDataSource(receiver, @"feed");
    id observedInitial = YTRCCaptureArrayCallback(initialBlock, @"feed-initial");
    id observedContinuation = YTRCCaptureArrayCallback(block, @"feed-continuation");
    if (!YTRCCategoryEnabled(@"home")) {
        ((void (*)(id, SEL, unsigned long long, id, id, id))OriginalFeedContinuation)(
            receiver, selector, feedType, observedInitial, observedContinuation, errorResponseBlock);
        return;
    }
    YTRCDeliveryContext *(^providerWithPhase)(NSString *) = ^YTRCDeliveryContext *(NSString *phase) {
        YTRCDeliveryContext *context = [YTRCDeliveryContext new];
        context.requestId = NSUUID.UUID.UUIDString;
        context.surface = @"home";
        context.phase = phase;
        context.responseType = @"YTIBrowseResponse";
        context.hookClass = NSStringFromClass([receiver class]);
        context.feedType = feedType;
        context.requestContext = @{@"feedType": @(feedType)};
        return context;
    };
    id wrappedInitial = YTRCWrapForTransform(observedInitial, @"home", @"YTIBrowseResponse",
        ^{ return providerWithPhase(@"initial"); }, nullptr);
    id wrappedContinuation = YTRCWrapForTransform(observedContinuation, @"home", @"YTIBrowseResponse",
        ^{ return providerWithPhase(@"continuation"); }, nullptr);
    ((void (*)(id, SEL, unsigned long long, id, id, id))OriginalFeedContinuation)(
        receiver, selector, feedType, wrappedInitial, wrappedContinuation, errorResponseBlock);
}

// Feed teaser prefetch continuations (recommendation-adjacent feeder content).
// The response type was never pinned on this boundary, so the expected-class
// gate is open and replacements are parsed into the observed class.
static void YTRCTeaserContinuation(id receiver, SEL selector, id token, unsigned long long continuationType,
                                   id attachment, BOOL cacheEnabled, id clickTracking, BOOL alwaysParseFeedNode,
                                   id responseBlock, id errorBlock) {
    // The live data source is the replay vehicle for the AI Overview fetch.
    YTAICaptureFeedDataSource(receiver, @"teaser");
    // AI-style continuations reveal which data source/service the app itself
    // uses for the panel. Log the full native call shape (service, type,
    // attachment, click tracking) and retain that data source + arguments
    // separately from generic feed instances.
    if ([token isKindOfClass:NSString.class] && [(NSString *)token hasPrefix:@"kta-"]) {
        YTAINoteContinuation((NSString *)token);
        id service = nil;
        if ([receiver respondsToSelector:@selector(service)])
            service = ((id (*)(id, SEL))objc_msgSend)(receiver, @selector(service));
        id innerService = nil;
        SEL resolve = NSSelectorFromString(@"getInnerTubeUIServiceForActiveIdentity");
        if (service != nil && [service respondsToSelector:resolve])
            innerService = ((id (*)(id, SEL))objc_msgSend)(service, resolve);
        YTRCLog(@{@"event": @"ai-continuation", @"source": @"teaser",
                  @"tokenPrefix": [(NSString *)token substringToIndex:MIN((NSUInteger)48, [(NSString *)token length])],
                  @"type": @(continuationType),
                  @"attachment": attachment != nil ? NSStringFromClass([attachment class]) : @"(none)",
                  @"clickTracking": clickTracking != nil ? NSStringFromClass([clickTracking class]) : @"(none)",
                  @"dataSource": NSStringFromClass([receiver class]) ?: @"?",
                  @"service": service != nil ? NSStringFromClass([service class]) : @"(none)",
                  @"innerService": innerService != nil ? NSStringFromClass([innerService class]) : @"(none)",
                  @"cacheEnabled": @(cacheEnabled),
                  @"alwaysParse": @(alwaysParseFeedNode)});
        YTAINoteNativeContinuation(receiver, continuationType, attachment, clickTracking, cacheEnabled, alwaysParseFeedNode);
    }
    // Capture runs ungated (diagnostic only): the AI Overview panel fetches
    // through these continuation callbacks.
    id observed = YTRCCaptureArrayCallback(responseBlock, @"browse-teaser");
    if ([token isKindOfClass:NSString.class] && [(NSString *)token length] != 0) {
        YTRCLog(@{@"event": @"continuation-request", @"tag": @"browse-teaser",
                  @"tokenPrefix": [(NSString *)token substringToIndex:MIN((NSUInteger)48, [(NSString *)token length])],
                  @"feedType": @(continuationType)});
    }
    if (!YTRCCategoryEnabled(@"browse-teaser")) {
        ((void (*)(id, SEL, id, unsigned long long, id, BOOL, id, BOOL, id, id))OriginalTeaserContinuation)(
            receiver, selector, token, continuationType, attachment, cacheEnabled, clickTracking,
            alwaysParseFeedNode, observed, errorBlock);
        return;
    }
    NSDictionary *requestContext = [token isKindOfClass:NSString.class] && [(NSString *)token length] != 0
        ? @{@"continuation": token, @"feedType": @(continuationType)}
        : @{@"feedType": @(continuationType)};
    YTRCDeliveryContext *(^provider)(void) = ^{
        YTRCDeliveryContext *context = [YTRCDeliveryContext new];
        context.requestId = NSUUID.UUID.UUIDString;
        context.surface = @"browse-teaser";
        context.phase = @"continuation";
        context.hookClass = NSStringFromClass([receiver class]);
        context.feedType = continuationType;
        context.requestContext = requestContext;
        return context;
    };
    id wrapped = YTRCWrapForTransform(observed, @"browse-teaser", @"", provider, nullptr);
    ((void (*)(id, SEL, id, unsigned long long, id, BOOL, id, BOOL, id, id))OriginalTeaserContinuation)(
        receiver, selector, token, continuationType, attachment, cacheEnabled, clickTracking,
        alwaysParseFeedNode, wrapped, errorBlock);
}

static void YTRCTeaserContinuationShort(id receiver, SEL selector, id token, BOOL cacheEnabled,
                                        id clickTracking, BOOL alwaysParseFeedNode,
                                        id responseBlock, id errorBlock) {
    YTAICaptureFeedDataSource(receiver, @"teaser-short");
    // Capture runs ungated (diagnostic only).
    id observed = YTRCCaptureArrayCallback(responseBlock, @"browse-teaser-short");
    if ([token isKindOfClass:NSString.class] && [(NSString *)token length] != 0) {
        YTRCLog(@{@"event": @"continuation-request", @"tag": @"browse-teaser-short",
                  @"tokenPrefix": [(NSString *)token substringToIndex:MIN((NSUInteger)48, [(NSString *)token length])]});
    }
    if (!YTRCCategoryEnabled(@"browse-teaser")) {
        ((void (*)(id, SEL, id, BOOL, id, BOOL, id, id))OriginalTeaserContinuationShort)(
            receiver, selector, token, cacheEnabled, clickTracking, alwaysParseFeedNode, observed, errorBlock);
        return;
    }
    NSDictionary *requestContext = [token isKindOfClass:NSString.class] && [(NSString *)token length] != 0
        ? @{@"continuation": token}
        : nil;
    YTRCDeliveryContext *(^provider)(void) = ^{
        YTRCDeliveryContext *context = [YTRCDeliveryContext new];
        context.requestId = NSUUID.UUID.UUIDString;
        context.surface = @"browse-teaser";
        context.phase = @"continuation";
        context.hookClass = NSStringFromClass([receiver class]);
        context.requestContext = requestContext;
        return context;
    };
    id wrapped = YTRCWrapForTransform(observed, @"browse-teaser", @"", provider, nullptr);
    ((void (*)(id, SEL, id, BOOL, id, BOOL, id, id))OriginalTeaserContinuationShort)(
        receiver, selector, token, cacheEnabled, clickTracking, alwaysParseFeedNode, wrapped, errorBlock);
}

// Search results are a video recommendation list; surface "search", endpoint
// /yt-search. Same request shape as the browse/watch service layers.
static void YTRCSearchCall(IMP original, id receiver, SEL selector, id request, BOOL refresh,
                           id responseBlock, id errorBlock) {
    if (!YTRCCategoryEnabled(@"search")) {
        ((void (*)(id, SEL, id, BOOL, id, id))original)(receiver, selector, request, refresh, responseBlock, errorBlock);
        return;
    }
    id continuation = YTRCObject(request, @"continuation");
    NSString *phase = YTRCPhase([continuation isKindOfClass:NSString.class] ? continuation : @"", refresh);
    NSDictionary *requestContext = YTRCCaptureRequestContext(request);
    YTRCDeliveryContext *(^provider)(void) = ^{
        YTRCDeliveryContext *context = [YTRCDeliveryContext new];
        context.requestId = NSUUID.UUID.UUIDString;
        context.surface = @"search";
        context.phase = phase;
        context.hookClass = NSStringFromClass([receiver class]);
        context.requestContext = requestContext;
        return context;
    };
    id wrapped = YTRCWrapForTransform(responseBlock, @"search", @"YTISearchResponse", provider, nullptr);
    ((void (*)(id, SEL, id, BOOL, id, id))original)(receiver, selector, request, refresh, wrapped, errorBlock);
}

static void YTRCAppSearch(id receiver, SEL selector, id request, BOOL refresh, id responseBlock, id errorBlock) {
    YTRCSearchCall(OriginalAppSearch, receiver, selector, request, refresh, responseBlock, errorBlock);
}

static void YTRCSearchImpl(id receiver, SEL selector, id request, BOOL refresh, id responseBlock, id errorBlock) {
    YTRCSearchCall(OriginalSearchImpl, receiver, selector, request, refresh, responseBlock, errorBlock);
}

static id YTRCBrowseID(id receiver, SEL selector, id browseID, id continuation) {
    id result = ((id (*)(id, SEL, id, id))OriginalBrowseID)(receiver, selector, browseID, continuation);
    [YTRCContinuations() rememberToken:continuation browseID:result];
    return result;
}

static void YTRCBrowseCache(id receiver, SEL selector, id key, id browseID) {
    ((void (*)(id, SEL, id, id))OriginalBrowseCache)(receiver, selector, key, browseID);
    [YTRCContinuations() rememberToken:key browseID:browseID];
}

static NSString *YTRCVideoIdentifier(id request) {
    id videoId = YTRCObject(request, @"videoId");
    return [videoId isKindOfClass:NSString.class] ? videoId : nil;
}

static YTRCDeliveryContext *(^YTRCWatchContext(id receiver, id request, SEL selector))(void) {
    id continuation = YTRCObject(request, @"continuation");
    NSString *phase = YTRCPhase([continuation isKindOfClass:NSString.class] ? continuation : @"", NO);
    NSString *videoId = YTRCVideoIdentifier(request);
    NSDictionary *requestContext = YTRCCaptureRequestContext(request);
    return ^{
        YTRCDeliveryContext *context = [YTRCDeliveryContext new];
        context.requestId = NSUUID.UUID.UUIDString;
        context.surface = @"watch";
        context.phase = phase;
        context.videoId = videoId;
        context.responseType = @"YTIWatchNextResponse";
        context.hookClass = NSStringFromClass([receiver class]);
        context.requestContext = requestContext;
        return context;
    };
}

static void YTRCWatchServiceCompletion(id receiver, SEL selector, id request, id willMakeRequest, id completion) {
    YTRCSetActiveVideoId(YTRCVideoIdentifier(request));
    id wrapped = completion;
    if (YTRCCategoryEnabled(@"watch")) {
        YTRCDeliveryContext *(^provider)(void) = YTRCWatchContext(receiver, request, selector);
        wrapped = YTRCWrapForTransform(completion, @"watch", @"YTIWatchNextResponse", ^{
            YTRCDeliveryContext *context = provider();
            context.initialDelivery = YES;
            return context;
        }, nullptr);
    }
    ((void (*)(id, SEL, id, id, id))OriginalWatchCompletion)(receiver, selector, request, willMakeRequest, wrapped);
}

static void YTRCWatchServiceValue(id receiver, SEL selector, id request, id willMakeRequest,
                                  id valueHandler, id completion) {
    YTRCSetActiveVideoId(YTRCVideoIdentifier(request));
    id wrapped = completion;
    if (YTRCCategoryEnabled(@"watch")) {
        YTRCDeliveryContext *(^provider)(void) = YTRCWatchContext(receiver, request, selector);
        wrapped = YTRCWrapForTransform(completion, @"watch", @"YTIWatchNextResponse", ^{
            YTRCDeliveryContext *context = provider();
            context.initialDelivery = YES;
            return context;
        }, nullptr);
    }
    ((void (*)(id, SEL, id, id, id, id))OriginalWatchValue)(receiver, selector, request,
        willMakeRequest, valueHandler, wrapped);
}

static void YTRCWatchContinuation(IMP original, id receiver, SEL selector, id request, BOOL refresh,
                                  double timeout, id responseBlock, id errorBlock, BOOL shortForm) {
    if (!YTRCCategoryEnabled(@"watch")) {
        if (shortForm)
            ((void (*)(id, SEL, id, BOOL, id, id))original)(receiver, selector, request, refresh, responseBlock, errorBlock);
        else
            ((void (*)(id, SEL, id, BOOL, double, id, id))original)(receiver, selector, request, refresh, timeout, responseBlock, errorBlock);
        return;
    }
    YTRCDeliveryContext *(^provider)(void) = YTRCWatchContext(receiver, request, selector);
    id wrapped = YTRCWrapForTransform(responseBlock, @"watch", @"YTIWatchNextResponse", provider, nullptr);
    if (shortForm)
        ((void (*)(id, SEL, id, BOOL, id, id))original)(receiver, selector, request, refresh, wrapped, errorBlock);
    else
        ((void (*)(id, SEL, id, BOOL, double, id, id))original)(receiver, selector, request, refresh, timeout, wrapped, errorBlock);
}

static void YTRCAppWatchShort(id receiver, SEL selector, id request, BOOL refresh, id responseBlock, id errorBlock) {
    YTRCWatchContinuation(OriginalAppWatchShort, receiver, selector, request, refresh, 0.0, responseBlock, errorBlock, YES);
}
static void YTRCAppWatchTimeout(id receiver, SEL selector, id request, BOOL refresh, double timeout,
                                id responseBlock, id errorBlock) {
    YTRCWatchContinuation(OriginalAppWatchTimeout, receiver, selector, request, refresh, timeout, responseBlock, errorBlock, NO);
}
static void YTRCAppWatchFallback(id receiver, SEL selector, id request, BOOL refresh, double timeout,
                                 id responseBlock, id errorBlock) {
    YTRCWatchContinuation(OriginalAppWatchFallback, receiver, selector, request, refresh, timeout, responseBlock, errorBlock, NO);
}
static void YTRCImplWatchShort(id receiver, SEL selector, id request, BOOL refresh, id responseBlock, id errorBlock) {
    YTRCWatchContinuation(OriginalImplWatchShort, receiver, selector, request, refresh, 0.0, responseBlock, errorBlock, YES);
}
static void YTRCImplWatchTimeout(id receiver, SEL selector, id request, BOOL refresh, double timeout,
                                 id responseBlock, id errorBlock) {
    YTRCWatchContinuation(OriginalImplWatchTimeout, receiver, selector, request, refresh, timeout, responseBlock, errorBlock, NO);
}
static void YTRCCompositeWatch(id receiver, SEL selector, id request, BOOL refresh, id responseBlock, id errorBlock) {
    YTRCWatchContinuation(OriginalCompositeWatch, receiver, selector, request, refresh, 0.0, responseBlock, errorBlock, YES);
}

static void YTRCInstall(NSString *className, NSString *methodName, const char *types, IMP replacement, IMP *original) {
    if (*original != nullptr) return;
    Class cls = NSClassFromString(className);
    SEL selector = NSSelectorFromString(methodName);
    Method method = cls != Nil ? class_getInstanceMethod(cls, selector) : nullptr;
    BOOL valid = YTRCMethodMatches(method, types);
    if (valid) {
        *original = method_getImplementation(method);
        if (!class_addMethod(cls, selector, replacement, method_getTypeEncoding(method))) {
            method_setImplementation(class_getInstanceMethod(cls, selector), replacement);
        }
    }
    // Startup retries may attempt the same install many times while YouTube's
    // classes are still loading; log each class+selector outcome once.
    static NSMutableSet<NSString *> *logged;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ logged = [NSMutableSet set]; });
    NSString *key = [NSString stringWithFormat:@"%@.%@.%@", className, methodName, @(valid)];
    if (![logged containsObject:key]) {
        [logged addObject:key];
        YTRCLog(@{@"event": @"hook", @"class": className, @"selector": methodName,
                  @"installed": @(valid),
                  @"types": method != nullptr ? @(method_getTypeEncoding(method)) : @"missing"});
    }
}

static void YTRCInstallHooks(void) {
    YTRCInstall(@"YTAppBrowseService",
        @"makeRequest:refresh:reloadContinuationData:initialResponseBlock:responseBlock:errorBlock:",
        "v@:@B@@?@?@?", (IMP)YTRCBrowse, &OriginalBrowse);
    YTRCInstall(@"YTAppBrowseService", @"selectBrowseIDForRequestForBrowseID:andContinuation:",
        "@@:@@", (IMP)YTRCBrowseID, &OriginalBrowseID);
    YTRCInstall(@"YTAppBrowseService", @"addBrowseIdToCacheIfRequiredForContinuationKey:browseID:",
        "v@:@@", (IMP)YTRCBrowseCache, &OriginalBrowseCache);
    YTRCInstall(@"YTWatchService", @"setWatchNextRequest:willMakeRequestBlock:completionBlock:",
        "v@:@@?@?", (IMP)YTRCWatchServiceCompletion, &OriginalWatchCompletion);
    YTRCInstall(@"YTWatchService", @"setWatchNextRequest:willMakeRequestBlock:valueHandler:completionHandler:",
        "v@:@@?@?@?", (IMP)YTRCWatchServiceValue, &OriginalWatchValue);
    YTRCInstall(@"YTAppWatchNextService", @"makeRequest:refresh:responseBlock:errorBlock:",
        "v@:@B@?@?", (IMP)YTRCAppWatchShort, &OriginalAppWatchShort);
    YTRCInstall(@"YTAppWatchNextService", @"makeRequest:refresh:timeoutInterval:responseBlock:errorBlock:",
        "v@:@Bd@?@?", (IMP)YTRCAppWatchTimeout, &OriginalAppWatchTimeout);
    YTRCInstall(@"YTAppWatchNextService", @"makeFallbackEnabledRequest:refresh:timeoutInterval:responseBlock:errorBlock:",
        "v@:@Bd@?@?", (IMP)YTRCAppWatchFallback, &OriginalAppWatchFallback);
    YTRCInstall(@"YTWatchNextServiceImpl", @"makeRequest:refresh:responseBlock:errorBlock:",
        "v@:@B@?@?", (IMP)YTRCImplWatchShort, &OriginalImplWatchShort);
    YTRCInstall(@"YTWatchNextServiceImpl", @"makeRequest:refresh:timeoutInterval:responseBlock:errorBlock:",
        "v@:@Bd@?@?", (IMP)YTRCImplWatchTimeout, &OriginalImplWatchTimeout);
    YTRCInstall(@"YTCompositeWatchNextService", @"makeRequest:refresh:responseBlock:errorBlock:",
        "v@:@B@?@?", (IMP)YTRCCompositeWatch, &OriginalCompositeWatch);
    // Same hook point released YTKACE uses to render its native settings
    // section; our extension runs whenever it commits its items.
    YTRCInstall(@"YTSettingsViewController", @"setSectionItems:forCategory:title:icon:titleDescription:headerHidden:",
        "v@:@Q@@@B", (IMP)YTRCSettingsItems, &OriginalSettingsItems);
    // Tabbed-Home category loads ([All] [Podcasts] [News] …) bypass
    // YTAppBrowseService and run through the InnerTube feed controller.
    YTRCInstall(@"YTInnerTubeFeedControllerDataSource", @"requestContinuationWithType:initialResponseBlock:block:errorResponseBlock:",
        "v@:Q@?@?@?", (IMP)YTRCFeedContinuation, &OriginalFeedContinuation);
    // Feed teaser prefetch continuations on the same controller.
    YTRCInstall(@"YTInnerTubeFeedControllerDataSource", @"requestInnerTubeContinuationWithContinuationToken:continuationType:clientAttachmentRequestData:cacheEnabled:clickTrackingParams:alwaysParseFeedNode:responseBlock:errorBlock:",
        "v@:@Q@B@B@?@?", (IMP)YTRCTeaserContinuation, &OriginalTeaserContinuation);
    YTRCInstall(@"YTInnerTubeFeedControllerDataSource", @"requestInnerTubeContinuationWithContinuationToken:cacheEnabled:clickTrackingParams:alwaysParseFeedNode:responseBlock:errorBlock:",
        "v@:@B@B@?@?", (IMP)YTRCTeaserContinuationShort, &OriginalTeaserContinuationShort);
    // Search results (a video recommendation list) go to /yt-search.
    // Shorts reel watch sequence (the vertical feed's fetch boundary).
    YTRCInstall(@"YTGetReelWatchSequenceServiceImpl", @"makeYTIReelWatchSequenceRequest:responseBlock:errorBlock:",
        "@@:@@?@?", (IMP)YTRCReelSequence, &OriginalReelSequence);
    YTRCInstall(@"YTGetReelWatchSequenceServiceImpl", @"makeYTIReelWatchSequenceRequest:retryEnabled:responseBlock:errorBlock:",
        "@@:@B@?@?", (IMP)YTRCReelSequenceRetry, &OriginalReelSequenceRetry);
    // Client-side playback observation (report-only; no substitution).
    YTRCInstall(@"YTPlayerViewController", @"playbackController:didActivateVideo:withPlaybackData:",
        "v@:@@@", (IMP)YTRCPlaybackActivate, &OriginalPlaybackActivate);
    YTRCInstall(@"YTPlayerViewController", @"playbackControllerDidFinishPlayback:",
        "v@:@", (IMP)YTRCPlaybackFinish, &OriginalPlaybackFinish);
    YTRCInstall(@"YTPlayerViewController", @"pauseWithStoppageReason:",
        "v@:i", (IMP)YTRCPlaybackPause, &OriginalPlaybackPause);
    YTRCInstall(@"YTAppSearchService", @"makeRequest:refresh:responseBlock:errorBlock:",
        "v@:@B@?@?", (IMP)YTRCAppSearch, &OriginalAppSearch);
    YTRCInstall(@"YTSearchServiceImpl", @"makeRequest:refresh:responseBlock:errorBlock:",
        "v@:@B@?@?", (IMP)YTRCSearchImpl, &OriginalSearchImpl);
    // AI panel service trace: request dispatch, handler delivery, and
    // cancellation on the concrete streaming panel service.
    YTRCInstall(@"YTStreamingPanelServiceImpl",
        @"makeStreamingRequest:refresh:timeoutInterval:engagementType:valueHandler:completionHandler:",
        "@@:@Bdi@?@?", (IMP)YTRCPanelStreamingRequest, &OriginalPanelStreamingRequest);
    YTRCInstall(@"YTStreamingPanelServiceImpl", @"cancelContinuationRequestWithToken:",
        "v@:@", (IMP)YTRCPanelCancel, &OriginalPanelCancel);
    // YouTube Assistant (AI) observation: records the request/response of a
    // manual AI use, revealing the exact request shape and the live service
    // instance for later replay. Observation-only.
    YTRCInstall(@"YTAssistantServiceImpl", @"makeRequest:refresh:responseBlock:errorBlock:",
        "v@:@B@?@?", (IMP)YTRCAssistantRequest, &OriginalAssistantRequest);
    YTRCInstall(@"YTAssistantServiceImpl", @"makeRequest:refresh:responseBlock:errorBlock:timeoutInterval:",
        "v@:@B@?@?d", (IMP)YTRCAssistantRequestTimeout, &OriginalAssistantRequestTimeout);
    // Player-controls launcher: both overlay classes act as layout ticks (the
    // cog may be built into either's subtree); visibility selectors sync the
    // button (and collapse the menu) with the tap-the-video chrome.
    YTRCInstall(@"YTMainAppControlsOverlayView", @"layoutSubviews", "v@:",
        (IMP)YTRCControlsOverlayLayout, &OriginalControlsOverlayLayout);
    YTRCInstall(@"YTMainAppVideoPlayerOverlayView", @"layoutSubviews", "v@:",
        (IMP)YTRCVideoOverlayLayout, &OriginalVideoOverlayLayout);
    YTRCInstall(@"YTMainAppControlsOverlayView", @"setOverlayVisible:", "v@:B",
        (IMP)YTRCControlsSetOverlayVisible, &OriginalControlsSetOverlayVisible);
    YTRCInstall(@"YTMainAppVideoPlayerOverlayView", @"setControlsOverlayVisible:", "v@:B",
        (IMP)YTRCVideoSetControlsVisible, &OriginalVideoSetControlsVisible);
}

// ---------- Settings panel ----------

@interface YTRCController : UITableViewController
@property(nonatomic) NSTimer *refreshTimer;
@end

@implementation YTRCController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Recommendations";
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(close)];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(tick)
                          userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}
- (void)tick { if (self.view.window != nil) [self.tableView reloadData]; }
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { return 4; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // The per-category toggles only exist while the master switch is on.
    if (section == 0) return YTRCEnabled(EnabledKey) ? 5 : 2;
    return section == 1 ? 3 : (section == 2 ? 4 : 2);
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == 0 ? @"Feature" : (section == 1 ? @"Server" : (section == 2 ? @"Statistics" : @"Diagnostics"));
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 1)
        return @"Server base URL only (scheme://host:port, no path), for example http://192.168.1.10:8046. The patch appends /yt-browse for the Home feed and /yt-next for the watch page + related list. HTTP is dev-only and needs the packaging script's ATS dev flag. The token is sent as an Authorization header when set; it is stored in app preferences, not the Keychain, for now. Responses contain personalized data; send them only to a server you control.";
    return @"Diagnostics are metadata only: counters, request ids, byte counts, and fallback reasons. No payloads are stored or exported.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (indexPath.section == 0) {
        BOOL masterOn = YTRCEnabled(EnabledKey);
        // Video stats is reserved: greyed out, no subtitle. Last row when the
        // master is on (after the toggles), second row when it is off.
        if ((masterOn && indexPath.row == 4) || (!masterOn && indexPath.row == 1)) {
            cell.textLabel.text = @"Video stats";
            cell.detailTextLabel.text = nil;
            cell.textLabel.enabled = NO;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            return cell;
        }
        NSArray *titles = @[@"Enable customized recommendations", @"Recommend feed", @"Subs/History feed", @"Search feed"];
        NSString *key = @[EnabledKey, RecommendKey, SubsKey, SearchKey][indexPath.row];
        cell.textLabel.text = titles[indexPath.row];
        UISwitch *toggle = [UISwitch new];
        toggle.on = YTRCEnabled(key);
        toggle.tag = indexPath.row;
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        if (indexPath.row == 0) {
            cell.textLabel.text = @"Server URL";
            NSString *url = [NSUserDefaults.standardUserDefaults stringForKey:@"YTKACE.Recommendations.ServerURL"] ?: @"";
            cell.detailTextLabel.text = url.length != 0 ? url : @"Not set";
        } else if (indexPath.row == 1) {
            cell.textLabel.text = @"Token";
            NSString *token = [NSUserDefaults.standardUserDefaults stringForKey:@"YTKACE.Recommendations.ServerToken"] ?: @"";
            cell.detailTextLabel.text = token.length != 0 ? @"Configured" : @"Not set";
        } else {
            cell.textLabel.text = @"Test connection";
            cell.detailTextLabel.text = nil;
            cell.textLabel.textColor = UIColor.systemBlueColor;
        }
    } else if (indexPath.section == 2) {
        NSArray *rows = @[
            @[[NSString stringWithFormat:@"Deliveries  recommend %llu · subs %llu · search %llu",
                YTRCCounter(CounterRecommendDeliveries), YTRCCounter(CounterSubsDeliveries),
                YTRCCounter(CounterSearchDeliveries)], @""],
            @[[NSString stringWithFormat:@"Server transforms sent %llu", YTRCCounter(CounterTransformsSent)], @""],
            @[[NSString stringWithFormat:@"Replacements %llu · fallbacks %llu",
                YTRCCounter(CounterReplacementsDelivered), YTRCCounter(CounterFallbackDelivered)], @""],
            @[[NSString stringWithFormat:@"Skips  dedupe %llu · marker %llu · cap %llu",
                YTRCCounter(CounterSkippedDedupe), YTRCCounter(CounterSkippedMarker), YTRCCounter(CounterSkippedCap)], @""]
        ];
        cell.textLabel.text = rows[indexPath.row][0];
        cell.textLabel.font = [UIFont systemFontOfSize:13];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = indexPath.row == 0 ? @"Export diagnostics" : @"Clear diagnostics";
        cell.textLabel.textColor = indexPath.row == 0 ? UIColor.systemBlueColor : UIColor.systemRedColor;
    }
    return cell;
}
- (void)toggleChanged:(UISwitch *)toggle {
    NSString *key = @[EnabledKey, RecommendKey, SubsKey, SearchKey][toggle.tag];
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:key];
    YTRCLog(@{@"event": @"setting", @"key": key, @"enabled": @(toggle.on)});
    if (toggle.tag == 0) {
        [YTRCRecent() clear];
        [self.tableView reloadData]; // category toggles appear only when on
    }
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1 && indexPath.row == 0) [self editServerURL];
    else if (indexPath.section == 1 && indexPath.row == 1) [self editServerToken];
    else if (indexPath.section == 1 && indexPath.row == 2) [self testConnection];
    else if (indexPath.section == 3 && indexPath.row == 0) [self exportDiagnostics];
    else if (indexPath.section == 3 && indexPath.row == 1) [self clearDiagnostics];
}
- (void)editServerURL {
    NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:@"YTKACE.Recommendations.ServerURL"] ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Server URL"
        message:@"Base URL only (no path). The patch appends /yt-browse and /yt-next. http works only with the dev ATS flag."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) { field.text = current; }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *value = alert.textFields.firstObject.text ?: @"";
        value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [NSUserDefaults.standardUserDefaults setObject:value forKey:@"YTKACE.Recommendations.ServerURL"];
        [YTRCRecent() clear];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)editServerToken {
    NSString *current = [NSUserDefaults.standardUserDefaults stringForKey:@"YTKACE.Recommendations.ServerToken"] ?: @"";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Token"
        message:@"Sent as an Authorization: Bearer header when set. Stored in app preferences for now."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = current;
        field.secureTextEntry = YES;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *value = alert.textFields.firstObject.text ?: @"";
        value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        [NSUserDefaults.standardUserDefaults setObject:value forKey:@"YTKACE.Recommendations.ServerToken"];
        [self.tableView reloadData];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)testConnection {
    UIAlertController *waiting = [UIAlertController alertControllerWithTitle:@"Testing…"
        message:[NSUserDefaults.standardUserDefaults stringForKey:@"YTKACE.Recommendations.ServerURL"]
        preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:waiting animated:YES completion:^{
        YTRCProbeServer(^(NSDictionary *health, NSError *error) {
            // Probe completions arrive on the client's background queue; all
            // UIKit work must hop to the main thread or the app goes down.
            dispatch_async(dispatch_get_main_queue(), ^{
                NSString *title = error != nil ? @"Connection failed" : @"Server reachable";
                NSString *message = error != nil ? YTRCErrorString(error)
                    : [NSString stringWithFormat:@"protocolVersion %@ · service %@",
                        health[@"protocolVersion"], health[@"service"] ?: @"(unspecified)"];
                UIAlertController *result = [UIAlertController alertControllerWithTitle:title message:message
                    preferredStyle:UIAlertControllerStyleAlert];
                [result addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                UIViewController *presenter = waiting.presentingViewController ?: self;
                [presenter dismissViewControllerAnimated:YES completion:^{
                    UIViewController *target = presenter == self ? self
                        : (self.presentingViewController != nil ? self : presenter);
                    [target presentViewController:result animated:YES completion:nil];
                }];
            });
        });
    }];
}
- (void)exportDiagnostics {
    dispatch_async(YTRCLogQueue(), ^{
        NSMutableArray *counters = [NSMutableArray array];
        for (int index = 0; index < CounterCount; index++)
            [counters addObject:@(YTRCCounter(index))];
        NSDictionary *report = @{@"module": @"recommendations", @"counters": counters,
                                 @"events": LogEvents ?: @[],
                                 @"assistantRequest": YTRCLastAssistantRequestBytes != nil
                                     ? [YTRCLastAssistantRequestBytes base64EncodedStringWithOptions:0] : @"",
                                 @"assistantResponse": YTRCLastAssistantResponseBytes != nil
                                     ? [YTRCLastAssistantResponseBytes base64EncodedStringWithOptions:0] : @"",
                                 @"notice": @"Metadata only; recommendation payloads are never recorded. assistantRequest/assistantResponse populate only after the AI feature has been used once."};
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
        NSURL *file = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"recommendations-%@.json", NSUUID.UUID.UUIDString]]];
        [json writeToURL:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[file]
                applicationActivities:nil];
            share.popoverPresentationController.sourceView = self.view;
            share.popoverPresentationController.sourceRect = self.view.bounds;
            share.completionWithItemsHandler = ^(__unused UIActivityType type, __unused BOOL completed,
                                                 __unused NSArray *items, __unused NSError *shareError) {
                [NSFileManager.defaultManager removeItemAtURL:file error:nil];
            };
            [self presentViewController:share animated:YES completion:nil];
        });
    });
}
- (void)clearDiagnostics {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Clear diagnostics?"
        message:@"Removes the in-memory metadata log and counter display resets on next launch." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        dispatch_async(YTRCLogQueue(), ^{ [LogEvents removeAllObjects]; });
        [YTRCRecent() clear];
        [YTRCContinuations() reset];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

// ---------- Player-controls launcher button + menu ----------

static const CGFloat YTRCButtonSize = 45.0; // 25% larger than the initial 36 pt

static UIView *YTRCMenuContainer = nil;       // expanded menu (backdrop + panel); nil = collapsed
static UIButton *YTRCMenuAnchor = nil;        // the launcher button it hangs off
static UILabel *YTRCNoteLabel = nil;          // transient "Saved"/error feedback
static __weak UIButton *YTRCOverlayButton = nil; // the live launcher button

static void YTRCMenuDismiss(void) {
    [YTRCMenuContainer removeFromSuperview];
    YTRCMenuContainer = nil;
    YTRCMenuAnchor = nil;
}

// The native settings cog sits in the player chrome's top-right region. It is
// found by hint match ("settings"/"gear" in identifier/label/class) restricted
// to that region — the same proven strategy the released YTKACE uses — with
// the topmost candidate winning. If the cog is not in the overlay being laid
// out, the search walks the whole window, since YouTube builds its chrome in
// whatever container the current layout uses.
static BOOL YTRCViewIsCogControl(UIView *view, UIView *coordinateView, UIView *exclude) {
    if (view == exclude || view.hidden || view.alpha < 0.05 || CGRectIsEmpty(view.bounds)) return NO;
    if ([view.accessibilityIdentifier isEqualToString:@"YTRCLauncherButton"]) return NO;
    if (![view isKindOfClass:UIControl.class] && ![view isKindOfClass:UIImageView.class]) return NO;
    NSString *hint = [[NSString stringWithFormat:@"%@ %@ %@",
        view.accessibilityIdentifier ?: @"", view.accessibilityLabel ?: @"",
        NSStringFromClass(view.class)] lowercaseString];
    if ([hint rangeOfString:@"settings"].location == NSNotFound &&
        [hint rangeOfString:@"gear"].location == NSNotFound) return NO;
    // The cog must be actually on screen: its whole ancestor chain visible.
    // Orientation/fullscreen transitions leave the old cog behind in a hidden
    // container — anchoring to that parked the button at the window origin.
    for (UIView *ancestor = view; ancestor != nil; ancestor = ancestor.superview) {
        if (ancestor.hidden || ancestor.alpha < 0.05) return NO;
    }
    CGRect frame = [view convertRect:view.bounds toView:coordinateView];
    CGFloat width = CGRectGetWidth(coordinateView.bounds);
    CGFloat height = CGRectGetHeight(coordinateView.bounds);
    CGFloat centerX = CGRectGetMidX(frame);
    CGFloat centerY = CGRectGetMidY(frame);
    return isfinite(centerX) && isfinite(centerY) &&
        centerX > width * 0.55 && centerY < height * 0.35 &&
        CGRectIntersectsRect(frame, coordinateView.bounds);
}

static void YTRCFindCogControlInView(UIView *view, UIView *exclude, UIView *coordinateView,
                                     UIView **best, CGFloat *bestScore) {
    if (YTRCViewIsCogControl(view, coordinateView, exclude)) {
        CGRect frame = [view convertRect:view.bounds toView:coordinateView];
        CGFloat score = -CGRectGetMidY(frame); // topmost candidate wins
        if (*best == nil || score > *bestScore) {
            *best = view;
            *bestScore = score;
        }
    }
    for (UIView *subview in view.subviews)
        YTRCFindCogControlInView(subview, exclude, coordinateView, best, bestScore);
}

static UIView *YTRCFindCogControl(UIView *root, UIView *exclude) {
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    YTRCFindCogControlInView(root, exclude, root, &best, &bestScore);
    return best;
}

static void YTRCShowNote(UIButton *anchor, NSString *text, BOOL success) {
    UIWindow *window = anchor.window;
    if (window == nil || text.length == 0) return;
    [YTRCNoteLabel removeFromSuperview];
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = UIColor.whiteColor;
    label.backgroundColor = success ? [UIColor colorWithWhite:0.0 alpha:0.72]
                                    : [UIColor.systemRedColor colorWithAlphaComponent:0.82];
    label.layer.cornerRadius = 10;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [window addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:anchor.centerXAnchor],
        [label.topAnchor constraintEqualToAnchor:anchor.bottomAnchor constant:10],
        [label.heightAnchor constraintEqualToConstant:28],
        [label.widthAnchor constraintGreaterThanOrEqualToConstant:96]
    ]];
    YTRCNoteLabel = label;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (YTRCNoteLabel != label) return;
        [UIView animateWithDuration:0.3 animations:^{ label.alpha = 0.0; }
                         completion:^(__unused BOOL finished) {
            if (YTRCNoteLabel == label) YTRCNoteLabel = nil;
            [label removeFromSuperview];
        }];
    });
}

// Menu metrics are 1.5x the original drop-down (user-requested size bump).
static UIButton *YTRCMenuRow(NSString *title, NSString *symbol, UIButton *anchor,
                             dispatch_block_t action) {
    UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
    row.tintColor = UIColor.whiteColor;
    row.titleLabel.font = [UIFont systemFontOfSize:21 weight:UIFontWeightMedium];
    [row setTitle:title forState:UIControlStateNormal];
    [row setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    UIImageSymbolConfiguration *symbols =
        [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightMedium];
    [row setPreferredSymbolConfiguration:symbols forImageInState:UIControlStateNormal];
    [row setImage:[UIImage systemImageNamed:symbol withConfiguration:symbols] forState:UIControlStateNormal];
    row.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeading;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // Legacy insets are honored for configuration-less system buttons (iOS 16
    // target); UIButtonConfiguration is never set on these rows.
    row.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 15);
    row.imageEdgeInsets = UIEdgeInsetsMake(0, 0, 0, 12); // icon -> title gap
#pragma clang diagnostic pop
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:63].active = YES;
    [row.widthAnchor constraintEqualToConstant:285].active = YES;
    objc_setAssociatedObject(row, MenuRowKey, action, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [row addTarget:YTRCLauncher.class action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    return row;
}

static void YTRCSaveCurrentVideo(BOOL ai, UIButton *anchor);

static void YTRCMenuShow(UIButton *button) {
    UIWindow *window = button.window;
    if (window == nil) return;
    UIView *container = [[UIView alloc] init];
    container.translatesAutoresizingMaskIntoConstraints = NO;
    container.backgroundColor = UIColor.clearColor;
    [window addSubview:container];
    [NSLayoutConstraint activateConstraints:@[
        [container.topAnchor constraintEqualToAnchor:window.topAnchor],
        [container.bottomAnchor constraintEqualToAnchor:window.bottomAnchor],
        [container.leadingAnchor constraintEqualToAnchor:window.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:window.trailingAnchor]
    ]];
    // Tap anywhere outside the panel reverts to the collapsed button.
    UIControl *backdrop = [UIControl new];
    backdrop.backgroundColor = UIColor.clearColor;
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    [backdrop addTarget:YTRCLauncher.class action:@selector(backdropTapped)
       forControlEvents:UIControlEventTouchUpInside];
    [container addSubview:backdrop];
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:container.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:container.trailingAnchor]
    ]];
    UIStackView *panel = [UIStackView new];
    panel.axis = UILayoutConstraintAxisVertical;
    panel.spacing = 3;
    panel.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.78];
    panel.layer.cornerRadius = 18;
    panel.layer.masksToBounds = YES;
    panel.layoutMargins = UIEdgeInsetsMake(9, 0, 9, 0);
    panel.layoutMarginsRelativeArrangement = YES;
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:panel];
    [panel addArrangedSubview:YTRCMenuRow(@"Save", @"text.quote", button, ^{
        YTRCSaveCurrentVideo(NO, button);
    })];
    [panel addArrangedSubview:YTRCMenuRow(@"Save w/ AI", @"sparkles", button, ^{
        YTRCSaveCurrentVideo(YES, button);
    })];
    [panel addArrangedSubview:YTRCMenuRow(@"Settings", @"gearshape", button, ^{
        [YTRCLauncher show:button];
    })];
    // The button hangs under the top-right cog, so the panel drops downward.
    [NSLayoutConstraint activateConstraints:@[
        [panel.trailingAnchor constraintEqualToAnchor:button.trailingAnchor],
        [panel.topAnchor constraintEqualToAnchor:button.bottomAnchor constant:8]
    ]];
    YTRCMenuContainer = container;
    YTRCMenuAnchor = button;
    container.alpha = 0.0;
    [UIView animateWithDuration:0.12 animations:^{ container.alpha = 1.0; }];
}

static void YTRCSaveCurrentVideo(BOOL ai, UIButton *anchor) {
    YTRCShowNote(anchor, @"Saving…", YES);
    NSString *videoId = YTRCActiveVideoId;
    // Gather the transcript first (fail-soft, bounded), then — for Save w/ AI
    // — replay the AI Overview request, then post everything together.
    YTRCFetchTranscript(videoId, ^(NSData *transcript, NSString *transcriptStatus) {
        if (!ai) {
            YTRCSendSaveRequest(videoId, NO, transcript, @"youtube-json3", transcriptStatus, nil, nil,
                ^(BOOL ok, NSString *message) {
                    if (ok && transcript.length != 0) message = @"Saved + transcript";
                    YTRCShowNote(anchor, message, ok);
                });
            return;
        }
        YTRCShowNote(anchor, @"Asking Gemini…", YES);
        YTAIFetchSummary(videoId, ^(NSString *summary, NSString *aiStatus) {
            YTRCSendSaveRequest(videoId, YES, transcript, @"youtube-json3", transcriptStatus, summary, aiStatus,
                ^(BOOL ok, NSString *message) {
                    if (summary.length != 0) {
                        YTAICloseAiPanel();
                        YTRCShowNote(anchor, ok ? @"Saved + AI overview" : message, ok);
                    } else {
                        if (ok) {
                            YTRCShowNote(anchor, @"Saved", YES);
                            [YTRCLauncher showAiGuidance:aiStatus fromButton:anchor];
                        } else {
                            YTRCShowNote(anchor, message, ok);
                        }
                    }
                });
        });
    });
}

@implementation YTRCLauncher
// Layout tick (both overlay classes): the button is hosted at WINDOW level —
// the only placement proven to render across YouTube's overlay churn — and
// constrained directly to the discovered settings cog (a shared ancestor with
// the window, so cross-hierarchy constraints resolve). No cog yet: the button
// stays hidden; a later tick anchors it.
+ (void)overlay:(UIView *)overlay {
    UIWindow *window = overlay.window;
    if (window == nil) return;
    UIButton *button = objc_getAssociatedObject(window, ButtonKey);
    if (![button isKindOfClass:UIButton.class]) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.accessibilityIdentifier = @"YTRCLauncherButton";
        button.accessibilityLabel = @"Recommendation menu";
        button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.42];
        button.tintColor = UIColor.whiteColor;
        UIImageSymbolConfiguration *symbols =
            [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightSemibold];
        [button setPreferredSymbolConfiguration:symbols forImageInState:UIControlStateNormal];
        [button setImage:[UIImage systemImageNamed:@"chevron.down" withConfiguration:symbols]
                forState:UIControlStateNormal];
        button.layer.cornerRadius = 10;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.hidden = YES;
        [button addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventTouchUpInside];
        [window addSubview:button];
        // Low-priority parking constraints: whenever the cog anchor
        // constraints are torn down by a layout transition, the button parks
        // at the top-right instead of collapsing to the window origin.
        NSLayoutConstraint *parkX =
            [button.trailingAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.trailingAnchor constant:-8];
        NSLayoutConstraint *parkY =
            [button.topAnchor constraintEqualToAnchor:window.safeAreaLayoutGuide.topAnchor constant:8];
        parkX.priority = UILayoutPriorityDefaultLow;
        parkY.priority = UILayoutPriorityDefaultLow;
        [NSLayoutConstraint activateConstraints:@[
            [button.widthAnchor constraintEqualToConstant:YTRCButtonSize],
            [button.heightAnchor constraintEqualToConstant:YTRCButtonSize],
            parkX,
            parkY
        ]];
        objc_setAssociatedObject(window, ButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    YTRCOverlayButton = button;
    [window bringSubviewToFront:button];
    UIView *cog = YTRCFindCogControl(window, button);
    UIView *anchoredCog = objc_getAssociatedObject(window, CogAnchorKey);
    NSArray *constraints = objc_getAssociatedObject(window, CogConstraintsKey);
    BOOL cogValid = cog != nil && cog.superview != nil && !cog.hidden;
    if (!cogValid) {
        button.hidden = YES; // no cog in this layout: nothing to hang under
        YTRCMenuDismiss();
        return;
    }
    button.hidden = NO;
    BOOL anchored = cog == anchoredCog && constraints.count > 0;
    if (anchored) {
        // Re-parenting the cog during rotation/fullscreen transitions makes
        // UIKit auto-remove our cross-view constraints while the view pointer
        // stays identical — rebuild whenever the constraints died.
        for (NSLayoutConstraint *constraint in constraints) {
            if (!constraint.isActive) { anchored = NO; break; }
        }
    }
    if (anchored) return;
    if (constraints != nil) [NSLayoutConstraint deactivateConstraints:constraints];
    objc_setAssociatedObject(window, CogAnchorKey, cog, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    constraints = @[
        [button.centerXAnchor constraintEqualToAnchor:cog.centerXAnchor],
        [button.topAnchor constraintEqualToAnchor:cog.bottomAnchor constant:8]
    ];
    [NSLayoutConstraint activateConstraints:constraints];
    objc_setAssociatedObject(window, CogConstraintsKey, constraints, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    YTRCLog(@{@"event": @"launcher-anchor", @"anchor": NSStringFromClass(cog.class)});
}
// Controls visibility hooks: fade with the chrome; hiding the chrome also
// collapses any open menu (its anchor is gone).
+ (void)setVisible:(BOOL)visible {
    UIButton *button = YTRCOverlayButton;
    if (button == nil) return;
    if (!visible) YTRCMenuDismiss();
    button.userInteractionEnabled = visible;
    [UIView animateWithDuration:0.2 animations:^{ button.alpha = visible ? 1.0 : 0.0; }];
    // Rotation and fullscreen transitions rebuild the chrome after the final
    // visibility flip; re-check the anchor once the new layout has settled.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *window = YTRCOverlayButton.window;
        if (window != nil) [YTRCLauncher overlay:window];
    });
}
+ (void)toggle:(UIButton *)sender {
    if (YTRCMenuContainer != nil) YTRCMenuDismiss();
    else YTRCMenuShow(sender);
}
+ (void)rowTapped:(UIButton *)row {
    dispatch_block_t action = objc_getAssociatedObject(row, MenuRowKey);
    YTRCMenuDismiss();
    if (action != nil) action();
}
+ (void)backdropTapped {
    YTRCMenuDismiss();
}
+ (void)showAiGuidance:(NSString *)status fromButton:(UIButton *)button {
    UIViewController *host = button.window.rootViewController;
    while (host.presentedViewController != nil) host = host.presentedViewController;
    if (host == nil) return;
    YTAIShowGuidanceAlert(status, host);
}

+ (void)showAiResult:(NSString *)text fromButton:(UIButton *)button {
    UIViewController *host = button.window.rootViewController;
    while (host.presentedViewController != nil) host = host.presentedViewController;
    if (host == nil) return;
    YTAIShowResultModal(text, host);
}
+ (void)show:(UIButton *)sender {
    UIViewController *host = sender.window.rootViewController;
    while (host.presentedViewController != nil) host = host.presentedViewController;
    if ([host isKindOfClass:UINavigationController.class] &&
        [((UINavigationController *)host).topViewController isKindOfClass:YTRCController.class]) return;
    YTRCController *controller = [[YTRCController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    [host presentViewController:navigation animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void YTRCStart(void) {
    @autoreleasepool {
        [NSUserDefaults.standardUserDefaults registerDefaults:@{
            EnabledKey: @NO,
            RecommendKey: @NO,
            SubsKey: @NO,
            SearchKey: @NO,
            @"YTKACE.Recommendations.ServerURL": @"",
            @"YTKACE.Recommendations.ServerToken": @"",
            @"YTKACE.Recommendations.TimeoutMS": @2000,
            @"YTKACE.Recommendations.MaxPayloadBytes": @(8 * 1024 * 1024),
            MaxInFlightKey: @8,
            MarkerFieldKey: @90001,
            DiagnosticsKey: @YES,
        }];
        YTRCLog(@{@"event": @"startup", @"module": @"recommendations", @"protocolVersion": @(YTRCProtocolVersion)});
        YTRCInstallHooks();
        // YTSettingsViewController can arrive after launch (same pattern the
        // released YTKACE uses for its native settings hooks).
        static dispatch_once_t retryOnce;
        dispatch_once(&retryOnce, ^{
            for (NSUInteger attempt = 1; attempt <= 60; attempt++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(attempt * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{ YTRCInstallHooks(); });
            }
        });
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                YTRCInstallHooks();
            }];
        // Rotation/fullscreen transitions rebuild the player chrome, sometimes
        // without a layout tick on our hooked overlay classes; re-anchor the
        // launcher directly once the orientation settles.
        [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
        [NSNotificationCenter.defaultCenter addObserverForName:UIDeviceOrientationDidChangeNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
                YTRCMenuDismiss();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    UIWindow *window = YTRCOverlayButton.window;
                    if (window != nil) [YTRCLauncher overlay:window];
                });
            }];
    }
}
