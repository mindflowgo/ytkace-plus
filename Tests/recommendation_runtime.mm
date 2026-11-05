// Host runtime checks for the production recommendations module:
// callback wrapping, codec (serialize/parse/marker), client protocol
// validation, and delivery-state semantics. Foundation-only; no YouTube classes.

#import <Foundation/Foundation.h>
#import "../Tweak/Features/Recommendations/RecommendationRuntime.h"
#import "../Tweak/Features/Recommendations/RecommendationCodec.h"
#import "../Tweak/Features/Recommendations/RecommendationClient.h"
#import "../Tweak/Features/Recommendations/RecommendationDelivery.h"

static NSUInteger Checks;
#define CHECK(value) do { Checks++; if (!(value)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); return 1; } } while (0)

@interface GoogleGlobalExtensionRegistry : NSObject
+ (id)extensionRegistry;
@end
@implementation GoogleGlobalExtensionRegistry
+ (id)extensionRegistry { return @"fixture-registry"; }
@end

// Minimal protobuf-like fixture: payload bytes round-trip verbatim, so a
// marker appended by the "server" survives parse exactly like a GPBMessage
// unknown field would.
@interface YTRCFixtureMessage : NSObject
@property(nonatomic, copy) NSData *payload;
@property(nonatomic) BOOL usedRegistry;
+ (id)parseFromData:(NSData *)data extensionRegistry:(id)registry error:(NSError **)error;
+ (id)parseFromData:(NSData *)data error:(NSError **)error;
@end
@implementation YTRCFixtureMessage
+ (id)parseFromData:(NSData *)data extensionRegistry:(id)registry error:(NSError **)error {
    if (data.length == 0) { if (error) *error = [NSError errorWithDomain:@"fixture" code:1 userInfo:nil]; return nil; }
    YTRCFixtureMessage *message = [self new];
    message.payload = data;
    message.usedRegistry = [registry isEqual:@"fixture-registry"];
    return message;
}
+ (id)parseFromData:(NSData *)data error:(NSError **)error {
    return [self parseFromData:data extensionRegistry:(id)self error:error];
}
- (NSUInteger)serializedSize { return self.payload.length; }
- (NSData *)data { return self.payload; }
- (BOOL)isEqual:(id)object {
    return [object isKindOfClass:self.class] && [self.payload isEqual:((YTRCFixtureMessage *)object).payload];
}
@end

// A fixture that misreports its serialized size to exercise the cap.
@interface YTRCOvergrownMessage : YTRCFixtureMessage
@end
@implementation YTRCOvergrownMessage
- (NSUInteger)serializedSize { return 1 << 30; }
@end

// A fixture that parses into a DIFFERENT class (rejection case).
@interface YTRCOtherMessage : NSObject
+ (id)parseFromData:(NSData *)data extensionRegistry:(id)registry error:(NSError **)error;
@end
@implementation YTRCOtherMessage
+ (id)parseFromData:(NSData *)data extensionRegistry:(id)registry error:(NSError **)error {
    return [YTRCFixtureMessage new];
}
@end

static NSData *FixturePayload(void) {
    const uint8_t raw[] = {0x08, 0x01}; // field 1 varint 1
    return [NSData dataWithBytes:raw length:sizeof(raw)];
}

