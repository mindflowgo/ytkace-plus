#import "AITranscriptHook.h"
#import "RecommendationCodec.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <ctype.h>

// ---------- AI Overview & Gemini Prompting Implementation ----------

// Retained data source references for InnerTube replays
static id YTAIFeedDataSource = nil;
static id YTAIAiDataSource = nil;
static id YTAIAttachment = nil;
static id YTAIClickTracking = nil;
static unsigned long long YTAIContinuationType = 0;
static BOOL YTAINativeCacheEnabled = NO;
static BOOL YTAINativeAlwaysParse = NO;
static BOOL YTAIHasNativeArgs = NO;
static BOOL YTAIReplayInFlight = NO;

@interface YTAISubmissionSnapshot : NSObject
@property (nonatomic, copy) NSString *token;
@property (nonatomic, assign) unsigned long long continuationType;
@property (nonatomic, strong) id attachment;
@property (nonatomic, copy) NSString *attachmentClass;
@property (nonatomic, strong) NSData *attachmentData;
@property (nonatomic, strong) id clickTracking;
@property (nonatomic, copy) NSString *clickTrackingClass;
@property (nonatomic, strong) NSData *clickTrackingData;
@property (nonatomic, assign) BOOL cacheEnabled;
@property (nonatomic, assign) BOOL alwaysParseFeedNode;
@property (nonatomic, strong) id dataSource;
@property (nonatomic, copy) NSString *dataSourceClass;
@property (nonatomic, strong) id service;
@property (nonatomic, copy) NSString *serviceClass;
@property (nonatomic, strong) id innerService;
@property (nonatomic, copy) NSString *innerServiceClass;
@property (nonatomic, copy) NSString *respSignature;
@property (nonatomic, copy) NSString *errSignature;
@property (nonatomic, copy) NSArray<NSString *> *callStack;
@property (nonatomic, copy) NSString *videoId;
@property (nonatomic, copy) NSString *conversationId;
@property (nonatomic, assign) NSTimeInterval timestamp;
@end

@implementation YTAISubmissionSnapshot
@end

static BOOL YTAIExtractSessionFromTeaserToken(NSString *teaserToken, NSString **outVideoId, NSString **outConversationId);

static YTAISubmissionSnapshot *YTAICapturedSubmissionSnapshot = nil;
static YTAISubmissionSnapshot *YTAILastContinuationSnapshot = nil;

void YTAICaptureFeedDataSource(id receiver, NSString *source) {
    if (receiver == nil) return;
    if (YTAIFeedDataSource == receiver) return;
    YTAIFeedDataSource = receiver;
    YTRCLog(@{@"event": @"ai-datasource", @"source": source ?: @"",
              @"class": NSStringFromClass([receiver class]) ?: @"?"});
}

static inline BOOL YTAIBytesContain(const uint8_t *bytes, NSUInteger length, const char *needle, NSUInteger needleLen) {
    if (bytes == NULL || needle == NULL || length < needleLen) return NO;
    return memmem(bytes, length, needle, needleLen) != NULL;
}

static id YTAICaptureLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL YTAICaptureActive = NO;
static BOOL YTAICaptureSawAnswer = NO;
static NSUInteger YTAIRunToken = 0;
static NSMutableArray *YTAICaptureItems = nil;
static NSUInteger YTAICaptureGeneration = 0;
static void (^YTAICaptureSettle)(void) = nil;
static BOOL YTAIHasWinningStrategy = NO;
static NSUInteger YTAIWinningStrategy = 0;
const void * const kYTAIDirectAttemptKey = &kYTAIDirectAttemptKey;
static BOOL YTAIPromptTypingStarted = NO;
static BOOL YTAIPromptSendAttempted = NO;
static BOOL YTAIPanelRequestObserved = NO;
static BOOL YTAISubmitRequestObserved = NO;
static NSInteger YTAIPreSubmissionItemCount = -1;

static BOOL YTAIIsComposerOrInputView(UIView * _Nullable view);
static BOOL YTAIIsUserMessageTurn(UIView * _Nullable root);
static NSInteger YTAICountPanelItems(UIView * _Nullable panel);

// ---------- Wire-Level Request & Continuation Capture ----------
static id YTAIPersistentAiDataSource = nil;
static id YTAIPersistentAiService = nil;

static void (*OriginalGTMBeginFetch)(id, SEL, id) = NULL;
static void (*OriginalMakeContinuationRequest)(id, SEL, id, unsigned long long, id, id, BOOL, BOOL, id, id, id) = NULL;
static id (*OriginalInitDataSource1)(id, SEL, id, id, id) = NULL;
static id (*OriginalInitDataSource2)(id, SEL, id, id, id) = NULL;
static void (*OriginalRegisterAttachment)(id, SEL, id, id) = NULL;
static id (*OriginalGetInnerTubeUIServiceForActiveIdentity)(id, SEL) = NULL;
static id (*OriginalForwardingTargetForSelector)(id, SEL, SEL) = NULL;
static id (*OriginalInitProxy1)(id, SEL, id, BOOL, id, id, Class) = NULL;
static id (*OriginalInitProxy2)(id, SEL, id, BOOL, id, id, Class) = NULL;
static id (*OriginalInitProxy3)(id, SEL, id, BOOL, id, Class) = NULL;
static void (*OriginalBrowseMakeRequest)(id, SEL, id, BOOL, id, id) = NULL;
static id (*OriginalBrowseContinuationRequest)(id, SEL, id, id) = NULL;
static void (*OriginalPanelMakeRequest)(id, SEL, id, BOOL, id, id) = NULL;
static id (*OriginalPanelContinuationRequest)(id, SEL, id, id) = NULL;


static BOOL YTAIIsPanelService(id service) {
    if (service == nil) return NO;
    NSString *cls = NSStringFromClass([service class]) ?: @"";
    if ([cls containsString:@"WatchNext"]) return NO;
    if ([cls containsString:@"Panel"]) return YES;
    SEL resolve = NSSelectorFromString(@"getInnerTubeUIServiceForActiveIdentity");
    if ([service respondsToSelector:resolve]) {
        id inner = ((id (*)(id, SEL))objc_msgSend)(service, resolve);
        if (inner != nil) {
            NSString *innerCls = NSStringFromClass([inner class]) ?: @"";
            if ([innerCls containsString:@"WatchNext"]) return NO;
            if ([innerCls containsString:@"Panel"]) return YES;
        }
    }
    return NO;
}

static BOOL YTAIIsPanelDataSource(id dataSource) {
    if (dataSource == nil) return NO;
    NSString *dsCls = NSStringFromClass([dataSource class]) ?: @"";
    if ([dsCls containsString:@"WatchNext"]) return NO;
    if (![dataSource respondsToSelector:@selector(service)]) return NO;
    id svc = ((id (*)(id, SEL))objc_msgSend)(dataSource, @selector(service));
    return YTAIIsPanelService(svc);
}

static void YTAICaptureAiServiceIfNeeded(id service, Class serviceClass, NSString *source) {
    if (service == nil) return;
    if (serviceClass != Nil && [NSStringFromClass(serviceClass) containsString:@"Panel"]) {
        YTAIPersistentAiService = service;
        YTRCLog(@{
            @"event": @"ai-persistent-service-captured",
            @"source": source ?: @"unknown",
            @"serviceClass": NSStringFromClass(serviceClass)
        });
        return;
    }
    if (YTAIIsPanelService(service)) {
        YTAIPersistentAiService = service;
        YTRCLog(@{
            @"event": @"ai-persistent-service-captured",
            @"source": source ?: @"unknown",
            @"serviceClass": NSStringFromClass([service class]) ?: @"?"
        });
    }
}

static id YTAIInitProxy1Hook(id self, SEL _cmd, id protocols, BOOL optionalMethods, id creationBlock, id scope, Class serviceClass) {
    id res = nil;
    if (OriginalInitProxy1 != NULL) {
        res = OriginalInitProxy1(self, _cmd, protocols, optionalMethods, creationBlock, scope, serviceClass);
    }
    YTAICaptureAiServiceIfNeeded(res, serviceClass, @"proxy-init1");
    return res;
}

static id YTAIInitProxy2Hook(id self, SEL _cmd, id protocols, BOOL optionalMethods, id creationBlock, id scope, Class serviceClass) {
    id res = nil;
    if (OriginalInitProxy2 != NULL) {
        res = OriginalInitProxy2(self, _cmd, protocols, optionalMethods, creationBlock, scope, serviceClass);
    }
    YTAICaptureAiServiceIfNeeded(res, serviceClass, @"proxy-init2");
    return res;
}

static id YTAIInitProxy3Hook(id self, SEL _cmd, id protocols, BOOL optionalMethods, id creationBlock, Class serviceClass) {
    id res = nil;
    if (OriginalInitProxy3 != NULL) {
        res = OriginalInitProxy3(self, _cmd, protocols, optionalMethods, creationBlock, serviceClass);
    }
    YTAICaptureAiServiceIfNeeded(res, serviceClass, @"proxy-init3");
    return res;
}

static void YTAIBrowseMakeRequestHook(id self, SEL _cmd, id request, BOOL refresh, id respBlock, id errBlock) {
    NSError *err = nil;
    NSData *reqData = request != nil ? YTRCSerializeMessage(request, 1024 * 1024, &err) : nil;
    NSString *reqStr = reqData.length > 0 ? [[NSString alloc] initWithData:reqData encoding:NSISOLatin1StringEncoding] : @"";
    BOOL isAi = [reqStr containsString:@"youchat"] || [reqStr containsString:@"Summarize"] || [reqStr containsString:@"kta-"];
    YTRCLog(@{
        @"event": @"ai-browse-service-make-request",
        @"serviceClass": NSStringFromClass([self class]) ?: @"?",
        @"requestClass": request != nil ? NSStringFromClass([request class]) : @"(nil)",
        @"reqBytes": @(reqData.length),
        @"isAi": @(isAi),
        @"preview": reqStr.length > 0 ? [reqStr substringToIndex:MIN((NSUInteger)160, reqStr.length)] : @""
    });
    if (OriginalBrowseMakeRequest != NULL) {
        OriginalBrowseMakeRequest(self, _cmd, request, refresh, respBlock, errBlock);
    }
}

static id YTAIBrowseContinuationRequestHook(id self, SEL _cmd, id token, id clickTracking) {
    id req = nil;
    if (OriginalBrowseContinuationRequest != NULL) {
        req = OriginalBrowseContinuationRequest(self, _cmd, token, clickTracking);
    }
    NSError *err = nil;
    NSData *reqData = req != nil ? YTRCSerializeMessage(req, 1024 * 1024, &err) : nil;
    NSString *tokenStr = [token isKindOfClass:NSString.class] ? (NSString *)token : @"";
    YTRCLog(@{
        @"event": @"ai-browse-continuation-request-built",
        @"serviceClass": NSStringFromClass([self class]) ?: @"?",
        @"requestClass": req != nil ? NSStringFromClass([req class]) : @"(nil)",
        @"reqBytes": @(reqData.length),
        @"tokenPrefix": [tokenStr substringToIndex:MIN((NSUInteger)80, tokenStr.length)]
    });
    return req;
}

static id YTAIInitDataSource1Hook(id self, SEL _cmd, id service, id feedNode, id contentsBlock) {
    id res = nil;
    if (OriginalInitDataSource1 != NULL) {
        res = OriginalInitDataSource1(self, _cmd, service, feedNode, contentsBlock);
    }
    if (YTAIIsPanelService(service)) {
        @synchronized (YTAICaptureLock()) {
            YTAIPersistentAiDataSource = res;
            YTAIPersistentAiService = service;
            YTRCLog(@{
                @"event": @"ai-datasource-initialized-panel",
                @"method": @"contentsBlock",
                @"dataSourceClass": NSStringFromClass([res class]) ?: @"?",
                @"serviceClass": NSStringFromClass([service class]) ?: @"?"
            });
        }
    }
    return res;
}

static id YTAIInitDataSource2Hook(id self, SEL _cmd, id service, id feedNode, id contentsKey) {
    id res = nil;
    if (OriginalInitDataSource2 != NULL) {
        res = OriginalInitDataSource2(self, _cmd, service, feedNode, contentsKey);
    }
    if (YTAIIsPanelService(service)) {
        @synchronized (YTAICaptureLock()) {
            YTAIPersistentAiDataSource = res;
            YTAIPersistentAiService = service;
            YTRCLog(@{
                @"event": @"ai-datasource-initialized-panel",
                @"method": @"contentsKey",
                @"dataSourceClass": NSStringFromClass([res class]) ?: @"?",
                @"serviceClass": NSStringFromClass([service class]) ?: @"?"
            });
        }
    }
    return res;
}

static void YTAIPanelMakeRequestHook(id self, SEL _cmd, id request, BOOL refresh, id respBlock, id errBlock) {
    NSError *err = nil;
    NSData *reqData = request != nil ? YTRCSerializeMessage(request, 1024 * 1024, &err) : nil;
    NSString *reqStr = reqData.length > 0 ? [[NSString alloc] initWithData:reqData encoding:NSISOLatin1StringEncoding] : @"";
    BOOL isAi = [reqStr containsString:@"youchat"] || [reqStr containsString:@"Summarize"] || [reqStr containsString:@"kta-"];
    NSTimeInterval start = [[NSDate date] timeIntervalSince1970];

    YTRCLog(@{
        @"event": @"ai-panel-service-make-request",
        @"serviceClass": NSStringFromClass([self class]) ?: @"?",
        @"servicePtr": [NSString stringWithFormat:@"%p", self],
        @"requestClass": request != nil ? NSStringFromClass([request class]) : @"(nil)",
        @"reqBytes": @(reqData.length),
        @"isAi": @(isAi),
        @"preview": reqStr.length > 0 ? [reqStr substringToIndex:MIN((NSUInteger)160, reqStr.length)] : @""
    });

    id wrappedResp = respBlock;
    if (isAi && respBlock != nil) {
        NSString *enc = YTRCBlockSignature(respBlock);
        NSMethodSignature *sig = enc.length > 0 ? [NSMethodSignature signatureWithObjCTypes:enc.UTF8String] : nil;
        if (sig != nil && strcmp(sig.methodReturnType, "v") == 0) {
            if (sig.numberOfArguments == 3 &&
                [sig getArgumentTypeAtIndex:1][0] == '@' &&
                strcmp([sig getArgumentTypeAtIndex:2], "B") == 0) {
                wrappedResp = ^(id panelResponse, BOOL isFromCache) {
                    NSTimeInterval elapsed = ([[NSDate date] timeIntervalSince1970] - start) * 1000.0;
                    NSError *serr = nil;
                    NSData *respData = panelResponse != nil ? YTRCSerializeMessage(panelResponse, 2 * 1024 * 1024, &serr) : nil;
                    if (respData.length != 0) {
                        YTAICollectCaptureItem(respData);
                    }
                    YTRCLog(@{
                        @"event": @"ai-panel-service-make-response",
                        @"responseClass": panelResponse != nil ? NSStringFromClass([panelResponse class]) : @"(nil)",
                        @"respBytes": @(respData.length),
                        @"isFromCache": @(isFromCache),
                        @"elapsedMs": @(elapsed)
                    });
                    void (^origResp)(id, BOOL) = respBlock;
                    origResp(panelResponse, isFromCache);
                };
            } else if (sig.numberOfArguments == 2 && [sig getArgumentTypeAtIndex:1][0] == '@') {
                wrappedResp = ^(id panelResponse) {
                    NSTimeInterval elapsed = ([[NSDate date] timeIntervalSince1970] - start) * 1000.0;
                    NSError *serr = nil;
                    NSData *respData = panelResponse != nil ? YTRCSerializeMessage(panelResponse, 2 * 1024 * 1024, &serr) : nil;
                    if (respData.length != 0) {
                        YTAICollectCaptureItem(respData);
                    }
                    YTRCLog(@{
                        @"event": @"ai-panel-service-make-response",
                        @"responseClass": panelResponse != nil ? NSStringFromClass([panelResponse class]) : @"(nil)",
                        @"respBytes": @(respData.length),
                        @"elapsedMs": @(elapsed)
                    });
                    void (^origResp)(id) = respBlock;
                    origResp(panelResponse);
                };
            }
        }
    }

    if (OriginalPanelMakeRequest != NULL) {
        OriginalPanelMakeRequest(self, _cmd, request, refresh, wrappedResp, errBlock);
    }
}

static id YTAIPanelContinuationRequestHook(id self, SEL _cmd, id token, id clickTracking) {
    id req = nil;
    if (OriginalPanelContinuationRequest != NULL) {
        req = OriginalPanelContinuationRequest(self, _cmd, token, clickTracking);
    }
    NSError *err = nil;
    NSData *reqData = req != nil ? YTRCSerializeMessage(req, 1024 * 1024, &err) : nil;
    NSString *tokenStr = [token isKindOfClass:NSString.class] ? (NSString *)token : @"";
    YTRCLog(@{
        @"event": @"ai-panel-continuation-request-built",
        @"serviceClass": NSStringFromClass([self class]) ?: @"?",
        @"requestClass": req != nil ? NSStringFromClass([req class]) : @"(nil)",
        @"reqBytes": @(reqData.length),
        @"tokenPrefix": [tokenStr substringToIndex:MIN((NSUInteger)80, tokenStr.length)]
    });
    return req;
}

static void (*OriginalDelegateWillSend)(id, SEL, id, id) = NULL;

static void YTAIWillSendContinuationHook(id self, SEL _cmd, id dataSource, id request) {
    @try {
        NSError *err = nil;
        NSData *reqData = request != nil ? YTRCSerializeMessage(request, 1024 * 1024, &err) : nil;
        NSString *reqStr = reqData.length > 0 ? [[NSString alloc] initWithData:reqData encoding:NSISOLatin1StringEncoding] : @"";
        BOOL hasPrompt = [reqStr containsString:@"Summarize"] || [reqStr containsString:@"prompt"] || [reqStr containsString:@"youchat"];

        if (reqData.length > 0) {
            NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
            NSString *capturesDir = [docDir stringByAppendingPathComponent:@"YTKACE/ai_captures"];
            [[NSFileManager defaultManager] createDirectoryAtPath:capturesDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
            NSString *basePath = [NSString stringWithFormat:@"%@/%.0f_willSendReq.bin", capturesDir, now];
            [reqData writeToFile:basePath atomically:YES];
        }

        YTRCLog(@{
            @"event": @"ai-will-send-continuation",
            @"delegateClass": NSStringFromClass([self class]) ?: @"?",
            @"requestClass": NSStringFromClass([request class]) ?: @"?",
            @"reqBytes": @(reqData.length),
            @"hasPrompt": @(hasPrompt),
            @"reqPreview": reqStr.length > 0 ? [reqStr substringToIndex:MIN((NSUInteger)160, reqStr.length)] : @""
        });
    } @catch (NSException *e) {}

    if (OriginalDelegateWillSend != NULL) {
        OriginalDelegateWillSend(self, _cmd, dataSource, request);
    }
}

static void YTAIHookDelegateClassIfNeeded(Class cls) {
    if (!cls) return;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL sel = NSSelectorFromString(@"innerTubeFeedControllerDataSource:willSendContinuationRequest:");
        Method m = class_getInstanceMethod(cls, sel);
        if (m) {
            OriginalDelegateWillSend = (void (*)(id, SEL, id, id))method_getImplementation(m);
            method_setImplementation(m, (IMP)YTAIWillSendContinuationHook);
            YTRCLog(@{@"event": @"ai-hooked-delegate", @"class": NSStringFromClass(cls)});
        }
    });
}

static void YTAIRegisterAttachmentHook(id self, SEL _cmd, id attachment, id token) {
    NSError *err = nil;
    NSData *attData = attachment != nil ? YTRCSerializeMessage(attachment, 512 * 1024, &err) : nil;
    NSString *tokenStr = [token isKindOfClass:NSString.class] ? (NSString *)token : @"";
    YTRCLog(@{
        @"event": @"ai-register-attachment",
        @"dataSourceClass": NSStringFromClass([self class]) ?: @"?",
        @"attachmentClass": attachment != nil ? NSStringFromClass([attachment class]) : @"(nil)",
        @"attachmentBytes": @(attData.length),
        @"tokenPrefix": [tokenStr substringToIndex:MIN((NSUInteger)80, tokenStr.length)]
    });
    if (OriginalRegisterAttachment != NULL) {
        OriginalRegisterAttachment(self, _cmd, attachment, token);
    }
}

static id YTAIGetInnerTubeUIServiceForActiveIdentity(id self, SEL _cmd) {
    id res = nil;
    if (OriginalGetInnerTubeUIServiceForActiveIdentity != NULL) {
        res = OriginalGetInnerTubeUIServiceForActiveIdentity(self, _cmd);
    }
    YTRCLog(@{
        @"event": @"ai-proxy-identity-service",
        @"proxyClass": NSStringFromClass([self class]) ?: @"?",
        @"resolvedClass": res != nil ? NSStringFromClass([res class]) : @"(nil)",
        @"resolvedPtr": [NSString stringWithFormat:@"%p", res]
    });
    return res;
}

static id YTAIForwardingTargetForSelector(id self, SEL _cmd, SEL aSelector) {
    id target = nil;
    if (OriginalForwardingTargetForSelector != NULL) {
        target = OriginalForwardingTargetForSelector(self, _cmd, aSelector);
    }
    NSString *selName = NSStringFromSelector(aSelector);
    if ([selName containsString:@"Continuation"] || [selName containsString:@"Request"] || [selName containsString:@"make"]) {
        YTRCLog(@{
            @"event": @"ai-proxy-forwarding-target",
            @"selector": selName ?: @"",
            @"targetClass": target != nil ? NSStringFromClass([target class]) : @"(nil)",
            @"targetPtr": [NSString stringWithFormat:@"%p", target]
        });
    }
    return target;
}

static void YTAIGTMBeginFetch(id self, SEL _cmd, id completionHandler) {
    if (OriginalGTMBeginFetch == NULL) return;

    NSURLRequest *req = nil;
    if ([self respondsToSelector:@selector(request)]) {
        req = ((NSURLRequest *(*)(id, SEL))objc_msgSend)(self, @selector(request));
    }
    NSString *urlStr = req.URL.absoluteString ?: @"";
    BOOL isAiRelevant = [urlStr containsString:@"you_chat"] ||
                        [urlStr containsString:@"youchat"] ||
                        [urlStr containsString:@"youtubei/v1/browse"] ||
                        [urlStr containsString:@"youtubei/v1/next"] ||
                        [urlStr containsString:@"youtubei/v1/att"] ||
                        YTAIReplayInFlight ||
                        YTAICaptureActive;

    if (isAiRelevant) {
        NSData *body = nil;
        if ([self respondsToSelector:@selector(bodyData)]) {
            body = ((NSData *(*)(id, SEL))objc_msgSend)(self, @selector(bodyData));
        }
        if (body.length == 0) body = req.HTTPBody;

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSString *endpoint = req.URL.path.lastPathComponent ?: @"unknown";

        NSString *docDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *capturesDir = [docDir stringByAppendingPathComponent:@"YTKACE/ai_captures"];
        [[NSFileManager defaultManager] createDirectoryAtPath:capturesDir withIntermediateDirectories:YES attributes:nil error:nil];

        NSString *basePath = [NSString stringWithFormat:@"%@/%.0f_%@", capturesDir, now, endpoint];
        if (body.length > 0) {
            [body writeToFile:[basePath stringByAppendingString:@"_request.bin"] atomically:YES];
        }

        BOOL hasPrompt = NO;
        if (body.length > 0) {
            const char *needle = "Summarize";
            if (memmem(body.bytes, body.length, needle, strlen(needle)) != NULL) {
                hasPrompt = YES;
            }
        }

        YTRCLog(@{
            @"event": @"ai-wire-request",
            @"endpoint": endpoint,
            @"url": urlStr,
            @"method": req.HTTPMethod ?: @"POST",
            @"bodyBytes": @(body.length),
            @"hasPrompt": @(hasPrompt),
            @"time": @(now)
        });

        if (completionHandler != nil) {
            void (^origBlock)(NSData *, NSError *) = [completionHandler copy];
            id wrappedBlock = ^(NSData *respData, NSError *respErr) {
                NSTimeInterval respTime = [[NSDate date] timeIntervalSince1970];
                if (respData.length > 0) {
                    [respData writeToFile:[basePath stringByAppendingString:@"_response.bin"] atomically:YES];
                }
                YTRCLog(@{
                    @"event": @"ai-wire-response",
                    @"endpoint": endpoint,
                    @"respBytes": @(respData.length),
                    @"hasError": @(respErr != nil),
                    @"elapsedMs": @((respTime - now) * 1000.0),
                    @"time": @(respTime)
                });
                origBlock(respData, respErr);
            };
            OriginalGTMBeginFetch(self, _cmd, [wrappedBlock copy]);
            return;
        }
    }

    OriginalGTMBeginFetch(self, _cmd, completionHandler);
}

static void YTAIMakeContinuationRequest(id self, SEL _cmd, id token, unsigned long long type, id attachment, id clickTracking, BOOL alwaysParse, BOOL refresh, id initialBlock, id responseBlock, id errorBlock) {
    id service = nil;
    if ([self respondsToSelector:@selector(service)]) service = ((id (*)(id, SEL))objc_msgSend)(self, @selector(service));
    id delegate = nil;
    if ([self respondsToSelector:@selector(delegate)]) delegate = ((id (*)(id, SEL))objc_msgSend)(self, @selector(delegate));


    NSString *tokenStr = [token isKindOfClass:NSString.class] ? (NSString *)token : @"";
    BOOL isAiContinuation = [tokenStr hasPrefix:@"kta-"];
    BOOL isPanelDS = YTAIIsPanelDataSource(self);

    if (isAiContinuation && isPanelDS && !YTAIReplayInFlight) {
        @synchronized (YTAICaptureLock()) {
            YTAIPersistentAiDataSource = self;
            if (service != nil) YTAIPersistentAiService = service;
            YTRCLog(@{
                @"event": @"ai-wire-panel-datasource-saved",
                @"dataSourceClass": NSStringFromClass([self class]) ?: @"?",
                @"serviceClass": service != nil ? NSStringFromClass([service class]) : @"(nil)"
            });
        }
    }

    if (isAiContinuation) {
        NSData *attData = nil;
        if (attachment != nil) {
            NSError *err = nil;
            attData = YTRCSerializeMessage(attachment, 512 * 1024, &err);
        }
        YTRCLog(@{
            @"event": @"ai-wire-make-continuation",
            @"tokenPrefix": [tokenStr substringToIndex:MIN((NSUInteger)80, tokenStr.length)],
            @"tokenLength": @(tokenStr.length),
            @"type": @(type),
            @"alwaysParse": @(alwaysParse),
            @"refresh": @(refresh),
            @"dataSourceClass": NSStringFromClass([self class]) ?: @"?",
            @"dataSourcePtr": [NSString stringWithFormat:@"%p", self],
            @"serviceClass": service != nil ? NSStringFromClass([service class]) : @"(nil)",
            @"servicePtr": [NSString stringWithFormat:@"%p", service],
            @"delegateClass": delegate != nil ? NSStringFromClass([delegate class]) : @"(nil)",
            @"attachmentClass": attachment != nil ? NSStringFromClass([attachment class]) : @"(nil)",
            @"attachmentBytes": @(attData.length)
        });
    }

    // Wrap responseBlock and errorBlock to log callbacks
    id wrappedResp = responseBlock;
    id wrappedErr = errorBlock;
    if (isAiContinuation && responseBlock != nil) {
        wrappedResp = ^(NSArray *items, NSUInteger itemIndex, id arg, NSData *data) {
            YTRCLog(@{
                @"event": @"ai-continuation-callback-resp",
                @"itemsCount": @(items.count),
                @"dataBytes": @(data.length),
                @"tokenPrefix": [tokenStr substringToIndex:MIN((NSUInteger)40, tokenStr.length)]
            });
            void (^origResp)(NSArray *, NSUInteger, id, NSData *) = responseBlock;
            origResp(items, itemIndex, arg, data);
        };
    }
    if (isAiContinuation && errorBlock != nil) {
        wrappedErr = ^(id error, id context) {
            YTRCLog(@{
                @"event": @"ai-continuation-callback-err",
                @"errorDesc": [error description] ?: @"?",
                @"tokenPrefix": [tokenStr substringToIndex:MIN((NSUInteger)40, tokenStr.length)]
            });
            void (^origErr)(id, id) = errorBlock;
            origErr(error, context);
        };
    }

    if (OriginalMakeContinuationRequest != NULL) {
        OriginalMakeContinuationRequest(self, _cmd, token, type, attachment, clickTracking, alwaysParse, refresh, initialBlock, wrappedResp, wrappedErr);
    }
}

