# AI prompt routing and response attribution: implementation handoff

Review of the working source on 2026-11-06. Locations below refer to that source and may move. This is implementation guidance, not an implemented fix. Example helper names and model fields are proposed application APIs, not discovered YouTube selectors or protobuf fields.

## Required behavior

- Keep Panel Open ON: execute the selected prompt through the AI panel, leave it open, and never substitute a direct request. Returning a cached answer without the corresponding visible interaction is insufficient.
- Keep Panel Open OFF: first initialize through a successful panel interaction; thereafter prefer direct execution, including on other videos, when it can execute the requested operation. On direct failure, immediately start the panel path without an error alert or failure toast. Only report a final failure if the panel path also fails.
- Preserve the exact selected prompt. Unsupported direct prompt delivery must route silently to the panel, not produce a default summary and call it success.
- Save only the current response, including its related-video results. Never include previous turns or the watch page's unrelated recommendations.

## 1. Make routing explicit and remove nested fallbacks

Locations:

- `Tweak/Features/Recommendations/RecommendationHooks.mm:2155`, `YTRCSaveCurrentVideo`.
- `Tweak/Features/Recommendations/AITranscriptHook.mm:3114`, `YTAIFetchSummaryWithPrompt`.
- `AITranscriptHook.mm:3147`, `startPlanBReplay`; called on UI readiness failure at approximately line 3467.
- `AITranscriptHook.mm:3138`, cache-hit shortcut.

The outer Keep Panel Open branch calls a function that internally falls back to direct. Direct failure can also enter the panel function, which can retry direct again. A panel-only policy must apply throughout the call graph, not just in the menu handler or close helper.

Split transport execution from routing. A panel executor must never call the direct executor. Neither executor should show terminal errors, save results, or choose another transport. One coordinator owns fallback and final completion.

Illustrative coordinator logic (all state transitions on the main queue):

```objc
// Proposed APIs; result validation includes correlation and completion.
void StartJob(YTAIJob *job) {
    if (job.keepPanelOpen || !PanelServiceReadyForAccount(job.accountKey)) {
        StartPanelOnly(job); // No internal direct fallback or cache-only shortcut.
        return;
    }
    if (!DirectSupportsOperation(job.prompt, job.action)) {
        StartPanelOnly(job); // Unsupported is an internal routing decision.
        return;
    }

    job.state = YTAIJobDirect;
    NSUInteger attempt = ++job.attempt;
    ExecuteDirect(job, attempt, ^(YTAIResult *result, NSError *error) {
        if (!IsCurrentAttempt(job, attempt, YTAIJobDirect)) return;
        if (ValidCompletedResultForJob(result, job)) {
            FinishJobOnce(job, result, nil);
            return;
        }
        // Invalidate attribution BEFORE cancellation or starting another request.
        ++job.attempt;
        CancelDirectTransportIfAvailable(job);
        LogDirectFallback(job, error); // Diagnostic only; no user error.
        StartPanelOnly(job);
    });
}
```

`StartPanelOnly` assigns a new attempt ID, enforces the captured panel policy, submits the exact prompt, and calls the single final completion. Disable or queue additional AI selections while one job owns the panel; do not let concurrent jobs share global capture state.

The current main save branch already hides a direct failure and starts panel execution. Preserve that behavior. “Immediately” means upon detected failure: the current direct deadline is 30 seconds, so a stalled request still delays fallback. Use a separately configurable direct deadline and distinguish explicit errors, unsupported operations, incomplete responses, and timeouts. Do not equate the first empty streaming callback with terminal failure.

Remove `YTAICloseAiPanel()` from `YTAIReplayDirect` (around line 2890). Only panel execution should clean up the specific panel it opened, and only when policy permits. Avoid the global search for any Close/Dismiss button.

## 2. Direct across videos is viable, but prompt delivery is still missing

Locations: `AITranscriptHook.mm:2251` (`YTAIConstructToken`), `:2852` (`YTAIReplayDirect`), and `RecommendationHooks.mm:2216`.

The current direct API accepts a video ID and completion, not prompt text. Token construction encodes video/conversation identifiers and a bootstrap flag. It cannot demonstrate submission of the newly selected server prompt. A nonempty default summary is not a successful answer to “List 5 similar videos and summarize their content.”

Keep direct replay for the proven native-summary operation. Add arbitrary-prompt capability only after tracing the actual custom-prompt request and verifying different prompts reach the wire. Until then, `DirectSupportsOperation` must reject unsupported operations and silently select the panel. Do not infer capability from wording containing “summarize.”

For another video, reuse only the verified account-appropriate service. Resolve and verify that video's conversation/session, then bootstrap it if needed. Do not reuse the previous video's conversation or assume its attachments/click tracking are portable. Replace `YTRCAiFirstQueryDone` with verified service readiness; a cached or scraped answer does not prove initialization. Invalidate readiness and session state on identity changes.