int main(void) {
    @autoreleasepool {
        NSError *error = nil;

        // ----- Runtime: callback wrapping preserves arguments and substitutes responses -----
        BOOL wrapped = NO;
        __block NSUInteger calls = 0;
        __block id received = nil;
        NSError *borrowedError = [NSError errorWithDomain:@"fixture" code:7 userInfo:nil];
        void (^completion)(id, NSError *) = ^(id response, NSError *argument) {
            calls++;
            received = response;
            NSCAssert(argument == borrowedError, @"NSError argument changed");
        };
        id block = YTRCWrapDelivery(completion, ^id(id response, NSNumber *aux) {
            NSCAssert(aux == nil, @"two-argument delivery must not report an auxiliary");
            return @"replacement";
        }, &wrapped);
        CHECK(wrapped);
        ((void (^)(id, NSError *))block)(@"original", borrowedError);
        CHECK(calls == 1 && [received isEqual:@"replacement"]);

        __block bool receivedFlag = false;
        void (^withFlag)(id, bool) = ^(id response, bool flag) { receivedFlag = flag; };
        block = YTRCWrapDelivery(withFlag, ^id(id response, NSNumber *aux) { return response; }, &wrapped);
        CHECK(wrapped);
        ((void (^)(id, bool))block)(@"same", true);
        CHECK(receivedFlag);
        block = YTRCWrapDelivery(withFlag, ^id(id response, NSNumber *aux) { return nil; }, &wrapped);
        ((void (^)(id, bool))block)(@"fallback", false);
        CHECK(!receivedFlag);
        void (^unsupported)(id, double) = ^(id response, double value) {};
        block = YTRCWrapDelivery(unsupported, ^id(id response, NSNumber *aux) { return response; }, &wrapped);
        CHECK(!wrapped && block == (id)unsupported);
        CHECK(YTRCWrapDelivery(nil, ^id(id response, NSNumber *aux) { abort(); }, &wrapped) == nil);

        Method method = class_getInstanceMethod(YTRCFixtureMessage.class, @selector(payload));
        CHECK(YTRCMethodMatches(method, "@@:"));
        CHECK(!YTRCMethodMatches(method, "v@:"));
        CHECK(!YTRCMethodMatches(nullptr, "@@:"));

        // ----- Codec -----
        YTRCFixtureMessage *message = [YTRCFixtureMessage new];
        message.payload = FixturePayload();
        NSData *serialized = YTRCSerializeMessage(message, 1024, &error);
        CHECK([serialized isEqual:FixturePayload()] && error == nil);
        CHECK(YTRCSerializeMessage(nil, 1024, &error) == nil && error != nil);
        error = nil;
        YTRCOvergrownMessage *overgrown = [YTRCOvergrownMessage new];
        overgrown.payload = FixturePayload();
        CHECK(YTRCSerializeMessage(overgrown, 1024, &error) == nil && error != nil);
        error = nil;

        // Parse rejects wrong classes and uses the registry.
        YTRCFixtureMessage *parsed = (YTRCFixtureMessage *)YTRCParseMessage(FixturePayload(), YTRCFixtureMessage.class, &error);
        CHECK(parsed != nil && error == nil && parsed.usedRegistry && [parsed.payload isEqual:FixturePayload()]);
        error = nil;
        CHECK(YTRCParseMessage([NSData data], YTRCFixtureMessage.class, &error) == nil && error != nil);
        error = nil;
        CHECK(YTRCParseMessage(FixturePayload(), YTRCOtherMessage.class, &error) == nil && error != nil);
        error = nil;

        // Marker bytes: varint tag (90001<<3)|2 = 720010 = 8a f9 2b, len 6, RECSRV.
        NSData *marker = YTRCMarkerFieldBytes(90001);
        const uint8_t expectedMarker[] = {0x8A, 0xF9, 0x2B, 0x06, 'R', 'E', 'C', 'S', 'R', 'V'};
        CHECK([marker isEqual:[NSData dataWithBytes:expectedMarker length:sizeof(expectedMarker)]]);
        CHECK(!YTRCPayloadHasMarker(FixturePayload(), 90001));
        NSMutableData *marked = [FixturePayload() mutableCopy];
        [marked appendData:marker];
        CHECK(YTRCPayloadHasMarker(marked, 90001));
        NSMutableData *surrounded = [NSMutableData data];
        [surrounded appendBytes:"\x01\x02" length:2];
        [surrounded appendData:marker];
        [surrounded appendBytes:"\x03" length:1];
        CHECK(YTRCPayloadHasMarker(surrounded, 90001));
        CHECK(!YTRCPayloadHasMarker(nil, 90001));
        NSString *fingerprint = YTRCSha256Prefix(FixturePayload());
        CHECK(fingerprint.length == 16);
        CHECK([fingerprint isEqualToString:YTRCSha256Prefix(FixturePayload())]);
        CHECK(![fingerprint isEqualToString:YTRCSha256Prefix(marked)]);

        // ----- Client protocol -----
        NSDictionary *envelope = YTRCBuildEnvelope(@"req-9", @"watch", @"initial", @"vid-1", nil,
                                                   @"YTIWatchNextResponse", @"21.33.6", FixturePayload());
        CHECK([envelope[@"protocolVersion"] isEqual:@1]);
        CHECK([envelope[@"mode"] isEqualToString:@"transform"]);
        CHECK([envelope[@"requestId"] isEqualToString:@"req-9"]);
        CHECK([envelope[@"surface"] isEqualToString:@"watch"]);
        CHECK([envelope[@"phase"] isEqualToString:@"initial"]);
        CHECK([envelope[@"context"][@"videoId"] isEqualToString:@"vid-1"]);
        CHECK([envelope[@"encoding"] isEqualToString:@"protobuf-base64"]);
        CHECK([envelope[@"responseType"] isEqualToString:@"YTIWatchNextResponse"]);
        CHECK([[NSData alloc] initWithBase64EncodedString:envelope[@"payload"] options:0] != nil);
        NSDictionary *homeEnvelope = YTRCBuildEnvelope(@"req-9", @"home", @"continuation", nil, nil,
                                                       @"YTIBrowseResponse", @"21.33.6", FixturePayload());
        CHECK(homeEnvelope[@"context"][@"videoId"] == nil);

        // Request-context capture: serialized request bytes + flat fields.
        YTRCFixtureMessage *requestFixture = [YTRCFixtureMessage new];
        requestFixture.payload = FixturePayload();
        NSDictionary *capturedRequest = YTRCCaptureRequestContext(requestFixture);
        CHECK([capturedRequest[@"requestClass"] isEqualToString:@"YTRCFixtureMessage"]);
        CHECK([[[NSData alloc] initWithBase64EncodedString:capturedRequest[@"requestPayload"] options:0]
              isEqual:FixturePayload()]);
        CHECK(YTRCCaptureRequestContext(nil) == nil);
        NSDictionary *requestContext = @{@"browseId": @"UCHhAPWPrNJscVPZArCYLm7g",
                                         @"requestClass": @"YTIBrowseRequest"};
        NSDictionary *browseEnvelope = YTRCBuildEnvelope(@"req-10", @"UCHhAPWPrNJscVPZArCYLm7g", @"initial",
                                                         nil, requestContext, @"YTIBrowseResponse",
                                                         @"21.33.6", FixturePayload());
        CHECK([browseEnvelope[@"context"][@"browseId"] isEqualToString:@"UCHhAPWPrNJscVPZArCYLm7g"]);
        CHECK([browseEnvelope[@"context"][@"requestClass"] isEqualToString:@"YTIBrowseRequest"]);

        // ----- §99 endpoint mapping -----
        // §99 endpoints mirror the InnerTube operation: browse-family pages to
        // /yt-browse, watch to /yt-next, search to /yt-search.
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"http://192.168.1.10:8046"], @"home")
            isEqual:[NSURL URLWithString:@"http://192.168.1.10:8046/yt-browse"]]);
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"https://rec.example"], @"watch")
            isEqual:[NSURL URLWithString:@"https://rec.example/yt-next"]]);
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"http://127.0.0.1:8046/"], @"home")
            isEqual:[NSURL URLWithString:@"http://127.0.0.1:8046/yt-browse"]]);
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s"], @"search")
            isEqual:[NSURL URLWithString:@"http://s/yt-search"]]);
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s"], @"FEsubscriptions")
            isEqual:[NSURL URLWithString:@"http://s/yt-browse"]]);
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s"], @"browse-teaser")
            isEqual:[NSURL URLWithString:@"http://s/yt-browse"]]);
        CHECK([YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s"], @"browse-unknown")
            isEqual:[NSURL URLWithString:@"http://s/yt-browse"]]);
        // One canonical endpoint set: a configured URL that includes a path is
        // rejected — no endpoint names ('yt-next', 'next', legacy names) may be
        // written into the URL setting.
        CHECK(YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s/yt-next"], @"home") == nil);
        CHECK(YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s/next"], @"watch") == nil);
        CHECK(YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s/yt-browse"], @"home") == nil);
        CHECK(YTRCEndpointForBaseURL([NSURL URLWithString:@"http://s/api"], @"home") == nil);
        CHECK(YTRCEndpointForBaseURL([NSURL URLWithString:@"ftp://s"], @"home") == nil);
        CHECK(YTRCEndpointForBaseURL(nil, @"home") == nil);
        CHECK([YTRCServerTokenKey isEqualToString:@"YTKACE.Recommendations.ServerToken"]);

        NSData *body = [NSJSONSerialization dataWithJSONObject:@{
            @"protocolVersion": @1, @"requestId": @"req-9", @"action": @"replace",
            @"encoding": @"protobuf-base64", @"payload": [marked base64EncodedStringWithOptions:0]
        } options:0 error:nil];
        YTRCTransformReply *reply = YTRCDecodeTransformReply(body, @"req-9", 1024, &error);
        CHECK(reply != nil && error == nil);
        CHECK([reply.action isEqualToString:@"replace"] && [reply.payload isEqual:marked]);

        body = [NSJSONSerialization dataWithJSONObject:@{@"protocolVersion": @1, @"requestId": @"req-9",
            @"action": @"passthrough"} options:0 error:nil];
        reply = YTRCDecodeTransformReply(body, @"req-9", 1024, &error);
        CHECK(reply != nil && [reply.action isEqualToString:@"passthrough"] && reply.payload == nil);

        NSArray *violations = @[
            @[],
            @{@"payload": @"x"},
            @{@"protocolVersion": @2, @"requestId": @"req-9", @"action": @"replace",
              @"encoding": @"protobuf-base64", @"payload": @"AAA="},
            @{@"protocolVersion": @1, @"requestId": @"other", @"action": @"replace",
              @"encoding": @"protobuf-base64", @"payload": @"AAA="},
            @{@"protocolVersion": @1, @"requestId": @"req-9", @"action": @"scramble",
              @"encoding": @"protobuf-base64", @"payload": @"AAA="},
            @{@"protocolVersion": @1, @"requestId": @"req-9", @"action": @"replace", @"payload": @"AAA="},
            @{@"protocolVersion": @1, @"requestId": @"req-9", @"action": @"replace",
              @"encoding": @"json", @"payload": @"AAA="},
            @{@"protocolVersion": @1, @"requestId": @"req-9", @"action": @"replace",
              @"encoding": @"protobuf-base64", @"payload": @"!!!"},
            @{@"protocolVersion": @1, @"requestId": @"req-9", @"action": @"replace",
              @"encoding": @"protobuf-base64", @"payload": @""},
            @{@"protocolVersion": @1, @"requestId": @"req-9", @"action": @"replace",
              @"encoding": @"protobuf-base64", @"payload": [@"" stringByPaddingToLength:2048 withString:@"A" startingAtIndex:0]},
        ];
        for (NSDictionary *violation in violations) {
            NSData *violationBody = [violation count] == 0 ? [NSData data]
                : [NSJSONSerialization dataWithJSONObject:violation options:0 error:nil];
            error = nil;
            CHECK(YTRCDecodeTransformReply(violationBody, @"req-9", 1024, &error) == nil && error != nil);
        }

        // ----- Delivery state: exactly one terminal claim -----
        YTRCDeliveryState *state = [[YTRCDeliveryState alloc] initWithRequestIdentifier:@"d-1"];
        CHECK([state.requestId isEqualToString:@"d-1"]);
        CHECK(!state.isResolved);
        CHECK([state claimReplacement]);
        CHECK(state.isResolved);
        CHECK(![state claimOriginal]);
        CHECK(![state claimReplacement]);
        state = [[YTRCDeliveryState alloc] initWithRequestIdentifier:@"d-2"];
        CHECK([state claimOriginal]);
        CHECK(![state claimReplacement]);

        // Concurrent claims produce exactly one winner.
        state = [[YTRCDeliveryState alloc] initWithRequestIdentifier:@"d-3"];
        __block NSUInteger winners = 0;
        dispatch_apply(16, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t index) {
            if (index % 2 == 0 ? [state claimReplacement] : [state claimOriginal]) winners++;
        });
        CHECK(winners == 1 && state.isResolved);

        // ----- Recent payloads: first transform, then dedupe (per-key TTL) -----
        YTRCRecentPayloads *recent = [[YTRCRecentPayloads alloc] initWithCapacity:4];
        CHECK([recent shouldTransform:@"aaa" ttl:0.5]);
        CHECK(![recent shouldTransform:@"aaa" ttl:0.5]);       // same TTL window
        CHECK(![recent shouldTransform:@"aaa" ttl:300.0]);     // longer TTL still deduped
        CHECK([recent shouldTransform:@"bbb" ttl:0.5]);
        [recent clear];
        CHECK([recent shouldTransform:@"aaa" ttl:300.0]);      // cleared -> fresh
        CHECK(![recent shouldTransform:@"" ttl:300.0]);
        for (NSUInteger index = 0; index < 8; index++)
            CHECK(([recent shouldTransform:[NSString stringWithFormat:@"e-%lu", (unsigned long)index] ttl:300.0]));
        CHECK(![recent shouldTransform:@"e-7" ttl:300.0]);
        CHECK([recent shouldTransform:@"aaa" ttl:300.0]);      // evicted beyond capacity 4

        fprintf(stdout, "Passed %lu runtime checks\n", (unsigned long)Checks);
    }
    return 0;
}
