# YouTube AI requests without presenting the panel

## Objective and scope

Implement `fetchNativeYouTubeAI(videoId, prompt, completion)` inside the injected
iOS tweak. YouTube's existing authenticated services should make the request and
return the parsed answer. A successful direct run must not present, instantiate,
type into, or scrape the AI panel. The working panel flow remains available for
reference captures and as an explicit fallback.

This is a plan for investigating the private API in the supplied YouTube build,
not a claim that its complete request protocol is already known. Start with an
exact replay of a successful app-level call, then remove its dependence on prior
panel initialization, then support arbitrary prompts.

## What the evidence already establishes

- The working submission crosses
  `YTInnerTubeFeedControllerDataSource`'s
  `requestInnerTubeContinuationWithContinuationToken:continuationType:clientAttachmentRequestData:cacheEnabled:clickTrackingParams:alwaysParseFeedNode:responseBlock:errorBlock:`.
- Successful captures use continuation type `8`, `cacheEnabled=NO`, and
  `alwaysParseFeedNode=YES`. Their service is an
  `YTAppScopedInnerTubeUIServiceProxy`.
- The observed response callback encoding
  `v40@?0@"NSArray"8Q16@24@"NSData"32` has FOUR explicit arguments:
  `(NSArray *items, NSUInteger index, id context, NSData *data)`.
  The block itself is the implicit argument. Verify the encoding on the installed
  build; independently inspect the error callback.
- Responses include `YTISectionListMutationOperations` containing the answer's
  `chat_response_item` renderer. Existing structured answer extraction can be
  shared by direct and panel flows.
- The old replay path is not an exact replay: it selects a suggestion token from
  the initial watch payload, hard-codes `alwaysParseFeedNode=NO`, and provides a
  two-argument response block. Its empty results do not establish that direct
  requests are impossible.
- The `kta-...` prefix and class names alone do not establish token semantics,
  prompt mutability, or the concrete transport used by this flow.

## 1. Capture one successful transaction completely

Add a diagnostic mode that records one reference run from watch-page readiness
through panel initialization, custom-prompt submission, and final answer.

Assign an experiment ID and label each operation as watch initialization, panel
initialization, submission, response update, completion, or cancellation. Record:

- Full continuation string, receiver/service identities and concrete classes.
- Every argument: type, flags, attachment class plus serialized content, and
  click-tracking bytes. Keep an immutable snapshot associated with that call;
  the existing global "last arguments" variables can be overwritten by another
  continuation.
- Response/error block encodings and every callback's argument types, data,
  order, and timing. Distinguish an initial empty/update callback from final
  completion.
- The underlying request object's class and complete serialized protobuf at the
  service boundary. Capture the return/cancellation handle and its lifetime.
- Short call stacks connecting the continuation to request construction and
  actual dispatch. If service dispatch cannot be located, instrument the actual
  transport reached by that call stack rather than assuming a transport class.

Use a separate diagnostic fixture for full payloads. Current exports truncate
array items at 16 KiB and retain only 200 events; those exports cannot be the
complete protocol fixture. Record byte counts, hashes, and truncation flags.
Keep authenticated session state inside the app; exported diagnostics should not
include reusable credentials.

Existing instrumentation locations:

- `RecommendationHooks.mm`: `YTRCTeaserContinuation`,
  `YTRCCaptureArrayCallback`, watch-service hooks, and assistant/panel hooks.
- `AITranscriptHook.mm`: `YTAINoteNativeContinuation`, native replay,
  and structured response extraction.

The supplied binary also exposes this useful intermediate boundary:

```text
YTInnerTubeFeedControllerDataSource
  makeContinuationRequestWithToken:continuationType:
    clientAttachmentRequestData:clickTrackingParams:alwaysParseFeedNode:
    refresh:initialResponseBlock:responseBlock:errorResponseBlock:
```

Trace the service actually reached. Existing assistant/streaming hooks are
candidates, not proof that either service carries the working submission.

Exit criterion: a complete submission fixture with verified callback signatures
and a correlated outgoing request and answer.

## 2. Prove exact replay with the panel closed

Use the successful SUBMISSION call from step 1, including its full token and all
native arguments. Dismiss the reference panel, then invoke the same continuation
method through the captured live data source with correctly typed callbacks.
Do not alter prompt, video, flags, or attachment in this first experiment.