The existing bootstrap callback around `AITranscriptHook.mm:3069` unconditionally marks the session ready. Validate a known session response and transition once; multiple bootstrap callbacks must not cause multiple submits. The 150 ms delay is not evidence of readiness.

## 3. Bind captures to the dispatched request, not global “current” state

Locations:

- `AITranscriptHook.mm:835`, `YTAINoteContinuation`.
- `AITranscriptHook.mm:855`, `YTAICollectCaptureItem`.
- `RecommendationHooks.mm:785`, `YTRCCaptureArrayCallback`.
- `RecommendationHooks.mm:900`, `YTRCPanelCaptureHandler`.
- `RecommendationHooks.mm:941`, `YTRCCaptureAssistantObject`.

Current collectors receive raw bytes without request identity. `YTAICollectCaptureItem` accepts `chat_response_item` content even before the new prompt's submission is observed, sets `YTAICaptureSawAnswer`, and schedules completion. That can also suppress submission because the UI submit routine stops when `YTAICaptureSawAnswer` is true.

`YTAINoteContinuation` uses token prefixes and global flags to classify submissions. A matching prefix is not proof that a request belongs to this job, video, conversation, or exact prompt.

Introduce immutable capture context containing local job ID, attempt ID, account key, video ID, prompt identity, request ID, and any verified conversation/message/parent IDs. Capture context when dispatching/wrapping the matching native request. A callback must carry that captured context; it must not look up the current job at callback time and assign itself to it.

```objc
// Conceptual: preserve the runtime-verified original block signature.
YTAICaptureContext *context = [contextAtDispatch copy];
id wrapped = MakeSignatureCheckedWrapper(originalBlock, ^(id response) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!IsCurrentCaptureContext(context)) return;
        YTAIDecodedResponse *decoded = DecodeObservedResponse(response);
        if (!ResponseBelongsToSubmittedTurn(decoded, context)) return;
        ApplyMessageMutations(context, decoded);
        FinishIfCurrentTurnIsComplete(context);
    });
});
```

Confirm submission at the actual native request boundary, checking exact prompt text when present or the verified native action identity. A tap, typing-start flag, or any chat request is insufficient. Discover the real message/turn fields from captures; do not invent protobuf field numbers.

If the initial response contains prior conversation history, select the assistant message linked to the submitted turn. A local request ID alone does not make every message in its response current. If explicit linkage is unavailable, use a before-submission message baseline plus observed new submission and newly created assistant message; document that evidence. Timestamps or “not previously seen” alone cannot prove attribution because older messages may load later.

Late direct callbacks after fallback must be rejected both by the direct executor and the global capture hooks. Cancellation alone does not prevent callbacks. Generation/attempt validation must happen before saving or caching anything.

## 4. Replace whole-window scraping and first-text extraction

Locations:

- `AITranscriptHook.mm:2686`, `YTAIScrapeAiResponseFromUI`.
- `AITranscriptHook.mm:3362`, timeout branch.
- `AITranscriptHook.mm:3264`, capture-settle branch.
- `AITranscriptHook.mm:2540`, subtree extraction, and `:2630`, `YTAITextFromPayloads`.

The scraper traverses all visible windows and joins qualifying labels/text views. It can include previous answers, the selected prompt, titles, and unrelated UI. The timeout branch invokes it before checking submission and reports success for any nonempty output.

Delete that whole-window fallback from the result path. If UI extraction remains necessary, require a proven current assistant message view and traverse only its response content and associated result cards. If the submitted turn or its message cannot be identified, return a capture failure; never save unrelated visible text.

The current protobuf extractor returns the first matching basic-content/chat text, and `YTAITextFromPayloads` returns the first successful payload. This loses additional blocks and can return an earlier partial response. Build a message model and apply updates/replacements/deltas according to the observed protocol. Do not concatenate every streaming snapshot. Preserve block order and update stable entity IDs in place.

The 2.5-second quiet period is only a heuristic, not proof that text and related cards are complete. Prefer an observed terminal message/request state. Where no terminal marker is understood, require attributable content, finished loading, and a bounded settle window; log that completion was inferred. Do not complete at the first nonempty text if cards are still arriving.

## 5. Preserve related-video cards as part of the current answer

`YTRCCaptureArrayCallback` stops after eight items (`if (index++ >= 8) break`). That limit affects collection, not just logs, so later response cards can be omitted. Keep diagnostic output capped independently from response processing. Bound collection by bytes/entities and explicitly report truncation rather than silently producing a complete-looking result.

The present extractor understands two text paths and returns one string. It does not implement a structured collection of related-video cards. Obtain a successful “List 5 similar videos…” response capture and inspect its actual renderer/entity structure. Field numbers for these cards have not been established by this review.

