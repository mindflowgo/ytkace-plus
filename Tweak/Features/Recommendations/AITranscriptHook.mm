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

void YTAICaptureFeedDataSource(id receiver, NSString *source) {
    if (receiver == nil) return;
    if (YTAIFeedDataSource == receiver) return;
    YTAIFeedDataSource = receiver;
    YTRCLog(@{@"event": @"ai-datasource", @"source": source ?: @"",
              @"class": NSStringFromClass([receiver class]) ?: @"?"});
}

void YTAINoteNativeContinuation(id receiver, unsigned long long continuationType, id attachment, id clickTracking, BOOL cacheEnabled, BOOL alwaysParse) {
    if (!YTAIReplayInFlight) {
        YTAIAiDataSource = receiver;
        YTAIContinuationType = continuationType;
        YTAINativeCacheEnabled = cacheEnabled;
        YTAINativeAlwaysParse = alwaysParse;
        YTAIAttachment = attachment;
        YTAIClickTracking = clickTracking;
        YTAIHasNativeArgs = YES;
    }
}

static void YTAICacheNativeAiAnswer(NSData *bytes);

static id YTAICaptureLock(void) {
    static id lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}

static BOOL YTAICaptureActive = NO;
static BOOL YTAICaptureSawAnswer = NO;
static NSUInteger YTAIRunToken = 0;
static NSMutableArray<NSData *> *YTAICaptureItems = nil;
static NSUInteger YTAICaptureGeneration = 0;
static void (^YTAICaptureSettle)(void) = nil;
static BOOL YTAIHasWinningStrategy = NO;
static NSUInteger YTAIWinningStrategy = 0;
static BOOL YTAIPromptSubmitted = NO;
static BOOL YTAIPanelRequestObserved = NO;
static BOOL YTAISubmitRequestObserved = NO;

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
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-observed", @"tokenPrefix": prefix});
        return;
    }
    if ([token hasPrefix:@"kta-ngv"] || !YTAIPromptSubmitted) {
        if (YTAIPanelRequestObserved) return;
        YTAIPanelRequestObserved = YES;
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"panel-request-observed", @"tokenPrefix": prefix});
        return;
    }
    if (YTAISubmitRequestObserved) return;
    YTAISubmitRequestObserved = YES;
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"submit-observed", @"tokenPrefix": prefix});
}

void YTAICollectCaptureItem(NSData *bytes) {
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
    BOOL isRelevant = isAnswer || isChat || isYouChat || isStreaming || isAssistant;
    if (!isRelevant && (!YTAICaptureActive || !YTAISubmitRequestObserved)) return;
    if (isAnswer) YTAICacheNativeAiAnswer(bytes);
    @synchronized (YTAICaptureLock()) {
        if (!YTAICaptureActive || YTAICaptureItems == nil) return;
        if (YTAICaptureItems.count >= 60) return;
        if (!isAnswer && !(YTAISubmitRequestObserved && isRelevant)) return;
        [YTAICaptureItems addObject:bytes];
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
    if (send == nil && realEditor != nil && realEditor.window != nil) {
        send = YTAIFindAiSendControl(realEditor, realEditor);
    }
    if (send == nil) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-control-not-found", @"run": @(run)});
        return;
    }

    YTAILogSendGestures(send);

    // Stage 1 (after 50ms): Native gesture target-action (handleTap)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (run != YTAIRunToken || YTAISubmitRequestObserved) return;
        BOOL gestureDispatched = YTAIFireSendGesture(send);
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"send-attempt",
                  @"stage": @(1), @"strategy": @"gesture-handleTap",
                  @"dispatched": @(gestureDispatched),
                  @"run": @(run)});

        // If Stage 1 dispatched, give YouTube time (2.0s) to process and send the InnerTube request.
        NSTimeInterval nextDelay = gestureDispatched ? 2.0 : 0.15;

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

            NSTimeInterval stage3Delay = touchDispatched ? 2.0 : 0.15;

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
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)),
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

    for (NSUInteger index = 0; index < length; index++) {
        NSString *character = [prompt substringWithRange:NSMakeRange(index, 1)];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)((0.03 * (double)(index + 1)) * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (run != YTAIRunToken || !YTAIViewIsVisibleOnScreen((UIView *)realEditor)) return;
            [realEditor insertText:character];
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)((0.03 * (double)length + 0.3) * NSEC_PER_SEC)),
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