static void YTAIInitWireCapture(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class fetcherCls = NSClassFromString(@"GTMSessionFetcher");
        if (fetcherCls) {
            SEL sel = NSSelectorFromString(@"beginFetchWithCompletionHandler:");
            Method m = class_getInstanceMethod(fetcherCls, sel);
            if (m) {
                OriginalGTMBeginFetch = (void (*)(id, SEL, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)YTAIGTMBeginFetch);
            }
        }
        Class dsCls = NSClassFromString(@"YTInnerTubeFeedControllerDataSource");
        if (dsCls) {
            SEL selMakeCont = NSSelectorFromString(@"makeContinuationRequestWithToken:continuationType:clientAttachmentRequestData:clickTrackingParams:alwaysParseFeedNode:refresh:initialResponseBlock:responseBlock:errorResponseBlock:");
            Method m = class_getInstanceMethod(dsCls, selMakeCont);
            if (m) {
                OriginalMakeContinuationRequest = (void (*)(id, SEL, id, unsigned long long, id, id, BOOL, BOOL, id, id, id))method_getImplementation(m);
                method_setImplementation(m, (IMP)YTAIMakeContinuationRequest);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTInnerTubeFeedControllerDataSource", @"selector": NSStringFromSelector(selMakeCont)});
            }
            SEL selInit1 = NSSelectorFromString(@"initWithInnerTubeService:initialFeedNode:contentsBlock:");
            Method m1 = class_getInstanceMethod(dsCls, selInit1);
            if (m1) {
                OriginalInitDataSource1 = (id (*)(id, SEL, id, id, id))method_getImplementation(m1);
                method_setImplementation(m1, (IMP)YTAIInitDataSource1Hook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTInnerTubeFeedControllerDataSource", @"selector": NSStringFromSelector(selInit1)});
            }
            SEL selInit2 = NSSelectorFromString(@"initWithInnerTubeService:initialFeedNode:contentsKey:");
            Method m2 = class_getInstanceMethod(dsCls, selInit2);
            if (m2) {
                OriginalInitDataSource2 = (id (*)(id, SEL, id, id, id))method_getImplementation(m2);
                method_setImplementation(m2, (IMP)YTAIInitDataSource2Hook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTInnerTubeFeedControllerDataSource", @"selector": NSStringFromSelector(selInit2)});
            }
        }
        Class delegateCls = NSClassFromString(@"YTSectionListContinuationControllerBlock");
        if (delegateCls) {
            YTAIHookDelegateClassIfNeeded(delegateCls);
            YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTSectionListContinuationControllerBlock", @"selector": @"innerTubeFeedControllerDataSource:willSendContinuationRequest:"});
        }
        Class panelSvcCls = NSClassFromString(@"YTPanelServiceImpl");
        if (panelSvcCls) {
            SEL selMake = NSSelectorFromString(@"makeRequest:refresh:responseBlock:errorBlock:");
            Method mMake = class_getInstanceMethod(panelSvcCls, selMake);
            if (mMake) {
                OriginalPanelMakeRequest = (void (*)(id, SEL, id, BOOL, id, id))method_getImplementation(mMake);
                method_setImplementation(mMake, (IMP)YTAIPanelMakeRequestHook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTPanelServiceImpl", @"selector": @"makeRequest:refresh:responseBlock:errorBlock:"});
            }
            SEL selReq = NSSelectorFromString(@"continuationRequestWithToken:clickTrackingParams:");
            Method mReq = class_getInstanceMethod(panelSvcCls, selReq);
            if (mReq) {
                OriginalPanelContinuationRequest = (id (*)(id, SEL, id, id))method_getImplementation(mReq);
                method_setImplementation(mReq, (IMP)YTAIPanelContinuationRequestHook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTPanelServiceImpl", @"selector": @"continuationRequestWithToken:clickTrackingParams:"});
            }
        }
        Class browseSvcCls = NSClassFromString(@"YTAppBrowseService");
        if (browseSvcCls) {
            SEL selMake = NSSelectorFromString(@"makeRequest:refresh:responseBlock:errorBlock:");
            Method mMake = class_getInstanceMethod(browseSvcCls, selMake);
            if (mMake) {
                OriginalBrowseMakeRequest = (void (*)(id, SEL, id, BOOL, id, id))method_getImplementation(mMake);
                method_setImplementation(mMake, (IMP)YTAIBrowseMakeRequestHook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTAppBrowseService", @"selector": @"makeRequest:refresh:responseBlock:errorBlock:"});
            }
            SEL selReq = NSSelectorFromString(@"continuationRequestWithToken:clickTrackingParams:");
            Method mReq = class_getInstanceMethod(browseSvcCls, selReq);
            if (mReq) {
                OriginalBrowseContinuationRequest = (id (*)(id, SEL, id, id))method_getImplementation(mReq);
                method_setImplementation(mReq, (IMP)YTAIBrowseContinuationRequestHook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTAppBrowseService", @"selector": @"continuationRequestWithToken:clickTrackingParams:"});
            }
            SEL selReg = NSSelectorFromString(@"registerClientAttachmentRequestData:forContinuationToken:");
            Method mReg = class_getInstanceMethod(browseSvcCls, selReg);
            if (mReg) {
                OriginalRegisterAttachment = (void (*)(id, SEL, id, id))method_getImplementation(mReg);
                method_setImplementation(mReg, (IMP)YTAIRegisterAttachmentHook);
                YTRCLog(@{@"event": @"ai-wire-hook-installed", @"class": @"YTAppBrowseService", @"selector": @"registerClientAttachmentRequestData:forContinuationToken:"});
            }
        }
        Class proxyCls = NSClassFromString(@"YTAppScopedInnerTubeUIServiceProxy");
        if (proxyCls) {
            SEL idSel = NSSelectorFromString(@"getInnerTubeUIServiceForActiveIdentity");
            Method m1 = class_getInstanceMethod(proxyCls, idSel);
            if (m1) {
                OriginalGetInnerTubeUIServiceForActiveIdentity = (id (*)(id, SEL))method_getImplementation(m1);
                method_setImplementation(m1, (IMP)YTAIGetInnerTubeUIServiceForActiveIdentity);
            }
            SEL fwdSel = NSSelectorFromString(@"forwardingTargetForSelector:");
            Method m2 = class_getInstanceMethod(proxyCls, fwdSel);
            if (m2) {
                OriginalForwardingTargetForSelector = (id (*)(id, SEL, SEL))method_getImplementation(m2);
                method_setImplementation(m2, (IMP)YTAIForwardingTargetForSelector);
            }
            SEL selInit1 = NSSelectorFromString(@"initWithInnerTubeUIServiceProtocols:respondToOptionalContinuationMethods:serviceCreationBlock:activeIdentityScope:serviceClass:");
            Method mInit1 = class_getInstanceMethod(proxyCls, selInit1);
            if (mInit1) {
                OriginalInitProxy1 = (id (*)(id, SEL, id, BOOL, id, id, Class))method_getImplementation(mInit1);
                method_setImplementation(mInit1, (IMP)YTAIInitProxy1Hook);
            }
            SEL selInit2 = NSSelectorFromString(@"initWithInnerTubeUIServiceProtocol:respondToOptionalContinuationMethods:serviceCreationBlock:activeIdentityScope:serviceClass:");
            Method mInit2 = class_getInstanceMethod(proxyCls, selInit2);
            if (mInit2) {
                OriginalInitProxy2 = (id (*)(id, SEL, id, BOOL, id, id, Class))method_getImplementation(mInit2);
                method_setImplementation(mInit2, (IMP)YTAIInitProxy2Hook);
            }
            SEL selInit3 = NSSelectorFromString(@"initWithInnerTubeUIServiceProtocol:respondToOptionalContinuationMethods:serviceCreationBlock:serviceClass:");
            Method mInit3 = class_getInstanceMethod(proxyCls, selInit3);
            if (mInit3) {
                OriginalInitProxy3 = (id (*)(id, SEL, id, BOOL, id, Class))method_getImplementation(mInit3);
                method_setImplementation(mInit3, (IMP)YTAIInitProxy3Hook);
            }
        }
    });
}

__attribute__((constructor)) static void YTAIConstructor(void) {
    YTAIInitWireCapture();
}

void YTAINoteNativeContinuation(NSString *token, id receiver, unsigned long long continuationType, id attachment, id clickTracking, BOOL cacheEnabled, BOOL alwaysParse, NSString *respSignature, NSString *errSignature) {
    if (token.length == 0 || receiver == nil) return;
    if (YTAIReplayInFlight) return; // Never record echoes during replay

    // Strictly enforce panel datasource verification
    if (!YTAIIsPanelDataSource(receiver)) {
        YTRCLog(@{@"event": @"ai-continuation-ignored-non-panel",
                  @"dataSource": NSStringFromClass([receiver class]) ?: @"?",
                  @"tokenPrefix": [token substringToIndex:MIN((NSUInteger)40, token.length)]});
        return;
    }

    YTAISubmissionSnapshot *snapshot = [YTAISubmissionSnapshot new];
    snapshot.token = [token copy];
    snapshot.continuationType = continuationType;
    snapshot.attachment = attachment;
    snapshot.attachmentClass = attachment != nil ? NSStringFromClass([attachment class]) : @"(none)";
    if (attachment != nil) {
        NSError *err = nil;
        snapshot.attachmentData = YTRCSerializeMessage(attachment, 512 * 1024, &err);
    }
    snapshot.clickTracking = clickTracking;
    snapshot.clickTrackingClass = clickTracking != nil ? NSStringFromClass([clickTracking class]) : @"(none)";
    if ([clickTracking isKindOfClass:[NSData class]]) {
        snapshot.clickTrackingData = (NSData *)clickTracking;
    } else if (clickTracking != nil) {
        NSError *err = nil;
        snapshot.clickTrackingData = YTRCSerializeMessage(clickTracking, 512 * 1024, &err);
    }
    snapshot.cacheEnabled = cacheEnabled;
    snapshot.alwaysParseFeedNode = alwaysParse;
    snapshot.dataSource = receiver;
    snapshot.dataSourceClass = NSStringFromClass([receiver class]) ?: @"?";

    id service = nil;
    if ([receiver respondsToSelector:@selector(service)]) {
        service = ((id (*)(id, SEL))objc_msgSend)(receiver, @selector(service));
    }
    snapshot.service = service;
    snapshot.serviceClass = service != nil ? NSStringFromClass([service class]) : @"(none)";

    id innerService = nil;
    SEL resolve = NSSelectorFromString(@"getInnerTubeUIServiceForActiveIdentity");
    if (service != nil && [service respondsToSelector:resolve]) {
        innerService = ((id (*)(id, SEL))objc_msgSend)(service, resolve);
    }
    snapshot.innerService = innerService;
    snapshot.innerServiceClass = innerService != nil ? NSStringFromClass([innerService class]) : @"(none)";

    snapshot.respSignature = [respSignature copy];
    snapshot.errSignature = [errSignature copy];
    snapshot.videoId = YTRCCurrentVideoId();
    snapshot.timestamp = [[NSDate date] timeIntervalSince1970];

    NSString *extVid = nil;
    NSString *extCid = nil;
    if (YTAIExtractSessionFromTeaserToken(token, &extVid, &extCid)) {
        if (extVid.length == 11) snapshot.videoId = extVid;
        if (extCid.length > 0) snapshot.conversationId = extCid;
    }

    NSArray *symbols = [NSThread callStackSymbols];
    snapshot.callStack = symbols.count > 12 ? [symbols subarrayWithRange:NSMakeRange(0, 12)] : symbols;

    @synchronized (YTAICaptureLock()) {
        if ([token hasPrefix:@"kta-"]) {
            YTAILastContinuationSnapshot = snapshot;
            YTAIPersistentAiDataSource = receiver;
            YTAIPersistentAiService = service;
            YTRCLog(@{
                @"event": @"ai-persistent-service-saved",
                @"dataSourceClass": NSStringFromClass([receiver class]) ?: @"?",
                @"serviceClass": snapshot.serviceClass ?: @"?",
                @"innerServiceClass": snapshot.innerServiceClass ?: @"?"
            });
        }

        BOOL isSubmit = [token hasPrefix:@"kta-ngtR"] || [token hasPrefix:@"kta-ngu"] || YTAISubmitRequestObserved;
        if (isSubmit) {
            YTAICapturedSubmissionSnapshot = snapshot;
            YTRCLog(@{
                @"event": @"ai-submission-snapshot",
                @"tokenLength": @(snapshot.token.length),
                @"tokenPrefix": [snapshot.token substringToIndex:MIN((NSUInteger)80, snapshot.token.length)],
                @"token": snapshot.token ?: @"",
                @"continuationType": @(snapshot.continuationType),
                @"attachmentClass": snapshot.attachmentClass ?: @"",
                @"attachmentBytes": @(snapshot.attachmentData.length),
                @"clickTrackingClass": snapshot.clickTrackingClass ?: @"",
                @"clickTrackingBytes": @(snapshot.clickTrackingData.length),
                @"cacheEnabled": @(snapshot.cacheEnabled),
                @"alwaysParse": @(snapshot.alwaysParseFeedNode),
                @"dataSource": snapshot.dataSourceClass ?: @"",
                @"service": snapshot.serviceClass ?: @"",
                @"innerService": snapshot.innerServiceClass ?: @"",
                @"respSignature": snapshot.respSignature ?: @"",
                @"errSignature": snapshot.errSignature ?: @"",
                @"videoId": snapshot.videoId ?: @"",
                @"callStack": snapshot.callStack ?: @[]
            });
        }

        YTAIAiDataSource = receiver;
        YTAIContinuationType = continuationType;
        YTAINativeCacheEnabled = cacheEnabled;
        YTAINativeAlwaysParse = alwaysParse;
        YTAIAttachment = attachment;
        YTAIClickTracking = clickTracking;
        YTAIHasNativeArgs = YES;
    }
}

static NSString *const YTAIPromptText = @"Summarize the top 5 concepts in this video?";
static const double YTAIPromptDelays[] = {
    0, 0.5, 1.0, 1.5, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0, 12.0, 14.0, 16.0
};
__attribute__((unused)) static const double YTAISendRetryDelays[] = {0.6, 1.5, 2.5, 4.0, 6.0};
static BOOL YTAISendChainLogged = NO;

void YTAINoteContinuation(NSString *token) {
    if (!YTAICaptureActive) return;
    NSString *prefix = token.length >= 10 ? [token substringToIndex:10] : (token ?: @"");
    if ([token hasPrefix:@"kta-nguq"] || [token hasPrefix:@"kta-ngtR"]) {
        if (YTAISubmitRequestObserved) return;
        YTAISubmitRequestObserved = YES;
        if (YTAIPreSubmissionItemCount < 0) {
            UIView *panel = YTAIFindAiPanelContainer(nil);
            YTAIPreSubmissionItemCount = YTAICountPanelItems(panel);
        }
        @synchronized (YTAICaptureLock()) {
            if (YTAICaptureItems != nil) {
                [YTAICaptureItems removeAllObjects];
            }
        }
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-observed", @"tokenPrefix": prefix});
        return;
    }
    if ([token hasPrefix:@"kta-ngv"] || !YTAIPromptSendAttempted) {
        if (YTAIPanelRequestObserved) return;
        YTAIPanelRequestObserved = YES;
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"panel-request-observed", @"tokenPrefix": prefix});
        return;
    }
    if (YTAISubmitRequestObserved) return;
    YTAISubmitRequestObserved = YES;
    if (YTAIPreSubmissionItemCount < 0) {
        UIView *panel = YTAIFindAiPanelContainer(nil);
        YTAIPreSubmissionItemCount = YTAICountPanelItems(panel);
    }
    @synchronized (YTAICaptureLock()) {
        if (YTAICaptureItems != nil) {
            [YTAICaptureItems removeAllObjects];
        }
    }
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-observed", @"tokenPrefix": prefix});
}

void YTAICollectCaptureItem(NSData *bytes) {
    YTAICollectCaptureItemWithClass(bytes, nil);
}

void YTAICollectCaptureItemWithClass(NSData *bytes, NSString * _Nullable className) {
    if (bytes.length == 0) return;
    BOOL isAnswer = [bytes rangeOfData:[@"chat_response_item" dataUsingEncoding:NSUTF8StringEncoding]
                               options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
    BOOL isChat = [bytes rangeOfData:[@"chat_response" dataUsingEncoding:NSUTF8StringEncoding]
                               options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
    BOOL isYouChat = [bytes rangeOfData:[@"youchat" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
    BOOL isStreaming = [bytes rangeOfData:[@"streaming_response" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
    BOOL isAssistant = [bytes rangeOfData:[@"assistant_response" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
    static const uint8_t kWatchKey[] = { 0xEA, 0xA8, 0xDD, 0xB9, 0x01 };
    BOOL hasWatchEndpoint = YTAIBytesContain((const uint8_t *)bytes.bytes, bytes.length, (const char *)kWatchKey, 5);
    BOOL isVideoCard = [bytes rangeOfData:[@"video_lockup" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound ||
                       [bytes rangeOfData:[@"compact_video" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound ||
                       [bytes rangeOfData:[@"watch?v=" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound ||
                       [bytes rangeOfData:[@"related" dataUsingEncoding:NSUTF8StringEncoding]
                                  options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound ||
                       hasWatchEndpoint;
    BOOL isMutation = [className isEqualToString:@"YTISectionListMutationOperations"] ||
                      [bytes rangeOfData:[@"mutation" dataUsingEncoding:NSUTF8StringEncoding]
                                 options:0 range:NSMakeRange(0, bytes.length)].location != NSNotFound;
    BOOL isRelevant = isAnswer || isChat || isYouChat || isStreaming || isAssistant || isVideoCard || isMutation;
    if (!isRelevant) return;

    @synchronized (YTAICaptureLock()) {
        if (!YTAICaptureActive || YTAICaptureItems == nil) return;
        // CRITICAL: Do NOT accept any response items until outbound prompt submission has occurred for this turn.
        // Pre-submission items are from previous turns or initial UI load.
        if (!YTAISubmitRequestObserved) return;
        if (YTAICaptureItems.count >= 500) {
            static BOOL loggedCap = NO;
            if (!loggedCap) {
                loggedCap = YES;
                YTRCLog(@{@"event": @"ai-capture-item-omitted",
                          @"reason": @"capture-items-count-exceeded-500-cap",
                          @"class": className ?: @"?"});
            }
            return;
        }
        [YTAICaptureItems addObject:@{@"data": bytes, @"class": className ?: @""}];
        YTAIDiagnosticLogEndpoints(bytes, className, @"collect-capture");
        NSUInteger generation = ++YTAICaptureGeneration;
        YTAICaptureSawAnswer = YES;
        void (^settle)(void) = YTAICaptureSettle;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (generation != YTAICaptureGeneration || !YTAICaptureActive) return;
            if (settle != nil) settle();
        });
    }
}

typedef NS_ENUM(NSUInteger, YTAIActivationStrategy) {
    YTAIActivationCollection = 0,
    YTAIActivationNodeControl = 1,
    YTAIActivationAccessibility = 2,
    YTAIActivationGesture = 3,
    YTAIActivationUIControl = 4,
};

static NSString *YTAIStrategyName(YTAIActivationStrategy strategy) {
    switch (strategy) {
        case YTAIActivationCollection: return @"collection";
        case YTAIActivationNodeControl: return @"node-control";
        case YTAIActivationAccessibility: return @"accessibility";
        case YTAIActivationGesture: return @"gesture";
        case YTAIActivationUIControl: return @"control";
    }
    return @"?";
}

static id YTAINodeOfView(UIView *view) {
    static SEL nodeSelectors[2];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        nodeSelectors[0] = NSSelectorFromString(@"asyncdisplaykit_node");
        nodeSelectors[1] = NSSelectorFromString(@"node");
    });
    for (NSUInteger index = 0; index < 2; index++) {
        if (![view respondsToSelector:nodeSelectors[index]]) continue;
        id node = ((id (*)(id, SEL))objc_msgSend)(view, nodeSelectors[index]);
        if (node != nil) return node;
    }
    return nil;
}

static void YTAIAppendInterestingMethods(Class cls, NSMutableArray<NSString *> *actions, NSUInteger max) {
    for (Class current = cls; current != nil && current != NSObject.class && actions.count < max;
         current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int index = 0; index < count && actions.count < max; index++) {
            NSString *name = NSStringFromSelector(method_getName(methods[index])) ?: @"";
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"tap"] || [lower containsString:@"activate"] ||
                [lower containsString:@"command"] || [lower containsString:@"select"] ||
                [lower containsString:@"press"] || [lower containsString:@"send"])
                [actions addObject:name];
        }
        free(methods);
    }
}

static NSString *YTAIDescribeNode(id node) {
    if (node == nil) return @"(none)";
    NSMutableString *description = [NSMutableString stringWithString:NSStringFromClass([node class]) ?: @"?"];
    id controller = nil;
    SEL controllerSelector = NSSelectorFromString(@"nodeController");
    if ([node respondsToSelector:controllerSelector]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(node, controllerSelector);
        if (controller != nil)
            [description appendFormat:@"/%@", NSStringFromClass([controller class]) ?: @"?"];
    }
    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    YTAIAppendInterestingMethods([node class], actions, 10);
    if (actions.count != 0)
        [description appendFormat:@" actions=[%@]", [actions componentsJoinedByString:@","]];
    if (controller != nil) {
        NSMutableArray<NSString *> *controllerActions = [NSMutableArray array];
        YTAIAppendInterestingMethods([controller class], controllerActions, 12);
        if (controllerActions.count != 0)
            [description appendFormat:@" controllerActions=[%@]",
                [controllerActions componentsJoinedByString:@","]];
    }
    return description;
}

static SEL YTAIReadIVarSEL(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    if (ivar == NULL) return NULL;
    return *(SEL *)((uint8_t *)(__bridge void *)object + ivar_getOffset(ivar));
}

static void YTAISetGestureState(UIGestureRecognizer *recognizer, NSInteger state) {
    @try { [recognizer setValue:@(state) forKey:@"state"]; return; } @catch (NSException *exception) {}
    Ivar ivar = class_getInstanceVariable(object_getClass(recognizer), "_state");
    if (ivar != NULL)
        *(NSInteger *)((uint8_t *)(__bridge void *)recognizer + ivar_getOffset(ivar)) = state;
}

static BOOL YTAIFireTapGestureTargets(UIGestureRecognizer *recognizer) {
    NSArray *pairs = nil;
    @try {
        id raw = [recognizer valueForKey:@"_targets"];
        if ([raw isKindOfClass:NSArray.class]) pairs = [raw copy];
    } @catch (NSException *exception) {}
    if (pairs.count == 0) return NO;
    YTAISetGestureState(recognizer, UIGestureRecognizerStateEnded);
    for (id pair in pairs) {
        id target = nil;
        @try { target = [pair valueForKey:@"_target"]; } @catch (NSException *exception) {}
        if (target == nil) continue;
        SEL action = YTAIReadIVarSEL(pair, "_action");
        if (target == nil || action == NULL) continue;
        NSMethodSignature *signature = nil;
        @try { signature = [target methodSignatureForSelector:action]; } @catch (NSException *e) {}
        if (signature == nil || signature.numberOfArguments > 3) continue;
        if (signature.numberOfArguments == 3 && [signature getArgumentTypeAtIndex:2][0] != '@')
            continue;
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = action;
        if (signature.numberOfArguments == 3) {
            UIGestureRecognizer *argument = recognizer;
            [invocation setArgument:&argument atIndex:2];
        }
        @try {
            [invocation invoke];
            return YES;
        } @catch (NSException *exception) {}
        if (YTAISubmitRequestObserved) return YES;
    }
    return NO;
}

static BOOL YTAIPerformCollectionSelection(UIView *element) {
    for (UIView *ancestor = element; ancestor != nil; ancestor = ancestor.superview) {
        if ([ancestor isKindOfClass:UICollectionView.class]) {
            UICollectionView *collection = (UICollectionView *)ancestor;
            CGPoint point = [element convertPoint:CGPointMake(CGRectGetMidX(element.bounds),
                                                              CGRectGetMidY(element.bounds))
                                           toView:collection];
            NSIndexPath *indexPath = [collection indexPathForItemAtPoint:point];
            if (indexPath != nil && [collection.delegate respondsToSelector:
                    @selector(collectionView:didSelectItemAtIndexPath:)]) {
                [collection.delegate collectionView:collection didSelectItemAtIndexPath:indexPath];
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                          @"mode": @"collection",
                          @"class": NSStringFromClass([element class]) ?: @"?",
                          @"indexPath": indexPath.description ?: @"?"});
                return YES;
            }
        }
        if ([ancestor isKindOfClass:UITableView.class]) {
            UITableView *table = (UITableView *)ancestor;
            CGPoint point = [element convertPoint:CGPointMake(CGRectGetMidX(element.bounds),
                                                              CGRectGetMidY(element.bounds))
                                           toView:table];
            NSIndexPath *indexPath = [table indexPathForRowAtPoint:point];
            if (indexPath != nil && [table.delegate respondsToSelector:
                    @selector(tableView:didSelectRowAtIndexPath:)]) {
                [table.delegate tableView:table didSelectRowAtIndexPath:indexPath];
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                          @"mode": @"table",
                          @"class": NSStringFromClass([element class]) ?: @"?",
                          @"indexPath": indexPath.description ?: @"?"});
                return YES;
            }
        }
    }
    return NO;
}

static BOOL YTAIPerformNodeControlAction(UIView *element) {
    for (UIView *ancestor = element; ancestor != nil; ancestor = ancestor.superview) {
        id node = YTAINodeOfView(ancestor);
        if (node == nil) continue;
        SEL send = NSSelectorFromString(@"sendActionsForControlEvents:");
        if (![node respondsToSelector:send]) continue;
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(node, send, (NSUInteger)(1 << 6));
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(node, send, (NSUInteger)(1 << 13));
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                  @"mode": @"node-control",
                  @"class": NSStringFromClass([node class]) ?: @"?"});
        return YES;
    }
    return NO;
}

static BOOL YTAIPerformAccessibilityActivation(UIView *element) {
    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    NSUInteger depth = 0;
    for (UIView *candidate = element; candidate != nil && depth < 8;
         candidate = candidate.superview, depth++) {
        BOOL isElement = candidate == element;
        if (!isElement) {
            NSString *identifier = [candidate.accessibilityIdentifier lowercaseString] ?: @"";
            NSString *label = [candidate.accessibilityLabel lowercaseString] ?: @"";
            BOOL relevant = [identifier containsString:@"youchat"] ||
                [identifier containsString:@"entrypoint"] ||
                [label isEqualToString:@"ask"] || [label containsString:@"ai overview"] ||
                [identifier containsString:@"send"] || [label isEqualToString:@"send"];
            if (!candidate.isAccessibilityElement || !relevant) continue;
        }
        BOOL activated = [candidate accessibilityActivate];
        [attempts addObject:[NSString stringWithFormat:@"%@@%lu=%d",
                             NSStringFromClass([candidate class]) ?: @"?",
                             (unsigned long)depth, activated]];
        if (activated) {
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                      @"mode": @"accessibility",
                      @"class": NSStringFromClass([candidate class]) ?: @"?",
                      @"attempts": attempts});
            return YES;
        }
    }
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-activated",
              @"mode": @"accessibility",
              @"class": NSStringFromClass([element class]) ?: @"?",
              @"accessibility": @NO,
              @"attempts": attempts});
    return NO;
}

static BOOL YTAIPerformGestureAction(UIView *element) {
    NSUInteger depth = 0;
    for (UIView *ancestor = element; ancestor != nil && depth < 10;
         ancestor = ancestor.superview, depth++) {
        for (UIGestureRecognizer *recognizer in ancestor.gestureRecognizers) {
            if (![recognizer isKindOfClass:UITapGestureRecognizer.class]) continue;
            if (!YTAIFireTapGestureTargets(recognizer)) continue;
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                      @"mode": @"gesture",
                      @"class": NSStringFromClass([recognizer class]) ?: @"?",
                      @"depth": @(depth)});
            return YES;
        }
    }
    return NO;
}

static NSString *YTAIDescribeAiView(UIView *view);

static BOOL YTAIFireTapTargetsInSubtree(UIView *view, NSUInteger depth, NSUInteger *budget) {
    if (view == nil || depth > 6 || *budget == 0) return NO;
    (*budget)--;
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
        NSString *name = [NSStringFromClass([recognizer class]) lowercaseString] ?: @"";
        BOOL tappable = [recognizer isKindOfClass:UITapGestureRecognizer.class] ||
            ([name containsString:@"tap"] && ![name containsString:@"longpress"]);
        if (!tappable) continue;
        if (YTAIFireTapGestureTargets(recognizer)) {
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                      @"mode": @"subtree-gesture",
                      @"class": NSStringFromClass([recognizer class]) ?: @"?",
                      @"depth": @(depth)});
            return YES;
        }
    }
    for (UIView *subview in view.subviews)
        if (YTAIFireTapTargetsInSubtree(subview, depth + 1, budget)) return YES;
    return NO;
}

static BOOL YTAIPerformSubtreeGestureAction(UIView *element) {
    NSUInteger budget = 40;
    return YTAIFireTapTargetsInSubtree(element, 0, &budget);
}

static BOOL YTAIPerformSubtreeControlAction(UIView *element) {
    __block BOOL dispatched = NO;
    __block NSUInteger budget = 40;
    __block __weak void (^weakWalk)(UIView *);
    void (^walk)(UIView *) = ^(UIView *view) {
        if (dispatched || view == nil || budget == 0) return;
        budget--;
        if ([view isKindOfClass:UIControl.class]) {
            UIControl *control = (UIControl *)view;
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            dispatched = YES;
            return;
        }
        for (UIView *subview in view.subviews) weakWalk(subview);
    };
    weakWalk = walk;
    walk(element);
    return dispatched;
}

__attribute__((unused)) static void YTAILogViewSubtree(UIView *root, NSString *event) {
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    __block NSUInteger budget = 40;
    __block __weak void (^weakWalk)(UIView *, NSUInteger);
    void (^walk)(UIView *, NSUInteger) = ^(UIView *view, NSUInteger depth) {
        if (view == nil || budget == 0 || depth > 6 || entries.count >= 30) return;
        budget--;
        [entries addObject:[NSString stringWithFormat:@"d%lu %@",
                            (unsigned long)depth, YTAIDescribeAiView(view)]];
        for (UIView *subview in view.subviews) weakWalk(subview, depth + 1);
    };
    weakWalk = walk;
    walk(root, 0);
    YTRCLog(@{@"event": event, @"entries": entries});
}

static BOOL YTAIPerformControlAction(UIView *element) {
    for (UIView *ancestor = element; ancestor != nil; ancestor = ancestor.superview) {
        if (![ancestor isKindOfClass:UIControl.class]) continue;
        UIControl *control = (UIControl *)ancestor;
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
        [control sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-selected",
                  @"mode": @"control",
                  @"class": NSStringFromClass([control class]) ?: @"?"});
        return YES;
    }
    return NO;
}

static BOOL YTAISimulateTouchOnView(UIView *view) {
    if (view == nil || view.window == nil) return NO;
    CGRect frame = [view convertRect:view.bounds toView:view.window];
    if (CGRectIsEmpty(frame)) return NO;
    CGPoint center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
    UIView *hit = [view.window hitTest:center withEvent:nil];
    // CRITICAL: Only use hit if it is a descendant of view (inside the button).
    // If hit is an ancestor (e.g. YTELMView backdrop), DO NOT touch it!
    UIView *targetView = view;
    if (hit != nil && hit != view && [hit isDescendantOfView:view]) {
        targetView = hit;
    }

    UITouch *touch = [[UITouch alloc] init];
    @try { [touch setValue:targetView forKey:@"view"]; } @catch (NSException *e) {}
    @try { [touch setValue:view.window forKey:@"window"]; } @catch (NSException *e) {}
    @try { [touch setValue:@(UITouchPhaseBegan) forKey:@"phase"]; } @catch (NSException *e) {}
    @try { [touch setValue:@([NSDate.date timeIntervalSince1970]) forKey:@"timestamp"]; } @catch (NSException *e) {}

    // Configure physical window coordinates on UITouch
    Ivar locIvar = class_getInstanceVariable(UITouch.class, "_locationInWindow");
    if (locIvar != NULL) {
        *(CGPoint *)((uint8_t *)(__bridge void *)touch + ivar_getOffset(locIvar)) = center;
    }
    Ivar prevIvar = class_getInstanceVariable(UITouch.class, "_previousLocationInWindow");
    if (prevIvar != NULL) {
        *(CGPoint *)((uint8_t *)(__bridge void *)touch + ivar_getOffset(prevIvar)) = center;
    }

    NSSet *touches = [NSSet setWithObject:touch];
    @try { [targetView touchesBegan:touches withEvent:nil]; } @catch (NSException *e) {}

    id targetNode = YTAINodeOfView(targetView);
    if (targetNode != nil && [targetNode respondsToSelector:@selector(touchesBegan:withEvent:)]) {
        @try { ((void (*)(id, SEL, id, id))objc_msgSend)(targetNode, @selector(touchesBegan:withEvent:), touches, nil); } @catch (NSException *e) {}
    }

    @try { [touch setValue:@(UITouchPhaseEnded) forKey:@"phase"]; } @catch (NSException *e) {}
    @try { [targetView touchesEnded:touches withEvent:nil]; } @catch (NSException *e) {}
    if (targetNode != nil && [targetNode respondsToSelector:@selector(touchesEnded:withEvent:)]) {
        @try { ((void (*)(id, SEL, id, id))objc_msgSend)(targetNode, @selector(touchesEnded:withEvent:), touches, nil); } @catch (NSException *e) {}
    }

    SEL selFwd = NSSelectorFromString(@"__forwardTouchesEnded:withEvent:");
    if ([targetView respondsToSelector:selFwd]) {
        @try { ((void (*)(id, SEL, id, id))objc_msgSend)(targetView, selFwd, touches, nil); } @catch (NSException *e) {}
    }
    if (targetView != view) {
        @try { [view touchesBegan:touches withEvent:nil]; } @catch (NSException *e) {}
        @try { [view touchesEnded:touches withEvent:nil]; } @catch (NSException *e) {}
        id viewNode = YTAINodeOfView(view);
        if (viewNode != nil) {
            if ([viewNode respondsToSelector:@selector(touchesBegan:withEvent:)]) {
                @try { ((void (*)(id, SEL, id, id))objc_msgSend)(viewNode, @selector(touchesBegan:withEvent:), touches, nil); } @catch (NSException *e) {}
            }
            if ([viewNode respondsToSelector:@selector(touchesEnded:withEvent:)]) {
                @try { ((void (*)(id, SEL, id, id))objc_msgSend)(viewNode, @selector(touchesEnded:withEvent:), touches, nil); } @catch (NSException *e) {}
            }
        }
        if ([view respondsToSelector:selFwd]) {
            @try { ((void (*)(id, SEL, id, id))objc_msgSend)(view, selFwd, touches, nil); } @catch (NSException *e) {}
        }
    }
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"touch-simulated",
              @"class": NSStringFromClass([targetView class]) ?: @"?",
              @"hit": hit != nil ? NSStringFromClass([hit class]) ?: @"?" : @"(none)"});
    return YES;
}

static BOOL YTAIPerformAccessibilityCustomActions(UIView *view) {
    if (view == nil) return NO;
    BOOL fired = NO;
    NSMutableArray<id> *candidates = [NSMutableArray array];
    if (view.accessibilityCustomActions != nil)
        [candidates addObjectsFromArray:view.accessibilityCustomActions];
    id node = YTAINodeOfView(view);
    if (node != nil && [node respondsToSelector:@selector(accessibilityCustomActions)]) {
        @try {
            NSArray *nodeActions = ((id (*)(id, SEL))objc_msgSend)(node, @selector(accessibilityCustomActions));
            if (nodeActions != nil) [candidates addObjectsFromArray:nodeActions];
        } @catch (NSException *e) {}
    }
    for (id item in candidates) {
        if (![item isKindOfClass:UIAccessibilityCustomAction.class]) continue;
        UIAccessibilityCustomAction *action = (UIAccessibilityCustomAction *)item;
        id target = action.target;
        SEL selector = action.selector;
        if (target != nil && selector != NULL && [target respondsToSelector:selector]) {
            @try {
                ((void (*)(id, SEL, id))objc_msgSend)(target, selector, action);
                fired = YES;
            } @catch (NSException *e) {}
        }
    }
    if ([view respondsToSelector:@selector(accessibilityActivate)]) {
        @try {
            if ([view accessibilityActivate]) fired = YES;
        } @catch (NSException *e) {}
    }
    return fired;
}

static BOOL YTAIPerformNodeControllerCommand(UIView *view) {
    if (view == nil) return NO;
    id node = YTAINodeOfView(view);
    id controller = nil;
    if (node != nil && [node respondsToSelector:NSSelectorFromString(@"controller")]) {
        @try { controller = ((id (*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"controller")); } @catch (NSException *e) {}
    }
    if (controller == nil && node != nil) {
        @try { controller = [node valueForKey:@"_controller"]; } @catch (NSException *e) {}
    }
    if (controller == nil && [view respondsToSelector:NSSelectorFromString(@"controller")]) {
        @try { controller = ((id (*)(id, SEL))objc_msgSend)(view, NSSelectorFromString(@"controller")); } @catch (NSException *e) {}
    }
    if (controller == nil) return NO;

    BOOL triggered = NO;
    SEL selOnTap = NSSelectorFromString(@"sendOnTapCommand");
    if ([controller respondsToSelector:selOnTap]) {
        @try { ((void (*)(id, SEL))objc_msgSend)(controller, selOnTap); triggered = YES; } @catch (NSException *e) {}
    }
    SEL selTrigger = NSSelectorFromString(@"triggerCommand:");
    if ([controller respondsToSelector:selTrigger]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(controller, selTrigger, nil); triggered = YES; } @catch (NSException *e) {}
    }
    return triggered;
}

static void YTAIInstallObservationTraces(void) {
    // Disabled: Observation traces are no longer needed now that native handleTap on
    // ELMTouchCommandPropertiesHandler has been confirmed as YouTube's composer submission path.
}

static BOOL YTAIPerformAiActivation(UIView *element, YTAIActivationStrategy strategy) {
    switch (strategy) {
        case YTAIActivationCollection: return YTAIPerformCollectionSelection(element);
        case YTAIActivationNodeControl: return YTAIPerformNodeControlAction(element);
        case YTAIActivationAccessibility: return YTAIPerformAccessibilityActivation(element);
        case YTAIActivationGesture: return YTAIPerformGestureAction(element);
        case YTAIActivationUIControl: return YTAIPerformControlAction(element);
    }
    return NO;
}

static YTAIActivationStrategy YTAIPreferredElementStrategy(UIView *element) {
    NSUInteger depth = 0;
    for (UIView *view = element; view != nil && depth < 3; view = view.superview, depth++) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers)
            if ([recognizer isKindOfClass:UITapGestureRecognizer.class])
                return YTAIActivationGesture;
    }
    return YTAIActivationCollection;
}

