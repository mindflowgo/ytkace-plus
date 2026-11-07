#import "RecommendationClient.h"
#import "RecommendationCodec.h"

NSString *YTRCActionReplace(void) { return @"replace"; }
NSString *YTRCActionPassthrough(void) { return @"passthrough"; }
NSUInteger const YTRCProtocolVersion = 1;
NSString * const YTRCServerTokenKey = @"YTKACE.Recommendations.ServerToken";
NSString * const YTRCTimeoutKey = @"YTKACE.Recommendations.TimeoutMS";

static NSString *YTRCServerURLKey = @"YTKACE.Recommendations.ServerURL";
static NSString *YTRCMaxPayloadKey = @"YTKACE.Recommendations.MaxPayloadBytes";
static const NSUInteger YTRCFallbackMaxPayloadBytes = 8 * 1024 * 1024;
static const NSUInteger YTRCFallbackTimeoutMS = 300; // Default 300 ms

NSUInteger YTRCConfiguredTimeoutMS(void) {
    id val = [NSUserDefaults.standardUserDefaults objectForKey:YTRCTimeoutKey];
    if (val != nil) {
        NSInteger intVal = [val integerValue];
        if (intVal > 0) return (NSUInteger)intVal;
    }
    return YTRCFallbackTimeoutMS;
}

NSTimeInterval YTRCConfiguredTimeout(void) {
    return (NSTimeInterval)YTRCConfiguredTimeoutMS() / 1000.0;
}

NSURL *YTRCEndpointForBaseURL(NSURL *base, NSString *surface) {
    // One canonical endpoint set, per §99. The configured ServerURL is the
    // server BASE ONLY (scheme://host[:port]); there are no alternate or
    // legacy URL forms — a configured URL that includes a path is rejected.
    // Endpoints follow the InnerTube operation:
    //   /yt-browse — every browse-family page (Home, category chips, tabs,
    //                subscriptions/history/other browse IDs, teasers, …)
    //   /yt-next   — watch page + related-list pages
    //   /yt-search — search results
    // /player (playback) is not intercepted at all.
    NSString *path = nil;
    if ([surface isEqualToString:@"watch"]) path = @"/yt-next";
    else if ([surface isEqualToString:@"search"]) path = @"/yt-search";
    else if ([surface isEqualToString:@"shorts"]) path = @"/yt-reels"; // YouTube's /reel/reel_watch_sequence
    else path = @"/yt-browse"; // home, browse IDs, unresolved browse — all /browse-family.
    if (base == nil) return nil;
    NSString *scheme = base.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return nil;
    NSString *host = base.host;
    if (host.length == 0) return nil;
    NSString *configuredPath = base.path;
    if (configuredPath.length != 0 && ![configuredPath isEqualToString:@"/"]) return nil;
    NSMutableString *endpoint = [NSMutableString stringWithFormat:@"%@://%@", scheme, host];
    if (base.port != nil) [endpoint appendFormat:@":%@", base.port];
    [endpoint appendString:path];
    return [NSURL URLWithString:endpoint];
}

// §99: no auth enforcement, but a configurable token-key identifies the client.
static void YTRCApplyAuthorization(NSMutableURLRequest *request) {
    NSString *token = [NSUserDefaults.standardUserDefaults stringForKey:YTRCServerTokenKey];
    if (token.length != 0)
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
}