static UIView *YTAIFindAiEntryControl(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha < 0.05) continue;
            __block UIView *found = nil;
            __block UIView *fallback = nil;
            __block NSUInteger budget = 4000;
            __block __weak void (^weakWalk)(UIView *);
            void (^walk)(UIView *) = ^(UIView *view) {
                if (found != nil || view == nil || budget == 0) return;
                budget--;
                if (view.hidden || view.alpha < 0.01) return;
                NSString *identifier = [view.accessibilityIdentifier lowercaseString] ?: @"";
                NSString *label = [view.accessibilityLabel lowercaseString] ?: @"";
                BOOL identifierMatch = [identifier containsString:@"you-chat-entrypoint"] ||
                    [identifier containsString:@"youchat"] ||
                    [identifier containsString:@"ask"];
                BOOL strongLabel = [label containsString:@"ai overview"] ||
                    [label containsString:@"ask about this video"] ||
                    [label containsString:@"ask gemini"] ||
                    [label isEqualToString:@"ask"];
                if (identifierMatch || strongLabel) {
                    found = view;
                    return;
                }
                if (fallback == nil && [label containsString:@"ask"]) fallback = view;
                for (UIView *subview in view.subviews) weakWalk(subview);
            };
            weakWalk = walk;
            walk(window);
            if (found != nil) return found;
            if (fallback != nil) return fallback;
        }
    }
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

static inline BOOL YTAIBytesContain(const uint8_t *bytes, NSUInteger length, const char *needle, NSUInteger needleLen) {
    if (bytes == NULL || needle == NULL || length < needleLen) return NO;
    return memmem(bytes, length, needle, needleLen) != NULL;
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

static NSString *YTAIExtractAnswerFromSubtrees(const uint8_t *bytes, NSUInteger length, NSUInteger depth) {
    if (bytes == NULL || length == 0 || depth > 24) return nil;
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
                // Check if this Elements entity represents basic_content or chat_response_item
                if (YTAIBytesContain(chunk, chunkLen, "basic_content", 13)) {
                    static const NSUInteger kBasicContentTail[] = { 5, 413471385, 1, 1382, 2, 2, 1 };
                    NSString *ans = YTAIExtractFieldByPath(chunk, chunkLen, kBasicContentTail, 7, 0);
                    if (ans.length != 0) return ans;
                }
                if (YTAIBytesContain(chunk, chunkLen, "chat_response_item", 18)) {
                    static const NSUInteger kChatItemTail[] = { 5, 413471385, 1, 2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382, 2, 2, 1 };
                    NSString *ans = YTAIExtractFieldByPath(chunk, chunkLen, kChatItemTail, 15, 0);
                    if (ans.length != 0) return ans;
                }
            }

            NSString *nested = YTAIExtractAnswerFromSubtrees(chunk, chunkLen, depth + 1);
            if (nested.length != 0) return nested;

            pos += chunkLen;
        } else if (wire == 5) {
            if (pos + 4 > length) break;
            pos += 4;
        } else {
            break;
        }
    }
    return nil;
}

static NSString *YTAIExtractAiSummaryFromPayload(NSData *payload) {
    if (payload.length < 100) return nil;
    const uint8_t *bytes = (const uint8_t *)payload.bytes;
    NSUInteger length = payload.length;

    // Layout 1: Primary observed Elements response path in YouTube iOS 21.33.6
    static const NSUInteger kRootPath[] = {
        1, 1, 1, 153515154, 172660663, 1, 168777401, 5, 413471385, 1,
        2465, 3, 36905, 1, 1, 168777401, 5, 413471385, 1, 1382, 2, 2, 1
    };
    NSString *answer = YTAIExtractFieldByPath(bytes, length, kRootPath, 23, 0);
    if (answer.length != 0) return answer;

    // Layout 2: Subtree search for validated basic_content or chat_response_item entities
    answer = YTAIExtractAnswerFromSubtrees(bytes, length, 0);
    if (answer.length != 0) return answer;

    return nil;
}