static NSString *YTAIDescribeAiView(UIView *view) {
    NSMutableArray<NSString *> *gestures = [NSMutableArray array];
    for (UIGestureRecognizer *recognizer in view.gestureRecognizers)
        [gestures addObject:NSStringFromClass([recognizer class]) ?: @"?"];
    NSMutableString *extra = [NSMutableString string];
    if ([view isKindOfClass:UIControl.class]) {
        UIControl *control = (UIControl *)view;
        [extra appendFormat:@" events=%lu targets=%lu enabled=%d",
                             (unsigned long)control.allControlEvents,
                             (unsigned long)control.allTargets.count,
                             control.enabled ? 1 : 0];
    }
    id node = YTAINodeOfView(view);
    if (node != nil) [extra appendFormat:@" node=%@", YTAIDescribeNode(node)];
    return [NSString stringWithFormat:@"%@ id=%@ label=%@ a11y=%d ui=%d alpha=%.2f gestures=[%@]%@",
            NSStringFromClass([view class]) ?: @"?",
            view.accessibilityIdentifier ?: @"", view.accessibilityLabel ?: @"",
            view.isAccessibilityElement ? 1 : 0,
            view.userInteractionEnabled ? 1 : 0, view.alpha,
            [gestures componentsJoinedByString:@","], extra];
}

static void YTAILogViewChain(UIView *element, NSString *event) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    for (UIView *view = element; view != nil && chain.count < 14; view = view.superview)
        [chain addObject:YTAIDescribeAiView(view)];
    YTRCLog(@{@"event": event ?: @"ai-view-chain", @"chain": chain});
}

static void YTAILogAiEntryChain(UIView *element) {
    YTAILogViewChain(element, @"ai-entry-chain");
}

static BOOL YTAIViewIsVisibleOnScreen(UIView *view) {
    if (view == nil || view.window == nil || view.hidden || view.alpha < 0.05) return NO;
    CGRect frame = [view convertRect:view.bounds toView:view.window];
    return !CGRectIsEmpty(frame) && CGRectIntersectsRect(frame, view.window.bounds);
}

static BOOL YTAIHintLooksLikePromptInput(NSString *hint) {
    NSString *lower = hint.lowercaseString ?: @"";
    return [lower containsString:@"ask a question"] || [lower containsString:@"question"] ||
           [lower containsString:@"prompt"] || [lower containsString:@"message"] ||
           [lower containsString:@"gemini"];
}

static id YTAIFindEditableTextNode(UIView *focus, UIView **outComposerField) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *focusWindow = focus.window;
    if (focusWindow != nil) [windows addObject:focusWindow];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window != focusWindow) [windows addObject:window];
        }
    }

    Class elmCls = NSClassFromString(@"ELMEditableTextNode");
    Class asCls = NSClassFromString(@"ASEditableTextNode");

    auto isEditableNode = ^BOOL(id node) {
        if (node == nil) return NO;
        if (elmCls != nil && [node isKindOfClass:elmCls]) return YES;
        if (asCls != nil && [node isKindOfClass:asCls]) return YES;
        if ([node respondsToSelector:NSSelectorFromString(@"textView")]) return YES;
        return NO;
    };

    __block __weak id (^weakSearchNode)(id);
    id (^searchNode)(id) = ^id(id node) {
        if (node == nil) return nil;
        if (isEditableNode(node)) return node;
        if ([node respondsToSelector:NSSelectorFromString(@"subnodes")]) {
            NSArray *subnodes = nil;
            @try { subnodes = ((NSArray *(*)(id, SEL))objc_msgSend)(node, NSSelectorFromString(@"subnodes")); } @catch (NSException *e) {}
            for (id sub in subnodes) {
                id found = weakSearchNode(sub);
                if (found != nil) return found;
            }
        }
        return nil;
    };
    weakSearchNode = searchNode;

    // Phase 1: Search inside view with accessibilityIdentifier containing @"input_composer_text_field"
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block UIView *composerView = nil;
        __block __weak void (^weakFindComposer)(UIView *);
        void (^findComposer)(UIView *) = ^(UIView *v) {
            if (composerView != nil || v == nil) return;
            NSString *ident = v.accessibilityIdentifier ?: @"";
            if ([ident containsString:@"input_composer_text_field"]) {
                composerView = v;
                return;
            }
            for (UIView *sub in v.subviews) weakFindComposer(sub);
        };
        weakFindComposer = findComposer;
        findComposer(window);

        if (composerView != nil) {
            if (outComposerField) *outComposerField = composerView;
            __block id foundNode = nil;
            __block __weak void (^weakWalk)(UIView *);
            void (^walk)(UIView *) = ^(UIView *v) {
                if (foundNode != nil || v == nil) return;
                id n = YTAINodeOfView(v);
                id target = searchNode(n);
                if (target != nil) {
                    foundNode = target;
                    return;
                }
                for (UIView *sub in v.subviews) weakWalk(sub);
            };
            weakWalk = walk;
            walk(composerView);
            if (foundNode != nil) return foundNode;
        }
    }

    // Phase 2: Search all visible views in windows
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block id foundNode = nil;
        __block __weak void (^weakWalkAll)(UIView *);
        void (^walkAll)(UIView *) = ^(UIView *v) {
            if (foundNode != nil || v == nil) return;
            if (!YTAIViewIsVisibleOnScreen(v)) return;
            id n = YTAINodeOfView(v);
            id target = searchNode(n);
            if (target != nil) {
                foundNode = target;
                return;
            }
            for (UIView *sub in v.subviews) weakWalkAll(sub);
        };
        weakWalkAll = walkAll;
        walkAll(window);
        if (foundNode != nil) return foundNode;
    }

    // Phase 3: Check visible UITextViews directly
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block id foundNode = nil;
        __block __weak void (^weakWalkTv)(UIView *);
        void (^walkTv)(UIView *) = ^(UIView *v) {
            if (foundNode != nil || v == nil) return;
            if ([v isKindOfClass:UITextView.class] && YTAIViewIsVisibleOnScreen(v)) {
                id n = YTAINodeOfView(v);
                id target = searchNode(n);
                if (target != nil) {
                    foundNode = target;
                    return;
                }
            }
            for (UIView *sub in v.subviews) weakWalkTv(sub);
        };
        weakWalkTv = walkTv;
        walkTv(window);
        if (foundNode != nil) return foundNode;
    }

    return nil;
}

static UIView<UITextInput> *YTAIFindAiPromptInput(UIView *focus) {
    UIView *composerField = nil;
    id editableNode = YTAIFindEditableTextNode(focus, &composerField);
    if (editableNode != nil && [editableNode respondsToSelector:NSSelectorFromString(@"textView")]) {
        @try {
            UITextView *tv = ((UITextView *(*)(id, SEL))objc_msgSend)(editableNode, NSSelectorFromString(@"textView"));
            if (tv != nil && [tv isKindOfClass:UITextView.class]) {
                return (UIView<UITextInput> *)tv;
            }
        } @catch (NSException *e) {}
    }

    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *focusWindow = focus.window;
    if (focusWindow != nil) [windows addObject:focusWindow];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window != focusWindow) [windows addObject:window];
        }
    }
    __block UIView<UITextInput> *best = nil;
    __block NSInteger bestScore = -1;
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (view == nil) return;
            if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class]) {
                if (YTAIViewIsVisibleOnScreen(view)) {
                    NSString *identifier = view.accessibilityIdentifier ?: @"";
                    NSString *label = view.accessibilityLabel ?: @"";
                    NSString *placeholder = @"";
                    if ([view isKindOfClass:UITextField.class])
                        placeholder = ((UITextField *)view).placeholder ?: @"";
                    NSString *hint = [NSString stringWithFormat:@"%@ %@ %@",
                                      identifier, label, placeholder];
                    NSInteger score = 1;
                    if (YTAIHintLooksLikePromptInput(hint)) score += 5;
                    if (view.isFirstResponder) score += 2;
                    if (window == focusWindow) score += 1;
                    if (score > bestScore) {
                        bestScore = score;
                        best = (UIView<UITextInput> *)view;
                    }
                }
            }
            for (UIView *subview in view.subviews) weakWalk(subview);
        };
        weakWalk = walk;
        walk(window);
    }
    return best;
}

static BOOL YTAIViewIsExcludedFromAiSend(UIView *view, UIView *input, UIView *entry) {
    if (view == nil) return YES;
    if (input != nil) {
        if (view == input || [view isDescendantOfView:input] || [input isDescendantOfView:view])
            return YES;
    }
    if (entry != nil) {
        if (view == entry || [view isDescendantOfView:entry] || [entry isDescendantOfView:view])
            return YES;
    }
    if ([view isKindOfClass:UITextField.class] || [view isKindOfClass:UITextView.class])
        return YES;

    NSString *identifier = [view.accessibilityIdentifier lowercaseString] ?: @"";
    NSString *label = [view.accessibilityLabel lowercaseString] ?: @"";

    if ([identifier containsString:@"text_field"] || [identifier containsString:@"_text_input"] ||
        [identifier containsString:@"composer_text"] || [identifier containsString:@"placeholder"])
        return YES;

    if ([label containsString:@"ask about"] || [label containsString:@"ai overview"] ||
        [label containsString:@"terms"] || [label containsString:@"privacy"] ||
        [label containsString:@"disclaimer"])
        return YES;

    return NO;
}

static UIView *YTAIFindAiSendControl(UIView *input, UIView *entry) {
    if (input == nil && entry == nil) return nil;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *inputWindow = input.window ?: entry.window;
    if (inputWindow != nil) [windows addObject:inputWindow];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window != inputWindow) [windows addObject:window];
        }
    }

    // Step 1: Direct exact match for YouTube's known AI composer send button container
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block UIView *foundExact = nil;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (foundExact != nil || view == nil) return;
            if (YTAIViewIsExcludedFromAiSend(view, input, entry)) {
                if (input != nil && (view == input || [view isDescendantOfView:input])) return;
                if (entry != nil && (view == entry || [view isDescendantOfView:entry])) return;
                for (UIView *subview in view.subviews) weakWalk(subview);
                return;
            }
            NSString *identifier = [view.accessibilityIdentifier lowercaseString] ?: @"";
            if ([identifier isEqualToString:@"input_composer_send_button_container"] ||
                [identifier containsString:@"send_button"]) {
                if (YTAIViewIsVisibleOnScreen(view)) {
                    CGRect cFrame = [view convertRect:view.bounds toView:view.window];
                    if (cFrame.size.width >= 16 && cFrame.size.height >= 16) {
                        foundExact = view;
                        return;
                    }
                }
            }
            for (UIView *subview in view.subviews) weakWalk(subview);
        };
        weakWalk = walk;
        walk(window);
        if (foundExact != nil) return foundExact;
    }

    // Step 2: Search within the composer container hierarchy adjacent to `input`
    if (input != nil) {
        UIView *container = input.superview;
        for (NSUInteger depth = 0; depth < 12 && container != nil; depth++, container = container.superview) {
            for (UIView *child in container.subviews) {
                if (YTAIViewIsExcludedFromAiSend(child, input, entry)) continue;
                if (!YTAIViewIsVisibleOnScreen(child)) continue;

                NSString *identifier = [child.accessibilityIdentifier lowercaseString] ?: @"";
                NSString *label = [child.accessibilityLabel lowercaseString] ?: @"";

                BOOL isSendName = [identifier containsString:@"send"] || [identifier containsString:@"submit"] ||
                                  [label isEqualToString:@"send"] || [label containsString:@"send message"] ||
                                  [label containsString:@"send prompt"] || [label containsString:@"send question"] ||
                                  [label containsString:@"submit"] || [label containsString:@"arrow up"] ||
                                  [label containsString:@"up arrow"];

                CGRect cFrame = [child convertRect:child.bounds toView:child.window];
                BOOL hasSize = cFrame.size.width >= 16 && cFrame.size.height >= 16;

                if (isSendName && hasSize) return child;
            }
        }
    }

    // Step 3: Global search for explicit send button attributes
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block UIView *found = nil;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (found != nil || view == nil) return;
            if (YTAIViewIsExcludedFromAiSend(view, input, entry)) {
                if (input != nil && (view == input || [view isDescendantOfView:input])) return;
                if (entry != nil && (view == entry || [view isDescendantOfView:entry])) return;
                for (UIView *subview in view.subviews) weakWalk(subview);
                return;
            }
            NSString *identifier = [view.accessibilityIdentifier lowercaseString] ?: @"";
            NSString *label = [view.accessibilityLabel lowercaseString] ?: @"";

            BOOL match = [identifier containsString:@"send"] ||
                         [identifier containsString:@"submit"] ||
                         [label isEqualToString:@"send"] || [label containsString:@"send message"] ||
                         [label containsString:@"send prompt"] || [label containsString:@"send question"] ||
                         [label containsString:@"submit"] || [label containsString:@"arrow up"] ||
                         [label containsString:@"up arrow"];
            if (match && YTAIViewIsVisibleOnScreen(view)) {
                CGRect cFrame = [view convertRect:view.bounds toView:view.window];
                if (cFrame.size.width >= 16 && cFrame.size.height >= 16) {
                    found = view;
                    return;
                }
            }
            for (UIView *subview in view.subviews) weakWalk(subview);
        };
        weakWalk = walk;
        walk(window);
        if (found != nil) return found;
    }

    // Step 4: Window hit-test at point to the right of input
    if (input != nil && input.window != nil) {
        CGRect inputFrame = [input convertRect:input.bounds toView:input.window];
        if (!CGRectIsEmpty(inputFrame)) {
            CGFloat targetX = MIN(input.window.bounds.size.width - 24.0, CGRectGetMaxX(inputFrame) + 24.0);
            CGPoint sendPoint = CGPointMake(targetX, CGRectGetMidY(inputFrame));
            UIView *hit = [input.window hitTest:sendPoint withEvent:nil];
            if (hit != nil && !YTAIViewIsExcludedFromAiSend(hit, input, entry)) {
                if (YTAIViewIsVisibleOnScreen(hit)) return hit;
            }
        }
    }

    return nil;
}

static void YTAILogSendGestures(UIView *send) {
    if (send == nil) return;
    NSMutableArray *recInfos = [NSMutableArray array];
    void (^inspect)(UIView *) = ^(UIView *v) {
        for (UIGestureRecognizer *rec in v.gestureRecognizers) {
            NSArray *pairs = nil;
            @try { pairs = [rec valueForKey:@"_targets"]; } @catch (NSException *e) {}
            NSMutableArray *targetList = [NSMutableArray array];
            if ([pairs isKindOfClass:NSArray.class]) {
                for (id pair in pairs) {
                    id target = nil;
                    @try { target = [pair valueForKey:@"_target"]; } @catch (NSException *e) {}
                    SEL action = YTAIReadIVarSEL(pair, "_action");
                    [targetList addObject:[NSString stringWithFormat:@"%@->%@",
                        target ? NSStringFromClass([target class]) : @"nil",
                        action ? NSStringFromSelector(action) : @"nil"]];
                }
            }
            [recInfos addObject:@{
                @"view": NSStringFromClass([v class]) ?: @"?",
                @"rec": NSStringFromClass([rec class]) ?: @"?",
                @"state": @(rec.state),
                @"enabled": @(rec.isEnabled),
                @"targets": targetList
            }];
        }
    };
    inspect(send);
    for (UIView *sub in send.subviews) inspect(sub);
    YTRCLog(@{@"event": @"ai-send-gestures", @"recognizers": recInfos});
}

static BOOL YTAIFireSendGesture(UIView *send) {
    if (send == nil) return NO;

    NSMutableArray<UIView *> *candidates = [NSMutableArray arrayWithObject:send];
    for (UIView *sub in send.subviews) [candidates addObject:sub];

    for (UIView *v in candidates) {
        NSArray *recognizers = [v.gestureRecognizers copy];
        for (UIGestureRecognizer *rec in recognizers) {
            NSArray *pairs = nil;
            @try {
                id rawPairs = [rec valueForKey:@"_targets"];
                if ([rawPairs isKindOfClass:NSArray.class]) {
                    pairs = [rawPairs copy];
                }
            } @catch (NSException *e) {}
            if (pairs.count == 0) continue;

            YTAISetGestureState(rec, UIGestureRecognizerStateEnded);

            for (id pair in pairs) {
                id target = nil;
                @try { target = [pair valueForKey:@"_target"]; } @catch (NSException *e) {}
                if (target == nil) continue;

                SEL action = YTAIReadIVarSEL(pair, "_action");
                NSString *targetClass = NSStringFromClass([target class]);
                NSString *actionName = action ? NSStringFromSelector(action) : @"(null)";

                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-target-found",
                          @"target": targetClass ?: @"?",
                          @"action": actionName ?: @"?",
                          @"rec": NSStringFromClass([rec class]) ?: @"?"});

                // Priority 1: Direct handleTap on ELMTouchCommandPropertiesHandler
                if ([target respondsToSelector:NSSelectorFromString(@"handleTap")]) {
                    @try {
                        ((void (*)(id, SEL))objc_msgSend)(target, NSSelectorFromString(@"handleTap"));
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-action-dispatched",
                                  @"method": @"handleTap-direct"});
                        return YES;
                    } @catch (NSException *e) {
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-action-exception",
                                  @"method": @"handleTap-direct", @"error": e.name ?: @"?"});
                    }
                }

                // Priority 2: UIKit native _sendActionWithGestureRecognizer:
                SEL selSend = NSSelectorFromString(@"_sendActionWithGestureRecognizer:");
                if ([pair respondsToSelector:selSend]) {
                    @try {
                        ((void (*)(id, SEL, id))objc_msgSend)(pair, selSend, rec);
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-action-dispatched",
                                  @"method": @"_sendActionWithGestureRecognizer:"});
                        return YES;
                    } @catch (NSException *e) {
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-action-exception",
                                  @"method": @"_sendActionWithGestureRecognizer:", @"error": e.name ?: @"?"});
                    }
                }

                // Priority 3: Standard invocation
                if (action != NULL) {
                    NSMethodSignature *sig = nil;
                    @try { sig = [target methodSignatureForSelector:action]; } @catch (NSException *e) {}
                    if (sig != nil && sig.numberOfArguments <= 3) {
                        @try {
                            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                            inv.target = target;
                            inv.selector = action;
                            if (sig.numberOfArguments == 3) {
                                UIGestureRecognizer *arg = rec;
                                [inv setArgument:&arg atIndex:2];
                            }
                            [inv invoke];
                            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-action-dispatched",
                                      @"method": @"invocation"});
                            return YES;
                        } @catch (NSException *e) {
                            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-action-exception",
                                      @"method": @"invocation", @"error": e.name ?: @"?"});
                        }
                    }
                }

                if (YTAISubmitRequestObserved) return YES;
            }
        }
    }
    return NO;
}

static void YTAITriggerSendPipeline(UIView *send, UIView *realEditor, NSUInteger run) {
    YTAIPromptSendAttempted = YES;
    if (send == nil && realEditor != nil && realEditor.window != nil) {
        send = YTAIFindAiSendControl(realEditor, realEditor);
    }
    if (send == nil) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-control-not-found", @"run": @(run)});
        return;
    }

    YTAILogSendGestures(send);

    // Stage 1 (immediate, 10ms): Native gesture target-action (handleTap)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (run != YTAIRunToken || YTAISubmitRequestObserved) return;
        BOOL gestureDispatched = YTAIFireSendGesture(send);
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-attempt",
                  @"stage": @(1), @"strategy": @"gesture-handleTap",
                  @"dispatched": @(gestureDispatched),
                  @"run": @(run)});

        // Fast follow-up: if Stage 1 didn't trigger network submit, Stage 2 fires after 0.25s (not 2.0s)
        NSTimeInterval nextDelay = gestureDispatched ? 0.25 : 0.08;

        // Stage 2: Synthesized touch with exact window coordinates
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(nextDelay * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (run != YTAIRunToken || YTAISubmitRequestObserved) {
                if (gestureDispatched) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-request-confirmed",
                              @"winningStage": @(1), @"run": @(run)});
                }
                return;
            }
            BOOL touchDispatched = YTAISimulateTouchOnView(send);
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-attempt",
                      @"stage": @(2), @"strategy": @"simulate-touch",
                      @"dispatched": @(touchDispatched),
                      @"run": @(run)});

            NSTimeInterval stage3Delay = touchDispatched ? 0.25 : 0.08;

            // Stage 3: Node control & accessibility custom actions
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(stage3Delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (run != YTAIRunToken || YTAISubmitRequestObserved) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-request-confirmed",
                              @"winningStage": @(2), @"run": @(run)});
                    return;
                }
                BOOL a11yDispatched = YTAIPerformAccessibilityCustomActions(send);
                BOOL nodeDispatched = YTAIPerformNodeControllerCommand(send) || YTAIPerformNodeControlAction(send);
                BOOL controlDispatched = YTAIPerformControlAction(send) || YTAIPerformSubtreeControlAction(send);
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-attempt",
                          @"stage": @(3), @"strategy": @"node-and-a11y",
                          @"dispatched": @(a11yDispatched || nodeDispatched || controlDispatched),
                          @"run": @(run)});

                // Stage 4: Return key on editor
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (run != YTAIRunToken || YTAISubmitRequestObserved) {
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-request-confirmed",
                                  @"winningStage": @(3), @"run": @(run)});
                        return;
                    }
                    if ([realEditor isKindOfClass:UITextView.class]) {
                        UITextView *tv = (UITextView *)realEditor;
                        if ([tv.delegate respondsToSelector:@selector(textView:shouldChangeTextInRange:replacementText:)]) {
                            @try {
                                NSRange endRange = NSMakeRange(tv.text.length, 0);
                                BOOL allowed = ((BOOL (*)(id, SEL, id, NSRange, id))objc_msgSend)(
                                    tv.delegate, @selector(textView:shouldChangeTextInRange:replacementText:), tv, endRange, @"\n");
                                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-attempt",
                                          @"stage": @(4), @"strategy": @"editor-return-key",
                                          @"allowed": @(allowed),
                                          @"run": @(run)});
                            } @catch (NSException *e) {}
                        }
                    }
                });
            });
        });
    });
}

static BOOL YTAIAnswerIsLoading(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.05) continue;
            __block BOOL loading = NO;
            __block NSUInteger budget = 4000;
            __block __weak void (^weakWalk)(UIView *);
            void (^walk)(UIView *) = ^(UIView *view) {
                if (loading || view == nil || budget == 0) return;
                budget--;
                if (view.hidden || view.alpha < 0.01) return;
                NSString *identifier = [view.accessibilityIdentifier lowercaseString] ?: @"";
                NSString *label = [view.accessibilityLabel lowercaseString] ?: @"";
                if ([identifier containsString:@"loading_response"] ||
                    [label containsString:@"asking gemini"] ||
                    [label containsString:@"load in progress"] ||
                    [label containsString:@"generating"]) {
                    loading = YES;
                    return;
                }
                for (UIView *subview in view.subviews) weakWalk(subview);
            };
            weakWalk = walk;
            walk(window);
            if (loading) return YES;
        }
    }
    return NO;
}

static BOOL YTAITypePrompt(UIView *focus, NSString *prompt, NSUInteger run, void (^completion)(void)) {
    UIView *composerField = nil;
    id editableNode = YTAIFindEditableTextNode(focus, &composerField);
    UITextView *nodeEditor = nil;
    if (editableNode != nil && [editableNode respondsToSelector:NSSelectorFromString(@"textView")]) {
        @try {
            nodeEditor = ((UITextView *(*)(id, SEL))objc_msgSend)(editableNode, NSSelectorFromString(@"textView"));
        } @catch (NSException *e) {}
    }

    UIView<UITextInput> *chosenInput = YTAIFindAiPromptInput(focus);
    if (chosenInput == nil && nodeEditor != nil) {
        chosenInput = (UIView<UITextInput> *)nodeEditor;
    }
    if (chosenInput == nil) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"prompt-input-missing", @"run": @(run)});
        return NO;
    }

    BOOL chosenMatches = (nodeEditor != nil && (UIView *)chosenInput == (UIView *)nodeEditor);
    BOOL uie = chosenInput.userInteractionEnabled;
    BOOL editable = YES;
    if ([chosenInput isKindOfClass:UITextView.class]) {
        editable = ((UITextView *)chosenInput).isEditable;
    } else if ([chosenInput isKindOfClass:UITextField.class]) {
        editable = ((UITextField *)chosenInput).isEnabled;
    }

    // Exclusively use nodeEditor as verified in Texture docs and binary
    UIView<UITextInput> *realEditor = (nodeEditor != nil) ? (UIView<UITextInput> *)nodeEditor : chosenInput;

    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"prompt-editor-verified",
              @"nodeClass": editableNode ? NSStringFromClass([editableNode class]) : @"(none)",
              @"editorClass": NSStringFromClass([realEditor class]) ?: @"?",
              @"chosenMatches": @(chosenMatches),
              @"userInteractionEnabled": @(uie),
              @"editable": @(editable),
              @"isFirstResponder": @(realEditor.isFirstResponder),
              @"run": @(run)});

    BOOL firstResp = [realEditor becomeFirstResponder];
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"first-responder-result",
              @"becameFirstResponder": @(firstResp),
              @"isFirstResponder": @(realEditor.isFirstResponder),
              @"run": @(run)});

    // Clear existing text without touching placeholder or replacing delegates
    UITextRange *all = [realEditor textRangeFromPosition:realEditor.beginningOfDocument toPosition:realEditor.endOfDocument];
    if (all != nil && [realEditor textInRange:all].length > 0) {
        [realEditor replaceRange:all withText:@""];
    }

    NSString *identifier = realEditor.accessibilityIdentifier ?: @"";
    NSString *label = realEditor.accessibilityLabel ?: @"";
    NSUInteger length = prompt.length;
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"prompt-typing",
              @"class": NSStringFromClass([realEditor class]) ?: @"?",
              @"identifier": identifier, @"label": label,
              @"chars": @(length),
              @"run": @(run)});

    const double kCharDelay = 0.012; // 12ms per char for crisp, fluid typing
    for (NSUInteger index = 0; index < length; index++) {
        NSString *character = [prompt substringWithRange:NSMakeRange(index, 1)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((kCharDelay * (double)(index + 1)) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (run != YTAIRunToken || !YTAIViewIsVisibleOnScreen((UIView *)realEditor)) return;
            [realEditor insertText:character];
            if (index == length - 1) {
                if ([realEditor isKindOfClass:UITextView.class]) {
                    UITextView *tv = (UITextView *)realEditor;
                    if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                        @try { [tv.delegate textViewDidChange:tv]; } @catch (NSException *e) {}
                    }
                    [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification object:tv];
                }
            }
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((kCharDelay * (double)length + 0.04) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (run != YTAIRunToken || !YTAIViewIsVisibleOnScreen((UIView *)realEditor)) return;
        NSString *currentText = [realEditor isKindOfClass:UITextView.class]
            ? ((UITextView *)realEditor).text
            : ([realEditor isKindOfClass:UITextField.class] ? ((UITextField *)realEditor).text : @"");

        NSString *nodeText = @"";
        if (editableNode != nil && [editableNode respondsToSelector:NSSelectorFromString(@"attributedText")]) {
            @try {
                NSAttributedString *attr = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(editableNode, NSSelectorFromString(@"attributedText"));
                nodeText = attr.string ?: @"";
            } @catch (NSException *e) {}
        }

        // If nodeText does not yet reflect typed prompt, trigger standard textViewDidChange:
        if (![nodeText containsString:prompt] && [realEditor isKindOfClass:UITextView.class]) {
            UITextView *tv = (UITextView *)realEditor;
            if ([tv.delegate respondsToSelector:@selector(textViewDidChange:)]) {
                @try { [tv.delegate textViewDidChange:tv]; } @catch (NSException *e) {}
            }
            [NSNotificationCenter.defaultCenter postNotificationName:UITextViewTextDidChangeNotification object:tv];

            if (editableNode != nil && [editableNode respondsToSelector:NSSelectorFromString(@"attributedText")]) {
                @try {
                    NSAttributedString *attr = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(editableNode, NSSelectorFromString(@"attributedText"));
                    nodeText = attr.string ?: @"";
                } @catch (NSException *e) {}
            }
        }

        UIView *send = YTAIFindAiSendControl((UIView *)realEditor, focus);
        CGRect sFrame = (send != nil && send.window != nil)
            ? [send convertRect:send.bounds toView:send.window] : CGRectZero;

        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"prompt-typed-ready-for-send",
                  @"editorText": currentText ?: @"",
                  @"nodeText": nodeText ?: @"",
                  @"prompt": prompt,
                  @"editorMatches": @([currentText isEqualToString:prompt]),
                  @"nodeMatches": @([nodeText containsString:prompt]),
                  @"sendFound": @(send != nil),
                  @"sendFrame": NSStringFromCGRect(sFrame),
                  @"sendLabel": send.accessibilityLabel ?: @"",
                  @"sendId": send.accessibilityIdentifier ?: @"",
                  @"run": @(run)});

        // Trigger automated Send pipeline
        YTAITriggerSendPipeline(send, (UIView *)realEditor, run);

        if (completion != nil) completion();
    });

    return YES;
}

static void YTAIDumpAiUiFromView(UIView *focus) {
    NSMutableArray<NSString *> *entries = [NSMutableArray array];
    UIView *priorityRoot = nil;
    for (UIView *view = focus; view != nil; view = view.superview) {
        NSString *name = NSStringFromClass([view class]).lowercaseString ?: @"";
        if ([name containsString:@"watchlayer"] || [name containsString:@"watchoverlay"] ||
            [name containsString:@"overlayview"] || [name containsString:@"watchview"])
            priorityRoot = view;
    }
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *focusWindow = focus.window;
    if (focusWindow != nil) [windows addObject:focusWindow];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window != focusWindow) [windows addObject:window];
        }
    }
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha < 0.05) continue;
        __block NSUInteger budget = 500;
        __block __weak void (^weakWalk)(UIView *, NSUInteger, BOOL);
        void (^walk)(UIView *, NSUInteger, BOOL) = ^(UIView *view, NSUInteger depth, BOOL skipPriority) {
            if (view == nil || budget == 0 || entries.count >= 220 || depth > 40) return;
            if (skipPriority && view == priorityRoot) return;
            budget--;
            NSString *identifier = view.accessibilityIdentifier ?: @"";
            NSString *label = view.accessibilityLabel ?: @"";
            if (label.length > 100) label = [[label substringToIndex:100] stringByAppendingString:@"…"];
            if ([view isKindOfClass:UIControl.class] || identifier.length != 0 || label.length != 0) {
                CGRect frame = [view convertRect:view.bounds toView:window];
                [entries addObject:[NSString stringWithFormat:
                    @"d%lu %@ id=%@ label=%@ frame=%.0f,%.0f,%.0f,%.0f",
                    (unsigned long)depth, NSStringFromClass([view class]), identifier, label,
                    frame.origin.x, frame.origin.y, frame.size.width, frame.size.height]];
            }
            for (UIView *subview in view.subviews) weakWalk(subview, depth + 1, skipPriority);
        };
        weakWalk = walk;
        if (priorityRoot != nil && priorityRoot.window == window) {
            walk(priorityRoot, 0, NO);
            walk(window, 0, YES);
        } else {
            walk(window, 0, NO);
        }
    }
    YTRCLog(@{@"event": @"ai-ui-dump",
              @"focus": focus != nil ? NSStringFromClass([focus class]) ?: @"?" : @"(none)",
              @"priorityRoot": priorityRoot != nil
                  ? NSStringFromClass([priorityRoot class]) ?: @"?" : @"(none)",
              @"entries": entries});
}

static void YTAIDumpAiUi(void) {
    YTAIDumpAiUiFromView(nil);
}

static UIView *YTAIResolveInteractiveControl(UIView *view) {
    if (view == nil) return nil;
    if ([view isKindOfClass:[UIControl class]]) return view;
    for (UIGestureRecognizer *r in view.gestureRecognizers) {
        if ([r isKindOfClass:[UITapGestureRecognizer class]]) return view;
    }
    for (UIView *p = view.superview; p != nil; p = p.superview) {
        if ([p isKindOfClass:[UIControl class]] || [p isKindOfClass:[UICollectionViewCell class]]) {
            return p;
        }
        for (UIGestureRecognizer *r in p.gestureRecognizers) {
            if ([r isKindOfClass:[UITapGestureRecognizer class]]) return p;
        }
    }
    return view;
}

