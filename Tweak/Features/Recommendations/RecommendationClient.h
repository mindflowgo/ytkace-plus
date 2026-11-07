#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Server protocol per docs/recommendations.md §5 (protocolVersion 1, transform),
// routed per §99: the configured ServerURL is the server BASE ONLY
// (scheme://host[:port], no path) and the patch appends exactly one canonical
// endpoint per surface — /yt-browse for the Home feed, /yt-next for the watch
// page + related list. There are no alternate, legacy, or path-qualified URL
// forms; a configured URL that includes a path is rejected. When
// YTKACE.Recommendations.ServerToken is set it is sent as
// "Authorization: Bearer <token>" on every request.
FOUNDATION_EXPORT NSString * const YTRCServerTokenKey;
FOUNDATION_EXPORT NSString * const YTRCTimeoutKey;
FOUNDATION_EXPORT NSString * _Nonnull YTRCActionReplace(void);   // "replace"
FOUNDATION_EXPORT NSString * _Nonnull YTRCActionPassthrough(void); // "passthrough"
FOUNDATION_EXPORT NSUInteger const YTRCProtocolVersion;
FOUNDATION_EXPORT NSTimeInterval YTRCConfiguredTimeout(void);
FOUNDATION_EXPORT NSUInteger YTRCConfiguredTimeoutMS(void);

// Maps a configured base URL + surface to the canonical endpoint. Returns nil
// for an unknown surface, a non-http(s) scheme, or a base that includes a path.
FOUNDATION_EXPORT NSURL * _Nullable YTRCEndpointForBaseURL(NSURL * _Nullable base, NSString * _Nullable surface);

// A validated server reply. `payload` is the decoded replacement bytes when
// action is replace; nil for passthrough.
@interface YTRCTransformReply : NSObject
@property(readonly, copy) NSString *action;
@property(readonly, nullable) NSData *payload;
@property(readonly) NSInteger statusCode;
@property(readonly) BOOL notModified;
- (instancetype)initWithAction:(NSString *)action payload:(NSData * _Nullable)payload statusCode:(NSInteger)statusCode notModified:(BOOL)notModified;
- (instancetype)initWithAction:(NSString *)action payload:(NSData * _Nullable)payload;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
@end

// Captures request-side context so the server can log what YouTube actually
// asked for: the request class, its serialized protobuf (browseId, params,
// continuation, query, …), plus flat copies of the named fields when the
// gateway exposes them. Returns nil when nothing is available; never throws.
FOUNDATION_EXPORT NSDictionary * _Nullable YTRCCaptureRequestContext(id _Nullable request);

// Builds the request envelope dictionary. Caller JSON-encodes it.
// `requestContext` is merged into `context` (videoId is added separately).
FOUNDATION_EXPORT NSDictionary *YTRCBuildEnvelope(NSString *requestId, NSString *surface, NSString *phase,
                                                  NSString * _Nullable videoId,
                                                  NSDictionary * _Nullable requestContext,
                                                  NSString *responseType,
                                                  NSString *youtubeVersion, NSData *payload);

// Validates a reply body against the contract. Returns nil and fills `error`
// on any violation: non-JSON, wrong version, request id mismatch, unknown
// action, wrong encoding, undecodable or oversized payload.
FOUNDATION_EXPORT YTRCTransformReply * _Nullable YTRCDecodeTransformReply(NSData *body, NSString *expectedRequestId,
                                                                          NSUInteger maxPayloadBytes,
                                                                          NSError * _Nullable * _Nullable error);

// Async transform. `completion` runs on a private serial queue. The server URL,
// timeout, and caps are read from the module's settings at call time. Errors
// cover: disabled/missing URL, URL build failure, HTTP failure, timeout, and
// every protocol violation (reply nil in that case).
FOUNDATION_EXPORT void YTRCRequestTransform(NSData *payload, NSString *surface, NSString *phase,
                                            NSString * _Nullable videoId,
                                            NSDictionary * _Nullable requestContext,
                                            NSString *responseType,
                                            void (^completion)(YTRCTransformReply * _Nullable reply,
                                                               NSError * _Nullable error));

// Observation-only playback events (client hook -> server log). No payload is
// sent and nothing is substituted; failure is silent by design.
FOUNDATION_EXPORT void YTRCSendPlaybackEvent(NSString *event, NSString * _Nullable videoId,
                                             NSDictionary * _Nullable detail);

// Explicit save request from the watch menu (POST /yt-save). The body
// carries the 11-character videoId, an `ai` flag distinguishing a plain
// save from "Save w/ AI", the transcript outcome (`transcriptStatus`), the
// AI Overview outcome (`aiStatus`), optionally the video's transcript as raw
// YouTube json3 caption bytes (base64, `transcriptEncoding: "youtube-json3"`),
// and for Save w/ AI the replayed AI Overview text (`aiSummary`).
// `completion` always runs on the main queue with a short user message.
FOUNDATION_EXPORT void YTRCSendSaveRequest(NSString * _Nullable videoId, BOOL aiEnhanced,
                                           NSData * _Nullable transcript,
                                           NSString * _Nullable transcriptEncoding,
                                           NSString * _Nullable transcriptStatus,
                                           NSString * _Nullable aiSummary,
                                           NSString * _Nullable aiStatus,
                                           void (^completion)(BOOL ok, NSString * _Nonnull message));

// Connection test: GET the configured URL and require HTTP 200 with a JSON
// object advertising protocolVersion 1 (the documented health probe).
FOUNDATION_EXPORT void YTRCProbeServer(void (^completion)(NSDictionary * _Nullable health,
                                                          NSError * _Nullable error));

// Fetches server runtime settings (GET /yt-settings). Returns the array of AI prompts on success.
FOUNDATION_EXPORT void YTRCFetchServerSettings(void (^completion)(NSArray<NSString *> * _Nullable aiPrompts,
                                                                  NSError * _Nullable error));

NS_ASSUME_NONNULL_END