Proposed result shape:

```json
{
  "jobId": "local-job-id",
  "videoId": "source-video-id",
  "promptId": "related-videos",
  "promptText": "List 5 similar videos and summarize their content",
  "executionMethod": "panel",
  "messageId": "observed-current-assistant-message-id",
  "complete": true,
  "blocks": [
    {"type": "text", "text": "Assistant's introduction"},
    {"type": "video", "videoId": "result-video-id", "title": "Observed title",
     "url": "observed-or-video-id-derived-watch-url", "description": "Observed description"}
  ]
}
```

Only include cards attached to the current response/message or its verified response section. Do not scrape the watch recommendation feed, previous turns' cards, or suggested follow-up questions as answer content. Do not discard a valid video card merely because its title contains “related.” Preserve descriptions supplied by YouTube; do not invent missing summaries.

Result validity must allow attributable video-card-only responses. Change success checks from `summary.length != 0` to a validated, completed result with text and/or cards.

Extend `RecommendationClient.mm:218` (`YTRCSendSaveRequest`) and `server/bun-recommendation-server.ts` (`handleSave`, around 1369) to preserve structured blocks and prompt provenance. Retain `aiSummary` as a backward-compatible text rendering of the same current response if needed. Update the mock server and contract tests together.

## 6. Other weaknesses to fix alongside this work

- **Cache attribution:** `YTAICacheNativeAiAnswer` around line 2676 labels arbitrary native answers with the current playing video and generic `summarize` tag. A delayed response can therefore be assigned to the wrong video or prompt. Cache only correlated completed results using the captured account/video/exact prompt identity. Do not lowercase prompt text for identity; case can matter. Capture context should survive navigation, or the job should be explicitly cancelled.
- **Fallback cache poisoning:** the old `startPlanBReplay` branch can save a default-summary response under the selected custom prompt's `flowTag`. Removing executor-owned fallback removes this ambiguity.
- **Navigation:** the menu captures a video ID before fetching the transcript, then starts UI work later. Revalidate the panel's target video before typing; if the user navigated, cancel or deliberately rebind the whole job. Never save a new video's panel answer under the old video ID.
- **Single completion:** `done` in direct replay queues its `finished` update asynchronously. Serialize all transitions and mark the job finished before invoking outward completion. Cancel timers logically, reject stale attempts, and ensure one save per job.
- **Block ABI:** the panel callback wrapper assumes `(id, BOOL)` and direct error adaptation searches for `"24"` in an encoding. Use `YTRCBlockSignature` plus parsed types, not size substrings. Unknown signatures must pass through untouched or make execution unsupported. The 30-hook verifier does not cover these new wrappers.
- **Delegate swizzle:** the existing per-class map still resolves from `[self class]`, leaving the previously identified subclass-to-super recursion case. Limit to the verified delegate class or use correctly scoped per-installation trampolines; synchronize map access.
- **Settings contract:** validate `protocolVersion` in `YTRCFetchServerSettings` around line 372. Invalidate the settings cache if the configured endpoint/account changes. Prefer stable prompt IDs and explicit action metadata, but server metadata alone must not assert an unimplemented direct capability.

## Acceptance tests that exercise behavior

1. Keep Panel Open ON, no existing panel: selected prompt is submitted visibly; panel remains open. No direct request occurs.
2. Same setting, panel unavailable: failure is reported after the panel attempt; no direct substitution.
3. Prompt A succeeds; prompt B fails to submit with A still visible: B fails without caching/saving A's answer.
4. Prompt A and B both succeed in one panel: B's saved result contains only B's text/cards, including when the response payload includes conversation history.
5. OFF, initialized service, second video, supported direct operation: correct new-video response is saved once without panel presentation.
6. Direct errors or times out: no failure alert/toast before panel fallback; one panel attempt and one final save. A delayed direct response cannot enter the panel result.
7. Unsupported direct custom prompt: silent panel routing with exact text, never a substituted default summary.
8. Related-video reply has little/no prose or cards beyond callback item eight: all current-turn cards are retained in order. No watch-feed or old-turn cards appear.
9. Streaming text revisions followed by delayed cards: save the completed current response, not the first partial text or concatenated revisions.
10. Navigate during transcript fetch or switch identity: no cross-video/account caching, submission, or saving.
11. Repeat a prompt with Keep Panel Open ON: cache does not bypass the required visible interaction.
12. Rapid repeated selections: queue or reject overlapping jobs explicitly; no shared-capture contamination.

Use captured protocol fixtures for the decoder and request/message attribution tests. The related-card schema needs a real successful capture; do not fabricate an assumed renderer path. Record job ID, attempt, method, prompt identity, target video/conversation, submission confirmation, accepted message IDs, block counts, completion evidence, fallback reason, and save count in diagnostics.