static UIView *YTAIFindAiEntryControl(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    UIWindow *keyWin = UIApplication.sharedApplication.keyWindow;
    if (keyWin != nil && !keyWin.hidden && keyWin.alpha >= 0.05) {
        [windows addObject:keyWin];
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha >= 0.05 && ![windows containsObject:window]) {
                [windows addObject:window];
            }
        }
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window.hidden && window.alpha >= 0.05 && ![windows containsObject:window]) {
            [windows addObject:window];
        }
    }

    __block UIView *bestFound = nil;
    __block UIView *bestFallback = nil;

    for (UIWindow *window in windows) {
        __block NSUInteger budget = 4000;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (bestFound != nil || view == nil || budget == 0) return;
            budget--;
            if (view.hidden || view.alpha < 0.01) return;

            NSString *identifier = [view.accessibilityIdentifier lowercaseString] ?: @"";
            NSMutableString *allText = [NSMutableString string];
            if (view.accessibilityLabel.length > 0) {
                [allText appendFormat:@"%@ ", [view.accessibilityLabel lowercaseString]];
            }
            if ([view isKindOfClass:[UIButton class]]) {
                NSString *btnTitle = [((UIButton *)view) titleForState:UIControlStateNormal];
                if (btnTitle.length > 0) [allText appendFormat:@"%@ ", [btnTitle lowercaseString]];
            }
            if ([view respondsToSelector:@selector(text)]) {
                @try {
                    id txt = ((UILabel *)view).text;
                    if ([txt isKindOfClass:[NSString class]] && [(NSString *)txt length] > 0) {
                        [allText appendFormat:@"%@ ", [(NSString *)txt lowercaseString]];
                    }
                } @catch (NSException *e) {}
            }
            if ([view respondsToSelector:@selector(attributedText)]) {
                @try {
                    NSAttributedString *atxt = ((UILabel *)view).attributedText;
                    if (atxt.string.length > 0) {
                        [allText appendFormat:@"%@ ", [atxt.string lowercaseString]];
                    }
                } @catch (NSException *e) {}
            }

            BOOL identifierMatch = [identifier containsString:@"you-chat-entrypoint"] ||
                [identifier containsString:@"youchat"] ||
                [identifier containsString:@"ask"] ||
                [identifier containsString:@"gemini"] ||
                [identifier containsString:@"summarize"] ||
                [identifier containsString:@"ai-overview"] ||
                [identifier containsString:@"ai_overview"] ||
                [identifier containsString:@"ai-summary"] ||
                [identifier containsString:@"ai_summary"];

            BOOL strongLabel = [allText containsString:@"ai overview"] ||
                [allText containsString:@"ask about this video"] ||
                [allText containsString:@"ask gemini"] ||
                [allText containsString:@"summarize this video"] ||
                [allText containsString:@"summarize the video"] ||
                [allText containsString:@"summarize video"] ||
                [allText containsString:@"ask a question"] ||
                [allText isEqualToString:@"ask "] ||
                [allText hasPrefix:@"ask "] ||
                [allText hasSuffix:@" ask "] ||
                [allText containsString:@" ask "] ||
                [allText isEqualToString:@"gemini "] ||
                [allText isEqualToString:@"summarize "];

            BOOL isVisible = YTAIViewIsVisibleOnScreen(view);

            if (identifierMatch || strongLabel) {
                UIView *interactive = YTAIResolveInteractiveControl(view);
                if (isVisible) {
                    bestFound = interactive;
                    return;
                } else if (bestFound == nil) {
                    bestFound = interactive;
                }
            }

            if (bestFallback == nil) {
                if ([allText containsString:@"ask"] ||
                    [allText containsString:@"gemini"] ||
                    [allText containsString:@"summariz"] ||
                    [identifier containsString:@"sparkle"] ||
                    [identifier containsString:@"chat"]) {
                    bestFallback = YTAIResolveInteractiveControl(view);
                }
            }

            for (UIView *subview in view.subviews) weakWalk(subview);
        };
        weakWalk = walk;
        walk(window);
        if (bestFound != nil && YTAIViewIsVisibleOnScreen(bestFound)) return bestFound;
    }
    if (bestFound != nil) return bestFound;
    if (bestFallback != nil) return bestFallback;
    return nil;
}

static NSData *YTAIBase64DecodeAny(NSString *string) {
    if (string.length == 0) return nil;
    NSString *unescaped = [string stringByRemovingPercentEncoding] ?: string;
    NSMutableString *clean = [NSMutableString stringWithCapacity:unescaped.length];
    for (NSUInteger index = 0; index < unescaped.length; index++) {
        unichar character = [unescaped characterAtIndex:index];
        if (character == '-') character = '+';
        else if (character == '_') character = '/';
        BOOL alphabet = (character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
            (character >= '0' && character <= '9') || character == '+' || character == '/';
        if (alphabet) [clean appendString:[NSString stringWithCharacters:&character length:1]];
    }
    while (clean.length % 4 != 0) [clean appendString:@"="];
    return [[NSData alloc] initWithBase64EncodedString:clean options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

static BOOL YTAIExtractSessionFromTeaserToken(NSString *teaserToken, NSString **outVideoId, NSString **outConversationId) {
    if (teaserToken.length == 0) return NO;
    NSString *cleanToken = teaserToken;
    if ([cleanToken hasPrefix:@"kta-"]) cleanToken = [cleanToken substringFromIndex:4];
    cleanToken = [cleanToken stringByRemovingPercentEncoding] ?: cleanToken;

    NSMutableString *b64 = [cleanToken mutableCopy];
    [b64 replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, b64.length)];
    [b64 replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, b64.length)];
    while (b64.length % 4 != 0) [b64 appendString:@"="];
    NSData *outerData = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (outerData.length < 16) return NO;

    const uint8_t *bytes = (const uint8_t *)outerData.bytes;
    NSUInteger len = outerData.length;

    NSData *needle = [@"kg" dataUsingEncoding:NSASCIIStringEncoding];
    NSRange r = [outerData rangeOfData:needle options:0 range:NSMakeRange(0, len)];
    if (r.location == NSNotFound) return NO;

    NSString *innerQuoted = [[NSString alloc] initWithBytes:bytes + r.location length:len - r.location encoding:NSASCIIStringEncoding];
    if (innerQuoted.length == 0) return NO;
    NSString *innerB64Str = [innerQuoted stringByRemovingPercentEncoding] ?: innerQuoted;

    NSMutableString *innerB64Clean = [innerB64Str mutableCopy];
    [innerB64Clean replaceOccurrencesOfString:@"-" withString:@"+" options:0 range:NSMakeRange(0, innerB64Clean.length)];
    [innerB64Clean replaceOccurrencesOfString:@"_" withString:@"/" options:0 range:NSMakeRange(0, innerB64Clean.length)];
    while (innerB64Clean.length % 4 != 0) [innerB64Clean appendString:@"="];
    NSData *innerData = [[NSData alloc] initWithBase64EncodedString:innerB64Clean options:NSDataBase64DecodingIgnoreUnknownCharacters];
    if (innerData.length < 20) return NO;

    const uint8_t *ibytes = (const uint8_t *)innerData.bytes;
    NSUInteger ilen = innerData.length;

    NSString *vid = nil;
    NSString *cid = nil;

    for (NSUInteger i = 0; i + 2 < ilen; i++) {
        if (ibytes[i] == 0x12 && ibytes[i+1] == 11 && i + 2 + 11 <= ilen) {
            vid = [[NSString alloc] initWithBytes:ibytes + i + 2 length:11 encoding:NSASCIIStringEncoding];
        }
        if (ibytes[i] == 0x22 && ibytes[i+1] == 26 && i + 2 + 26 <= ilen) {
            cid = [[NSString alloc] initWithBytes:ibytes + i + 2 length:26 encoding:NSASCIIStringEncoding];
        }
    }

    if (vid.length == 11 && cid.length == 26) {
        if (outVideoId) *outVideoId = vid;
        if (outConversationId) *outConversationId = cid;
        return YES;
    }
    return NO;
}

static NSString *YTAIConstructToken(NSString *videoId, NSString *conversationId, BOOL isBootstrap) {
    if (videoId.length != 11 || conversationId.length == 0) return nil;

    // 1. Inner payload: Field 1 (varint 1) + Field 2 (videoId) + Field 4 (convId) [+ Field 5 for bootstrap]
    NSMutableData *innerPayload = [NSMutableData data];
    const uint8_t f1[] = {0x08, 0x01};
    [innerPayload appendBytes:f1 length:sizeof(f1)];

    const uint8_t f2Tag[] = {0x12, (uint8_t)videoId.length};
    [innerPayload appendBytes:f2Tag length:sizeof(f2Tag)];
    [innerPayload appendData:[videoId dataUsingEncoding:NSASCIIStringEncoding]];

    const uint8_t f4Tag[] = {0x22, (uint8_t)conversationId.length};
    [innerPayload appendBytes:f4Tag length:sizeof(f4Tag)];
    [innerPayload appendData:[conversationId dataUsingEncoding:NSASCIIStringEncoding]];

    if (isBootstrap) {
        const uint8_t f5[] = {0x2a, 0x02, 0x20, 0x01};
        [innerPayload appendBytes:f5 length:sizeof(f5)];
    }

    // 2. Inner wrapper: \x92\x0a + payload length
    NSMutableData *innerMessage = [NSMutableData data];
    const uint8_t innerTag[] = {0x92, 0x0a, (uint8_t)innerPayload.length};
    [innerMessage appendBytes:innerTag length:sizeof(innerTag)];
    [innerMessage appendData:innerPayload];

    // 3. Base64 encode and percent-encode padding
    NSString *innerB64 = [innerMessage base64EncodedStringWithOptions:0];
    NSMutableCharacterSet *allowed = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [allowed addCharactersInString:@"-_."];
    NSString *innerQuoted = [innerB64 stringByAddingPercentEncodingWithAllowedCharacters:allowed];
    NSData *innerQuotedData = [innerQuoted dataUsingEncoding:NSASCIIStringEncoding];

    // 4. Outer payload: Field 2 ("PAyouchat") + Field 3 (innerQuoted)
    NSMutableData *outerPayload = [NSMutableData data];
    const uint8_t f2Outer[] = {0x12, 0x09, 'P', 'A', 'y', 'o', 'u', 'c', 'h', 'a', 't'};
    [outerPayload appendBytes:f2Outer length:sizeof(f2Outer)];

    const uint8_t f3OuterTag[] = {0x1a, (uint8_t)innerQuotedData.length};
    [outerPayload appendBytes:f3OuterTag length:sizeof(f3OuterTag)];
    [outerPayload appendData:innerQuotedData];

    // 5. Outer wrapper: \x9e\x0b framing header + payload length
    NSMutableData *outerMessage = [NSMutableData data];
    const uint8_t outerTag[] = {0x9e, 0x0b, (uint8_t)outerPayload.length};
    [outerMessage appendBytes:outerTag length:sizeof(outerTag)];
    [outerMessage appendData:outerPayload];

    // 6. Base64URL encode and prefix with kta-
    NSString *outerB64 = [outerMessage base64EncodedStringWithOptions:0];
    NSMutableString *b64url = [NSMutableString stringWithCapacity:outerB64.length];
    for (NSUInteger i = 0; i < outerB64.length; i++) {
        unichar c = [outerB64 characterAtIndex:i];
        if (c == '+') [b64url appendString:@"-"];
        else if (c == '/') [b64url appendString:@"_"];
        else if (c == '=') [b64url appendString:@"%3D"];
        else [b64url appendString:[NSString stringWithCharacters:&c length:1]];
    }

    return [@"kta-" stringByAppendingString:b64url];
}

static inline NSString *YTAIConstructSubmissionToken(NSString *videoId, NSString *conversationId) {
    return YTAIConstructToken(videoId, conversationId, NO);
}

static inline NSString *YTAIConstructBootstrapToken(NSString *videoId, NSString *conversationId) {
    return YTAIConstructToken(videoId, conversationId, YES);
}

static uint64_t YTAIHashString(NSString *str) {
    if (str.length == 0) return 0;
    const char *bytes = [str UTF8String];
    uint64_t hash = 14695981039346656037ULL;
    while (*bytes) {
        hash ^= (uint64_t)(unsigned char)(*bytes++);
        hash *= 1099511628211ULL;
    }
    return hash;
}

static void YTAIAppendTokenLayerText(NSData *data, NSMutableString *text, NSUInteger depth) {
    if (data.length == 0 || depth > 3 || text.length > 20000) return;
    NSString *layer = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    if (layer.length != 0) [text appendString:layer];
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger i = 0;
    while (i < data.length) {
        NSUInteger start = i;
        while (i < data.length && (isalnum(bytes[i]) || bytes[i] == '-' || bytes[i] == '_' ||
                                   bytes[i] == '+' || bytes[i] == '/' || bytes[i] == '%' || bytes[i] == '='))
            i++;
        NSUInteger runLength = i - start;
        if (runLength < 16) {
            if (i == start) i++;
            continue;
        }
        NSString *run = [[NSString alloc] initWithBytes:bytes + start length:runLength
                                               encoding:NSASCIIStringEncoding];
        if (run.length == 0) continue;
        NSData *inner = YTAIBase64DecodeAny(run);
        if (inner.length < 8) continue;
        [text appendString:run];
        YTAIAppendTokenLayerText(inner, text, depth + 1);
    }
}

static NSUInteger YTAIWireSkipVarintBytes(const uint8_t *bytes, NSUInteger length, NSUInteger offset) {
    NSUInteger position = offset;
    while (position < length) {
        if (!(bytes[position] & 0x80)) return position + 1;
        position += 1;
    }
    return 0;
}

static BOOL YTAIWireWalkValues(const uint8_t *bytes, NSUInteger length, NSUInteger depth,
                               NSUInteger *budget,
                               BOOL (^visit)(const uint8_t *value, NSUInteger valueLength)) {
    if (depth > 32) return NO;
    NSUInteger i = 0;
    while (i < length) {
        if (*budget == 0) return NO;
        unsigned long long key = 0;
        int shift = 0;
        NSUInteger next = 0;
        NSUInteger position = i;
        while (position < length && shift < 70) {
            uint8_t byte = bytes[position];
            key |= (unsigned long long)(byte & 0x7F) << shift;
            position += 1;
            if (!(byte & 0x80)) { next = position; break; }
            shift += 7;
        }
        if (next == 0) return NO;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) return NO;
        i = next;
        if (wire == 0) {
            i = YTAIWireSkipVarintBytes(bytes, length, i);
            if (i == 0) return NO;
        } else if (wire == 1) {
            if (i + 8 > length) return NO;
            i += 8;
        } else if (wire == 2) {
            unsigned long long fieldLength = 0;
            shift = 0;
            next = 0;
            position = i;
            while (position < length && shift < 70) {
                uint8_t byte = bytes[position];
                fieldLength |= (unsigned long long)(byte & 0x7F) << shift;
                position += 1;
                if (!(byte & 0x80)) { next = position; break; }
                shift += 7;
            }
            if (next == 0) return NO;
            i = next;
            if (i + fieldLength > length) return NO;
            (*budget)--;
            if (visit(bytes + i, (NSUInteger)fieldLength)) return YES;
            if (fieldLength > 0)
                if (YTAIWireWalkValues(bytes + i, (NSUInteger)fieldLength, depth + 1, budget, visit))
                    return YES;
            i += (NSUInteger)fieldLength;
        } else if (wire == 5) {
            if (i + 4 > length) return NO;
            i += 4;
        } else {
            return NO;
        }
    }
    return NO;
}