static dispatch_queue_t YTRCClientQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("ytkace.recommendations.client", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

@implementation YTRCTransformReply
- (instancetype)initWithAction:(NSString *)action payload:(NSData *)payload statusCode:(NSInteger)statusCode notModified:(BOOL)notModified {
    self = [super init];
    if (self) {
        _action = [action copy];
        _payload = payload;
        _statusCode = statusCode;
        _notModified = notModified;
    }
    return self;
}
- (instancetype)initWithAction:(NSString *)action payload:(NSData *)payload {
    return [self initWithAction:action payload:payload statusCode:200 notModified:NO];
}
@end

NSDictionary *YTRCCaptureRequestContext(id request) {
    if (request == nil) return nil;
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    // The request object is a protobuf message; serializing it captures the
    // complete request context (browseId, params, continuation, query, client
    // info) without depending on individual property names. Requests are a few
    // KB; the cap only guards against surprises.
    NSData *bytes = YTRCSerializeMessage(request, 512 * 1024, nullptr);
    if (bytes.length != 0)
        context[@"requestPayload"] = [bytes base64EncodedStringWithOptions:0];
    // Flat copies make the log readable even if a build renames a property.
    for (NSString *key in @[@"browseId", @"continuation", @"params", @"query", @"videoId"]) {
        id value = YTRCObject(request, key);
        if ([value isKindOfClass:NSString.class] && [(NSString *)value length] != 0 &&
            [(NSString *)value length] <= 16 * 1024) {
            context[key] = value;
        }
    }
    NSString *className = NSStringFromClass([request class]);
    if (className.length != 0) context[@"requestClass"] = className;
    return context.count != 0 ? [context copy] : nil;
}

NSDictionary *YTRCBuildEnvelope(NSString *requestId, NSString *surface, NSString *phase,
                                NSString *videoId, NSDictionary *requestContext,
                                NSString *responseType,
                                NSString *youtubeVersion, NSData *payload) {
    NSMutableDictionary *context = [NSMutableDictionary dictionary];
    if (requestContext.count != 0) [context addEntriesFromDictionary:requestContext];
    if (videoId.length != 0) context[@"videoId"] = videoId;
    return @{@"protocolVersion": @(YTRCProtocolVersion),
             @"mode": @"transform",
             @"requestId": requestId,
             @"surface": surface,
             @"phase": phase,
             @"youtubeVersion": youtubeVersion ?: @"unknown",
             @"responseType": responseType,
             @"context": context,
             @"encoding": @"protobuf-base64",
             @"payload": [payload base64EncodedStringWithOptions:0]};
}

static BOOL YTRCIsNumberWithValue(id value, long long expected) {
    return [value isKindOfClass:NSNumber.class] && [value longLongValue] == expected;
}

YTRCTransformReply *YTRCDecodeTransformReply(NSData *body, NSString *expectedRequestId,
                                             NSUInteger maxPayloadBytes, NSError **error) {
    if (body.length == 0) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:20
                userInfo:@{NSLocalizedDescriptionKey: @"empty reply body"}];
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:21
                userInfo:@{NSLocalizedDescriptionKey: @"reply is not a JSON object"}];
        return nil;
    }
    NSDictionary *reply = json;
    if (!YTRCIsNumberWithValue(reply[@"protocolVersion"], YTRCProtocolVersion)) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:22
                userInfo:@{NSLocalizedDescriptionKey: @"unsupported protocolVersion"}];
        return nil;
    }
    if (![reply[@"requestId"] isKindOfClass:NSString.class] ||
        ![reply[@"requestId"] isEqualToString:expectedRequestId]) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:23
                userInfo:@{NSLocalizedDescriptionKey: @"requestId mismatch"}];
        return nil;
    }
    NSString *action = [reply[@"action"] isKindOfClass:NSString.class] ? reply[@"action"] : nil;
    if (![action isEqualToString:YTRCActionReplace()] && ![action isEqualToString:YTRCActionPassthrough()]) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:24
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"unknown action %@", action ?: @"(missing)"]}];
        return nil;
    }
    if ([action isEqualToString:YTRCActionPassthrough()])
        return [[YTRCTransformReply alloc] initWithAction:action payload:nil statusCode:200 notModified:NO];
    if (![reply[@"encoding"] isKindOfClass:NSString.class] ||
        ![reply[@"encoding"] isEqualToString:@"protobuf-base64"]) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:25
                userInfo:@{NSLocalizedDescriptionKey: @"replace reply has an unsupported encoding"}];
        return nil;
    }
    if (![reply[@"payload"] isKindOfClass:NSString.class]) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:26
                userInfo:@{NSLocalizedDescriptionKey: @"replace reply payload is missing"}];
        return nil;
    }
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:reply[@"payload"]
                                                          options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (decoded == nil) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:27
                userInfo:@{NSLocalizedDescriptionKey: @"replace reply payload is not valid base64"}];
        return nil;
    }
    if (decoded.length == 0 || decoded.length > maxPayloadBytes) {
        if (error != nullptr)
            *error = [NSError errorWithDomain:YTRCDomain() code:28
                userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:
                    @"replacement payload is empty or exceeds the %lu byte cap", (unsigned long)maxPayloadBytes]}];
        return nil;
    }
    return [[YTRCTransformReply alloc] initWithAction:action payload:decoded statusCode:200 notModified:NO];
}

