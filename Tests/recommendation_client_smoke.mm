// End-to-end host smoke test: the real RecommendationClient talks to the real
// mock-recommendation-server.py over HTTP. REC_SERVER_URL must point at a
// server base URL (no path) running with --action replace; REC_SERVER_TOKEN is
// optional. Verifies §99 routing (watch posts to /yt-next), the
// Authorization header, the marker echo, and that an unreachable URL yields an
// error reply (the patch's fallback trigger).

#import <Foundation/Foundation.h>
#import "../Tweak/Features/Recommendations/RecommendationClient.h"
#import "../Tweak/Features/Recommendations/RecommendationCodec.h"

static NSUInteger Checks;
#define CHECK(value) do { Checks++; if (!(value)) { \
    fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #value); return 1; } } while (0)

static void WaitFor(BOOL (^finished)(void)) {
    // Session completions arrive on dispatch queues, not the main run loop;
    // poll with short wakeups so the flag check actually re-runs.
    while (!finished())
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                              beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

int main(void) {
    @autoreleasepool {
        NSString *url = [NSProcessInfo.processInfo environment][@"REC_SERVER_URL"];
        if (url.length == 0) {
            fprintf(stderr, "REC_SERVER_URL is required\n");
            return 2;
        }
        NSString *token = [NSProcessInfo.processInfo environment][@"REC_SERVER_TOKEN"] ?: @"";
        // setObject, not registerDefaults: NSUserDefaults persistent values from
        // earlier runs (this test writes an unreachable URL at the end) would
        // otherwise shadow the registered defaults.
        [NSUserDefaults.standardUserDefaults setObject:url forKey:@"YTKACE.Recommendations.ServerURL"];
        [NSUserDefaults.standardUserDefaults setObject:token forKey:@"YTKACE.Recommendations.ServerToken"];
        [NSUserDefaults.standardUserDefaults setObject:@2000 forKey:@"YTKACE.Recommendations.TimeoutMS"];
        [NSUserDefaults.standardUserDefaults setObject:@(1024 * 1024) forKey:@"YTKACE.Recommendations.MaxPayloadBytes"];

        const uint8_t raw[] = {0x08, 0x01};
        NSData *payload = [NSData dataWithBytes:raw length:sizeof(raw)];
        __block BOOL transformed = NO;
        __block YTRCTransformReply *reply = nil;
        __block NSError *transformError = nil;
        // Surface watch must route to /yt-next (the /next InnerTube operation) on the base URL.
        YTRCRequestTransform(payload, @"watch", @"initial", @"vid-1", nil, @"YTIWatchNextResponse",
            ^(YTRCTransformReply *result, NSError *error) {
                reply = result;
                transformError = error;
                transformed = YES;
            });
        WaitFor(^{ return transformed; });
        if (transformError != nil)
            fprintf(stderr, "transform error: %s\n", transformError.localizedDescription.UTF8String ?: "?");
        CHECK(transformError == nil && reply != nil);
        CHECK([reply.action isEqualToString:YTRCActionReplace()]);
        CHECK(reply.payload.length == payload.length + YTRCMarkerFieldBytes(90001).length);
        NSData *head = [reply.payload subdataWithRange:NSMakeRange(0, payload.length)];
        CHECK([head isEqual:payload]); // original bytes come back unchanged
        CHECK(YTRCPayloadHasMarker(reply.payload, 90001));
        NSString *fingerprint = YTRCSha256Prefix(reply.payload);
        CHECK(fingerprint.length == 16);
        CHECK(![fingerprint isEqualToString:YTRCSha256Prefix(payload)]);

        // The probe reports the last POST's path and Authorization header, so
        // this also asserts the §99 routing and the token header.
        __block BOOL probed = NO;
        __block NSDictionary *health = nil;
        __block NSError *probeError = nil;
        YTRCProbeServer(^(NSDictionary *result, NSError *error) {
            health = result;
            probeError = error;
            probed = YES;
        });
        WaitFor(^{ return probed; });
        CHECK(probeError == nil && health != nil);
        CHECK([health[@"protocolVersion"] isEqual:@1]);
        CHECK([health[@"service"] isKindOfClass:NSString.class]);
        CHECK([health[@"lastPath"] isEqual:@"/yt-next"]);
        if (token.length != 0)
            CHECK([health[@"lastAuth"] isEqualToString:[@"Bearer " stringByAppendingString:token]]);
        else
            CHECK(health[@"lastAuth"] == nil);

        // Unreachable endpoint must produce an error (never a fake reply).
        [NSUserDefaults.standardUserDefaults setObject:@"http://127.0.0.1:1/x"
                                                forKey:@"YTKACE.Recommendations.ServerURL"];
        __block BOOL failed = NO;
        __block YTRCTransformReply *failedReply = nil;
        YTRCRequestTransform(payload, @"home", @"continuation", nil, nil, @"YTIBrowseResponse",
            ^(YTRCTransformReply *result, NSError *error) {
                NSCAssert(error != nil, @"unreachable endpoint must surface an error");
                failedReply = result;
                failed = YES;
            });
        WaitFor(^{ return failed; });
        CHECK(failedReply == nil);

        fprintf(stdout, "Passed %lu client smoke checks\n", (unsigned long)Checks);
    }
    return 0;
}