static NSString *YTAISummaryTokenInPayload(NSData *payload, NSString *videoId) {
    if (payload.length == 0 || videoId.length != 11) return nil;
    __block NSString *preferred = nil;
    __block NSString *fallback = nil;
    NSUInteger budget = 200000;
    YTAIWireWalkValues((const uint8_t *)payload.bytes, payload.length, 0, &budget,
        ^BOOL(const uint8_t *value, NSUInteger valueLength) {
            if (valueLength < 40 || valueLength > 2048) return NO;
            if (memcmp(value, "kta-", 4) != 0) return NO;
            NSString *token = [[NSString alloc] initWithBytes:value length:valueLength
                                                      encoding:NSASCIIStringEncoding];
            if (token.length == 0) return NO;
            NSData *decoded = YTAIBase64DecodeAny(token);
            if (decoded.length < 12) return NO;
            NSMutableString *layers = [NSMutableString string];
            YTAIAppendTokenLayerText(decoded, layers, 0);
            if ([layers rangeOfString:videoId].location == NSNotFound) return NO;
            if ([layers rangeOfString:@"Summarize" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                preferred = token;
                return YES;
            }
            if (fallback == nil &&
                [layers rangeOfString:@"youchat" options:NSCaseInsensitiveSearch].location != NSNotFound)
                fallback = token;
            return NO;
        });
    return preferred ?: fallback;
}

static BOOL YTAIStringIsNoise(NSString *string) {
    if (string.length < 8) return YES;
    if ([string rangeOfString:@".eml-"].location != NSNotFound) return YES;
    if ([string rangeOfString:@"youtube_"].location != NSNotFound) return YES;
    if ([string rangeOfString:@"USER_INTERFACE_THEME"].location != NSNotFound) return YES;
    if ([string hasPrefix:@"SanFrancisco"]) return YES;
    if ([string rangeOfString:@" "].location == NSNotFound &&
        [string rangeOfString:@"http"].location == NSNotFound &&
        string.length > 40) return YES;
    NSUInteger letters = 0;
    for (NSUInteger index = 0; index < string.length; index++) {
        unichar character = [string characterAtIndex:index];
        if ((character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z')) letters++;
    }
    return letters * 3 < string.length;
}

static NSString *YTAIExtractFieldByPath(const uint8_t *bytes, NSUInteger length,
                                        const NSUInteger *path, NSUInteger pathCount,
                                        NSUInteger step) {
    if (bytes == NULL || length == 0) return nil;
    if (step == pathCount) {
        return [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
    }
    NSUInteger targetField = path[step];
    NSUInteger pos = 0;
    while (pos < length) {
        unsigned long long key = 0;
        int shift = 0;
        NSUInteger p = pos;
        while (p < length && shift < 70) {
            uint8_t b = bytes[p];
            key |= (unsigned long long)(b & 0x7F) << shift;
            p++;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        pos = p;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            unsigned long long flen = 0;
            shift = 0;
            p = pos;
            while (p < length && shift < 70) {
                uint8_t b = bytes[p];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                p++;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            if (field == targetField) {
                NSString *result = YTAIExtractFieldByPath(bytes + pos, (NSUInteger)flen,
                                                         path, pathCount, step + 1);
                if (result.length != 0) return result;
            }
            pos += (NSUInteger)flen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
    return nil;
}

static NSString *YTAIExtractKeyFromChunk(const uint8_t *chunk, NSUInteger chunkLen) {
    if (chunk == NULL || chunkLen < 3) return nil;
    if (chunk[0] == 0x0A) {
        NSUInteger kpos = 1;
        unsigned long long klen = 0;
        int shift = 0;
        while (kpos < chunkLen && shift < 35) {
            uint8_t kb = chunk[kpos++];
            klen |= (unsigned long long)(kb & 0x7F) << shift;
            if (!(kb & 0x80)) break;
            shift += 7;
        }
        if (kpos + klen <= chunkLen && klen > 0) {
            return [[NSString alloc] initWithBytes:chunk + kpos length:(NSUInteger)klen encoding:NSUTF8StringEncoding];
        }
    }
    const char *prefixes[] = { "basic_content.eml-fe|", "chat_response_item.eml-fe|", "basic_content.", "chat_response_item." };
    for (int i = 0; i < 4; i++) {
        const char *pfx = prefixes[i];
        size_t pfxLen = strlen(pfx);
        const uint8_t *found = (const uint8_t *)memmem(chunk, MIN((NSUInteger)256, chunkLen), pfx, pfxLen);
        if (found != NULL) {
            NSUInteger startOffset = (NSUInteger)(found - chunk);
            NSUInteger maxLen = MIN((NSUInteger)80, chunkLen - startOffset);
            NSUInteger kLen = pfxLen;
            while (kLen < maxLen) {
                uint8_t c = found[kLen];
                if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.') {
                    kLen++;
                } else {
                    break;
                }
            }
            return [[NSString alloc] initWithBytes:found length:kLen encoding:NSUTF8StringEncoding];
        }
    }
    return nil;
}

static void YTAIDiagnosticScanEndpoints(const uint8_t *bytes, NSUInteger length, NSUInteger depth,
                                        NSMutableArray<NSString *> *pathStack,
                                        NSString *currentEntity,
                                        NSString *className,
                                        NSString *source) {
    if (bytes == NULL || length < 4 || depth > 32) return;
    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long tag = 0;
        NSUInteger shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            tag |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(tag >> 3);
        NSUInteger wire = (NSUInteger)(tag & 7);

        if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            NSUInteger chunkLen = (NSUInteger)flen;
            const uint8_t *chunk = bytes + pos;
            pos += chunkLen;

            [pathStack addObject:[NSString stringWithFormat:@"%lu", (unsigned long)field]];

            NSString *nextEntity = currentEntity;
            if (field == 168777401) {
                NSString *entKey = YTAIExtractKeyFromChunk(chunk, chunkLen);
                if (entKey.length > 0) nextEntity = entKey;
            }

            if (field == 48687757) { // watchEndpoint
                NSString *videoId = nil;
                double startTime = 0.0;
                NSUInteger wpos = 0;
                while (wpos < chunkLen) {
                    NSUInteger wp = wpos;
                    unsigned long long wtag = 0;
                    shift = 0;
                    while (wp < chunkLen && shift < 35) {
                        uint8_t b = chunk[wp++];
                        wtag |= (unsigned long long)(b & 0x7F) << shift;
                        if (!(b & 0x80)) break;
                        shift += 7;
                    }
                    if (wp == wpos) break;
                    wpos = wp;
                    NSUInteger wfield = (NSUInteger)(wtag >> 3);
                    NSUInteger wwire = (NSUInteger)(wtag & 7);
                    if (wwire == 2) {
                        wp = wpos;
                        unsigned long long wlen = 0;
                        shift = 0;
                        while (wp < chunkLen && shift < 35) {
                            uint8_t b = chunk[wp++];
                            wlen |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (wp == wpos) break;
                        wpos = wp;
                        if (wpos + wlen > chunkLen) break;
                        if (wfield == 1 && wlen == 11) {
                            videoId = [[NSString alloc] initWithBytes:chunk + wpos length:11 encoding:NSUTF8StringEncoding];
                        }
                        wpos += (NSUInteger)wlen;
                    } else if (wwire == 0) {
                        wp = wpos;
                        unsigned long long wval = 0;
                        shift = 0;
                        while (wp < chunkLen && shift < 64) {
                            uint8_t b = chunk[wp++];
                            wval |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (wp == wpos) break;
                        wpos = wp;
                        if (wfield == 7) startTime = (double)wval;
                    } else if (wwire == 5) {
                        if (wpos + 4 <= chunkLen) {
                            if (wfield == 7) {
                                float f = 0.0f;
                                memcpy(&f, chunk + wpos, 4);
                                startTime = (double)f;
                            }
                            wpos += 4;
                        } else {
                            break;
                        }
                    } else if (wwire == 1) {
                        wpos += 8;
                    } else {
                        break;
                    }
                }
                NSString *pathStr = [pathStack componentsJoinedByString:@"/"];
                YTRCLog(@{
                    @"event": @"ai-diagnostic-endpoint",
                    @"source": source ?: @"",
                    @"class": className ?: @"",
                    @"fieldPath": pathStr ?: @"",
                    @"videoId": videoId ?: @"",
                    @"startTimeSeconds": @(startTime),
                    @"owningEntity": nextEntity ?: @""
                });
            }

            YTAIDiagnosticScanEndpoints(chunk, chunkLen, depth + 1, pathStack, nextEntity, className, source);
            [pathStack removeLastObject];
        } else if (wire == 0) {
            while (pos < length && (bytes[pos++] & 0x80)) {}
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 5) {
            pos += 4;
        } else {
            break;
        }
    }
}

void YTAIDiagnosticLogEndpoints(NSData * _Nullable payload, NSString * _Nullable className, NSString * _Nullable source) {
    if (payload.length < 13) return;
    NSMutableArray<NSString *> *pathStack = [NSMutableArray array];
    YTAIDiagnosticScanEndpoints((const uint8_t *)payload.bytes, payload.length, 0, pathStack, @"", className, source);
}

static void YTAIExtractAllFieldsByPath(const uint8_t *bytes, NSUInteger length,
                                      const NSUInteger *path, NSUInteger pathCount,
                                      NSUInteger step, NSString *currentKey,
                                      NSMutableArray<NSDictionary<NSString *, NSString *> *> *results) {
    if (bytes == NULL || length == 0) return;
    if (step == pathCount) {
        NSString *s = [[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
        if (s.length != 0) {
            NSString *trimmed = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length != 0 && !YTAIStringIsNoise(trimmed)) {
                NSString *k = currentKey ?: [NSString stringWithFormat:@"primary_root_%lu", (unsigned long)results.count];
                [results addObject:@{ @"key": k, @"text": trimmed }];
            }
        }
        return;
    }
    NSUInteger targetField = path[step];
    NSUInteger pos = 0;
    while (pos < length) {
        unsigned long long key = 0;
        int shift = 0;
        NSUInteger p = pos;
        while (p < length && shift < 70) {
            uint8_t b = bytes[p];
            key |= (unsigned long long)(b & 0x7F) << shift;
            p++;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        pos = p;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            unsigned long long flen = 0;
            shift = 0;
            p = pos;
            while (p < length && shift < 70) {
                uint8_t b = bytes[p];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                p++;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            if (field == targetField) {
                NSString *chunkKey = currentKey;
                if (field == 168777401) {
                    NSString *k = YTAIExtractKeyFromChunk(bytes + pos, (NSUInteger)flen);
                    if (k.length > 0) chunkKey = k;
                }
                YTAIExtractAllFieldsByPath(bytes + pos, (NSUInteger)flen,
                                          path, pathCount, step + 1, chunkKey, results);
            }
            pos += (NSUInteger)flen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtractEntitiesFromSubtrees(const uint8_t *bytes, NSUInteger length, NSUInteger depth, NSMutableArray<NSDictionary<NSString *, NSString *> *> *entities) {
    if (bytes == NULL || length == 0 || depth > 24) return;
    static const uint8_t kEntityTagBytes[] = { 0xCA, 0xEB, 0xEA, 0x83, 0x05 };
    NSUInteger pos = 0;
    while (pos < length) {
        unsigned long long key = 0;
        int shift = 0;
        NSUInteger p = pos;
        while (p < length && shift < 70) {
            uint8_t b = bytes[p];
            key |= (unsigned long long)(b & 0x7F) << shift;
            p++;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        pos = p;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            unsigned long long flen = 0;
            shift = 0;
            p = pos;
            while (p < length && shift < 70) {
                uint8_t b = bytes[p];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                p++;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            const uint8_t *chunk = bytes + pos;
            NSUInteger chunkLen = (NSUInteger)flen;

            if (field == 168777401) {
                NSString *entKey = YTAIExtractKeyFromChunk(chunk, chunkLen);
                BOOL hasChildEntity = YTAIBytesContain(chunk, chunkLen, (const char *)kEntityTagBytes, sizeof(kEntityTagBytes));

                if (!hasChildEntity) {
                    // Check if this Elements entity represents basic_content or chat_response_item
                    if (YTAIBytesContain(chunk, chunkLen, "basic_content", 13)) {
                        static const NSUInteger kBasicContentTail[] = { 5, 413471385, 1, 1382, 2, 2, 1 };
                        NSString *ans = YTAIExtractFieldByPath(chunk, chunkLen, kBasicContentTail, 7, 0);
                        if (ans.length != 0) {
                            NSString *trimmed = [ans stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            if (trimmed.length > 0 && !YTAIStringIsNoise(trimmed)) {
                                [entities addObject:@{ @"key": entKey ?: [NSString stringWithFormat:@"entity_%lu", (unsigned long)entities.count], @"text": trimmed }];
                            }
                        }
                    } else if (YTAIBytesContain(chunk, chunkLen, "chat_response_item", 18)) {
                        static const NSUInteger kChatItemTail[] = { 5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382, 2, 2, 1 };
                        NSString *ans = YTAIExtractFieldByPath(chunk, chunkLen, kChatItemTail, 15, 0);
                        if (ans.length != 0) {
                            NSString *trimmed = [ans stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                            if (trimmed.length > 0 && !YTAIStringIsNoise(trimmed)) {
                                [entities addObject:@{ @"key": entKey ?: [NSString stringWithFormat:@"entity_%lu", (unsigned long)entities.count], @"text": trimmed }];
                            }
                        }
                    }
                }
            }

            YTAIExtractEntitiesFromSubtrees(chunk, chunkLen, depth + 1, entities);
            pos += chunkLen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtractRichTextFromVerifiedEntities(const uint8_t *bytes, NSUInteger length,
                                                    NSString * _Nullable activeVid,
                                                    NSMutableSet<NSString *> *seen,
                                                    NSMutableArray *results);
static NSString *YTAIReconstructEntityTextWithAnnotations(NSString *text, NSArray<NSDictionary *> *annotations);

static NSArray<NSDictionary<NSString *, id> *> *YTAIExtractEntitiesFromPayload(NSData *payload) {
    if (payload.length < 40) return @[];
    const uint8_t *bytes = (const uint8_t *)payload.bytes;
    NSUInteger length = payload.length;

    NSMutableArray<NSDictionary<NSString *, id> *> *entities = [NSMutableArray array];
    NSMutableSet<NSString *> *seenKeys = [NSMutableSet set];

    // Collect verified rich-text annotations for this payload
    NSMutableArray<NSMutableDictionary<NSString *, id> *> *payloadAnns = [NSMutableArray array];
    YTAIExtractRichTextFromVerifiedEntities(bytes, length, nil, [NSMutableSet set], payloadAnns);

    // Layout 1: Primary observed Elements response path in YouTube iOS 21.33.6
    static const NSUInteger kRootPath[] = {
        1, 1, 1, 153515154, 172660663, 1, 168777401, 5, 413471385, 1,
        2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382, 2, 2, 1
    };
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *rootMatches = [NSMutableArray array];
    YTAIExtractAllFieldsByPath(bytes, length, kRootPath, 23, 0, nil, rootMatches);

    for (NSUInteger idx = 0; idx < rootMatches.count; idx++) {
        NSDictionary<NSString *, NSString *> *rm = rootMatches[idx];
        NSString *k = rm[@"key"];
        if (rootMatches.count == 1 && [k hasPrefix:@"primary_root_"]) {
            k = @"primary_root";
        }
        if (![seenKeys containsObject:k]) {
            [seenKeys addObject:k];
            NSMutableArray<NSDictionary *> *matchingAnns = [NSMutableArray array];
            for (NSDictionary *ann in payloadAnns) {
                NSString *ek = ann[@"entityKey"];
                if (ek.length == 0 || [ek isEqualToString:k] || [ek isEqualToString:rm[@"key"]] || rootMatches.count == 1) {
                    [matchingAnns addObject:ann];
                }
            }
            [entities addObject:@{ @"key": k, @"text": rm[@"text"], @"annotations": matchingAnns }];
        }
    }

    // Layout 2: Subtree search for validated basic_content or chat_response_item entities
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *subEntities = [NSMutableArray array];
    YTAIExtractEntitiesFromSubtrees(bytes, length, 0, subEntities);

    for (NSDictionary<NSString *, NSString *> *sub in subEntities) {
        NSString *k = sub[@"key"];
        NSString *t = sub[@"text"];
        if (k.length > 0 && t.length > 0) {
            if (![seenKeys containsObject:k]) {
                [seenKeys addObject:k];
                NSMutableArray<NSDictionary *> *matchingAnns = [NSMutableArray array];
                for (NSDictionary *ann in payloadAnns) {
                    NSString *ek = ann[@"entityKey"];
                    if (ek.length == 0 || [ek isEqualToString:k]) {
                        [matchingAnns addObject:ann];
                    }
                }
                [entities addObject:@{ @"key": k, @"text": t, @"annotations": matchingAnns }];
            }
        }
    }

    return [entities copy];
}

static NSString *YTAITextFromPayloads(NSArray *payloads) {
    if (payloads.count == 0) return nil;

    NSMutableArray<NSString *> *orderedKeys = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *entityStates = [NSMutableDictionary dictionary];

    for (id item in payloads) {
        NSData *bytes = nil;
        if ([item isKindOfClass:NSData.class]) {
            bytes = (NSData *)item;
        } else if ([item isKindOfClass:NSDictionary.class]) {
            bytes = item[@"data"];
        }
        if (![bytes isKindOfClass:NSData.class] || bytes.length < 40) continue;
        NSArray<NSDictionary<NSString *, id> *> *entities = YTAIExtractEntitiesFromPayload(bytes);
        for (NSDictionary<NSString *, id> *ent in entities) {
            NSString *key = ent[@"key"];
            NSString *text = ent[@"text"];
            if (key.length == 0 || text.length == 0) continue;

            NSArray *anns = ent[@"annotations"];
            if (anns.count > 0) {
                text = YTAIReconstructEntityTextWithAnnotations(text, anns);
            }

            if (entityStates[key] == nil) {
                [orderedKeys addObject:key];
            }
            // Chronological update: newer payload replaces previous state of this entity,
            // even if the new text is shorter (e.g. final correction replaces a draft).
            entityStates[key] = text;
        }
    }

    if (orderedKeys.count == 0) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"extraction-failed",
                  @"reason": @"structured-renderer-missing", @"payloads": @(payloads.count)});
        return nil;
    }

    NSMutableArray<NSString *> *fragments = [NSMutableArray array];
    for (NSString *key in orderedKeys) {
        NSString *val = entityStates[key];
        if (val.length > 0) {
            [fragments addObject:val];
        }
    }

    return fragments.count > 0 ? [fragments componentsJoinedByString:@"\n\n"] : nil;
}

static NSString *YTAICachedAiSummary = nil;
static NSString *YTAICachedAiSummaryVideoId = nil;
static NSString *YTAICachedAiSummaryTag = nil;
static NSString *const YTAIFlowTag = @"summarize";

static NSString *YTAIFlowTagForPrompt(NSString *prompt) {
    NSString *normalized = [[prompt stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString] ?: @"";
    if ([normalized isEqualToString:@"summarize the video"] ||
        [normalized isEqualToString:@"summarize this video"] ||
        [normalized isEqualToString:@"summarize this video."])
        return YTAIFlowTag;
    return [@"prompt:" stringByAppendingString:normalized];
}

static BOOL YTAICacheHit(NSString *videoId, NSString *tag, NSString **summary) {
    if (videoId.length == 0 || summary == nullptr) return NO;
    if (![videoId isEqualToString:YTAICachedAiSummaryVideoId]) return NO;
    if (![tag isEqualToString:YTAICachedAiSummaryTag]) return NO;
    if (YTAICachedAiSummary.length == 0) return NO;
    *summary = YTAICachedAiSummary;
    return YES;
}

static void YTAICacheStore(NSString *videoId, NSString *tag, NSString *summary) {
    if (videoId.length == 0 || summary.length == 0) return;
    YTAICachedAiSummaryVideoId = [videoId copy];
    YTAICachedAiSummaryTag = [tag copy];
    YTAICachedAiSummary = summary;
}

__attribute__((unused)) static NSString *YTAIScrapeAiResponseFromUI(void) {
    NSMutableArray<NSString *> *fragments = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.05) continue;
            __block NSUInteger budget = 500;
            __block __weak void (^weakWalk)(UIView *);
            void (^walk)(UIView *) = ^(UIView *view) {
                if (view == nil || budget == 0) return;
                budget--;
                if (view.hidden || view.alpha < 0.05) return;
                NSString *text = nil;
                if ([view isKindOfClass:UILabel.class]) {
                    text = ((UILabel *)view).text;
                    if (text.length == 0 && ((UILabel *)view).attributedText.length > 0) {
                        text = ((UILabel *)view).attributedText.string;
                    }
                } else if ([view isKindOfClass:UITextView.class]) {
                    if (!view.isFirstResponder && !((UITextView *)view).isEditable) {
                        text = ((UITextView *)view).text;
                        if (text.length == 0 && ((UITextView *)view).attributedText.length > 0) {
                            text = ((UITextView *)view).attributedText.string;
                        }
                    }
                } else {
                    id node = YTAINodeOfView(view);
                    if (node != nil && [node respondsToSelector:@selector(attributedText)]) {
                        NSAttributedString *attr = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(node, @selector(attributedText));
                        if (attr.length > 0) text = attr.string;
                    }
                }
                if (text.length > 20 && ![seen containsObject:text]) {
                    NSString *lower = text.lowercaseString ?: @"";
                    if (![lower containsString:@"ask a question"] &&
                        ![lower containsString:@"terms of service"] &&
                        ![lower containsString:@"privacy policy"] &&
                        ![lower containsString:@"summarize the video"] &&
                        ![lower containsString:@"asking gemini"] &&
                        !YTAIStringIsNoise(text)) {
                        [seen addObject:text];
                        [fragments addObject:text];
                    }
                }
                for (UIView *subview in view.subviews) weakWalk(subview);
            };
            weakWalk = walk;
            walk(window);
        }
    }
    return fragments.count != 0 ? [fragments componentsJoinedByString:@"\n\n"] : nil;
}

BOOL YTAIIsValidVideoId(NSString *vid) {
    if (vid.length != 11) return NO;
    for (NSUInteger i = 0; i < 11; i++) {
        unichar c = [vid characterAtIndex:i];
        BOOL valid = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-';
        if (!valid) return NO;
    }
    if ([vid hasPrefix:@"youchat"] || [vid hasPrefix:@"SanFran"] || [vid hasPrefix:@"capabil"]) return NO;
    return YES;
}

typedef NS_ENUM(NSInteger, YTAICardContext) {
    YTAICardCtxRoot = 0,
    YTAICardCtxFramework,
    YTAICardCtxRootEntity,
    YTAICardCtxEntity,
    YTAICardCtxEntityData,
    YTAICardCtxCarousel,
    YTAICardCtxCarouselItems,
    YTAICardCtxCardWrapper,
    YTAICardCtxCard,
    YTAICardCtxCommand,
    YTAICardCtxEndpoint
};

static inline NSInteger YTAICardNextContext(YTAICardContext currentCtx, NSUInteger field) {
    switch (currentCtx) {
        case YTAICardCtxRoot:
            if (field == 153515154) return YTAICardCtxFramework;
            if (field == 172660663) return YTAICardCtxRootEntity;
            if (field == 168777401) return YTAICardCtxEntity;
            if (field == 232954548 || field == 413471385) return YTAICardCtxCarousel;
            if (field == 169495254) return YTAICardCtxCard;
            return -1;
        case YTAICardCtxFramework:
            if (field == 1) return YTAICardCtxFramework;
            if (field == 172660663) return YTAICardCtxRootEntity;
            if (field == 168777401) return YTAICardCtxEntity;
            return -1;
        case YTAICardCtxRootEntity:
            if (field == 1) return YTAICardCtxRootEntity;
            if (field == 168777401) return YTAICardCtxEntity;
            return -1;
        case YTAICardCtxEntity:
            if (field == 5) return YTAICardCtxEntityData;
            return -1;
        case YTAICardCtxEntityData:
            if (field == 232954548 || field == 413471385) return YTAICardCtxCarousel;
            if (field == 169495254) return YTAICardCtxCard;
            return -1;
        case YTAICardCtxCarousel:
            if (field == 18) return YTAICardCtxCarouselItems;
            if (field == 1) return YTAICardCtxCarousel;
            return -1;
        case YTAICardCtxCarouselItems:
            if (field == 1 || field == 4 || field == 5) return YTAICardCtxCardWrapper;
            if (field == 169495254) return YTAICardCtxCard;
            return -1;
        case YTAICardCtxCardWrapper:
            if (field == 169495254) return YTAICardCtxCard;
            return -1;
        case YTAICardCtxCard:
            if (field == 462702848) return YTAICardCtxCommand;
            if (field == 98150882) return YTAICardCtxEndpoint;
            return -1;
        case YTAICardCtxCommand:
            if (field == 1) return YTAICardCtxEndpoint;
            return -1;
        case YTAICardCtxEndpoint:
            if (field == 1 || field == 2 || field == 3 || field == 5 ||
                field == 1892 || field == 66439850 || field == 77258115) return YTAICardCtxEndpoint;
            return -1;
        default:
            return -1;
    }
}

static void YTAIWalkProtobufCardFields(const uint8_t *bytes, NSUInteger length, YTAICardContext ctx, NSUInteger depth,
                                      NSString * _Nullable activeVid,
                                      NSMutableSet<NSString *> *seen,
                                      NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *results) {
    if (bytes == NULL || length < 4 || depth > 20) return;

    NSString *vidInCard = nil;
    NSString *titleInCard = @"";

    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long tag = 0;
        NSUInteger shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            tag |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(tag >> 3);
        NSUInteger wire = (NSUInteger)(tag & 7);

        if (wire == 0) {
            while (pos < length && (bytes[pos++] & 0x80)) {}
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            NSUInteger chunkLen = (NSUInteger)flen;
            const uint8_t *chunk = bytes + pos;
            pos += chunkLen;

            if (field == 48687757 && (ctx == YTAICardCtxEndpoint || ctx == YTAICardCtxCommand)) {
                // Structural watchEndpoint parsing: field 1 is videoId, field 36 is title
                NSUInteger wpos = 0;
                while (wpos < chunkLen) {
                    NSUInteger wp = wpos;
                    unsigned long long wtag = 0;
                    shift = 0;
                    while (wp < chunkLen && shift < 35) {
                        uint8_t b = chunk[wp++];
                        wtag |= (unsigned long long)(b & 0x7F) << shift;
                        if (!(b & 0x80)) break;
                        shift += 7;
                    }
                    if (wp == wpos) break;
                    wpos = wp;
                    NSUInteger wfield = (NSUInteger)(wtag >> 3);
                    NSUInteger wwire = (NSUInteger)(wtag & 7);
                    if (wwire == 0) {
                        while (wpos < chunkLen && (chunk[wpos++] & 0x80)) {}
                    } else if (wwire == 1) {
                        wpos += 8;
                    } else if (wwire == 2) {
                        wp = wpos;
                        unsigned long long wlen = 0;
                        shift = 0;
                        while (wp < chunkLen && shift < 35) {
                            uint8_t b = chunk[wp++];
                            wlen |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (wp == wpos) break;
                        wpos = wp;
                        if (wpos + wlen > chunkLen) break;
                        NSUInteger wact = (NSUInteger)wlen;
                        const uint8_t *wchunk = chunk + wpos;
                        if (wfield == 1 && wlen == 11) {
                            NSString *candidate = [[NSString alloc] initWithBytes:wchunk length:11 encoding:NSASCIIStringEncoding];
                            if (candidate.length == 11 && YTAIIsValidVideoId(candidate)) {
                                vidInCard = candidate;
                            }
                        } else if (wfield == 36 && wact > 0 && titleInCard.length == 0) {
                            NSString *t = [[NSString alloc] initWithBytes:wchunk length:wact encoding:NSUTF8StringEncoding];
                            if (t.length > 0) titleInCard = [t stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        }
                        wpos += wact;
                    } else if (wwire == 5) {
                        wpos += 4;
                    } else {
                        break;
                    }
                }
            } else if (ctx == YTAICardCtxCard && (field >= 33 && field <= 36) && titleInCard.length == 0 && chunkLen > 0) {
                // Structural title in Elements card
                NSUInteger tpos = 0;
                while (tpos < chunkLen) {
                    NSUInteger tp = tpos;
                    unsigned long long ttag = 0;
                    shift = 0;
                    while (tp < chunkLen && shift < 35) {
                        uint8_t b = chunk[tp++];
                        ttag |= (unsigned long long)(b & 0x7F) << shift;
                        if (!(b & 0x80)) break;
                        shift += 7;
                    }
                    if (tp == tpos) break;
                    tpos = tp;
                    NSUInteger tfield = (NSUInteger)(ttag >> 3);
                    NSUInteger twire = (NSUInteger)(ttag & 7);
                    if (tfield == 1 && twire == 2) {
                        tp = tpos;
                        unsigned long long tlen = 0;
                        shift = 0;
                        while (tp < chunkLen && shift < 35) {
                            uint8_t b = chunk[tp++];
                            tlen |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (tp == tpos) break;
                        tpos = tp;
                        if (tpos + tlen > chunkLen) break;
                        NSUInteger tact = (NSUInteger)tlen;
                        const uint8_t *tchunk = chunk + tpos;
                        NSString *s = nil;
                        if (tact > 2 && tchunk[0] == 0x0A) {
                            NSUInteger nlen = tchunk[1];
                            if (tact >= 2 + nlen) {
                                s = [[NSString alloc] initWithBytes:tchunk + 2 length:nlen encoding:NSUTF8StringEncoding];
                            }
                        } else {
                            s = [[NSString alloc] initWithBytes:tchunk length:tact encoding:NSUTF8StringEncoding];
                        }
                        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if (s.length > 3 && ![s hasPrefix:@"eml."] && !YTAIStringIsNoise(s)) {
                            titleInCard = s;
                        }
                        break;
                    } else if (twire == 2) {
                        tp = tpos;
                        unsigned long long sublen = 0;
                        shift = 0;
                        while (tp < chunkLen && shift < 35) {
                            uint8_t b = chunk[tp++];
                            sublen |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (tp == tpos) break;
                        if (tp + sublen > chunkLen) break;
                        tpos = tp + (NSUInteger)sublen;
                    } else {
                        break;
                    }
                }
            } else {
                NSInteger nextCtx = YTAICardNextContext(ctx, field);
                if (nextCtx >= 0) {
                    YTAIWalkProtobufCardFields(chunk, chunkLen, (YTAICardContext)nextCtx, depth + 1, activeVid, seen, results);
                }
            }
        } else if (wire == 5) {
            pos += 4;
        } else {
            break;
        }
    }

    if (vidInCard.length == 11 && (activeVid.length == 0 || ![vidInCard isEqualToString:activeVid])) {
        if (![seen containsObject:vidInCard]) {
            [seen addObject:vidInCard];
            [results addObject:[@{@"videoId": vidInCard, @"title": titleInCard ?: @""} mutableCopy]];
        } else if (titleInCard.length > 0) {
            for (NSMutableDictionary *existing in results) {
                if ([existing[@"videoId"] isEqualToString:vidInCard] && [existing[@"title"] length] == 0) {
                    existing[@"title"] = titleInCard;
                    break;
                }
            }
        }
    }
}

static NSString * _Nullable YTAIFindWatchEndpointInAnnotationCommand(const uint8_t *bytes, NSUInteger length,
                                                                      double * _Nullable outTimestamp) {
    if (bytes == NULL || length < 10) return nil;
    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long tag = 0;
        int shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            tag |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(tag >> 3);
        NSUInteger wire = (NSUInteger)(tag & 7);
        if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            NSUInteger chunkLen = (NSUInteger)flen;
            const uint8_t *chunk = bytes + pos;
            pos += chunkLen;

            if (field == 48687757) { // watchEndpoint
                NSString *vid = nil;
                double ts = 0.0;
                NSUInteger wpos = 0;
                while (wpos < chunkLen) {
                    NSUInteger wp = wpos;
                    unsigned long long wtag = 0;
                    shift = 0;
                    while (wp < chunkLen && shift < 35) {
                        uint8_t b = chunk[wp++];
                        wtag |= (unsigned long long)(b & 0x7F) << shift;
                        if (!(b & 0x80)) break;
                        shift += 7;
                    }
                    if (wp == wpos) break;
                    wpos = wp;
                    NSUInteger wfield = (NSUInteger)(wtag >> 3);
                    NSUInteger wwire = (NSUInteger)(wtag & 7);
                    if (wwire == 2) {
                        wp = wpos;
                        unsigned long long wlen = 0;
                        shift = 0;
                        while (wp < chunkLen && shift < 35) {
                            uint8_t b = chunk[wp++];
                            wlen |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (wp == wpos) break;
                        wpos = wp;
                        if (wpos + wlen > chunkLen) break;
                        if (wfield == 1 && wlen == 11) {
                            NSString *cand = [[NSString alloc] initWithBytes:chunk + wpos length:11 encoding:NSUTF8StringEncoding];
                            if (cand.length == 11 && YTAIIsValidVideoId(cand)) {
                                vid = cand;
                            }
                        }
                        wpos += (NSUInteger)wlen;
                    } else if (wwire == 5) {
                        if (wpos + 4 <= chunkLen && wfield == 7) {
                            float fval = 0.0f;
                            memcpy(&fval, chunk + wpos, 4);
                            ts = (double)fval;
                        }
                        wpos += 4;
                    } else if (wwire == 0) {
                        wp = wpos;
                        unsigned long long vval = 0;
                        shift = 0;
                        while (wp < chunkLen && shift < 64) {
                            uint8_t b = chunk[wp++];
                            vval |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (wp > wpos) {
                            wpos = wp;
                            if (wfield == 7 && ts == 0.0) ts = (double)vval;
                        } else {
                            break;
                        }
                    } else if (wwire == 1) {
                        wpos += 8;
                    } else {
                        break;
                    }
                }
                if (vid.length == 11) {
                    if (outTimestamp != NULL) *outTimestamp = ts;
                    return vid;
                }
            } else if (field == 170382656 || field == 1 || field == 169495254) {
                // Strictly follow recognized annotation-command wrapper fields only
                NSString *sub = YTAIFindWatchEndpointInAnnotationCommand(chunk, chunkLen, outTimestamp);
                if (sub.length == 11) return sub;
            }
        } else if (wire == 0) {
            while (pos < length && (bytes[pos++] & 0x80)) {}
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 5) {
            pos += 4;
        } else {
            break;
        }
    }
    return nil;
}

static void YTAIExtractRichTextAnnotationsFrom1382(const uint8_t *bytes, NSUInteger length,
                                                   NSString * _Nullable activeVid,
                                                   NSString * _Nullable entKey,
                                                   NSMutableSet<NSString *> *seen,
                                                   NSMutableArray *results) {
    if (bytes == NULL || length < 10) return;
    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long tag = 0;
        NSUInteger shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            tag |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(tag >> 3);
        NSUInteger wire = (NSUInteger)(tag & 7);
        if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            NSUInteger chunkLen = (NSUInteger)flen;
            const uint8_t *chunk = bytes + pos;
            pos += chunkLen;

            if (field == 2) {
                NSUInteger f2pos = 0;
                while (f2pos < chunkLen) {
                    NSUInteger f2p = f2pos;
                    unsigned long long f2tag = 0;
                    shift = 0;
                    while (f2p < chunkLen && shift < 35) {
                        uint8_t b = chunk[f2p++];
                        f2tag |= (unsigned long long)(b & 0x7F) << shift;
                        if (!(b & 0x80)) break;
                        shift += 7;
                    }
                    if (f2p == f2pos) break;
                    f2pos = f2p;
                    NSUInteger f2field = (NSUInteger)(f2tag >> 3);
                    NSUInteger f2wire = (NSUInteger)(f2tag & 7);
                    if (f2wire == 2) {
                        f2p = f2pos;
                        unsigned long long f2len = 0;
                        shift = 0;
                        while (f2p < chunkLen && shift < 35) {
                            uint8_t b = chunk[f2p++];
                            f2len |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (f2p == f2pos) break;
                        f2pos = f2p;
                        if (f2pos + f2len > chunkLen) break;
                        NSUInteger f2chunkLen = (NSUInteger)f2len;
                        const uint8_t *f2chunk = chunk + f2pos;
                        f2pos += f2chunkLen;

                        if (f2field == 2) {
                            NSString *fullText = nil;
                            NSMutableArray<NSData *> *annotations = [NSMutableArray array];

                            NSUInteger inpos = 0;
                            while (inpos < f2chunkLen) {
                                NSUInteger inp = inpos;
                                unsigned long long intag = 0;
                                shift = 0;
                                while (inp < f2chunkLen && shift < 35) {
                                    uint8_t b = f2chunk[inp++];
                                    intag |= (unsigned long long)(b & 0x7F) << shift;
                                    if (!(b & 0x80)) break;
                                    shift += 7;
                                }
                                if (inp == inpos) break;
                                inpos = inp;
                                NSUInteger infield = (NSUInteger)(intag >> 3);
                                NSUInteger inwire = (NSUInteger)(intag & 7);
                                if (inwire == 2) {
                                    inp = inpos;
                                    unsigned long long inlen = 0;
                                    shift = 0;
                                    while (inp < f2chunkLen && shift < 35) {
                                        uint8_t b = f2chunk[inp++];
                                        inlen |= (unsigned long long)(b & 0x7F) << shift;
                                        if (!(b & 0x80)) break;
                                        shift += 7;
                                    }
                                    if (inp == inpos) break;
                                    inpos = inp;
                                    if (inpos + inlen > f2chunkLen) break;
                                    NSUInteger inchunkLen = (NSUInteger)inlen;
                                    const uint8_t *inchunk = f2chunk + inpos;
                                    inpos += inchunkLen;

                                    if (infield == 1 && fullText == nil) {
                                        fullText = [[NSString alloc] initWithBytes:inchunk length:inchunkLen encoding:NSUTF8StringEncoding];
                                    } else if (infield == 5) {
                                        [annotations addObject:[NSData dataWithBytes:inchunk length:inchunkLen]];
                                    }
                                } else if (inwire == 0) {
                                    while (inpos < f2chunkLen && (f2chunk[inpos++] & 0x80)) {}
                                } else if (inwire == 1) {
                                    inpos += 8;
                                } else if (inwire == 5) {
                                    inpos += 4;
                                } else {
                                    break;
                                }
                            }

                            for (NSData *annData in annotations) {
                                const uint8_t *annBytes = (const uint8_t *)annData.bytes;
                                NSUInteger annLen = annData.length;
                                NSUInteger offset = 0;
                                NSUInteger spanLen = 0;
                                NSData *cmdData = nil;

                                NSUInteger apos = 0;
                                while (apos < annLen) {
                                    NSUInteger ap = apos;
                                    unsigned long long atag = 0;
                                    shift = 0;
                                    while (ap < annLen && shift < 35) {
                                        uint8_t b = annBytes[ap++];
                                        atag |= (unsigned long long)(b & 0x7F) << shift;
                                        if (!(b & 0x80)) break;
                                        shift += 7;
                                    }
                                    if (ap == apos) break;
                                    apos = ap;
                                    NSUInteger afield = (NSUInteger)(atag >> 3);
                                    NSUInteger awire = (NSUInteger)(atag & 7);
                                    if (awire == 0) {
                                        ap = apos;
                                        unsigned long long aval = 0;
                                        shift = 0;
                                        while (ap < annLen && shift < 64) {
                                            uint8_t b = annBytes[ap++];
                                            aval |= (unsigned long long)(b & 0x7F) << shift;
                                            if (!(b & 0x80)) break;
                                            shift += 7;
                                        }
                                        if (ap == apos) break;
                                        apos = ap;
                                        if (afield == 1) offset = (NSUInteger)aval;
                                        else if (afield == 2) spanLen = (NSUInteger)aval;
                                    } else if (awire == 2) {
                                        ap = apos;
                                        unsigned long long alen = 0;
                                        shift = 0;
                                        while (ap < annLen && shift < 35) {
                                            uint8_t b = annBytes[ap++];
                                            alen |= (unsigned long long)(b & 0x7F) << shift;
                                            if (!(b & 0x80)) break;
                                            shift += 7;
                                        }
                                        if (ap == apos) break;
                                        apos = ap;
                                        if (apos + alen > annLen) break;
                                        NSUInteger achunkLen = (NSUInteger)alen;
                                        const uint8_t *achunk = annBytes + apos;
                                        apos += achunkLen;
                                        if (afield == 3) {
                                            cmdData = [NSData dataWithBytes:achunk length:achunkLen];
                                        }
                                    } else if (awire == 1) {
                                        apos += 8;
                                    } else if (awire == 5) {
                                        apos += 4;
                                    } else {
                                        break;
                                    }
                                }

                                if (cmdData != nil) {
                                    double ts = 0.0;
                                    NSString *extractedVid = YTAIFindWatchEndpointInAnnotationCommand((const uint8_t *)cmdData.bytes, cmdData.length, &ts);
                                    if (extractedVid.length == 11 && YTAIIsValidVideoId(extractedVid)) {
                                        // Ignore endpoints that reference the active video (source video timestamps)
                                        if (activeVid.length > 0 && [extractedVid isEqualToString:activeVid]) {
                                            continue;
                                        }
                                        NSString *anchor = @"";
                                        if (fullText.length > 0 && offset + spanLen <= fullText.length) {
                                            anchor = [fullText substringWithRange:NSMakeRange(offset, spanLen)];
                                        }
                                        NSString *title = [anchor stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"[]() \t\n\u00A0"]];
                                        NSMutableDictionary *entry = [@{
                                            @"videoId": extractedVid,
                                            @"title": title ?: @"",
                                            @"offset": @(offset),
                                            @"length": @(spanLen),
                                            @"entityKey": entKey ?: @""
                                        } mutableCopy];
                                        if (ts > 0.0) {
                                            entry[@"timestamp"] = @(ts);
                                        }
                                        if (seen != nil) {
                                            if ([seen containsObject:extractedVid]) {
                                                continue;
                                            }
                                            [seen addObject:extractedVid];
                                        }
                                        [results addObject:entry];
                                    }
                                }
                            }
                        }
                    } else if (f2wire == 0) {
                        while (f2pos < chunkLen && (chunk[f2pos++] & 0x80)) {}
                    } else if (f2wire == 1) {
                        f2pos += 8;
                    } else if (f2wire == 5) {
                        f2pos += 4;
                    } else {
                        break;
                    }
                }
            }
        } else if (wire == 0) {
            while (pos < length && (bytes[pos++] & 0x80)) {}
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 5) {
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtractAll1382ChunksByPath(const uint8_t *bytes, NSUInteger length,
                                           const NSUInteger *path, NSUInteger pathCount,
                                           NSUInteger step, NSString * _Nullable currentKey,
                                           NSMutableArray<NSDictionary *> *results) {
    if (bytes == NULL || length == 0 || step > pathCount) return;
    if (step == pathCount) {
        [results addObject:@{
            @"chunk": [NSData dataWithBytes:bytes length:length],
            @"key": currentKey ?: @""
        }];
        return;
    }
    NSUInteger targetField = path[step];
    NSUInteger pos = 0;
    while (pos < length) {
        unsigned long long key = 0;
        int shift = 0;
        NSUInteger p = pos;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            key |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            unsigned long long flen = 0;
            shift = 0;
            p = pos;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            if (field == targetField) {
                NSString *chunkKey = currentKey;
                if (field == 168777401) {
                    NSString *k = YTAIExtractKeyFromChunk(bytes + pos, (NSUInteger)flen);
                    if (k.length > 0) chunkKey = k;
                }
                YTAIExtractAll1382ChunksByPath(bytes + pos, (NSUInteger)flen,
                                              path, pathCount, step + 1, chunkKey, results);
            }
            pos += (NSUInteger)flen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtract1382FromVerifiedSubtrees(const uint8_t *bytes, NSUInteger length,
                                                NSUInteger depth,
                                                NSMutableArray<NSDictionary *> *results) {
    if (bytes == NULL || length == 0 || depth > 24) return;
    static const uint8_t kEntityTagBytes[] = { 0xCA, 0xEB, 0xEA, 0x83, 0x05 };
    NSUInteger pos = 0;
    while (pos < length) {
        unsigned long long key = 0;
        int shift = 0;
        NSUInteger p = pos;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            key |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            unsigned long long flen = 0;
            shift = 0;
            p = pos;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            const uint8_t *chunk = bytes + pos;
            NSUInteger chunkLen = (NSUInteger)flen;

            if (field == 168777401) {
                NSString *entKey = YTAIExtractKeyFromChunk(chunk, chunkLen);
                BOOL hasChildEntity = YTAIBytesContain(chunk, chunkLen, (const char *)kEntityTagBytes, sizeof(kEntityTagBytes));

                if (!hasChildEntity) {
                    if (YTAIBytesContain(chunk, chunkLen, "basic_content", 13)) {
                        static const NSUInteger kBasicTail[] = { 5, 413471385, 1, 1382 };
                        YTAIExtractAll1382ChunksByPath(chunk, chunkLen, kBasicTail, 4, 0, entKey, results);
                    } else if (YTAIBytesContain(chunk, chunkLen, "chat_response_item", 18)) {
                        static const NSUInteger kChatTail[] = { 5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382 };
                        YTAIExtractAll1382ChunksByPath(chunk, chunkLen, kChatTail, 12, 0, entKey, results);
                    }
                }
            }

            YTAIExtract1382FromVerifiedSubtrees(chunk, chunkLen, depth + 1, results);
            pos += chunkLen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtractRichTextFromVerifiedEntities(const uint8_t *bytes, NSUInteger length,
                                                    NSString * _Nullable activeVid,
                                                    NSMutableSet<NSString *> *seen,
                                                    NSMutableArray *results) {
    if (bytes == NULL || length < 30) return;

    NSMutableArray<NSDictionary *> *node1382Items = [NSMutableArray array];

    // Layout 1: Primary observed Elements response path in YouTube iOS (20 fields)
    static const NSUInteger kFullRootPathTo1382[] = {
        1, 1, 1, 153515154, 172660663, 1, 168777401, 5, 413471385, 1,
        2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382
    };
    YTAIExtractAll1382ChunksByPath(bytes, length, kFullRootPathTo1382, 20, 0, nil, node1382Items);

    // Layout 2: Standalone YTIElementRenderer or unwrapped elementRenderer (17 fields)
    static const NSUInteger kRootPathTo1382[] = {
        153515154, 172660663, 1, 168777401, 5, 413471385, 1,
        2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382
    };
    YTAIExtractAll1382ChunksByPath(bytes, length, kRootPathTo1382, 17, 0, nil, node1382Items);

    // Layout 3: Subtree verified assistant entities
    YTAIExtract1382FromVerifiedSubtrees(bytes, length, 0, node1382Items);

    NSMutableSet<NSData *> *processedChunks = [NSMutableSet set];
    for (NSDictionary *item in node1382Items) {
        NSData *chunkData = item[@"chunk"];
        if (chunkData == nil || [processedChunks containsObject:chunkData]) continue;
        [processedChunks addObject:chunkData];
        NSString *entKey = item[@"key"];
        YTAIExtractRichTextAnnotationsFrom1382((const uint8_t *)chunkData.bytes, chunkData.length,
                                               activeVid, entKey, seen, results);
    }
}

static void YTAIExtractChunksByPath(const uint8_t *bytes, NSUInteger length,
                                    const NSUInteger *path, NSUInteger pathCount,
                                    NSUInteger step,
                                    NSMutableArray<NSData *> *results) {
    if (bytes == NULL || length == 0 || step > pathCount) return;
    if (step == pathCount) {
        [results addObject:[NSData dataWithBytes:bytes length:length]];
        return;
    }
    NSUInteger targetField = path[step];
    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long key = 0;
        int shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            key |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            if (field == targetField) {
                YTAIExtractChunksByPath(bytes + pos, (NSUInteger)flen,
                                        path, pathCount, step + 1, results);
            }
            pos += (NSUInteger)flen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtract1337CardsFromVerifiedSubtrees(const uint8_t *bytes, NSUInteger length,
                                                     NSUInteger depth,
                                                     NSMutableArray<NSData *> *results) {
    if (bytes == NULL || length == 0 || depth > 24) return;
    static const uint8_t kEntityTagBytes[] = { 0xCA, 0xEB, 0xEA, 0x83, 0x05 };
    NSUInteger pos = 0;
    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long key = 0;
        int shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            key |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(key >> 3);
        NSUInteger wire = (NSUInteger)(key & 7);
        if (field == 0) break;
        if (wire == 0) {
            pos = YTAIWireSkipVarintBytes(bytes, length, pos);
            if (pos == 0) break;
        } else if (wire == 1) {
            if (pos + 8 > length) break;
            pos += 8;
        } else if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            NSUInteger chunkLen = (NSUInteger)flen;
            const uint8_t *chunk = bytes + pos;
            if (field == 168777401) {
                BOOL hasChild = YTAIBytesContain(chunk, chunkLen, (const char *)kEntityTagBytes, sizeof(kEntityTagBytes));
                if (!hasChild) {
                    static const NSUInteger kSubtreeCardPath[] = {
                        5, 1337, 6, 2, 17, 3, 1, 36905, 1, 1, 168777401, 5, 232903841
                    };
                    YTAIExtractChunksByPath(chunk, chunkLen, kSubtreeCardPath, 13, 0, results);
                }
            }
            YTAIExtract1337CardsFromVerifiedSubtrees(chunk, chunkLen, depth + 1, results);
            pos += chunkLen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
}

static void YTAIExtractVideosFrom1337Layout(const uint8_t *bytes, NSUInteger length,
                                            NSString * _Nullable activeVid,
                                            NSMutableSet<NSString *> *seen,
                                            NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *results) {
    if (bytes == NULL || length < 30) return;

    static const NSUInteger kFullCardPath[] = {
        1, 1, 1, 153515154, 172660663, 1, 168777401, 5,
        1337, 6, 2, 17, 3, 1, 36905, 1, 1, 168777401, 5, 232903841
    };
    static const NSUInteger kRootCardPath[] = {
        153515154, 172660663, 1, 168777401, 5,
        1337, 6, 2, 17, 3, 1, 36905, 1, 1, 168777401, 5, 232903841
    };
    static const NSUInteger kCommandPath[] = {
        1, 6, 170382656, 1, 169495254, 462702848
    };

    NSMutableArray<NSData *> *cardChunks = [NSMutableArray array];
    // Layout 1: Outer mutation operations envelope (20 fields)
    YTAIExtractChunksByPath(bytes, length, kFullCardPath, 20, 0, cardChunks);

    // Layout 2: Standalone ElementRenderer (17 fields)
    if (cardChunks.count == 0) {
        YTAIExtractChunksByPath(bytes, length, kRootCardPath, 17, 0, cardChunks);
    }

    // Layout 3: Subtree verified assistant entities
    if (cardChunks.count == 0) {
        YTAIExtract1337CardsFromVerifiedSubtrees(bytes, length, 0, cardChunks);
    }

    if (cardChunks.count == 0) return;

    for (NSData *cardData in cardChunks) {
        NSMutableArray<NSData *> *cmdChunks = [NSMutableArray array];
        YTAIExtractChunksByPath((const uint8_t *)cardData.bytes, cardData.length,
                                kCommandPath, 6, 0, cmdChunks);
        for (NSData *cmdData in cmdChunks) {
            NSArray<NSDictionary<NSString *, NSString *> *> *vids = YTAIExtractVideosFromCommandPayload(cmdData, activeVid);
            for (NSDictionary<NSString *, NSString *> *v in vids) {
                NSString *vid = v[@"videoId"];
                NSString *title = v[@"title"];
                if (vid.length == 11 && YTAIIsValidVideoId(vid)) {
                    if (![seen containsObject:vid]) {
                        [seen addObject:vid];
                        [results addObject:[@{
                            @"videoId": vid,
                            @"title": title ?: @""
                        } mutableCopy]];
                    } else if (title.length > 0) {
                        for (NSMutableDictionary *existing in results) {
                            if ([existing[@"videoId"] isEqualToString:vid] && [existing[@"title"] length] == 0) {
                                existing[@"title"] = title;
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromPayloadWithClass(NSData *payload, NSString * _Nullable payloadClass, NSString * _Nullable activeVid) {
    if (payload.length < 30) return @[];
    const uint8_t *bytes = (const uint8_t *)payload.bytes;
    NSUInteger length = payload.length;

    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (activeVid.length > 0) [seen addObject:activeVid];

    // 1. Standalone command
    if ([payloadClass isEqualToString:@"YTICommand"] || [payloadClass isEqualToString:@"ELMCommand"]) {
        return YTAIExtractVideosFromCommandPayload(payload, activeVid);
    }

    // 2. Section list mutation envelope (YTISectionListMutationOperations)
    // Structure: field 1 (mutationOperations) -> field 1 (payload) -> field 1 (elementRenderer)
    BOOL isMutationEnvelope = [payloadClass isEqualToString:@"YTISectionListMutationOperations"];
    if (!isMutationEnvelope && payloadClass.length == 0 && length > 10 && bytes[0] == 0x0A) {
        // Auto-detect: starts with field 1
        isMutationEnvelope = YES;
    }

    if (isMutationEnvelope) {
        NSUInteger pos = 0;
        while (pos < length) {
            NSUInteger p = pos;
            unsigned long long tag = 0;
            NSUInteger shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                tag |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            NSUInteger field = (NSUInteger)(tag >> 3);
            NSUInteger wire = (NSUInteger)(tag & 7);
            if (wire == 2) {
                p = pos;
                unsigned long long flen = 0;
                shift = 0;
                while (p < length && shift < 35) {
                    uint8_t b = bytes[p++];
                    flen |= (unsigned long long)(b & 0x7F) << shift;
                    if (!(b & 0x80)) break;
                    shift += 7;
                }
                if (p == pos) break;
                pos = p;
                if (pos + flen > length) break;
                NSUInteger chunkLen = (NSUInteger)flen;
                const uint8_t *chunk = bytes + pos;
                pos += chunkLen;

                if (field == 1) { // mutationOperation
                    NSUInteger mpos = 0;
                    while (mpos < chunkLen) {
                        NSUInteger mp = mpos;
                        unsigned long long mtag = 0;
                        shift = 0;
                        while (mp < chunkLen && shift < 35) {
                            uint8_t b = chunk[mp++];
                            mtag |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (mp == mpos) break;
                        mpos = mp;
                        NSUInteger mfield = (NSUInteger)(mtag >> 3);
                        NSUInteger mwire = (NSUInteger)(mtag & 7);
                        if (mwire == 2) {
                            mp = mpos;
                            unsigned long long mlen = 0;
                            shift = 0;
                            while (mp < chunkLen && shift < 35) {
                                uint8_t b = chunk[mp++];
                                mlen |= (unsigned long long)(b & 0x7F) << shift;
                                if (!(b & 0x80)) break;
                                shift += 7;
                            }
                            if (mp == mpos) break;
                            mpos = mp;
                            if (mpos + mlen > chunkLen) break;
                            NSUInteger mact = (NSUInteger)mlen;
                            const uint8_t *mchunk = chunk + mpos;
                            mpos += mact;

                            if (mfield == 1) { // payload
                                NSUInteger ppos = 0;
                                while (ppos < mact) {
                                    NSUInteger pp = ppos;
                                    unsigned long long ptag = 0;
                                    shift = 0;
                                    while (pp < mact && shift < 35) {
                                        uint8_t b = mchunk[pp++];
                                        ptag |= (unsigned long long)(b & 0x7F) << shift;
                                        if (!(b & 0x80)) break;
                                        shift += 7;
                                    }
                                    if (pp == ppos) break;
                                    ppos = pp;
                                    NSUInteger pfield = (NSUInteger)(ptag >> 3);
                                    NSUInteger pwire = (NSUInteger)(ptag & 7);
                                    if (pwire == 2) {
                                        pp = ppos;
                                        unsigned long long plen = 0;
                                        shift = 0;
                                        while (pp < mact && shift < 35) {
                                            uint8_t b = mchunk[pp++];
                                            plen |= (unsigned long long)(b & 0x7F) << shift;
                                            if (!(b & 0x80)) break;
                                            shift += 7;
                                        }
                                        if (pp == ppos) break;
                                        ppos = pp;
                                        if (ppos + plen > mact) break;
                                        NSUInteger pact = (NSUInteger)plen;
                                        const uint8_t *pchunk = mchunk + ppos;
                                        ppos += pact;

                                        if (pfield == 1) { // elementRenderer
                                            YTAIWalkProtobufCardFields(pchunk, pact, YTAICardCtxRoot, 0, activeVid, seen, results);
                                        }
                                    } else if (pwire == 0) {
                                        while (ppos < mact && (mchunk[ppos++] & 0x80)) {}
                                    } else if (pwire == 1) {
                                        ppos += 8;
                                    } else if (pwire == 5) {
                                        ppos += 4;
                                    } else {
                                        break;
                                    }
                                }
                            }
                        } else if (mwire == 0) {
                            while (mpos < chunkLen && (chunk[mpos++] & 0x80)) {}
                        } else if (mwire == 1) {
                            mpos += 8;
                        } else if (mwire == 5) {
                            mpos += 4;
                        } else {
                            break;
                        }
                    }
                }
            } else if (wire == 0) {
                while (pos < length && (bytes[pos++] & 0x80)) {}
            } else if (wire == 1) {
                pos += 8;
            } else if (wire == 5) {
                pos += 4;
            } else {
                break;
            }
        }
    }

    // 3. Direct card / YTIElementRenderer
    if (results.count == 0) {
        YTAIWalkProtobufCardFields(bytes, length, YTAICardCtxRoot, 0, activeVid, seen, results);
    }

    // 4. Structural rich-text annotation decoder through verified assistant entity paths only
    YTAIExtractRichTextFromVerifiedEntities(bytes, length, activeVid, seen, results);

    // 5. Observed 1337 -> ... -> 232903841 card layout
    YTAIExtractVideosFrom1337Layout(bytes, length, activeVid, seen, results);

    return [results copy];
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromPayload(NSData *payload, NSString *activeVid) {
    return YTAIExtractVideosFromPayloadWithClass(payload, nil, activeVid);
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromCommandPayload(NSData *cmdPayload, NSString *activeVid) {
    if (cmdPayload.length < 10) return @[];
    const uint8_t *bytes = (const uint8_t *)cmdPayload.bytes;
    NSUInteger length = cmdPayload.length;

    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (activeVid.length > 0) [seen addObject:activeVid];

    // Standalone navigation command parsing: starts at Command context
    YTAIWalkProtobufCardFields(bytes, length, YTAICardCtxCommand, 0, activeVid, seen, results);
    if (results.count == 0) {
        // Direct Endpoint payload
        YTAIWalkProtobufCardFields(bytes, length, YTAICardCtxEndpoint, 0, activeVid, seen, results);
    }
    return [results copy];
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromPayloads(NSArray *payloads, NSString *activeVid) {
    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *all = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (activeVid.length > 0) [seen addObject:activeVid];

    for (id item in payloads) {
        NSData *data = nil;
        NSString *cls = nil;
        if ([item isKindOfClass:NSData.class]) {
            data = (NSData *)item;
        } else if ([item isKindOfClass:NSDictionary.class]) {
            data = item[@"data"];
            cls = item[@"class"];
        }
        if (![data isKindOfClass:NSData.class] || data.length < 30) continue;
        NSArray<NSDictionary<NSString *, NSString *> *> *extracted = YTAIExtractVideosFromPayloadWithClass(data, cls, activeVid);
        for (NSDictionary *v in extracted) {
            NSString *vid = v[@"videoId"];
            NSString *title = v[@"title"];
            if (vid.length == 11 && ![seen containsObject:vid]) {
                [seen addObject:vid];
                [all addObject:[v mutableCopy]];
            } else if (vid.length == 11 && title.length > 0) {
                for (NSMutableDictionary *existing in all) {
                    if ([existing[@"videoId"] isEqualToString:vid] && [existing[@"title"] length] == 0) {
                        existing[@"title"] = title;
                        break;
                    }
                }
            }
        }
    }
    return [all copy];
}

static NSString *YTAIExtractVideoIdFromUrl(NSString *urlStr) {
    if (urlStr.length == 0) return nil;
    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:@"(?:watch\\?v=|youtu\\.be/)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"
                                                                        options:0
                                                                          error:nil];
    NSTextCheckingResult *m = [rx firstMatchInString:urlStr options:0 range:NSMakeRange(0, urlStr.length)];
    if (m != nil && m.numberOfRanges >= 2) {
        NSString *vid = [urlStr substringWithRange:[m rangeAtIndex:1]];
        if (vid.length == 11 && YTAIIsValidVideoId(vid)) {
            return vid;
        }
    }
    return nil;
}

UIView *YTAIFindAiPanelContainer(UIView *focusView) {
    if (focusView != nil) {
        UIView *curr = focusView;
        UIView *candidate = nil;
        while (curr != nil && ![curr isKindOfClass:UIWindow.class]) {
            NSString *cls = NSStringFromClass([curr class]);
            if ([cls containsString:@"EngagementPanel"] ||
                [cls containsString:@"BottomSheet"] ||
                [cls containsString:@"PanelContainer"] ||
                [cls containsString:@"AssistantPanel"] ||
                [cls containsString:@"AIPanel"]) {
                candidate = curr;
                break;
            }
            curr = curr.superview;
        }
        if (candidate != nil) return candidate;
    }

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.05) continue;
            __block UIView *found = nil;
            __block __weak void (^weakFindPanel)(UIView *);
            void (^findPanel)(UIView *) = ^(UIView *v) {
                if (found != nil || v == nil) return;
                NSString *cls = NSStringFromClass([v class]);
                if ([cls containsString:@"EngagementPanelView"] || [cls containsString:@"YTEngagementPanelContainerView"] ||
                    [cls containsString:@"AssistantPanel"] || [cls containsString:@"AIPanel"]) {
                    if (YTAIViewIsVisibleOnScreen(v)) {
                        found = v;
                        return;
                    }
                }
                for (UIView *sub in v.subviews) weakFindPanel(sub);
            };
            weakFindPanel = findPanel;
            findPanel(window);
            if (found != nil) return found;
        }
    }
    return nil;
}

static BOOL YTAIIsComposerOrInputView(UIView * _Nullable view) {
    if (view == nil) return NO;
    NSString *cls = NSStringFromClass([view class]);
    if ([cls containsString:@"Composer"] ||
        [cls containsString:@"ChatInput"] ||
        [cls containsString:@"VoiceInput"]) {
        return YES;
    }
    if ([view isKindOfClass:UITextField.class]) return YES;
    if ([view isKindOfClass:UITextView.class] && (((UITextView *)view).isEditable || view.isFirstResponder)) return YES;
    NSString *accId = view.accessibilityIdentifier;
    if (accId.length > 0) {
        NSString *lowerId = [accId lowercaseString];
        if ([lowerId containsString:@"composer"] ||
            [lowerId containsString:@"chat_input"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTAIIsUserMessageTurn(UIView * _Nullable root) {
    if (root == nil) return NO;
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"UserMessage"] ||
        [cls containsString:@"UserPrompt"] ||
        [cls containsString:@"UserInputTurn"]) {
        return YES;
    }
    NSString *accId = root.accessibilityIdentifier;
    if (accId.length > 0) {
        NSString *lowerId = [accId lowercaseString];
        if ([lowerId containsString:@"user_message"] ||
            [lowerId containsString:@"user_turn"] ||
            [lowerId containsString:@"user_prompt"]) {
            return YES;
        }
    }
    return NO;
}

static BOOL YTAIIsUserOrInputTurnWithReason(UIView * _Nullable root, NSString * _Nullable * _Nullable outReason) {
    if (root == nil) return NO;
    if (YTAIIsComposerOrInputView(root)) {
        if (outReason) *outReason = @"is-composer-or-input";
        return YES;
    }
    if (YTAIIsUserMessageTurn(root)) {
        if (outReason) *outReason = @"is-user-message-turn";
        return YES;
    }

    __block BOOL isUser = NO;
    __block NSString *reason = nil;
    __block NSUInteger budget = 200;
    __block __weak void (^weakWalk)(UIView *);
    void (^walk)(UIView *) = ^(UIView *view) {
        if (view == nil || isUser || budget == 0) return;
        budget--;

        if (YTAIIsComposerOrInputView(view)) {
            // Skip composer subtrees rather than condemning the entire root container if root is not itself a composer
            return;
        }

        if (YTAIIsUserMessageTurn(view)) {
            isUser = YES;
            reason = [NSString stringWithFormat:@"user-turn-class:%@", NSStringFromClass([view class])];
            return;
        }

        for (UIView *sub in view.subviews) {
            weakWalk(sub);
            if (isUser) return;
        }
    };
    weakWalk = walk;
    walk(root);
    if (outReason) *outReason = reason;
    return isUser;
}

static BOOL YTAIIsUserOrInputTurn(UIView * _Nullable root) {
    return YTAIIsUserOrInputTurnWithReason(root, NULL);
}

static NSInteger YTAICountPanelItems(UIView * _Nullable panel) {
    if (panel == nil) return -1;
    __block NSInteger count = -1;
    __block __weak void (^weakFindList)(UIView *);
    void (^findList)(UIView *) = ^(UIView *v) {
        if (count >= 0 || v == nil) return;
        if (YTAIIsComposerOrInputView(v)) return; // skip composer subtree
        if ([v isKindOfClass:UICollectionView.class]) {
            UICollectionView *cv = (UICollectionView *)v;
            NSInteger total = 0;
            NSInteger sections = [cv numberOfSections];
            for (NSInteger s = 0; s < sections; s++) {
                total += [cv numberOfItemsInSection:s];
            }
            count = total;
            return;
        } else if ([v isKindOfClass:UITableView.class]) {
            UITableView *tv = (UITableView *)v;
            NSInteger total = 0;
            NSInteger sections = [tv numberOfSections];
            for (NSInteger s = 0; s < sections; s++) {
                total += [tv numberOfRowsInSection:s];
            }
            count = total;
            return;
        }
        for (UIView *sub in v.subviews) weakFindList(sub);
    };
    weakFindList = findList;
    findList(panel);
    return count;
}

static BOOL YTAIIsVerifiedCarouselOrCardContainer(UIView * _Nullable root) {
    if (root == nil) return NO;
    __block BOOL isVerified = NO;
    __block NSUInteger budget = 250;
    __block __weak void (^weakWalk)(UIView *);
    void (^walk)(UIView *) = ^(UIView *view) {
        if (view == nil || isVerified || budget == 0) return;
        budget--;

        NSString *cls = NSStringFromClass([view class]);
        if ([cls containsString:@"Carousel"] ||
            [cls containsString:@"Shelf"] ||
            [cls containsString:@"VideoLockup"] ||
            [cls containsString:@"VideoCard"] ||
            [cls containsString:@"CardCollection"] ||
            [cls containsString:@"HorizontalList"] ||
            [cls containsString:@"ASCollectionView"]) {
            isVerified = YES;
            return;
        }

        NSString *accId = view.accessibilityIdentifier;
        if (accId.length > 0) {
            NSString *lowerId = [accId lowercaseString];
            if ([lowerId containsString:@"carousel"] ||
                [lowerId containsString:@"shelf"] ||
                [lowerId containsString:@"video_lockup"] ||
                [lowerId containsString:@"video_card"] ||
                [lowerId containsString:@"vwc"] ||
                [lowerId containsString:@"thumbnail"] ||
                [lowerId containsString:@"lockup"] ||
                [lowerId containsString:@"compact_video"]) {
                isVerified = YES;
                return;
            }
        }

        NSString *accLabel = view.accessibilityLabel;
        if (accLabel.length > 0) {
            NSString *lowerLabel = [accLabel lowercaseString];
            if ([lowerLabel containsString:@"related video"] ||
                [lowerLabel containsString:@"similar video"] ||
                [lowerLabel containsString:@"related content"]) {
                isVerified = YES;
                return;
            }
        }

        if ([view isKindOfClass:UILabel.class]) {
            NSString *txt = [((UILabel *)view).text lowercaseString];
            if ([txt containsString:@"related video"] || [txt containsString:@"similar video"]) {
                isVerified = YES;
                return;
            }
        }

        if ([view isKindOfClass:UICollectionView.class]) {
            UICollectionView *cv = (UICollectionView *)view;
            if ([cv.collectionViewLayout isKindOfClass:[UICollectionViewFlowLayout class]]) {
                UICollectionViewFlowLayout *flow = (UICollectionViewFlowLayout *)cv.collectionViewLayout;
                if (flow.scrollDirection == UICollectionViewScrollDirectionHorizontal) {
                    isVerified = YES;
                    return;
                }
            }
            if (cv.contentSize.width > cv.bounds.size.width + 10.0) {
                isVerified = YES;
                return;
            }
        } else if ([view isKindOfClass:UIScrollView.class] && ![view isKindOfClass:UITextView.class]) {
            UIScrollView *sv = (UIScrollView *)view;
            if (sv.contentSize.width > sv.bounds.size.width + 10.0) {
                isVerified = YES;
                return;
            }
        }

        id node = YTAINodeOfView(view);
        if (node != nil) {
            NSString *nodeCls = NSStringFromClass([node class]);
            if ([nodeCls containsString:@"VideoLockup"] ||
                [nodeCls containsString:@"VideoCard"] ||
                [nodeCls containsString:@"Carousel"] ||
                [nodeCls containsString:@"Shelf"] ||
                [nodeCls containsString:@"vwc"]) {
                isVerified = YES;
                return;
            }
        }

        for (UIView *sub in view.subviews) {
            weakWalk(sub);
            if (isVerified) return;
        }
    };
    weakWalk = walk;
    walk(root);
    return isVerified;
}

UIView *YTAIFindCurrentAssistantMessageContainer(UIView *panelContainer, NSString *answerText) {
    if (panelContainer == nil) return nil;

    NSString *prefix = nil;
    if (answerText.length > 0) {
        NSString *trimmed = [answerText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trimmed.length > 20) {
            prefix = [trimmed substringToIndex:MIN(trimmed.length, 35)];
        } else if (trimmed.length > 0) {
            prefix = trimmed;
        }
    }

    __block UIView *matchingLabelOrTextView = nil;

    if (prefix.length > 0) {
        // Scoped text matching: MUST match the actual answer text
        __block NSUInteger budget = 1500;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (matchingLabelOrTextView != nil || view == nil || budget == 0) return;
            budget--;
            if (view.hidden || view.alpha < 0.05) return;
            if (YTAIIsComposerOrInputView(view)) return; // skip composer subtree

            NSString *text = nil;
            if ([view isKindOfClass:UILabel.class]) {
                text = ((UILabel *)view).text ?: ((UILabel *)view).attributedText.string;
            } else if ([view isKindOfClass:UITextView.class]) {
                if (!view.isFirstResponder && !((UITextView *)view).isEditable) {
                    text = ((UITextView *)view).text ?: ((UITextView *)view).attributedText.string;
                }
            } else {
                id node = YTAINodeOfView(view);
                if (node != nil && [node respondsToSelector:@selector(attributedText)]) {
                    NSAttributedString *attr = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(node, @selector(attributedText));
                    if (attr.length > 0) text = attr.string;
                }
            }

            if (text.length > 0 && [text containsString:prefix]) {
                matchingLabelOrTextView = view;
                return;
            }

            for (UIView *sub in view.subviews) weakWalk(sub);
        };
        weakWalk = walk;
        walk(panelContainer);

        // If text matching fails when text was expected, return nil (never fall back to arbitrary text)
        if (matchingLabelOrTextView == nil) {
            return nil;
        }
    }

    __block UIView *target = matchingLabelOrTextView;

    if (target == nil) {
        // Cards-only answer path (prefix.length == 0): identify newly created response/card section using pre-submission baseline
        __block UIView *cardsCandidate = nil;
        __block __weak void (^weakFindNewCell)(UIView *);
        void (^findNewCell)(UIView *) = ^(UIView *v) {
            if (cardsCandidate != nil || v == nil) return;
            if (YTAIIsComposerOrInputView(v)) return; // skip composer subtree

            if ([v isKindOfClass:UICollectionView.class]) {
                UICollectionView *cv = (UICollectionView *)v;
                NSInteger totalSections = [cv numberOfSections];
                NSInteger baseCount = YTAIPreSubmissionItemCount;
                for (NSInteger s = 0; s < totalSections; s++) {
                    NSInteger items = [cv numberOfItemsInSection:s];
                    NSInteger startItem = (s == 0 && baseCount >= 0) ? baseCount : 0;
                    for (NSInteger item = startItem; item < items; item++) {
                        NSIndexPath *ip = [NSIndexPath indexPathForItem:item inSection:s];
                        UICollectionViewCell *cell = [cv cellForItemAtIndexPath:ip];
                        if (cell != nil && !cell.hidden && cell.alpha >= 0.05) {
                            if (YTAIIsUserMessageTurn(cell) || YTAIIsComposerOrInputView(cell)) continue;
                            if (YTAIIsVerifiedCarouselOrCardContainer(cell)) {
                                cardsCandidate = cell;
                                return;
                            }
                        }
                    }
                }
            } else if ([v isKindOfClass:UITableView.class]) {
                UITableView *tv = (UITableView *)v;
                NSInteger totalSections = [tv numberOfSections];
                NSInteger baseCount = YTAIPreSubmissionItemCount;
                for (NSInteger s = 0; s < totalSections; s++) {
                    NSInteger rows = [tv numberOfRowsInSection:s];
                    NSInteger startRow = (s == 0 && baseCount >= 0) ? baseCount : 0;
                    for (NSInteger row = startRow; row < rows; row++) {
                        NSIndexPath *ip = [NSIndexPath indexPathForRow:row inSection:s];
                        UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
                        if (cell != nil && !cell.hidden && cell.alpha >= 0.05) {
                            if (YTAIIsUserMessageTurn(cell) || YTAIIsComposerOrInputView(cell)) continue;
                            if (YTAIIsVerifiedCarouselOrCardContainer(cell)) {
                                cardsCandidate = cell;
                                return;
                            }
                        }
                    }
                }
            }
            for (UIView *sub in v.subviews) weakFindNewCell(sub);
        };
        weakFindNewCell = findNewCell;
        findNewCell(panelContainer);
        target = cardsCandidate;
    }

    if (target == nil) return nil;

    UIView *curr = target;
    UIView *container = curr;
    while (curr.superview != nil && curr.superview != panelContainer) {
        if ([curr isKindOfClass:UICollectionViewCell.class] || [curr isKindOfClass:UITableViewCell.class]) {
            return curr;
        }
        if ([curr.superview isKindOfClass:UICollectionView.class] || [curr.superview isKindOfClass:UITableView.class] || [curr.superview isKindOfClass:UIScrollView.class]) {
            return curr;
        }
        curr = curr.superview;
        container = curr;
    }
    return container;
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIScrapeRelatedVideosAndLinks(
    UIView *assistantContainer,
    NSString *activeVid,
    NSMutableDictionary<NSString *, NSString *> *outResolutions)
{
    if (assistantContainer == nil) return @[];

    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *results = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (activeVid.length > 0) [seen addObject:activeVid];

    NSMutableArray<UIView *> *roots = [NSMutableArray array];
    [roots addObject:assistantContainer];

    if ([assistantContainer.superview isKindOfClass:UICollectionView.class]) {
        UICollectionView *cv = (UICollectionView *)assistantContainer.superview;
        NSIndexPath *ip = nil;
        if ([assistantContainer isKindOfClass:UICollectionViewCell.class]) {
            ip = [cv indexPathForCell:(UICollectionViewCell *)assistantContainer];
        } else {
            for (UICollectionViewCell *cell in cv.visibleCells) {
                if (cell == assistantContainer || [assistantContainer isDescendantOfView:cell]) {
                    ip = [cv indexPathForCell:cell];
                    break;
                }
            }
        }
        if (ip != nil) {
            NSInteger totalItems = [cv numberOfItemsInSection:ip.section];
            for (NSInteger item = ip.item + 1; item < totalItems; item++) {
                NSIndexPath *nextIp = [NSIndexPath indexPathForItem:item inSection:ip.section];
                UICollectionViewCell *nextCell = [cv cellForItemAtIndexPath:nextIp];
                if (nextCell == nil || nextCell.hidden || nextCell.alpha < 0.05) continue;
                if (YTAIIsUserOrInputTurn(nextCell)) break;
                [roots addObject:nextCell];
            }
        }
    } else if ([assistantContainer.superview isKindOfClass:UITableView.class]) {
        UITableView *tv = (UITableView *)assistantContainer.superview;
        NSIndexPath *ip = nil;
        if ([assistantContainer isKindOfClass:UITableViewCell.class]) {
            ip = [tv indexPathForCell:(UITableViewCell *)assistantContainer];
        } else {
            for (UITableViewCell *cell in tv.visibleCells) {
                if (cell == assistantContainer || [assistantContainer isDescendantOfView:cell]) {
                    ip = [tv indexPathForCell:cell];
                    break;
                }
            }
        }
        if (ip != nil) {
            NSInteger totalRows = [tv numberOfRowsInSection:ip.section];
            for (NSInteger row = ip.row + 1; row < totalRows; row++) {
                NSIndexPath *nextIp = [NSIndexPath indexPathForRow:row inSection:ip.section];
                UITableViewCell *nextCell = [tv cellForRowAtIndexPath:nextIp];
                if (nextCell == nil || nextCell.hidden || nextCell.alpha < 0.05) continue;
                if (YTAIIsUserOrInputTurn(nextCell)) break;
                [roots addObject:nextCell];
            }
        }
    }

    if (assistantContainer.superview != nil) {
        UIView *parent = assistantContainer.superview;
        CGFloat containerBottom = CGRectGetMaxY(assistantContainer.frame);

        NSMutableArray<UIView *> *siblingsBelow = [NSMutableArray array];
        for (UIView *sibling in parent.subviews) {
            if (sibling == assistantContainer || sibling.hidden || sibling.alpha < 0.05) continue;
            if (sibling.frame.origin.y >= containerBottom - 2.0) {
                [siblingsBelow addObject:sibling];
            }
        }
        [siblingsBelow sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            if (a.frame.origin.y < b.frame.origin.y) return NSOrderedAscending;
            if (a.frame.origin.y > b.frame.origin.y) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        for (UIView *sibling in siblingsBelow) {
            if (YTAIIsUserOrInputTurn(sibling)) break;
            if (![roots containsObject:sibling]) {
                [roots addObject:sibling];
            }
        }
    }

    for (UIView *root in roots) {
        __block NSUInteger budget = 500;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (view == nil || budget == 0) return;
            budget--;
            if (view.hidden || view.alpha < 0.05) return;
            if (YTAIIsComposerOrInputView(view)) return; // skip composer subtree

            // 1. Attributed text links
            NSAttributedString *attrStr = nil;
            if ([view isKindOfClass:UILabel.class]) {
                attrStr = ((UILabel *)view).attributedText;
            } else if ([view isKindOfClass:UITextView.class]) {
                attrStr = ((UITextView *)view).attributedText;
            } else {
                id node = YTAINodeOfView(view);
                if (node != nil && [node respondsToSelector:@selector(attributedText)]) {
                    attrStr = ((NSAttributedString *(*)(id, SEL))objc_msgSend)(node, @selector(attributedText));
                }
            }

            if (attrStr != nil && attrStr.length > 0) {
                [attrStr enumerateAttributesInRange:NSMakeRange(0, attrStr.length)
                                            options:0
                                         usingBlock:^(NSDictionary<NSAttributedStringKey,id> *attrs, NSRange range, BOOL *stop) {
                    id link = attrs[NSLinkAttributeName];
                    NSString *urlStr = nil;
                    if ([link isKindOfClass:NSURL.class]) {
                        urlStr = ((NSURL *)link).absoluteString;
                    } else if ([link isKindOfClass:NSString.class]) {
                        urlStr = (NSString *)link;
                    }
                    if (urlStr.length > 0) {
                        NSString *v = YTAIExtractVideoIdFromUrl(urlStr);
                        if (v.length == 11 && YTAIIsValidVideoId(v) && (activeVid.length == 0 || ![v isEqualToString:activeVid])) {
                            NSString *display = [attrStr.string substringWithRange:range];
                            if (display.length > 0 && outResolutions != nil) {
                                outResolutions[display] = v;
                            }
                            if (![seen containsObject:v]) {
                                [seen addObject:v];
                                [results addObject:[@{@"videoId": v, @"title": @"", @"displayText": display ?: @""} mutableCopy]];
                            }
                        }
                    }
                }];
            }

            // 2. Gesture recognizer targets (watchEndpoint serialization)
            for (UIGestureRecognizer *rec in view.gestureRecognizers) {
                NSArray *pairs = nil;
                @try {
                    id raw = [rec valueForKey:@"_targets"];
                    if ([raw isKindOfClass:NSArray.class]) pairs = [raw copy];
                } @catch (NSException *ex) {}
                for (id pair in pairs) {
                    id target = nil;
                    @try { target = [pair valueForKey:@"_target"]; } @catch (NSException *ex) {}
                    if (target == nil) continue;
                    NSError *err = nil;
                    NSData *cmdBytes = YTRCSerializeMessage(target, 64 * 1024, &err);
                    if (cmdBytes.length > 0) {
                        NSArray<NSDictionary *> *extracted = YTAIExtractVideosFromCommandPayload(cmdBytes, activeVid);
                        if (extracted.count == 0) {
                            extracted = YTAIExtractVideosFromPayload(cmdBytes, activeVid);
                        }
                        for (NSDictionary *d in extracted) {
                            NSString *v = d[@"videoId"];
                            NSString *t = d[@"title"];
                            if (t.length == 0 && view.accessibilityLabel.length > 0) {
                                NSString *lbl = [view.accessibilityLabel stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                                if (lbl.length > 3 && ![lbl containsString:@"Action menu"] && ![lbl containsString:@"More actions"]) {
                                    NSRange dashRange = [lbl rangeOfString:@" - "];
                                    if (dashRange.location != NSNotFound && dashRange.location > 3) {
                                        t = [lbl substringToIndex:dashRange.location];
                                    } else {
                                        t = lbl;
                                    }
                                }
                            }
                            if (v.length == 11 && YTAIIsValidVideoId(v) && ![seen containsObject:v]) {
                                [seen addObject:v];
                                [results addObject:[@{@"videoId": v, @"title": t ?: @""} mutableCopy]];
                            } else if (v.length == 11 && t.length > 0) {
                                for (NSMutableDictionary *existing in results) {
                                    if ([existing[@"videoId"] isEqualToString:v] && [existing[@"title"] length] == 0) {
                                        existing[@"title"] = t;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // 3. Accessibility string matches
            for (NSString *str in @[view.accessibilityLabel ?: @"", view.accessibilityIdentifier ?: @""]) {
                if (str.length > 0 && ([str containsString:@"watch?v="] || [str containsString:@"youtu.be/"])) {
                    NSString *v = YTAIExtractVideoIdFromUrl(str);
                    if (v.length == 11 && YTAIIsValidVideoId(v) && ![seen containsObject:v]) {
                        [seen addObject:v];
                        [results addObject:[@{@"videoId": v, @"title": @""} mutableCopy]];
                    }
                }
            }

            for (UIView *sub in view.subviews) weakWalk(sub);
        };
        weakWalk = walk;
        walk(root);
    }

    return [results copy];
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIScrapeRelatedVideosFromView(UIView * _Nullable rootView, NSString * _Nullable activeVid) {
    if (rootView == nil) return @[];
    return YTAIScrapeRelatedVideosAndLinks(rootView, activeVid, nil);
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIScrapeRelatedVideosFromUI(NSString * _Nullable activeVid) {
    UIView *panel = YTAIFindAiPanelContainer(nil);
    UIView *assistant = YTAIFindCurrentAssistantMessageContainer(panel, nil);
    NSArray<NSDictionary *> *res = (assistant != nil) ? YTAIScrapeRelatedVideosAndLinks(assistant, activeVid, nil) : @[];
    return res;
}

NSArray<NSDictionary<NSString *, NSString *> *> *YTAIMergeRelatedVideos(NSArray<NSDictionary *> *v1, NSArray<NSDictionary *> *v2, NSString *activeVid) {
    NSMutableArray<NSMutableDictionary<NSString *, NSString *> *> *merged = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    if (activeVid.length > 0) [seen addObject:activeVid];

    for (NSArray *list in @[v1 ?: @[], v2 ?: @[]]) {
        for (NSDictionary *v in list) {
            NSString *vid = v[@"videoId"];
            NSString *title = v[@"title"];
            if (vid.length == 11 && YTAIIsValidVideoId(vid)) {
                if (![seen containsObject:vid]) {
                    [seen addObject:vid];
                    [merged addObject:[v mutableCopy]];
                } else if (title.length > 0) {
                    for (NSMutableDictionary *existing in merged) {
                        if ([existing[@"videoId"] isEqualToString:vid] && [existing[@"title"] length] == 0) {
                            existing[@"title"] = title;
                            break;
                        }
                    }
                }
            }
        }
    }
    return [merged copy];
}

static NSString *YTAIReconstructEntityTextWithAnnotations(NSString *text, NSArray<NSDictionary *> *annotations) {
    if (text.length == 0 || annotations.count == 0) return text;

    NSMutableArray<NSDictionary *> *validAnns = [NSMutableArray array];
    for (NSDictionary *ann in annotations) {
        NSString *vid = ann[@"videoId"];
        NSNumber *offNum = ann[@"offset"];
        NSNumber *lenNum = ann[@"length"];
        if (vid.length == 11 && offNum != nil && lenNum != nil) {
            NSUInteger off = [offNum unsignedIntegerValue];
            NSUInteger len = [lenNum unsignedIntegerValue];
            if (off + len <= text.length) {
                [validAnns addObject:ann];
            }
        }
    }
    if (validAnns.count == 0) return text;

    // Sort descending by offset so replacements at later indices never invalidate earlier offsets
    [validAnns sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSUInteger offA = [a[@"offset"] unsignedIntegerValue];
        NSUInteger offB = [b[@"offset"] unsignedIntegerValue];
        if (offA < offB) return NSOrderedDescending;
        if (offA > offB) return NSOrderedAscending;
        return NSOrderedSame;
    }];

    static NSString * const kPlaceholderRegexStr =
        @"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*"
        @"[\\(\\[]"
        @"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*"
        @"[•\\*·\\u2022\\u2023\\u25E6\\u2043\\u2219\\u25AA\\u25AB]"
        @"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*"
        @"[\\)\\]]";
    NSRegularExpression *placeholderRx = [NSRegularExpression regularExpressionWithPattern:kPlaceholderRegexStr
                                                                                   options:0
                                                                                     error:nil];

    NSMutableString *working = [text mutableCopy];
    for (NSDictionary *ann in validAnns) {
        NSUInteger off = [ann[@"offset"] unsignedIntegerValue];
        NSUInteger len = [ann[@"length"] unsignedIntegerValue];
        NSString *vid = ann[@"videoId"];
        NSString *linkUrl = [NSString stringWithFormat:@"https://youtu.be/%@", vid];

        if (off + len > working.length) continue;
        NSRange spanRange = NSMakeRange(off, len);
        NSString *span = [working substringWithRange:spanRange];

        // 1. Direct placeholder match on the span
        NSTextCheckingResult *directMatch = placeholderRx ? [placeholderRx firstMatchInString:span options:0 range:NSMakeRange(0, span.length)] : nil;
        if (directMatch != nil && directMatch.range.length == span.length) {
            [working replaceCharactersInRange:spanRange withString:linkUrl];
            continue;
        }

        // 2. Span contains placeholder
        if (directMatch != nil) {
            NSString *replaced = [placeholderRx stringByReplacingMatchesInString:span options:0 range:NSMakeRange(0, span.length) withTemplate:linkUrl];
            [working replaceCharactersInRange:spanRange withString:replaced];
            continue;
        }

        // 3. Span is anchor text immediately followed by placeholder (e.g. "Title ( • )")
        NSUInteger searchStart = off + len;
        NSUInteger searchLen = MIN((NSUInteger)30, working.length - searchStart);
        if (searchLen > 0 && placeholderRx != nil) {
            NSRange searchRange = NSMakeRange(searchStart, searchLen);
            NSTextCheckingResult *adjMatch = [placeholderRx firstMatchInString:working options:0 range:searchRange];
            if (adjMatch != nil) {
                NSRange betweenRange = NSMakeRange(searchStart, adjMatch.range.location - searchStart);
                NSString *between = [working substringWithRange:betweenRange];
                NSString *trimmedBetween = [between stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000"]];
                if (trimmedBetween.length == 0) {
                    [working replaceCharactersInRange:adjMatch.range withString:[NSString stringWithFormat:@" %@", linkUrl]];
                    continue;
                }
            }
        }

        // 4. Span is anchor text without placeholder
        [working replaceCharactersInRange:spanRange withString:[NSString stringWithFormat:@"%@ %@", span, linkUrl]];
    }

    return [working copy];
}

NSString *YTAIFixTruncatedLinksInText(NSString *text, id _Nullable resolutionsOrVideos) {
    if (text.length == 0) return @"";

    NSMutableArray<NSDictionary *> *annotations = [NSMutableArray array];
    NSDictionary<NSString *, NSString *> *urlMap = nil;

    if ([resolutionsOrVideos isKindOfClass:[NSArray class]]) {
        NSArray *list = (NSArray *)resolutionsOrVideos;
        for (id item in list) {
            if ([item isKindOfClass:[NSDictionary class]] && item[@"offset"] != nil && item[@"videoId"] != nil) {
                [annotations addObject:item];
            }
        }
    } else if ([resolutionsOrVideos isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = (NSDictionary *)resolutionsOrVideos;
        if ([dict[@"annotations"] isKindOfClass:[NSArray class]]) {
            [annotations addObjectsFromArray:dict[@"annotations"]];
        }
        if ([dict[@"videos"] isKindOfClass:[NSArray class]]) {
            for (id item in dict[@"videos"]) {
                if ([item isKindOfClass:[NSDictionary class]] && item[@"offset"] != nil && item[@"videoId"] != nil) {
                    [annotations addObject:item];
                }
            }
        }
        if ([dict[@"resolutions"] isKindOfClass:[NSDictionary class]]) {
            urlMap = dict[@"resolutions"];
        } else {
            urlMap = dict;
        }
    }

    // Step 1: Perform verified range-based reconstruction first (before whitespace normalization)
    if (annotations.count > 0) {
        text = YTAIReconstructEntityTextWithAnnotations(text, annotations);
    }

    // Step 2: Apply exact URL mappings
    if (urlMap.count > 0) {
        for (NSString *badUrl in urlMap) {
            NSString *goodUrl = urlMap[badUrl];
            if ([badUrl hasPrefix:@"http"] || [badUrl containsString:@"youtube"]) {
                NSString *target = [goodUrl hasPrefix:@"http"] ? goodUrl : [NSString stringWithFormat:@"https://youtu.be/%@", goodUrl];
                text = [text stringByReplacingOccurrencesOfString:badUrl withString:target];
            }
        }
    }

    static NSString * const kUrlPattern =
        @"(?:https?://(?:www\\.|m\\.)?youtube(?:\\.[a-z]{2,})?\\S*|"
        @"https?://youtu\\.be/\\S*|"
        @"(?:www\\.|m\\.)youtube(?:\\.[a-z]{2,})?\\S*|"
        @"youtube\\.[a-z]{2,}\\S*|"
        @"(?:https?://)?(?:www\\.)?youtube(?:\\.[a-z]{0,4})?(?:\\.{2,3}|…)\\S*|"
        @"youtu\\.be/\\S*)";

    static NSString * const kPlaceholderPattern =
        @"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*"
        @"[\\(\\[]"
        @"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*"
        @"[•\\*·\\u2022\\u2023\\u25E6\\u2043\\u2219\\u25AA\\u25AB]"
        @"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*"
        @"[\\)\\]]";

    NSRegularExpression *rx = [NSRegularExpression regularExpressionWithPattern:kUrlPattern
                                                                        options:NSRegularExpressionCaseInsensitive
                                                                          error:nil];
    NSRegularExpression *placeholderRx = [NSRegularExpression regularExpressionWithPattern:kPlaceholderPattern
                                                                                   options:0
                                                                                     error:nil];
    if (rx == nil || placeholderRx == nil) return text;

    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    NSMutableArray<NSString *> *cleanedLines = [NSMutableArray array];

    for (NSString *line in lines) {
        NSArray<NSTextCheckingResult *> *matches = [rx matchesInString:line options:0 range:NSMakeRange(0, line.length)];
        NSArray<NSTextCheckingResult *> *placeholderMatches = [placeholderRx matchesInString:line options:0 range:NSMakeRange(0, line.length)];

        if (matches.count == 0 && placeholderMatches.count == 0) {
            [cleanedLines addObject:line];
            continue;
        }

        BOOL hasValidUrl = NO;
        for (NSTextCheckingResult *m in matches) {
            NSString *matchedUrl = [line substringWithRange:m.range];
            NSUInteger trailLen = 0;
            while (matchedUrl.length > trailLen) {
                unichar lastC = [matchedUrl characterAtIndex:matchedUrl.length - 1 - trailLen];
                if ((lastC == ',' || lastC == ';' || lastC == '!' || lastC == '?') &&
                    ![matchedUrl hasSuffix:@"..."]) {
                    trailLen++;
                } else {
                    break;
                }
            }
            NSString *url = [matchedUrl substringToIndex:matchedUrl.length - trailLen];
            if (![url containsString:@"..."] && ![url containsString:@"…"]) {
                if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) {
                    NSString *extractedVid = YTAIExtractVideoIdFromUrl(url);
                    if (extractedVid.length == 11 && YTAIIsValidVideoId(extractedVid)) {
                        hasValidUrl = YES;
                        break;
                    }
                }
            }
        }

        NSRegularExpression *trailWsRx = [NSRegularExpression regularExpressionWithPattern:@"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]+$" options:0 error:nil];
        if (hasValidUrl) {
            NSMutableString *lineMutable = [line mutableCopy];
            for (NSInteger i = (NSInteger)matches.count - 1; i >= 0; i--) {
                NSTextCheckingResult *m = matches[i];
                NSString *matchedUrl = [line substringWithRange:m.range];
                NSUInteger trailLen = 0;
                while (matchedUrl.length > trailLen) {
                    unichar lastC = [matchedUrl characterAtIndex:matchedUrl.length - 1 - trailLen];
                    if ((lastC == ',' || lastC == ';' || lastC == '!' || lastC == '?') &&
                        ![matchedUrl hasSuffix:@"..."]) {
                        trailLen++;
                    } else {
                        break;
                    }
                }
                NSString *url = [matchedUrl substringToIndex:matchedUrl.length - trailLen];
                BOOL isSingleValid = NO;
                if (![url containsString:@"..."] && ![url containsString:@"…"]) {
                    if ([url hasPrefix:@"http://"] || [url hasPrefix:@"https://"]) {
                        NSString *extractedVid = YTAIExtractVideoIdFromUrl(url);
                        if (extractedVid.length == 11 && YTAIIsValidVideoId(extractedVid)) {
                            isSingleValid = YES;
                        }
                    }
                }
                if (!isSingleValid) {
                    [lineMutable replaceCharactersInRange:m.range withString:@""];
                }
            }
            NSArray<NSTextCheckingResult *> *pms = [placeholderRx matchesInString:lineMutable options:0 range:NSMakeRange(0, lineMutable.length)];
            for (NSInteger i = (NSInteger)pms.count - 1; i >= 0; i--) {
                NSTextCheckingResult *pm = pms[i];
                [lineMutable replaceCharactersInRange:pm.range withString:@""];
            }
            [trailWsRx replaceMatchesInString:lineMutable options:0 range:NSMakeRange(0, lineMutable.length) withTemplate:@""];
            NSString *trimmed = [lineMutable stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000"]];
            if (trimmed.length > 0) {
                [cleanedLines addObject:lineMutable];
            }
            continue;
        }

        // Line does not have a verified valid URL: strip malformed URLs and unverified placeholders
        NSMutableString *cleanedLine = [line mutableCopy];
        for (NSInteger i = (NSInteger)matches.count - 1; i >= 0; i--) {
            NSTextCheckingResult *m = matches[i];
            [cleanedLine replaceCharactersInRange:m.range withString:@""];
        }
        NSArray<NSTextCheckingResult *> *pms = [placeholderRx matchesInString:cleanedLine options:0 range:NSMakeRange(0, cleanedLine.length)];
        for (NSInteger i = (NSInteger)pms.count - 1; i >= 0; i--) {
            NSTextCheckingResult *pm = pms[i];
            [cleanedLine replaceCharactersInRange:pm.range withString:@""];
        }
        NSRegularExpression *trailPunctRx = [NSRegularExpression regularExpressionWithPattern:@"[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*[:\\-–—][ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*$" options:0 error:nil];
        [trailPunctRx replaceMatchesInString:cleanedLine options:0 range:NSMakeRange(0, cleanedLine.length) withTemplate:@""];
        [trailWsRx replaceMatchesInString:cleanedLine options:0 range:NSMakeRange(0, cleanedLine.length) withTemplate:@""];

        NSRegularExpression *emptyBulletRx = [NSRegularExpression regularExpressionWithPattern:@"^[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*[•\\*\\-–—0-9\\.\\)]+[ \\t\\u00A0\\u1680\\u2000-\\u200A\\u202F\\u205F\\u3000]*$" options:0 error:nil];
        NSTextCheckingResult *emptyMatch = [emptyBulletRx firstMatchInString:cleanedLine options:0 range:NSMakeRange(0, cleanedLine.length)];
        if (emptyMatch == nil) {
            NSString *trimmed = [cleanedLine stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\u00A0\u1680\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009\u200A\u202F\u205F\u3000"]];
            if (trimmed.length > 0) {
                [cleanedLines addObject:cleanedLine];
            }
        }
    }

    NSString *result = [cleanedLines componentsJoinedByString:@"\n"];
    NSRegularExpression *multiNlRx = [NSRegularExpression regularExpressionWithPattern:@"\\n{3,}" options:0 error:nil];
    result = [multiNlRx stringByReplacingMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:@"\n\n"];
    return [result stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

NSString *YTAIAppendRelatedVideosToText(NSString *text, NSArray<NSDictionary *> *videos) {
    if (videos.count == 0) return text ?: @"";

    NSMutableArray<NSDictionary *> *missing = [NSMutableArray array];
    for (NSDictionary *v in videos) {
        NSString *vid = v[@"videoId"];
        if (vid.length == 11 && text.length > 0) {
            if ([text rangeOfString:vid].location != NSNotFound) {
                continue;
            }
        }
        [missing addObject:v];
    }

    BOOL hasLinksInText = (text.length > 0) && ([text containsString:@"youtu.be/"] || [text containsString:@"watch?v="]);
    if (hasLinksInText && missing.count == 0) {
        return text;
    }

    NSArray<NSDictionary *> *toAppend = (missing.count > 0) ? missing : videos;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSUInteger num = 1;
    for (NSDictionary *v in toAppend) {
        NSString *vid = v[@"videoId"];
        NSString *title = v[@"title"];
        if (vid.length != 11) continue;
        if (title.length > 0) {
            [lines addObject:[NSString stringWithFormat:@"%lu. https://youtu.be/%@ - %@", (unsigned long)num, vid, title]];
        } else {
            [lines addObject:[NSString stringWithFormat:@"%lu. https://youtu.be/%@", (unsigned long)num, vid]];
        }
        num++;
    }

    if (lines.count == 0) return text ?: @"";

    NSString *formatted = [lines componentsJoinedByString:@"\n"];
    if (text.length == 0) {
        return [NSString stringWithFormat:@"Related videos:\n%@", formatted];
    }

    return [NSString stringWithFormat:@"%@\n\nRelated videos:\n%@", text, formatted];
}

static UIView *YTAIFindAiSuggestionChip(NSString *promptText) {
    if (promptText.length == 0) return nil;
    NSString *target = promptText.lowercaseString;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (!window.hidden && window.alpha >= 0.05) [windows addObject:window];
        }
    }
    for (UIWindow *window in windows) {
        __block UIView *found = nil;
        __block NSUInteger budget = 2000;
        __block __weak void (^weakWalk)(UIView *);
        void (^walk)(UIView *) = ^(UIView *view) {
            if (found != nil || view == nil || budget == 0) return;
            budget--;
            if (view.hidden || view.alpha < 0.05) return;
            NSString *label = [view.accessibilityLabel lowercaseString] ?: @"";
            if ([label isEqualToString:target]) {
                if (YTAIViewIsVisibleOnScreen(view)) {
                    CGRect frame = [view convertRect:view.bounds toView:view.window];
                    if (frame.size.width >= 40 && frame.size.height >= 20) {
                        found = view;
                        return;
                    }
                }
            }
            for (UIView *subview in view.subviews) weakWalk(subview);
        };
        weakWalk = walk;
        walk(window);
        if (found != nil) return found;
    }
    return nil;
}

static BOOL YTAITriggerAiSuggestionChip(UIView *chip) {
    if (chip == nil) return NO;
    BOOL triggered = YTAIPerformGestureAction(chip);
    if (!triggered) triggered = YTAISimulateTouchOnView(chip);
    if (!triggered) triggered = YTAIPerformCollectionSelection(chip);
    if (!triggered) triggered = YTAIPerformAccessibilityActivation(chip);
    if (!triggered) triggered = YTAIPerformSubtreeGestureAction(chip);
    return triggered;
}

static void YTAIPollForUIReadiness(NSDate *startDate, NSTimeInterval maxWait, NSTimeInterval pollInterval,
                                   NSUInteger run,
                                   void (^onReady)(UIView *entry, UIView *existingInput),
                                   void (^onTimeout)(void)) {
    if (run != YTAIRunToken) return;

    UIView *existingInput = (UIView *)YTAIFindAiPromptInput(nil);
    UIView *entry = (existingInput != nil) ? nil : YTAIFindAiEntryControl();

    if (existingInput != nil || entry != nil) {
        NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startDate];
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"ui-ready",
                  @"run": @(run),
                  @"elapsed": @(elapsed),
                  @"hasExistingInput": @(existingInput != nil),
                  @"hasEntry": @(entry != nil)});
        if (onReady != nil) onReady(entry, existingInput);
        return;
    }

    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startDate];
    if (elapsed < maxWait) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(pollInterval * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            YTAIPollForUIReadiness(startDate, maxWait, pollInterval, run, onReady, onTimeout);
        });
        return;
    }

    NSTimeInterval totalElapsed = [[NSDate date] timeIntervalSinceDate:startDate];
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"no-entry-control",
              @"run": @(run), @"elapsed": @(totalElapsed)});
    if (onTimeout != nil) onTimeout();
}

BOOL YTAICanReplayDirect(NSString *videoId) {
    // 1. Usable data source check: AI panel data source, persistent data source, or feed data source
    BOOL hasAiSource = NO;
    @synchronized (YTAICaptureLock()) {
        hasAiSource = (YTAIPersistentAiDataSource != nil) ||
                      (YTAICapturedSubmissionSnapshot.dataSource != nil) ||
                      (YTAIAiDataSource != nil) ||
                      (YTAIFeedDataSource != nil);
    }
    if (!hasAiSource) return NO;

    // 2. Warm snapshot check
    @synchronized (YTAICaptureLock()) {
        if (YTAICapturedSubmissionSnapshot != nil &&
            [YTAICapturedSubmissionSnapshot.token hasPrefix:@"kta-"] &&
            (videoId.length == 0 || [videoId isEqualToString:YTAICapturedSubmissionSnapshot.videoId])) {
            return YES;
        }
    }
    // 3. Cold watch payload check: can we extract teaser token?
    NSString *payloadVid = nil;
    NSData *payload = YTRCCurrentWatchPayload(&payloadVid);
    NSString *targetVid = videoId.length == 11 ? videoId : payloadVid;
    if (payload.length > 0 && targetVid.length == 11) {
        NSString *teaser = YTAISummaryTokenInPayload(payload, targetVid);
        if (teaser.length > 0) {
            NSString *v = nil;
            NSString *c = nil;
            if (YTAIExtractSessionFromTeaserToken(teaser, &v, &c)) {
                return YES;
            }
            return YES;
        }
    }
    return NO;
}

BOOL YTAIDirectSupportsOperation(NSString * _Nullable prompt) {
    if (prompt.length == 0) return YES;
    NSString *trimmed = [prompt stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return YES;
    NSString *lower = [trimmed lowercaseString];
    while (lower.length > 0 && ([lower hasSuffix:@"?"] || [lower hasSuffix:@"."])) {
        lower = [lower substringToIndex:lower.length - 1];
    }
    lower = [lower stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];

    if ([lower isEqualToString:@"summarize the core ideas in this video"] ||
        [lower isEqualToString:@"summarize the core concepts in this video"] ||
        [lower isEqualToString:@"summarize the top 5 concepts in this video"] ||
        [lower isEqualToString:@"summarize the video"] ||
        [lower isEqualToString:@"summarize this video"] ||
        [lower hasPrefix:@"summarize"]) {
        return YES;
    }
    return NO;
}

static NSUInteger YTAIDirectAttemptToken = 0;

void YTAIInvalidateDirectAttempts(void) {
    @synchronized (YTAICaptureLock()) {
        ++YTAIDirectAttemptToken;
        YTAIReplayInFlight = NO;
    }
}

void YTAICancelActiveOperations(void) {
    @synchronized (YTAICaptureLock()) {
        ++YTAIRunToken;
        ++YTAIDirectAttemptToken;
        YTAICaptureActive = NO;
        YTAICaptureSettle = nil;
        YTAIReplayInFlight = NO;
        [YTAICaptureItems removeAllObjects];
        YTAICaptureItems = nil;
    }
}

static NSMutableSet<NSString *> *YTAIBootstrappedSessions(void) {
    static NSMutableSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ set = [NSMutableSet set]; });
    return set;
}

static BOOL YTAIInspectBootstrapProtobuf(const uint8_t *bytes, NSUInteger length,
                                         NSString * _Nullable activeVid,
                                         NSString * _Nullable activeCid,
                                         NSString * _Nullable * _Nullable outFoundCid,
                                         NSString * _Nullable * _Nullable outErrorReason) {
    if (bytes == NULL || length < 4) return YES;

    NSUInteger pos = 0;
    unsigned long long rpcStatusCode = 0;
    NSString *rpcStatusMessage = nil;

    while (pos < length) {
        NSUInteger p = pos;
        unsigned long long tag = 0;
        NSUInteger shift = 0;
        while (p < length && shift < 35) {
            uint8_t b = bytes[p++];
            tag |= (unsigned long long)(b & 0x7F) << shift;
            if (!(b & 0x80)) break;
            shift += 7;
        }
        if (p == pos) break;
        pos = p;
        NSUInteger field = (NSUInteger)(tag >> 3);
        NSUInteger wire = (NSUInteger)(tag & 7);

        if (wire == 0) {
            p = pos;
            unsigned long long val = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                val |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (field == 1) {
                rpcStatusCode = val;
            }
        } else if (wire == 1) {
            pos += 8;
        } else if (wire == 2) {
            p = pos;
            unsigned long long flen = 0;
            shift = 0;
            while (p < length && shift < 35) {
                uint8_t b = bytes[p++];
                flen |= (unsigned long long)(b & 0x7F) << shift;
                if (!(b & 0x80)) break;
                shift += 7;
            }
            if (p == pos) break;
            pos = p;
            if (pos + flen > length) break;
            const uint8_t *chunk = bytes + pos;
            NSUInteger chunkLen = (NSUInteger)flen;
            pos += chunkLen;

            if (field == 2 && rpcStatusCode > 0 && chunkLen > 0) {
                rpcStatusMessage = [[NSString alloc] initWithBytes:chunk length:chunkLen encoding:NSUTF8StringEncoding];
            } else if (field == 9 || field == 12 || field == 14) {
                // Structural error container (alerts / serviceError / rpc status)
                if (YTAIBytesContain(chunk, chunkLen, "conversation unavailable", 24) ||
                    YTAIBytesContain(chunk, chunkLen, "error_code", 10) ||
                    YTAIBytesContain(chunk, chunkLen, "alertRenderer", 13) ||
                    YTAIBytesContain(chunk, chunkLen, "status: failed", 14) ||
                    YTAIBytesContain(chunk, chunkLen, "permission_denied", 17)) {
                    if (outErrorReason) *outErrorReason = [NSString stringWithFormat:@"structural-error-field-%lu", (unsigned long)field];
                    return NO;
                }
            } else if (field == 1 || field == 3) {
                // Response context / conversation context: inspect for field 13 (conversationId)
                NSUInteger cpos = 0;
                while (cpos < chunkLen) {
                    NSUInteger cp = cpos;
                    unsigned long long ctag = 0;
                    shift = 0;
                    while (cp < chunkLen && shift < 35) {
                        uint8_t b = chunk[cp++];
                        ctag |= (unsigned long long)(b & 0x7F) << shift;
                        if (!(b & 0x80)) break;
                        shift += 7;
                    }
                    if (cp == cpos) break;
                    cpos = cp;
                    NSUInteger cfield = (NSUInteger)(ctag >> 3);
                    NSUInteger cwire = (NSUInteger)(ctag & 7);

                    if (cwire == 0) {
                        while (cpos < chunkLen && (chunk[cpos++] & 0x80)) {}
                    } else if (cwire == 1) {
                        cpos += 8;
                    } else if (cwire == 2) {
                        cp = cpos;
                        unsigned long long clen = 0;
                        shift = 0;
                        while (cp < chunkLen && shift < 35) {
                            uint8_t b = chunk[cp++];
                            clen |= (unsigned long long)(b & 0x7F) << shift;
                            if (!(b & 0x80)) break;
                            shift += 7;
                        }
                        if (cp == cpos) break;
                        cpos = cp;
                        if (cpos + clen > chunkLen) break;
                        if (cfield == 13 && clen > 0) {
                            NSString *cidCandidate = [[NSString alloc] initWithBytes:chunk + cpos length:(NSUInteger)clen encoding:NSUTF8StringEncoding];
                            if (cidCandidate.length > 0 &&
                                ![cidCandidate isEqualToString:@"dynamic_welcome_chips_placeholder_chat_id"]) {
                                if (outFoundCid) *outFoundCid = cidCandidate;
                            }
                        }
                        cpos += (NSUInteger)clen;
                    } else if (cwire == 5) {
                        cpos += 4;
                    } else {
                        break;
                    }
                }
            }
        } else if (wire == 5) {
            pos += 4;
        } else {
            break;
        }
    }

    if (rpcStatusCode > 0) {
        if (outErrorReason) {
            *outErrorReason = [NSString stringWithFormat:@"rpc-status-%llu:%@", rpcStatusCode, rpcStatusMessage ?: @""];
        }
        return NO;
    }

    return YES;
}

static BOOL YTAIValidateBootstrapResponse(NSData * _Nullable data, NSArray * _Nullable items,
                                         NSString * _Nullable activeVid, NSString * _Nullable activeCid,
                                         NSString * _Nullable * _Nullable outValidatedCid,
                                         NSString * _Nullable * _Nullable outReason) {
    NSMutableArray<NSData *> *messages = [NSMutableArray array];
    if (data.length > 0) [messages addObject:data];
    if ([items isKindOfClass:[NSArray class]]) {
        for (id item in items) {
            NSError *err = nil;
            NSData *b = YTRCSerializeMessage(item, 512 * 1024, &err);
            if (b.length > 0) [messages addObject:b];
        }
    }

    if (messages.count == 0) {
        if (outReason) *outReason = @"payload-empty";
        return NO;
    }

    NSString *extractedCid = nil;
    BOOL foundCidMismatch = NO;

    for (NSData *msg in messages) {
        NSString *foundCid = nil;
        NSString *errReason = nil;
        BOOL ok = YTAIInspectBootstrapProtobuf((const uint8_t *)msg.bytes, msg.length,
                                              activeVid, activeCid, &foundCid, &errReason);
        if (!ok) {
            if (outReason) *outReason = errReason ?: @"structural-error";
            return NO;
        }

        if (foundCid.length > 0) {
            if (activeCid.length > 0) {
                if ([foundCid isEqualToString:activeCid]) {
                    extractedCid = foundCid;
                } else {
                    foundCidMismatch = YES;
                }
            } else {
                // Cold bootstrap: adopt first valid session CID
                if (extractedCid.length == 0 && foundCid.length >= 8) {
                    extractedCid = foundCid;
                }
            }
        }
    }

    if (extractedCid.length > 0) {
        if (outValidatedCid) *outValidatedCid = extractedCid;
        if (outReason) *outReason = (activeCid.length > 0) ? @"matched-active-cid" : @"established-session-cid";
        return YES;
    }

    if (foundCidMismatch) {
        if (outReason) *outReason = @"session-cid-mismatch";
        return NO;
    }

    if (outReason) *outReason = @"no-matching-session-id";
    return NO;
}

void YTAIReplayDirect(NSString *videoId, void (^completion)(NSString * _Nullable summary, NSString *status)) {
    YTAISubmissionSnapshot *snapshot = nil;
    @synchronized (YTAICaptureLock()) {
        if (YTAICapturedSubmissionSnapshot != nil && [YTAICapturedSubmissionSnapshot.token hasPrefix:@"kta-"]) {
            // Re-use app-scoped attributes from captured submission snapshot
            snapshot = YTAICapturedSubmissionSnapshot;
        }
    }

    NSString *activeVid = videoId.length == 11 ? videoId : snapshot.videoId;
    __block NSString *activeCid = [activeVid isEqualToString:snapshot.videoId] ? snapshot.conversationId : nil;
    NSString *directTeaserToken = nil;

    // Cold path: resolve videoId and conversationId from watch payload teaser token
    if (activeCid.length == 0 || activeVid.length != 11) {
        NSString *payloadVid = nil;
        NSData *payload = YTRCCurrentWatchPayload(&payloadVid);
        NSString *targetVid = activeVid.length == 11 ? activeVid : payloadVid;
        if (payload.length > 0 && targetVid.length == 11) {
            NSString *teaserToken = YTAISummaryTokenInPayload(payload, targetVid);
            if (teaserToken.length > 0) {
                directTeaserToken = teaserToken;
                NSString *vid = nil;
                NSString *cid = nil;
                if (YTAIExtractSessionFromTeaserToken(teaserToken, &vid, &cid)) {
                    activeVid = vid;
                    activeCid = cid;
                }
            }
        }
    }

    if (activeVid.length != 11 || (activeCid.length == 0 && directTeaserToken.length == 0)) {
        if (completion) completion(nil, @"ai-direct-no-session");
        return;
    }

    NSString *curVid = YTRCCurrentVideoId();
    if (activeVid.length > 0 && curVid.length > 0 && ![activeVid isEqualToString:curVid]) {
        YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"aborted-navigated-away",
                  @"targetVid": activeVid, @"currentVid": curVid});
        if (completion) completion(nil, @"ai-navigated-away");
        return;
    }

    __block NSString *sessionKey = [NSString stringWithFormat:@"%@:%@", activeVid, activeCid ?: @"direct"];

    NSUInteger directAttempt = 0;
    @synchronized (YTAICaptureLock()) {
        directAttempt = ++YTAIDirectAttemptToken;
    }

    __block BOOL finished = NO;
    void (^done)(NSString *, NSString *) = ^(NSString *summary, NSString *status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            @synchronized (YTAICaptureLock()) {
                if (finished || directAttempt != YTAIDirectAttemptToken) return;
                finished = YES;
                YTAIReplayInFlight = NO;
            }
            if (completion) completion(summary, status);
        });
    };

    // Bounded overall timeout (30s)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (finished) return;
        YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"timeout", @"videoId": activeVid ?: @""});
        done(nil, @"ai-direct-timeout");
    });

    SEL selector = NSSelectorFromString(
        @"requestInnerTubeContinuationWithContinuationToken:continuationType:clientAttachmentRequestData:"
        @"cacheEnabled:clickTrackingParams:alwaysParseFeedNode:responseBlock:errorBlock:");

    id dataSource = nil;
    @synchronized (YTAICaptureLock()) {
        if (YTAIPersistentAiDataSource != nil && YTAIIsPanelDataSource(YTAIPersistentAiDataSource)) {
            dataSource = YTAIPersistentAiDataSource;
        } else if (snapshot.dataSource != nil && YTAIIsPanelDataSource(snapshot.dataSource)) {
            dataSource = snapshot.dataSource;
        } else if (YTAIAiDataSource != nil && YTAIIsPanelDataSource(YTAIAiDataSource)) {
            dataSource = YTAIAiDataSource;
        } else if (YTAIPersistentAiDataSource != nil) {
            dataSource = YTAIPersistentAiDataSource;
        } else if (YTAIAiDataSource != nil) {
            dataSource = YTAIAiDataSource;
        } else if (YTAIFeedDataSource != nil) {
            dataSource = YTAIFeedDataSource;
        }
    }

    if (dataSource == nil || ![dataSource respondsToSelector:selector]) {
        YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"no-ai-panel-service",
                  @"reason": dataSource == nil ? @"no-ai-panel-datasource" : @"bad-selector"});
        done(nil, @"ai-direct-no-ai-panel");
        return;
    }

    id service = [dataSource respondsToSelector:@selector(service)] ? ((id (*)(id, SEL))objc_msgSend)(dataSource, @selector(service)) : nil;

    unsigned long long contType = snapshot.continuationType != 0 ? snapshot.continuationType : 8;
    id attachment = snapshot.attachment;
    if (attachment == nil) {
        Class attCls = NSClassFromString(@"YTIClientAttachmentRequestData");
        if (attCls) attachment = [[attCls alloc] init];
    }
    id clickTracking = snapshot.clickTracking ?: [NSData data];
    BOOL cacheEnabled = NO;
    BOOL alwaysParse = YES;

    typedef void (*ReplayFn)(id, SEL, id, unsigned long long, id, BOOL, id, BOOL, id, id);
    ReplayFn dispatchContinuation = (ReplayFn)objc_msgSend;

    void (^sendContinuation)(NSString *, NSString *, void (^)(NSArray *, NSData *), void (^)(id)) =
        ^(NSString *tokenToSend, NSString *stepName, void (^onResp)(NSArray *, NSData *), void (^onErr)(id)) {
            if (tokenToSend.length == 0) {
                YTRCLog(@{@"event": @"ai-direct-replay",
                          @"outcome": [stepName stringByAppendingString:@"-empty-token"],
                          @"videoId": activeVid ?: @"", @"conversationId": activeCid ?: @""});
                done(nil, [NSString stringWithFormat:@"ai-direct-no-token:%@", stepName]);
                return;
            }

            void (^respBlock)(NSArray *, NSUInteger, id, NSData *) =
                ^(NSArray *items, NSUInteger itemIndex, id arg, NSData *data) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @synchronized (YTAICaptureLock()) {
                            if (finished || directAttempt != YTAIDirectAttemptToken) return;
                        }
                        if (onResp) onResp(items, data);
                    });
                };

            id errBlock = nil;
            if (snapshot.errSignature != nil && [snapshot.errSignature containsString:@"24"]) {
                errBlock = ^(id error, id context) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @synchronized (YTAICaptureLock()) {
                            if (finished || directAttempt != YTAIDirectAttemptToken) return;
                        }
                        if (onErr) onErr(error);
                    });
                };
            } else {
                errBlock = ^(id error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        @synchronized (YTAICaptureLock()) {
                            if (finished || directAttempt != YTAIDirectAttemptToken) return;
                        }
                        if (onErr) onErr(error);
                    });
                };
            }

            objc_setAssociatedObject(respBlock, kYTAIDirectAttemptKey, @(directAttempt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(errBlock, kYTAIDirectAttemptKey, @(directAttempt), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

            YTRCLog(@{@"event": @"ai-direct-replay",
                      @"outcome": [stepName stringByAppendingString:@"-starting"],
                      @"tokenPrefix": (tokenToSend.length > 0 ? [tokenToSend substringToIndex:MIN((NSUInteger)80, tokenToSend.length)] : @""),
                      @"tokenLength": @(tokenToSend.length),
                      @"videoId": activeVid ?: @"", @"conversationId": activeCid ?: @"",
                      @"continuationType": @(contType),
                      @"dataSource": NSStringFromClass([dataSource class]) ?: @"?",
                      @"dataSourcePtr": [NSString stringWithFormat:@"%p", dataSource],
                      @"service": service != nil ? NSStringFromClass([service class]) : @"(none)",
                      @"servicePtr": [NSString stringWithFormat:@"%p", service]});

            @try {
                dispatchContinuation(dataSource, selector,
                    tokenToSend, contType, attachment, cacheEnabled, clickTracking, alwaysParse,
                    respBlock, errBlock);
            } @catch (NSException *ex) {
                YTRCLog(@{@"event": @"ai-direct-replay",
                          @"outcome": [stepName stringByAppendingString:@"-exception"],
                          @"name": ex.name ?: @"", @"reason": ex.reason ?: @""});
                done(nil, [NSString stringWithFormat:@"ai-direct-exception:%@", ex.name]);
            }
        };

    NSTimeInterval startTime = [[NSDate date] timeIntervalSince1970];
    __block NSUInteger callbackCount = 0;
    __block NSMutableArray *receivedItems = [NSMutableArray array];

    __block void (^submitPrompt)(BOOL) = nil;
    __block void (^doBootstrap)(void) = nil;

    submitPrompt = ^(BOOL canRetryBootstrap) {
        NSString *subToken = (activeCid.length > 0)
            ? YTAIConstructSubmissionToken(activeVid, activeCid)
            : (directTeaserToken ?: YTAIConstructSubmissionToken(activeVid, activeCid));
        sendContinuation(subToken, @"submit",
            ^(NSArray *items, NSData *data) {
                callbackCount++;
                YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"response-callback",
                          @"itemsCount": @(items.count),
                          @"callbackNum": @(callbackCount),
                          @"dataBytes": @(data.length)});
                if ([items isKindOfClass:[NSArray class]]) {
                    [receivedItems addObjectsFromArray:items];
                }
                NSMutableArray *payloads = [NSMutableArray array];
                for (id item in receivedItems) {
                    NSError *err = nil;
                    NSData *b = YTRCSerializeMessage(item, 16 * 1024 * 1024, &err);
                    if (b.length != 0) {
                        NSString *c = NSStringFromClass([item class]);
                        [payloads addObject:@{@"data": b, @"class": c ?: @""}];
                        YTAIDiagnosticLogEndpoints(b, c, @"direct-replay");
                    }
                }
                NSString *summary = YTAITextFromPayloads(payloads);
                NSArray<NSDictionary *> *payloadVideos = YTAIExtractVideosFromPayloads(payloads, activeVid);
                YTRCLog(@{@"event": @"ai-summary-pre-cleanup",
                          @"rawText": summary ?: @"",
                          @"rawLength": @(summary.length),
                          @"videoId": activeVid ?: @""});
                if (summary.length != 0) {
                    summary = YTAIFixTruncatedLinksInText(summary, payloadVideos);
                }
                if (payloadVideos.count > 0) {
                    summary = YTAIAppendRelatedVideosToText(summary ?: @"", payloadVideos);
                }
                if (summary.length != 0) {
                    @synchronized (YTAICaptureLock()) {
                        if (finished || directAttempt != YTAIDirectAttemptToken) return;
                    }
                    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
                    uint64_t ansHash = YTAIHashString(summary);
                    YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"success",
                              @"items": @(receivedItems.count),
                              @"chars": @(summary.length),
                              @"answerHash": [NSString stringWithFormat:@"%016llx", ansHash],
                              @"callbacks": @(callbackCount),
                              @"elapsedMs": @((now - startTime) * 1000.0)});
                    @synchronized (YTAICaptureLock()) {
                        if (!finished && directAttempt == YTAIDirectAttemptToken) {
                            YTAICacheStore(activeVid, @"direct-replay", summary);
                        }
                    }
                    done(summary, @"ai-direct-fetched");
                } else {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        @synchronized (YTAICaptureLock()) {
                            if (finished || directAttempt != YTAIDirectAttemptToken) return;
                        }
                        NSMutableArray *p2 = [NSMutableArray array];
                        for (id item in receivedItems) {
                            NSError *err = nil;
                            NSData *b = YTRCSerializeMessage(item, 16 * 1024 * 1024, &err);
                            if (b.length != 0) {
                                NSString *c = NSStringFromClass([item class]);
                                [p2 addObject:@{@"data": b, @"class": c ?: @""}];
                                YTAIDiagnosticLogEndpoints(b, c, @"direct-replay-settled");
                            }
                        }
                        NSString *s2 = YTAITextFromPayloads(p2);
                        NSArray<NSDictionary *> *p2Videos = YTAIExtractVideosFromPayloads(p2, activeVid);
                        YTRCLog(@{@"event": @"ai-summary-pre-cleanup",
                                  @"rawText": s2 ?: @"",
                                  @"rawLength": @(s2.length),
                                  @"videoId": activeVid ?: @""});
                        if (s2.length != 0) {
                            s2 = YTAIFixTruncatedLinksInText(s2, p2Videos);
                        }
                        if (p2Videos.count > 0) {
                            s2 = YTAIAppendRelatedVideosToText(s2 ?: @"", p2Videos);
                        }
                        if (s2.length != 0) {
                            uint64_t ansHash = YTAIHashString(s2);
                            YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"settled-success",
                                      @"chars": @(s2.length),
                                      @"answerHash": [NSString stringWithFormat:@"%016llx", ansHash]});
                            @synchronized (YTAICaptureLock()) {
                                if (!finished && directAttempt == YTAIDirectAttemptToken) {
                                    YTAICacheStore(activeVid, @"direct-replay", s2);
                                }
                            }
                            done(s2, @"ai-direct-fetched");
                        } else if (canRetryBootstrap) {
                            YTRCLog(@{@"event": @"ai-direct-replay",
                                      @"outcome": @"warm-session-empty-retrying-bootstrap",
                                      @"videoId": activeVid});
                            @synchronized (YTAIBootstrappedSessions()) {
                                [YTAIBootstrappedSessions() removeObject:sessionKey];
                            }
                            doBootstrap();
                        } else {
                            done(nil, @"ai-direct-empty-response");
                        }
                    });
                }
            },
            ^(id error) {
                YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"error",
                          @"errorDesc": [error description] ?: @""});
                done(nil, [NSString stringWithFormat:@"ai-direct-error:%@", [error description] ?: @"unknown"]);
            });
    };

    __block BOOL bootstrapSubmitted = NO;
    __block __weak void (^weakDoBootstrap)(void) = nil;
    doBootstrap = ^{
        NSString *bootToken = nil;
        if (activeCid.length > 0) {
            bootToken = YTAIConstructBootstrapToken(activeVid, activeCid);
        } else if (directTeaserToken.length > 0) {
            bootToken = directTeaserToken;
        }

        if (bootToken.length == 0) {
            YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"bootstrap-no-token",
                      @"videoId": activeVid ?: @"", @"hasTeaser": @(directTeaserToken.length > 0)});
            done(nil, @"ai-direct-no-session");
            return;
        }

        sendContinuation(bootToken, @"bootstrap",
            ^(NSArray *items, NSData *data) {
                @synchronized (YTAICaptureLock()) {
                    if (finished || directAttempt != YTAIDirectAttemptToken) return;
                }
                if (bootstrapSubmitted) return;

                NSString *validatedCid = nil;
                NSString *validationReason = nil;
                BOOL isValid = YTAIValidateBootstrapResponse(data, items, activeVid, activeCid, &validatedCid, &validationReason);
                if (!isValid) {
                    YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"bootstrap-invalid-session",
                              @"videoId": activeVid ?: @"", @"reason": validationReason ?: @"unknown"});
                    done(nil, [NSString stringWithFormat:@"ai-direct-bootstrap-invalid:%@", validationReason ?: @"unknown"]);
                    return;
                }
                if (validatedCid.length > 0) {
                    activeCid = validatedCid;
                    sessionKey = [NSString stringWithFormat:@"%@:%@", activeVid, activeCid];
                }
                bootstrapSubmitted = YES;

                YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"bootstrap-response",
                          @"itemsCount": @(items.count), @"dataBytes": @(data.length),
                          @"validatedCid": validatedCid ?: @""});

                @synchronized (YTAIBootstrappedSessions()) {
                    [YTAIBootstrappedSessions() addObject:sessionKey];
                }
                // Small 150ms pause to ensure server session index is fully registered
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    @synchronized (YTAICaptureLock()) {
                        if (finished || directAttempt != YTAIDirectAttemptToken) return;
                    }
                    submitPrompt(NO);
                });
            },
            ^(id error) {
                if (directTeaserToken.length > 0 && activeCid.length > 0) {
                    YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"bootstrap-failed-trying-teaser",
                              @"videoId": activeVid ?: @""});
                    activeCid = @"";
                    void (^strongDoBootstrap)(void) = weakDoBootstrap;
                    if (strongDoBootstrap) strongDoBootstrap();
                    return;
                }
                YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"bootstrap-failed",
                          @"errorDesc": [error description] ?: @""});
                done(nil, [NSString stringWithFormat:@"ai-direct-bootstrap-failed:%@", [error description] ?: @"unknown"]);
            });
    };
    weakDoBootstrap = doBootstrap;

    BOOL alreadyBootstrapped = NO;
    @synchronized (YTAIBootstrappedSessions()) {
        alreadyBootstrapped = [YTAIBootstrappedSessions() containsObject:sessionKey];
    }

    YTAIReplayInFlight = YES;

    if (alreadyBootstrapped) {
        YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"warm-session-starting", @"videoId": activeVid ?: @""});
        submitPrompt(YES);
    } else {
        YTRCLog(@{@"event": @"ai-direct-replay", @"outcome": @"cold-session-bootstrapping", @"videoId": activeVid ?: @"", @"hasCid": @(activeCid.length > 0)});
        doBootstrap();
    }
}