static NSString *YTAITextFromPayloads(NSArray<NSData *> *payloads) {
    for (NSData *bytes in payloads) {
        if (![bytes isKindOfClass:NSData.class] || bytes.length < 100) continue;
        NSString *answer = YTAIExtractAiSummaryFromPayload(bytes);
        if (answer.length != 0) {
            NSString *trimmed = [answer stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (trimmed.length != 0) return trimmed;
        }
    }
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"extraction-failed",
              @"reason": @"structured-renderer-missing", @"payloads": @(payloads.count)});
    return nil;
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

static void YTAICacheNativeAiAnswer(NSData *bytes) {
    NSString *text = YTAITextFromPayloads(@[bytes]);
    if (text.length == 0) return;
    NSString *videoId = YTRCCurrentVideoId();
    if (videoId.length == 0) return;
    YTAICacheStore(videoId, YTAIFlowTag, text);
    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"native-cached",
              @"chars": @(text.length), @"videoId": videoId});
}

static NSString *YTAIScrapeAiResponseFromUI(void) {
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
                } else if ([view isKindOfClass:UITextView.class]) {
                    if (!view.isFirstResponder && !((UITextView *)view).isEditable) {
                        text = ((UITextView *)view).text;
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

void YTAIFetchSummary(NSString *videoId, void (^completion)(NSString * _Nullable, NSString *)) {
    NSUInteger run = ++YTAIRunToken;
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
    YTAIInstallObservationTraces();
    NSString *prompt = YTAIPromptText;
    NSString *flowTag = YTAIFlowTagForPrompt(prompt);
    NSString *cached = nil;
    if (YTAICacheHit(videoId, flowTag, &cached)) {
        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"cache-hit",
                  @"chars": @(cached.length), @"videoId": videoId, @"flow": flowTag,
                  @"run": @(run)});
        YTAICloseAiPanel();
        done(cached, @"ai-cached");
        return;
    }

    void (^startPlanBReplay)(void) = ^{
        if (run != YTAIRunToken || finished) return;
        NSString *payloadVideoId = nil;
        NSData *payload = YTRCCurrentWatchPayload(&payloadVideoId);
        NSString *token = nil;
        if (payload != nil && [videoId isEqualToString:payloadVideoId])
            token = YTAISummaryTokenInPayload(payload, videoId);
        id dataSource = YTAIAiDataSource ?: YTAIFeedDataSource;
        SEL selector = NSSelectorFromString(
            @"requestInnerTubeContinuationWithContinuationToken:continuationType:clientAttachmentRequestData:"
            @"cacheEnabled:clickTrackingParams:alwaysParseFeedNode:responseBlock:errorBlock:");
        BOOL canReplay = token.length != 0 && dataSource != nil && [dataSource respondsToSelector:selector];
        if (canReplay) {
            id service = nil;
            if ([dataSource respondsToSelector:@selector(service)])
                service = ((id (*)(id, SEL))objc_msgSend)(dataSource, @selector(service));
            YTRCLog(@{@"event": @"ai-summary", @"outcome": @"request-sent",
                      @"tokenLength": @(token.length),
                      @"dataSource": NSStringFromClass([dataSource class]) ?: @"?",
                      @"service": service != nil ? NSStringFromClass([service class]) : @"(none)",
                      @"nativeArgs": @(YTAIHasNativeArgs),
                      @"run": @(run)});
            __block NSMutableArray *items = [NSMutableArray array];
            void (^responseBlock)(id) = ^(id response) {
                if (run != YTAIRunToken || finished) return;
                if ([response isKindOfClass:NSArray.class])
                    [items addObjectsFromArray:(NSArray *)response];
                else if (response != nil)
                    [items addObject:response];
                NSMutableArray<NSData *> *payloads = [NSMutableArray array];
                for (id item in items) {
                    NSError *err = nil;
                    NSData *b = YTRCSerializeMessage(item, 2 * 1024 * 1024, &err);
                    if (b.length != 0) [payloads addObject:b];
                }
                NSString *summary = YTAITextFromPayloads(payloads);
                if (summary.length != 0) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"success",
                              @"items": @(items.count), @"chars": @(summary.length),
                              @"run": @(run)});
                    YTAICacheStore(videoId, flowTag, summary);
                    done(summary, @"ai-fetched");
                } else {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"empty-response",
                              @"items": @(items.count), @"run": @(run)});
                    done(nil, @"ai-empty-response");
                }
            };
            YTAIReplayInFlight = YES;
            @try {
                typedef void (*ReplayFn)(id, SEL, id, unsigned long long, id, BOOL, id, BOOL, id, id);
                ((ReplayFn)objc_msgSend)(dataSource, selector,
                    token, 8, YTAIAttachment, NO, YTAIClickTracking, NO,
                    ^void(id resp, id __unused cont) { responseBlock(resp); },
                    ^void(id __unused a, id __unused b, id __unused c, id detail) {
                        YTAIReplayInFlight = NO;
                        if (run != YTAIRunToken || finished) return;
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"error-detail",
                                  @"detail": [detail description] ?: @"?", @"run": @(run)});
                        done(nil, [@"ai-fetch-failed:" stringByAppendingString:detail ?: @"unknown"]);
                    });
                YTAIReplayInFlight = NO;
            } @catch (NSException *exception) {
                YTAIReplayInFlight = NO;
                if (run != YTAIRunToken || finished) return;
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"exception", @"name": exception.name, @"run": @(run)});
                done(nil, [@"ai-exception:" stringByAppendingString:exception.name ?: @"?"]);
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (run != YTAIRunToken || finished) return;
                done(nil, @"ai-timeout");
            });
            return;
        }
        if (payload == nil || ![videoId isEqualToString:payloadVideoId]) {
            done(nil, @"ai-no-watch-payload");
        } else if (token.length == 0) {
            done(nil, @"ai-no-token");
        } else {
            done(nil, @"ai-no-datasource");
        }
    };

    void (^startUiFlow)(UIView *, UIView *) = ^(UIView *entry, UIView *existingInput) {
        if (run != YTAIRunToken || finished) return;

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
            YTAIPromptSubmitted = NO;
            YTAIPanelRequestObserved = NO;
            YTAISubmitRequestObserved = NO;
            YTAISendChainLogged = NO;
            YTAICaptureItems = [NSMutableArray array];
            YTAICaptureSettle = ^{
                if (run != YTAIRunToken || finished) return;
                NSArray<NSData *> *items;
                @synchronized (YTAICaptureLock()) { items = [YTAICaptureItems copy]; }
                NSString *text = YTAITextFromPayloads(items);
                if (text.length != 0) {
                    YTRCLog(@{@"event": @"ai-summary", @"outcome": @"captured",
                              @"items": @(items.count), @"chars": @(text.length),
                              @"run": @(run)});
                    YTAICacheStore(videoId, flowTag, text);
                    YTAICloseAiPanel();
                    done(text, @"ai-fetched");
                } else {
                    NSString *scraped = YTAIScrapeAiResponseFromUI();
                    if (scraped.length != 0) {
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"ui-scraped",
                                  @"chars": @(scraped.length),
                                  @"run": @(run)});
                        YTAICacheStore(videoId, flowTag, scraped);
                        YTAICloseAiPanel();
                        done(scraped, @"ai-fetched");
                    } else {
                        YTRCLog(@{@"event": @"ai-summary", @"outcome": @"empty-capture",
                                  @"items": @(items.count),
                                  @"run": @(run)});
                        if (focusView != nil) YTAIDumpAiUiFromView(focusView);
                        done(nil, @"ai-empty-capture");
                    }
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
                    YTAIPromptSubmitted = YES;
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
            YTAIPromptSubmitted = YES;
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
            NSString *scraped = YTAIScrapeAiResponseFromUI();
            if (scraped.length != 0) {
                YTRCLog(@{@"event": @"ai-summary", @"outcome": @"ui-scraped-timeout",
                          @"chars": @(scraped.length),
                          @"run": @(run)});
                YTAICacheStore(videoId, flowTag, scraped);
                YTAICloseAiPanel();
                done(scraped, @"ai-fetched");
                return;
            }
            NSString *status = @"ai-timeout";
            if (!opened && !YTAIPanelRequestObserved)
                status = @"ai-panel-failed";
            else if (!inputSeen)
                status = @"ai-input-missing";
            else if (!YTAISubmitRequestObserved)
                status = @"ai-submit-failed";
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
    NSTimeInterval pollInterval = 0.25;
    NSTimeInterval maxWait = 4.0;
    NSDate *startDate = [NSDate date];

    YTAIPollForUIReadiness(startDate, maxWait, pollInterval, run,
        ^(UIView *entry, UIView *existingInput) {
            startUiFlow(entry, existingInput);
        },
        ^{
            YTAIDumpAiUi();
            startPlanBReplay();
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