void YTRCSendPlaybackEvent(NSString *event, NSString *videoId, NSDictionary *detail) {
    // Same base URL + auth as transforms, dedicated /yt-playback endpoint.
    NSString *serverURL = [NSUserDefaults.standardUserDefaults stringForKey:YTRCServerURLKey];
    NSURL *base = serverURL.length != 0 ? [NSURL URLWithString:serverURL] : nil;
    if (YTRCEndpointForBaseURL(base, @"home") == nil) return; // no configured server
    NSMutableString *endpoint = [NSMutableString stringWithFormat:@"%@://%@",
        base.scheme.lowercaseString, base.host];
    if (base.port != nil) [endpoint appendFormat:@":%@", base.port];
    [endpoint appendString:@"/yt-playback"];
    NSMutableDictionary *record = [@{
        @"protocolVersion": @(YTRCProtocolVersion),
        @"type": @"playback",
        @"requestId": NSUUID.UUID.UUIDString,
        @"event": event,
        @"youtubeVersion": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
    } mutableCopy];
    if (videoId.length != 0) record[@"videoId"] = videoId;
    if (detail != nil) record[@"detail"] = detail;
    NSError *encodeError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:record options:0 error:&encodeError];
    if (body == nil) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = 2.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    YTRCApplyAuthorization(request);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:nil delegateQueue:[NSOperationQueue new]];
    [[session dataTaskWithRequest:request completionHandler:^(__unused NSData *data,
                                                              __unused NSURLResponse *response,
                                                              __unused NSError *error) {
        [session finishTasksAndInvalidate];
    }] resume];
}

void YTRCSendSaveRequest(NSString *videoId, BOOL aiEnhanced, NSData *transcript,
                         NSString *transcriptEncoding, NSString *transcriptStatus,
                         NSString *aiSummary, NSString *aiStatus,
                         void (^completion)(BOOL, NSString *)) {
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(ok, message); });
    };
    if (![videoId isKindOfClass:NSString.class] || videoId.length != 11) {
        finish(NO, @"No active video");
        return;
    }
    // Same base URL + auth as playback events, dedicated /yt-save endpoint.
    NSString *serverURL = [NSUserDefaults.standardUserDefaults stringForKey:YTRCServerURLKey];
    NSURL *base = serverURL.length != 0 ? [NSURL URLWithString:serverURL] : nil;
    if (YTRCEndpointForBaseURL(base, @"home") == nil) {
        finish(NO, @"No server URL configured");
        return;
    }
    NSMutableString *endpoint = [NSMutableString stringWithFormat:@"%@://%@",
        base.scheme.lowercaseString, base.host];
    if (base.port != nil) [endpoint appendFormat:@":%@", base.port];
    [endpoint appendString:@"/yt-save"];
    NSMutableDictionary *record = [@{
        @"protocolVersion": @(YTRCProtocolVersion),
        @"type": @"save",
        @"requestId": NSUUID.UUID.UUIDString,
        @"videoId": videoId,
        @"ai": @(aiEnhanced),
        @"youtubeVersion": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown",
    } mutableCopy];
    if (transcript.length != 0) {
        record[@"transcriptEncoding"] = transcriptEncoding.length != 0 ? transcriptEncoding : @"youtube-json3";
        record[@"transcriptPayload"] = [transcript base64EncodedStringWithOptions:0];
    }
    if (transcriptStatus.length != 0) record[@"transcriptStatus"] = transcriptStatus;
    if (aiSummary.length != 0) record[@"aiSummary"] = aiSummary;
    if (aiStatus.length != 0) record[@"aiStatus"] = aiStatus;
    NSError *encodeError = nil;
    NSData *body = [NSJSONSerialization dataWithJSONObject:record options:0 error:&encodeError];
    if (body == nil) {
        finish(NO, @"Request encoding failed");
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = 4.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    YTRCApplyAuthorization(request);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:nil delegateQueue:[NSOperationQueue new]];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response,
                                                              NSError *taskError) {
        [session finishTasksAndInvalidate];
        if (taskError != nil) {
            finish(NO, taskError.localizedDescription);
            return;
        }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode != 200) {
            finish(NO, [NSString stringWithFormat:@"Server returned HTTP %ld", (long)http.statusCode]);
            return;
        }
        id json = data.length != 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL ok = [json isKindOfClass:NSDictionary.class] && [((NSDictionary *)json)[@"ok"] boolValue];
        finish(ok, ok ? @"Saved" : @"Server rejected the save");
    }] resume];
}