void YTAIFetchSummary(NSString *videoId, void (^completion)(NSString * _Nullable, NSString *)) {
    YTAIFetchSummaryWithPrompt(videoId, nil, completion);
}

void YTAIFetchSummaryWithPrompt(NSString *videoId, NSString * _Nullable customPrompt, void (^completion)(NSString * _Nullable, NSString *)) {
    NSUInteger run = ++YTAIRunToken;
    YTAIPreSubmissionItemCount = -1;
    __block BOOL finished = NO;

    void (^done)(NSString *, NSString *) = ^(NSString *summary, NSString *status) {
        void (^invoke)(void) = ^{
            if (finished || run != YTAIRunToken) return;
            finished = YES;
            YTAICaptureActive = NO;
            YTAICaptureSettle = nil;
            completion(summary, status);
        };
        if (NSThread.isMainThread) {
            invoke();
        } else {
            dispatch_async(dispatch_get_main_queue(), invoke);
        }
    };

    if (videoId.length == 0) { done(nil, @"ai-no-video-id"); return; }
    NSString *curVid = YTRCCurrentVideoId();
    if (videoId.length > 0 && curVid.length > 0 && ![videoId isEqualToString:curVid]) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"aborted-navigated-away",
                  @"targetVid": videoId, @"currentVid": curVid, @"run": @(run)});
        done(nil, @"ai-navigated-away");
        return;
    }
    YTAIInstallObservationTraces();
    NSString *prompt = (customPrompt.length > 0) ? customPrompt : YTAIPromptText;
    NSString *flowTag = YTAIFlowTagForPrompt(prompt);
    NSString *cached = nil;
    BOOL keepPanelOpen = [NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Recommendations.KeepPanelOpenEnabled"];
    // Cache shortcut is only permitted when Keep Panel Open is OFF.
    // When Keep Panel Open is ON, the visible panel interaction is required.
    if (!keepPanelOpen && YTAICacheHit(videoId, flowTag, &cached)) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"cache-hit",
                  @"chars": @(cached.length), @"videoId": videoId, @"flow": flowTag,
                  @"run": @(run)});
        YTAICloseAiPanel();
        done(cached, @"ai-cached");
        return;
    }

    void (^startUiFlow)(UIView *, UIView *) = ^(UIView *entry, UIView *existingInput) {
        if (run != YTAIRunToken || finished) return;

        NSString *curVid = YTRCCurrentVideoId();
        if (videoId.length > 0 && curVid.length > 0 && ![videoId isEqualToString:curVid]) {
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"aborted-navigated-away-start",
                      @"targetVid": videoId, @"currentVid": curVid, @"run": @(run)});
            done(nil, @"ai-navigated-away");
            return;
        }

        UIView *focusView = entry ?: existingInput;

        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-found",
                  @"class": NSStringFromClass([focusView class]) ?: @"?",
                  @"hasExistingInput": @(existingInput != nil),
                  @"run": @(run)});

        YTAICaptureLock();
        @synchronized (YTAICaptureLock()) {
            YTAICaptureActive = YES;
            YTAICaptureSawAnswer = NO;
            YTAICaptureGeneration = 0;
            YTAIPromptTypingStarted = NO;
            YTAIPromptSendAttempted = NO;
            YTAIPanelRequestObserved = NO;
            YTAISubmitRequestObserved = NO;
            YTAISendChainLogged = NO;
            YTAICaptureItems = [NSMutableArray array];
            YTAICaptureSettle = ^{
                if (run != YTAIRunToken || finished) return;
                NSString *curV = YTRCCurrentVideoId();
                if (videoId.length > 0 && curV.length > 0 && ![videoId isEqualToString:curV]) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"aborted-navigated-away-settle",
                              @"targetVid": videoId, @"currentVid": curV, @"run": @(run)});
                    done(nil, @"ai-navigated-away");
                    return;
                }
                NSArray<NSData *> *items;
                @synchronized (YTAICaptureLock()) { items = [YTAICaptureItems copy]; }
                NSString *text = YTAITextFromPayloads(items);
                NSArray<NSDictionary *> *payloadVideos = YTAIExtractVideosFromPayloads(items, videoId);
                UIView *panel = YTAIFindAiPanelContainer(focusView);
                UIView *assistantContainer = YTAIFindCurrentAssistantMessageContainer(panel, text);
                NSMutableDictionary<NSString *, NSString *> *linkResolutions = [NSMutableDictionary dictionary];
                NSArray<NSDictionary *> *uiVideos = (assistantContainer != nil)
                    ? YTAIScrapeRelatedVideosAndLinks(assistantContainer, videoId, linkResolutions)
                    : @[];
                NSArray<NSDictionary *> *allVideos = YTAIMergeRelatedVideos(payloadVideos, uiVideos, videoId);

                YTRCLog(@{@"event": @"ai-summary-pre-cleanup",
                          @"rawText": text ?: @"",
                          @"rawLength": @(text.length),
                          @"videoId": videoId ?: @""});

                if (text.length != 0) {
                    NSDictionary *resPayload = @{@"videos": allVideos ?: @[], @"resolutions": linkResolutions ?: @{}};
                    text = YTAIFixTruncatedLinksInText(text, resPayload);
                }
                if (allVideos.count > 0) {
                    text = YTAIAppendRelatedVideosToText(text ?: @"", allVideos);
                }

                NSUInteger totalCapturedBytes = 0;
                NSUInteger firstOriginalBytes = 0;
                NSString *primaryClass = @"(none)";
                if (items.count > 0) {
                    id first = items[0];
                    if ([first isKindOfClass:NSDictionary.class]) {
                        primaryClass = first[@"class"] ?: @"?";
                        firstOriginalBytes = [first[@"data"] length];
                    } else if ([first isKindOfClass:NSData.class]) {
                        firstOriginalBytes = [(NSData *)first length];
                    }
                    for (id it in items) {
                        if ([it isKindOfClass:NSDictionary.class]) totalCapturedBytes += [it[@"data"] length];
                        else if ([it isKindOfClass:NSData.class]) totalCapturedBytes += [(NSData *)it length];
                    }
                }
                BOOL carouselAccepted = (allVideos.count > 0);
                NSString *rejectionReason = @"none";
                if (assistantContainer == nil) {
                    rejectionReason = @"assistant-container-not-found";
                } else if (uiVideos.count == 0) {
                    rejectionReason = @"no-ui-videos-found-in-container";
                }

                if (text.length != 0) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"captured",
                              @"payloadClass": primaryClass,
                              @"capturedBytes": @(totalCapturedBytes),
                              @"originalBytes": @(firstOriginalBytes),
                              @"payloadVideoCount": @(payloadVideos.count),
                              @"assistantContainerFound": @(assistantContainer != nil),
                              @"carouselAccepted": @(carouselAccepted),
                              @"rejectionReason": rejectionReason,
                              @"uiVideoCount": @(uiVideos.count),
                              @"mergedVideoCount": @(allVideos.count),
                              @"items": @(items.count),
                              @"chars": @(text.length),
                              @"run": @(run)});
                    YTAICacheStore(videoId, flowTag, text);
                    if (!keepPanelOpen) {
                        YTAICloseAiPanel();
                    }
                    done(text, @"ai-fetched");
                    return;
                } else {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"empty-capture",
                              @"payloadClass": primaryClass,
                              @"capturedBytes": @(totalCapturedBytes),
                              @"originalBytes": @(firstOriginalBytes),
                              @"payloadVideoCount": @(payloadVideos.count),
                              @"assistantContainerFound": @(assistantContainer != nil),
                              @"carouselAccepted": @(carouselAccepted),
                              @"rejectionReason": rejectionReason,
                              @"uiVideoCount": @(uiVideos.count),
                              @"mergedVideoCount": @(allVideos.count),
                              @"items": @(items.count),
                              @"run": @(run)});
                    if (focusView != nil) YTAIDumpAiUiFromView(focusView);
                    done(nil, @"ai-empty-capture");
                }
            };
        }

        __block BOOL opened = (existingInput != nil);
        __block BOOL inputSeen = (existingInput != nil);
        __block BOOL typingStarted = NO;
        __block NSInteger lastStep = -1;
        __block void (^submitPrompt)(void);
        submitPrompt = ^{
            if (run != YTAIRunToken || finished || YTAICaptureSawAnswer) return;
            if (YTAISubmitRequestObserved || typingStarted) return;

            UIView *panel = YTAIFindAiPanelContainer(focusView);
            YTAIPreSubmissionItemCount = YTAICountPanelItems(panel);

            NSString *curV = YTRCCurrentVideoId();
            if (videoId.length > 0 && curV.length > 0 && ![videoId isEqualToString:curV]) {
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"aborted-navigated-away-submit",
                          @"targetVid": videoId, @"currentVid": curV, @"run": @(run)});
                done(nil, @"ai-navigated-away");
                return;
            }

            // 1. Direct suggestion chip fast path if available
            UIView *chip = YTAIFindAiSuggestionChip(prompt);
            if (chip != nil) {
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"suggestion-chip-found",
                          @"class": NSStringFromClass([chip class]) ?: @"?",
                          @"label": chip.accessibilityLabel ?: @"",
                          @"run": @(run)});
                BOOL triggered = YTAITriggerAiSuggestionChip(chip);
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"suggestion-chip-triggered",
                          @"dispatched": @(triggered),
                          @"run": @(run)});
                if (triggered) {
                    typingStarted = YES;
                    YTAIPromptTypingStarted = YES;
                    YTAIPromptSendAttempted = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (run != YTAIRunToken || finished || YTAICaptureSawAnswer) return;
                        if (!YTAISubmitRequestObserved && !YTAIAnswerIsLoading()) {
                            UIView *inputFallback = (UIView *)YTAIFindAiPromptInput(focusView);
                            if (inputFallback != nil) {
                                YTAITypePrompt(focusView, prompt, run, ^{});
                            }
                        }
                    });
                    return;
                }
            }

            // 2. Fallback to prompt input typing and composer Send
            UIView *input = (UIView *)YTAIFindAiPromptInput(focusView);
            if (input == nil) return;
            inputSeen = YES;
            typingStarted = YES;
            YTAIPromptTypingStarted = YES;
            YTAITypePrompt(focusView, prompt, run, ^{});
        };

        void (^notePanelOpen)(void) = ^{
            if (opened && lastStep != -1) return;
            opened = YES;
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"panel-open-confirmed",
                      @"winningStrategy": @(lastStep),
                      @"run": @(run)});
            if (lastStep >= 0) {
                YTAIHasWinningStrategy = YES;
                YTAIWinningStrategy = (NSUInteger)lastStep;
            }
            for (NSUInteger i = 0; i < sizeof(YTAIPromptDelays) / sizeof(YTAIPromptDelays[0]); i++) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                             (int64_t)(YTAIPromptDelays[i] * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    if (run != YTAIRunToken || finished) return;
                    submitPrompt();
                });
            }
        };

        // Capture timeout scheduled BEFORE branching into reuse vs open
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (run != YTAIRunToken || finished) return;
            if (YTAISubmitRequestObserved) {
                NSString *curV = YTRCCurrentVideoId();
                if (videoId.length > 0 && curV.length > 0 && ![videoId isEqualToString:curV]) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"aborted-navigated-away-timeout",
                              @"targetVid": videoId, @"currentVid": curV, @"run": @(run)});
                    done(nil, @"ai-navigated-away");
                    return;
                }
                NSArray<NSData *> *items;
                @synchronized (YTAICaptureLock()) { items = [YTAICaptureItems copy]; }
                NSString *text = YTAITextFromPayloads(items);
                NSArray<NSDictionary *> *payloadVideos = YTAIExtractVideosFromPayloads(items, videoId);
                UIView *panel = YTAIFindAiPanelContainer(focusView);
                UIView *assistantContainer = YTAIFindCurrentAssistantMessageContainer(panel, text);
                NSMutableDictionary<NSString *, NSString *> *linkResolutions = [NSMutableDictionary dictionary];
                NSArray<NSDictionary *> *uiVideos = (assistantContainer != nil)
                    ? YTAIScrapeRelatedVideosAndLinks(assistantContainer, videoId, linkResolutions)
                    : @[];
                NSArray<NSDictionary *> *allVideos = YTAIMergeRelatedVideos(payloadVideos, uiVideos, videoId);

                YTRCLog(@{@"event": @"ai-summary-pre-cleanup",
                          @"rawText": text ?: @"",
                          @"rawLength": @(text.length),
                          @"videoId": videoId ?: @""});

                if (text.length != 0) {
                    NSDictionary *resPayload = @{@"videos": allVideos ?: @[], @"resolutions": linkResolutions ?: @{}};
                    text = YTAIFixTruncatedLinksInText(text, resPayload);
                }
                if (allVideos.count > 0) {
                    text = YTAIAppendRelatedVideosToText(text ?: @"", allVideos);
                }
                NSUInteger totalCapturedBytes = 0;
                NSUInteger firstOriginalBytes = 0;
                NSString *primaryClass = @"(none)";
                if (items.count > 0) {
                    id first = items[0];
                    if ([first isKindOfClass:NSDictionary.class]) {
                        primaryClass = first[@"class"] ?: @"?";
                        firstOriginalBytes = [first[@"data"] length];
                    } else if ([first isKindOfClass:NSData.class]) {
                        firstOriginalBytes = [(NSData *)first length];
                    }
                    for (id it in items) {
                        if ([it isKindOfClass:NSDictionary.class]) totalCapturedBytes += [it[@"data"] length];
                        else if ([it isKindOfClass:NSData.class]) totalCapturedBytes += [(NSData *)it length];
                    }
                }
                BOOL carouselAccepted = (allVideos.count > 0);
                NSString *rejectionReason = @"none";
                if (assistantContainer == nil) {
                    rejectionReason = @"assistant-container-not-found";
                } else if (uiVideos.count == 0) {
                    rejectionReason = @"no-ui-videos-found-in-container";
                }

                if (text.length != 0) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"ui-scraped-timeout",
                              @"payloadClass": primaryClass,
                              @"capturedBytes": @(totalCapturedBytes),
                              @"originalBytes": @(firstOriginalBytes),
                              @"payloadVideoCount": @(payloadVideos.count),
                              @"assistantContainerFound": @(assistantContainer != nil),
                              @"carouselAccepted": @(carouselAccepted),
                              @"rejectionReason": rejectionReason,
                              @"uiVideoCount": @(uiVideos.count),
                              @"mergedVideoCount": @(allVideos.count),
                              @"items": @(items.count),
                              @"chars": @(text.length),
                              @"run": @(run)});
                    YTAICacheStore(videoId, flowTag, text);
                    if (!keepPanelOpen) {
                        YTAICloseAiPanel();
                    }
                    done(text, @"ai-fetched");
                    return;
                }
            }
            NSString *status = @"ai-timeout";
            if (!opened && !YTAIPanelRequestObserved)
                status = @"ai-panel-failed";
            else if (!inputSeen)
                status = @"ai-input-missing";
            else if (!YTAISubmitRequestObserved)
                status = @"ai-submit-failed";
            else
                status = @"ai-empty-capture";
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"capture-timeout",
                      @"status": status,
                      @"run": @(run),
                      @"panelOpen": @(opened),
                      @"panelRequest": @(YTAIPanelRequestObserved),
                      @"inputSeen": @(inputSeen),
                      @"submitRequest": @(YTAISubmitRequestObserved),
                      @"hasEntry": @(YTAIFindAiEntryControl() != nil),
                      @"hasInput": @(YTAIFindAiPromptInput(focusView) != nil)});
            if (focusView != nil) YTAIDumpAiUiFromView(focusView);
            done(nil, status);
        });

        if (existingInput != nil) {
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"panel-already-open", @"run": @(run)});
            notePanelOpen();
            return;
        }

        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-triggered",
                  @"class": NSStringFromClass([entry class]) ?: @"?",
                  @"hasExistingInput": @(NO),
                  @"run": @(run)});
        YTAILogAiEntryChain(entry);

        YTAIActivationStrategy preferred = YTAIPreferredElementStrategy(entry);
        YTAIActivationStrategy order[5];
        NSUInteger count = 0;
        if (YTAIHasWinningStrategy) {
            order[count++] = (YTAIActivationStrategy)YTAIWinningStrategy;
        } else {
            order[count++] = preferred;
        }
        YTAIActivationStrategy all[5] = {
            YTAIActivationGesture, YTAIActivationCollection,
            YTAIActivationNodeControl, YTAIActivationAccessibility,
            YTAIActivationUIControl
        };
        for (NSUInteger i = 0; i < 5; i++) {
            BOOL exists = NO;
            for (NSUInteger j = 0; j < count; j++) {
                if (order[j] == all[i]) { exists = YES; break; }
            }
            if (!exists) order[count++] = all[i];
        }

        for (NSUInteger step = 0; step < count; step++) {
            YTAIActivationStrategy strategy = order[step];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((double)step * 1.4 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (run != YTAIRunToken || finished || opened) return;
                if (YTAIPanelRequestObserved) { notePanelOpen(); return; }
                if (YTAIFindAiPromptInput(entry) != nil) { notePanelOpen(); return; }
                lastStep = (NSInteger)strategy;
                BOOL dispatched = YTAIPerformAiActivation(entry, strategy);
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"entry-attempt",
                          @"strategy": YTAIStrategyName(strategy),
                          @"dispatched": @(dispatched),
                          @"run": @(run)});
            });
        }
        for (NSUInteger check = 1; check <= 3; check++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)((7.0 + (double)check * 3.0) * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (run != YTAIRunToken || finished || opened) return;
                if (YTAIPanelRequestObserved || YTAIFindAiPromptInput(entry) != nil)
                    notePanelOpen();
            });
        }
    };

    // Bounded UI readiness loop: check for existing open composer or Ask button
    NSTimeInterval pollInterval = 0.20;
    NSTimeInterval maxWait = 2.5;
    NSDate *startDate = [NSDate date];

    YTAIPollForUIReadiness(startDate, maxWait, pollInterval, run,
        ^(UIView *entry, UIView *existingInput) {
            startUiFlow(entry, existingInput);
        },
        ^{
            YTAIDumpAiUi();
            done(nil, @"ai-panel-ui-timeout");
        });
}

