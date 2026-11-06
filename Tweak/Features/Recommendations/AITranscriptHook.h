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

// Feeds continuation tokens observed in YouTube InnerTube hooks into the AI engine
FOUNDATION_EXPORT void YTAINoteContinuation(NSString *token);

// Captures full native continuation parameters seen during an active session
FOUNDATION_EXPORT void YTAINoteNativeContinuation(id receiver, unsigned long long continuationType, id _Nullable attachment, id _Nullable clickTracking, BOOL cacheEnabled, BOOL alwaysParse);

// Feeds raw response bytes received from InnerTube continuation hooks into the AI engine
FOUNDATION_EXPORT void YTAICollectCaptureItem(NSData *bytes);

// Captures active feed data source references seen in continuation hooks for replay calls
FOUNDATION_EXPORT void YTAICaptureFeedDataSource(id receiver, NSString *source);

// UI Presentation controllers & panel dismissal
FOUNDATION_EXPORT void YTAICloseAiPanel(void);
FOUNDATION_EXPORT void YTAIShowResultModal(NSString *text, UIViewController *presentingController);
FOUNDATION_EXPORT void YTAIShowGuidanceAlert(NSString *status, UIViewController *presentingController);

NS_ASSUME_NONNULL_END