void YTRCProbeServer(void (^completion)(NSDictionary *, NSError *)) {
    NSString *serverURL = [NSUserDefaults.standardUserDefaults stringForKey:YTRCServerURLKey];
    NSURL *url = serverURL.length != 0 ? [NSURL URLWithString:serverURL] : nil;
    if (YTRCEndpointForBaseURL(url, @"home") == nil) url = nil;
    if (url == nil) {
        dispatch_async(YTRCClientQueue(), ^{ completion(nil, [NSError errorWithDomain:YTRCDomain() code:30
            userInfo:@{NSLocalizedDescriptionKey: @"no valid server URL configured"}]); });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 5.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    YTRCApplyAuthorization(request);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:nil delegateQueue:[NSOperationQueue new]];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        [session finishTasksAndInvalidate];
        void (^finish)(NSDictionary *, NSError *) = ^(NSDictionary *health, NSError *error) {
            dispatch_async(YTRCClientQueue(), ^{ completion(health, error); });
        };
        if (taskError != nil) { finish(nil, taskError); return; }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode != 200) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:32 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"probe returned HTTP %ld", (long)http.statusCode]}]);
            return;
        }
        id json = data.length != 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class] ||
            !YTRCIsNumberWithValue(((NSDictionary *)json)[@"protocolVersion"], YTRCProtocolVersion)) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:33
                userInfo:@{NSLocalizedDescriptionKey: @"endpoint did not advertise protocolVersion 1"}]);
            return;
        }
        finish(json, nil);
    }] resume];
}

void YTRCFetchServerSettings(void (^completion)(NSArray<NSString *> *aiPrompts, NSError *error)) {
    NSString *serverURL = [NSUserDefaults.standardUserDefaults stringForKey:YTRCServerURLKey];
    NSURL *baseURL = serverURL.length != 0 ? [NSURL URLWithString:serverURL] : nil;
    if (baseURL == nil || baseURL.host.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:YTRCDomain() code:30
                userInfo:@{NSLocalizedDescriptionKey: @"no valid server URL configured"}]);
        });
        return;
    }
    NSString *str = baseURL.absoluteString;
    while ([str hasSuffix:@"/"]) str = [str substringToIndex:str.length - 1];
    NSURL *url = [NSURL URLWithString:[str stringByAppendingString:@"/yt-settings"]];
    if (url == nil) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil, [NSError errorWithDomain:YTRCDomain() code:31
                userInfo:@{NSLocalizedDescriptionKey: @"invalid settings URL"}]);
        });
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 4.0;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    YTRCApplyAuthorization(request);
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:nil delegateQueue:[NSOperationQueue new]];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        [session finishTasksAndInvalidate];
        void (^finish)(NSArray<NSString *> *, NSError *) = ^(NSArray<NSString *> *prompts, NSError *err) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(prompts, err); });
        };
        if (taskError != nil) { finish(nil, taskError); return; }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode != 200) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:32 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"settings returned HTTP %ld", (long)http.statusCode]}]);
            return;
        }
        id json = data.length != 0 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:33
                userInfo:@{NSLocalizedDescriptionKey: @"settings response is not a JSON object"}]);
            return;
        }
        if (!YTRCIsNumberWithValue(((NSDictionary *)json)[@"protocolVersion"], YTRCProtocolVersion)) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:36
                userInfo:@{NSLocalizedDescriptionKey: @"unsupported settings protocolVersion"}]);
            return;
        }
        NSArray *prompts = ((NSDictionary *)json)[@"aiPrompts"];
        if (![prompts isKindOfClass:NSArray.class] || prompts.count == 0) {
            prompts = ((NSDictionary *)json)[@"prompts"];
        }
        if (![prompts isKindOfClass:NSArray.class] || prompts.count == 0) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:34
                userInfo:@{NSLocalizedDescriptionKey: @"no aiPrompts in settings response"}]);
            return;
        }
        NSMutableArray<NSString *> *validPrompts = [NSMutableArray array];
        for (id p in prompts) {
            if ([p isKindOfClass:NSString.class] && [(NSString *)p length] > 0) {
                [validPrompts addObject:(NSString *)p];
            }
        }
        if (validPrompts.count == 0) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:35
                userInfo:@{NSLocalizedDescriptionKey: @"empty aiPrompts in settings response"}]);
            return;
        }
        finish(validPrompts, nil);
    }] resume];
}