Temporarily bypass the tweak's answer cache, while preserving the captured native
request flags. Require an observed outbound request plus a new correlated answer;
reading an old cache entry does not pass this experiment.

Retain the required native objects/returned request handle for the operation's
lifetime. Borrowed C++ command pointers from UI handlers are not replay objects.
Use a per-run object, finish once on the main queue, and cancel or ignore all
remaining callbacks after completion.

If replay fails, compare stages: method entered, request constructed, dispatched,
callback delivered, answer parsed, request cancelled. Log the native error object
with its real type. A UI-related cancellation or detached data source is evidence
to move to the underlying request service, not evidence that the server rejected
the prompt. If the service enforces freshness, obtain a new native request/token
through its builder rather than weakening that check.

Exit criterion: one real request and answer while the panel is closed, with no
panel activation or UI extraction during the direct run. This is a warm-session
milestone; it does not yet prove independence from panel initialization.

## 3. Remove the dependency on panel initialization

Compare two executions of the same operation:

1. Immediately after a successful reference-panel session.
2. After relaunching YouTube, loading the same video, and never opening Ask.

If only the first succeeds, identify the state established by opening Ask:
service construction, conversation/session identifiers, attachment data,
bootstrap response, account context, or token acquisition. Reproduce the smallest
observed initialization sequence through native services.

Prefer an existing request builder/service from YouTube's active account scope.
The binary exposes `getInnerTubeUIServiceForActiveIdentity` on the service proxy;
verify its actual result and lifetime instead of assuming it is usable. The feed
data source also exposes `initWithInnerTubeService:initialFeedNode:contentsBlock:`
and a `contentsKey:` variant. These are investigation points, not instructions to
construct a data source with guessed or nil dependencies.

If opening Ask performs a required bootstrap request, make that request directly
and consume its result before submission. Check watch-page delivery readiness;
earlier logs show discovery running before the watch response was delivered.

Exit criterion: after app relaunch and video load, the direct function works
without constructing or presenting the AI panel, including offscreen panels.

## 4. Find how the app constructs arbitrary prompts

Collect controlled native submissions, changing one factor at a time:

| Capture | Video | Prompt | Conversation |
| --- | --- | --- | --- |
| A | A | P | Fresh |
| B | A | P | Another fresh conversation |
| C | A | Q | Fresh |
| D | B | P | Fresh |
| E | A | Q | Follow-up after P |

Diff decoded protobuf fields, attachment data, and full continuation tokens.
Where a token contains nested base64url/percent-encoded protobuf, decode only
validated layers and retain original bytes and unknown fields. Record which
fields vary with prompt, video, conversation, and freshness.

Trace backward from the outgoing request to the native builder that inserts the
composer's text. Prefer calling that builder with a supplied `NSString` and the
current video/session context. This avoids recreating tokens whose opaque parts
may depend on server state or integrity checks.

If a prompt is demonstrably an ordinary mutable protobuf string, re-encode all
enclosing lengths and preserve unknown fields. Test that hypothesis only after
unchanged replay works. If changing it breaks validation, use the native builder
or obtain a fresh server-issued token; do not assume arbitrary tokens can be
minted by replacing printable text.

Do not call `buildSenderState:withText:` with guessed parameters. It takes a C++
`SenderState*` followed by the text object. Any use of that native construction
path needs correctly owned state and verified signatures.

Exit criterion: two different custom prompts on two videos, including after a
fresh launch, each producing the matching answer without the panel.

## 5. Integrate and verify

Expose one operation with explicit states:

```text
waitingForWatch -> initializingSession -> submitting -> receiving -> completed
```

Scope receiver, request, callbacks, timer, response items, video, prompt, and
conversation to that operation. Associate updates with request/message identity;
use the native completion semantics discovered in tracing. A settle delay may be
a documented fallback if the API has no usable final signal.

Cache by video, prompt, conversation where relevant, and extractor version.
Keep the parsed answer field intact. Use the panel fallback only after direct
execution has finished or been cancelled, with a single save/result completion
for the user's operation.

Verify a fresh launch, a new video, repeated requests, two prompts, an already-open
panel, navigation during a request, a native error, and a timeout. Confirm one
completion and one save, plus no later stale timeout. Record whether each result
came from a fresh request, cache, or panel fallback.

Deliverables for each milestone: the complete diagnostic fixture, decoded field
diff, verified method/block signatures, observed native call path, and a small
direct-call test entry point. Preserve the working panel implementation while
developing the direct path.