// ---------- UI Presentation Controllers ----------

@interface YTAIResultController : UIViewController
@property(nonatomic, copy) NSString *text;
@end

@implementation YTAIResultController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.title = @"AI Overview";
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                      target:self action:@selector(close)];
    UITextView *textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    textView.editable = NO;
    textView.alwaysBounceVertical = YES;
    textView.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    textView.text = self.text;
    textView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    [self.view addSubview:textView];
}
- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end

void YTAICloseAiPanel(void) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"YTKACE.Recommendations.KeepPanelOpenEnabled"]) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        // Strategy 1: Find YTEngagementPanelHeaderView or close button
        __block UIView *closeButton = nil;
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha < 0.05) continue;

                // Priority 1a: Search inside YTEngagementPanelHeaderView
                __block __weak void (^weakFindHeader)(UIView *);
                void (^findHeader)(UIView *) = ^(UIView *view) {
                    if (closeButton != nil || view == nil) return;
                    NSString *cls = NSStringFromClass([view class]);
                    if ([cls containsString:@"EngagementPanelHeader"]) {
                        @try {
                            id btn = [view valueForKey:@"closeButton"];
                            if ([btn isKindOfClass:UIView.class] && YTAIViewIsVisibleOnScreen((UIView *)btn)) {
                                closeButton = (UIView *)btn;
                                return;
                            }
                        } @catch (NSException *e) {}
                        for (UIView *sub in view.subviews) {
                            NSString *subIdent = [sub.accessibilityIdentifier lowercaseString] ?: @"";
                            NSString *subLabel = [sub.accessibilityLabel lowercaseString] ?: @"";
                            if ([sub isKindOfClass:UIControl.class] &&
                                ([subIdent containsString:@"close"] || [subLabel containsString:@"close"])) {
                                closeButton = sub;
                                return;
                            }
                        }
                    }
                    for (UIView *sub in view.subviews) weakFindHeader(sub);
                };
                weakFindHeader = findHeader;
                findHeader(window);
                if (closeButton != nil) break;

                // Priority 1b: Search globally for id.ui.browse.close.button
                __block __weak void (^weakFindClose)(UIView *);
                void (^findClose)(UIView *) = ^(UIView *view) {
                    if (closeButton != nil || view == nil) return;
                    NSString *ident = [view.accessibilityIdentifier lowercaseString] ?: @"";
                    NSString *label = [view.accessibilityLabel lowercaseString] ?: @"";
                    if ([view isKindOfClass:UIControl.class]) {
                        BOOL isCloseId = [ident containsString:@"id.ui.browse.close.button"] ||
                                         ([ident containsString:@"engagement_panel"] && [ident containsString:@"close"]);
                        BOOL isCloseLabel = [label isEqualToString:@"close"] || [label isEqualToString:@"dismiss"];
                        BOOL notPlayer = ![ident containsString:@"miniplayer"] && ![ident containsString:@"player"];
                        if ((isCloseId || isCloseLabel) && notPlayer && YTAIViewIsVisibleOnScreen(view)) {
                            closeButton = view;
                            return;
                        }
                    }
                    for (UIView *sub in view.subviews) weakFindClose(sub);
                };
                weakFindClose = findClose;
                findClose(window);
                if (closeButton != nil) break;
            }
            if (closeButton != nil) break;
        }

        if (closeButton != nil) {
            YTRCLog(@{@"event": @"ai-panel-close", @"strategy": @"close-button",
                      @"class": NSStringFromClass([closeButton class]) ?: @"?",
                      @"id": closeButton.accessibilityIdentifier ?: @"",
                      @"label": closeButton.accessibilityLabel ?: @""});
            BOOL tapped = NO;
            if ([closeButton isKindOfClass:UIControl.class]) {
                [(UIControl *)closeButton sendActionsForControlEvents:UIControlEventTouchUpInside];
                tapped = YES;
            }
            if (!tapped) tapped = YTAIPerformGestureAction(closeButton);
            if (!tapped) tapped = YTAISimulateTouchOnView(closeButton);
            if (tapped) return;
        }

        // Strategy 2: Controller responder chain
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.hidden || window.alpha < 0.05) continue;
                __block BOOL dismissed = NO;
                __block __weak void (^weakFindController)(UIView *);
                void (^findController)(UIView *) = ^(UIView *view) {
                    if (dismissed || view == nil) return;
                    for (UIResponder *r = view; r != nil; r = r.nextResponder) {
                        SEL selDismiss = NSSelectorFromString(@"dismissEngagementPanelsAnimated:");
                        if ([r respondsToSelector:selDismiss]) {
                            @try {
                                ((void (*)(id, SEL, BOOL))objc_msgSend)(r, selDismiss, YES);
                                dismissed = YES;
                                YTRCLog(@{@"event": @"ai-panel-close", @"strategy": @"dismissEngagementPanelsAnimated:",
                                          @"class": NSStringFromClass([r class]) ?: @"?"});
                                return;
                            } @catch (NSException *e) {}
                        }
                        SEL selCloseNav = NSSelectorFromString(@"closeEngagementPanelNavigationController:animated:");
                        if ([r respondsToSelector:selCloseNav]) {
                            @try {
                                ((void (*)(id, SEL, id, BOOL))objc_msgSend)(r, selCloseNav, nil, YES);
                                dismissed = YES;
                                YTRCLog(@{@"event": @"ai-panel-close", @"strategy": @"closeEngagementPanelNavigationController:animated:",
                                          @"class": NSStringFromClass([r class]) ?: @"?"});
                                return;
                            } @catch (NSException *e) {}
                        }
                    }
                    for (UIView *sub in view.subviews) weakFindController(sub);
                };
                weakFindController = findController;
                findController(window);
                if (dismissed) return;
            }
        }

        // Strategy 3: Modal presentation dismissal
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                UIViewController *top = window.rootViewController;
                while (top.presentedViewController != nil) top = top.presentedViewController;
                if (top != nil && top != window.rootViewController && ![top isKindOfClass:UIAlertController.class]) {
                    [top dismissViewControllerAnimated:YES completion:nil];
                    YTRCLog(@{@"event": @"ai-panel-close", @"strategy": @"dismissViewController",
                              @"class": NSStringFromClass([top class]) ?: @"?"});
                    return;
                }
            }
        }
    });
}

void YTAIShowResultModal(NSString *text, UIViewController *presentingController) {
    if (presentingController == nil) return;
    UIViewController *host = presentingController;
    while (host.presentedViewController != nil) host = host.presentedViewController;
    YTAIResultController *controller = [YTAIResultController new];
    controller.text = text;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:controller];
    [host presentViewController:navigation animated:YES completion:nil];
}

void YTAIShowGuidanceAlert(NSString *status, UIViewController *presentingController) {
    if (presentingController == nil) return;
    UIViewController *host = presentingController;
    while (host.presentedViewController != nil) host = host.presentedViewController;
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"AI Overview not captured"
                         message:[NSString stringWithFormat:
            @"Saved without AI text (%@). To include it: open the ✦ menu on the watch page, "
             "tap \"Summarize this video\", then tap Save w/ AI again — the answer is cached and "
             "saved instantly, even with the panel still open.", status ?: @"unavailable"]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [host presentViewController:alert animated:YES completion:nil];
}