void YTRCRequestTransform(NSData *payload, NSString *surface, NSString *phase,
                          NSString *videoId, NSDictionary *requestContext,
                          NSString *responseType,
                          void (^completion)(YTRCTransformReply *, NSError *)) {
    NSString *requestId = NSUUID.UUID.UUIDString;
    NSString *serverURL = [NSUserDefaults.standardUserDefaults stringForKey:YTRCServerURLKey];
    NSTimeInterval timeout = YTRCConfiguredTimeout();
    NSUInteger maxPayloadBytes = [NSUserDefaults.standardUserDefaults objectForKey:YTRCMaxPayloadKey] != nil
        ? (NSUInteger)[NSUserDefaults.standardUserDefaults integerForKey:YTRCMaxPayloadKey]
        : YTRCFallbackMaxPayloadBytes;
    if (maxPayloadBytes == 0) maxPayloadBytes = YTRCFallbackMaxPayloadBytes;
    NSString *youtubeVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"unknown";

    void (^finish)(YTRCTransformReply *, NSError *) = ^(YTRCTransformReply *reply, NSError *error) {
        dispatch_async(YTRCClientQueue(), ^{ completion(reply, error); });
    };
    NSURL *url = serverURL.length != 0 ? [NSURL URLWithString:serverURL] : nil;
    url = YTRCEndpointForBaseURL(url, surface);
    if (url == nil || payload == nil) {
        finish(nil, [NSError errorWithDomain:YTRCDomain() code:30
            userInfo:@{NSLocalizedDescriptionKey: @"transform skipped: ServerURL must be the server base "
                      "(scheme://host[:port], no path); the patch appends /yt-browse or /yt-next"}]);
        return;
    }

    NSError *encodeError = nil;
    NSDictionary *envelope = YTRCBuildEnvelope(requestId, surface, phase, videoId, requestContext,
                                               responseType, youtubeVersion, payload);
    NSData *body = [NSJSONSerialization dataWithJSONObject:envelope options:0 error:&encodeError];
    if (body == nil) {
        finish(nil, encodeError ?: [NSError errorWithDomain:YTRCDomain() code:31
            userInfo:@{NSLocalizedDescriptionKey: @"envelope encoding failed"}]);
        return;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    request.timeoutInterval = timeout;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    YTRCApplyAuthorization(request);

    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.HTTPShouldSetCookies = NO;
    configuration.HTTPShouldUsePipelining = NO;
    configuration.timeoutIntervalForRequest = timeout;
    configuration.timeoutIntervalForResource = timeout + 5.0;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration
                                                        delegate:nil delegateQueue:[NSOperationQueue new]];
    NSString *capturedRequestId = requestId;
    NSUInteger capturedCap = maxPayloadBytes;
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *taskError) {
        [session finishTasksAndInvalidate];
        if (taskError != nil) { finish(nil, taskError); return; }
        NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
        if (http.statusCode == 304) {
            YTRCTransformReply *reply = [[YTRCTransformReply alloc] initWithAction:YTRCActionPassthrough()
                                                                           payload:nil
                                                                        statusCode:304
                                                                       notModified:YES];
            finish(reply, nil);
            return;
        }
        if (http.statusCode != 200) {
            finish(nil, [NSError errorWithDomain:YTRCDomain() code:32 userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"server returned HTTP %ld", (long)http.statusCode]}]);
            return;
        }
        NSError *decodeError = nil;
        YTRCTransformReply *reply = YTRCDecodeTransformReply(data, capturedRequestId, capturedCap, &decodeError);
        finish(reply, decodeError);
    }] resume];
}
