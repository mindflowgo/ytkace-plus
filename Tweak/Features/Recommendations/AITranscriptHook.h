#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// Forward declarations of logging & watch payload providers in RecommendationHooks
FOUNDATION_EXPORT void YTRCLog(NSDictionary *event);
FOUNDATION_EXPORT NSData * _Nullable YTRCCurrentWatchPayload(NSString * _Nullable * _Nullable videoId);
FOUNDATION_EXPORT NSString * _Nullable YTRCCurrentVideoId(void);

// ---------- AI Overview & Gemini Prompting Public API ----------

// Main entry point for "Save w/ AI":
// Gathers the Gemini AI Overview summary for the given video (via Plan A UI automation
// or Plan B InnerTube replay). Invokes completion on the main thread with summary text and status.
FOUNDATION_EXPORT void YTAIFetchSummary(NSString *videoId, void (^completion)(NSString * _Nullable summary, NSString *status));
FOUNDATION_EXPORT void YTAIFetchSummaryWithPrompt(NSString *videoId, NSString * _Nullable prompt,
                                                  void (^completion)(NSString * _Nullable summary, NSString *status));

// Direct API replay without UI panel presentation
FOUNDATION_EXPORT const void * const kYTAIDirectAttemptKey;
FOUNDATION_EXPORT BOOL YTAICanReplayDirect(NSString *videoId);
FOUNDATION_EXPORT BOOL YTAIDirectSupportsOperation(NSString * _Nullable prompt);
FOUNDATION_EXPORT void YTAIInvalidateDirectAttempts(void);
FOUNDATION_EXPORT void YTAICancelActiveOperations(void);
FOUNDATION_EXPORT void YTAIReplayDirect(NSString *videoId, void (^completion)(NSString * _Nullable summary, NSString *status));

// Feeds continuation tokens observed in YouTube InnerTube hooks into the AI engine
FOUNDATION_EXPORT void YTAINoteContinuation(NSString *token);

// Captures full native continuation parameters seen during an active session
FOUNDATION_EXPORT void YTAINoteNativeContinuation(NSString *token, id receiver, unsigned long long continuationType, id _Nullable attachment, id _Nullable clickTracking, BOOL cacheEnabled, BOOL alwaysParse, NSString * _Nullable respSignature, NSString * _Nullable errSignature);

// Feeds raw response bytes received from InnerTube continuation hooks into the AI engine
FOUNDATION_EXPORT void YTAICollectCaptureItem(NSData *bytes);
FOUNDATION_EXPORT void YTAICollectCaptureItemWithClass(NSData *bytes, NSString * _Nullable className);

// Captures active feed data source references seen in continuation hooks for replay calls
FOUNDATION_EXPORT void YTAICaptureFeedDataSource(id receiver, NSString *source);

// UI Presentation controllers & panel dismissal
FOUNDATION_EXPORT void YTAICloseAiPanel(void);
FOUNDATION_EXPORT void YTAIShowResultModal(NSString *text, UIViewController *presentingController);
FOUNDATION_EXPORT void YTAIShowGuidanceAlert(NSString *status, UIViewController *presentingController);

// Related videos extraction & link resolution
FOUNDATION_EXPORT BOOL YTAIIsValidVideoId(NSString *vid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromPayload(NSData *payload, NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromPayloadWithClass(NSData *payload, NSString * _Nullable payloadClass, NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromCommandPayload(NSData *cmdPayload, NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIExtractVideosFromPayloads(NSArray *payloads, NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIScrapeRelatedVideosFromView(UIView * _Nullable rootView, NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIScrapeRelatedVideosFromUI(NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIScrapeRelatedVideosAndLinks(UIView * _Nullable assistantContainer, NSString * _Nullable activeVid, NSMutableDictionary<NSString *, NSString *> * _Nullable outResolutions);
FOUNDATION_EXPORT UIView * _Nullable YTAIFindAiPanelContainer(UIView * _Nullable focusView);
FOUNDATION_EXPORT UIView * _Nullable YTAIFindCurrentAssistantMessageContainer(UIView * _Nullable panelContainer, NSString * _Nullable answerText);
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, NSString *> *> *YTAIMergeRelatedVideos(NSArray<NSDictionary *> *v1, NSArray<NSDictionary *> *v2, NSString * _Nullable activeVid);
FOUNDATION_EXPORT NSString *YTAIFixTruncatedLinksInText(NSString *text, id _Nullable resolutionsOrVideos);
FOUNDATION_EXPORT NSString *YTAIAppendRelatedVideosToText(NSString * _Nullable text, NSArray<NSDictionary *> *videos);
FOUNDATION_EXPORT void YTAIDiagnosticLogEndpoints(NSData * _Nullable payload, NSString * _Nullable className, NSString * _Nullable source);

NS_ASSUME_NONNULL_END
