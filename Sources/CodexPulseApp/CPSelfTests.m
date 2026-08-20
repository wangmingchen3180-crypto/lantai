#import "CPSelfTests.h"
#import "CodexPulse.h"
#import "CPAppDelegate.h"
#import "CPBridgeServer.h"
#import "CPAgentControl.h"
#import "CPCodexDriver.h"
#import "CPWorkdirStore.h"
#import "CPControlSettingsController.h"
#import <CoreImage/CoreImage.h>
#import <sqlite3.h>
#import <string.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <unistd.h>
#import <errno.h>
#import <sys/time.h>

CPTask *CPTestTask(NSString *taskID, CPStatus status, NSTimeInterval updatedAt) {
    CPTask *t = CPTask.new;
    t.taskID = taskID;
    t.title = taskID;
    t.projectName = @"proj";
    t.projectPath = @"~/proj";
    t.activity = @"activity";
    t.status = status;
    t.updatedAt = [NSDate dateWithTimeIntervalSince1970:updatedAt];
    return t;
}

CPAgent *CPTestAgent(NSString *agentID, NSArray<CPTask *> *tasks) {
    CPAgent *a = CPAgent.new;
    a.agentID = agentID;
    a.name = agentID;
    a.iconName = @"sparkles";
    a.tasks = [NSMutableArray arrayWithArray:tasks];
    return a;
}

static NSDictionary *CPBridgeTestRequest(NSString *method, NSString *url, NSString *token, id jsonBody, NSInteger *statusOut, NSData **rawOut) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    req.HTTPMethod = method;
    req.timeoutInterval = 3;
    if (token.length) [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    if (jsonBody) {
        req.HTTPBody = [NSJSONSerialization dataWithJSONObject:jsonBody options:0 error:nil];
        [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSHTTPURLResponse *resp = nil;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        (void)e;
        data = d;
        resp = [r isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)r : nil;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC));
    if (statusOut) *statusOut = resp.statusCode;
    if (rawOut) *rawOut = data;
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static int CPBridgeTestRawGET(NSInteger port, NSString *path, NSInteger *statusOut, NSMutableString *bodyOut) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct timeval tv = {.tv_sec = 2, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    NSString *req = [NSString stringWithFormat:@"GET %@ HTTP/1.1\r\nHost: 127.0.0.1:%ld\r\n\r\n", path, (long)port];
    NSData *reqData = [req dataUsingEncoding:NSUTF8StringEncoding];
    if (send(fd, reqData.bytes, reqData.length, 0) < (ssize_t)reqData.length) { close(fd); return -1; }
    NSMutableData *buf = NSMutableData.data;
    uint8_t tmp[4096];
    while (buf.length < 65536) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if (n == 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        NSRange hdrEnd = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                                  options:0 range:NSMakeRange(0, buf.length)];
        if (hdrEnd.location == NSNotFound) continue;
        NSString *head = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)]
                                               encoding:NSUTF8StringEncoding];
        NSString *body = [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(hdrEnd.location + 4, buf.length - hdrEnd.location - 4)]
                                               encoding:NSUTF8StringEncoding] ?: @"";
        if ([head containsString:@"text/event-stream"]) {
            if ([body containsString:@"event: snapshot"] && [body containsString:@"\n\n"]) break;
            continue;
        }
        break;
    }
    NSRange hdrEnd = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                              options:0 range:NSMakeRange(0, buf.length)];
    NSString *head = hdrEnd.location == NSNotFound ? @"" :
        [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(0, hdrEnd.location)] encoding:NSUTF8StringEncoding];
    NSString *body = hdrEnd.location == NSNotFound ? @"" :
        [[NSString alloc] initWithData:[buf subdataWithRange:NSMakeRange(hdrEnd.location + 4, buf.length - hdrEnd.location - 4)] encoding:NSUTF8StringEncoding];
    if (statusOut) {
        *statusOut = 0;
        if ([head hasPrefix:@"HTTP/1.1 "] && head.length >= 12) *statusOut = [[head substringWithRange:NSMakeRange(9, 3)] integerValue];
    }
    if (bodyOut && body) [bodyOut setString:body];
    return fd;
}

@interface CPStubControlDriver : NSObject <CPAgentControlDriver>
@property (copy) NSString *agentID;
@property BOOL healthy;
@property (copy) NSArray<NSString *> *controlCapabilities;
@property (copy) NSArray<CPAgentModel *> *availableModels;
@property (copy) NSArray<NSString *> *managedTaskIDs;
@property BOOL shouldSucceed;
@property (copy) NSString *failMessage;
@property (copy) NSString *resultTaskID;
@property NSTimeInterval delay;
@property NSInteger executeCount;
@property CPAgentCommand *lastCommand;
@end

@implementation CPStubControlDriver
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _healthy = YES;
    _shouldSucceed = YES;
    _controlCapabilities = @[@"control", @"interrupt"];
    _availableModels = @[];
    _managedTaskIDs = @[];
    return self;
}
- (BOOL)isHealthy { return self.healthy; }
- (BOOL)isManagedTaskID:(NSString *)taskID {
    return taskID.length && [self.managedTaskIDs containsObject:taskID];
}
- (void)executeCommand:(CPAgentCommand *)command
            completion:(void (^)(BOOL ok, NSString *errorMessage, NSString *resultTaskID))completion {
    @synchronized (self) {
        self.executeCount += 1;
        self.lastCommand = command;
    }
    BOOL ok = self.shouldSucceed;
    NSString *err = ok ? nil : (self.failMessage ?: @"stub_failed");
    NSString *taskID = ok ? (self.resultTaskID ?: command.taskID) : nil;
    NSTimeInterval delay = self.delay;
    void (^done)(void) = ^{
        if (completion) completion(ok, err, taskID);
    };
    if (delay > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), done);
    } else {
        done();
    }
}
@end

@interface CPFakeCodexTransport : NSObject <CPCodexTransport>
@property (copy) void (^onLine)(NSString *line);
@property (copy) void (^onClosed)(void);
@property BOOL alive;
@property BOOL autoHandshake;
@property (readonly) NSMutableArray<NSString *> *sent;
@property (copy) NSDictionary *(^responder)(NSDictionary *request);
- (void)deliverJSON:(id)obj;
- (void)simulateClose;
@end

@implementation CPFakeCodexTransport
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _sent = NSMutableArray.array;
    _autoHandshake = YES;
    return self;
}
- (BOOL)start { _alive = YES; return YES; }
- (void)stop { _alive = NO; }
- (BOOL)isAlive { return _alive; }
- (NSDictionary *)parseLine:(NSString *)line {
    if (!line.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}
- (void)deliverJSON:(id)obj {
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    if (!data || !self.onLine) return;
    self.onLine([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]);
}
- (void)sendLine:(NSString *)line {
    if (line) [_sent addObject:line];
    NSDictionary *msg = [self parseLine:line];
    NSDictionary *reply = self.responder ? self.responder(msg) : nil;
    if (reply) { [self deliverJSON:reply]; return; }
    NSString *method = [msg[@"method"] isKindOfClass:NSString.class] ? msg[@"method"] : nil;
    if (self.autoHandshake && [method isEqualToString:@"initialize"] && msg[@"id"] != nil) {
        [self deliverJSON:@{@"jsonrpc": @"2.0", @"id": msg[@"id"], @"result": @{@"userAgent": @"test"}}];
        return;
    }
    if (self.autoHandshake && [method isEqualToString:@"model/list"] && msg[@"id"] != nil) {
        [self deliverJSON:@{@"jsonrpc": @"2.0", @"id": msg[@"id"], @"result": @{@"data": @[]}}];
    }
}
- (void)simulateClose {
    _alive = NO;
    if (self.onClosed) self.onClosed();
}
@end

static NSDictionary *CPJSONLine(NSString *line) {
    if (!line.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSDictionary *CPFindSentMethod(NSArray<NSString *> *sent, NSString *method) {
    for (NSString *line in sent) {
        NSDictionary *msg = CPJSONLine(line);
        if ([msg[@"method"] isEqualToString:method]) return msg;
    }
    return nil;
}

static CPCodexDriver *CPMakeCodexDriver(CPFakeCodexTransport *transport) {
    CPCodexDriver *driver = [[CPCodexDriver alloc] initWithTransport:transport
                                                          binaryPath:@"/nonexistent/codex"];
    driver.requestTimeout = 2.0;
    return driver;
}

static BOOL CPJSONLeaksWorkdir(id json, NSString *absPath) {
    if (!json) return NO;
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    NSString *text = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
    if ([text containsString:@"\"workdir\""]) return YES;
    return absPath.length && [text containsString:absPath];
}

static BOOL CPWaitFlag(BOOL *flag, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!*flag && [deadline timeIntervalSinceNow] > 0) usleep(10000);
    return *flag;
}

static CPAgentCommand *CPMakeCmd(CPCommandAction action, NSString *taskID, NSString *text) {
    CPAgentCommand *cmd = CPAgentCommand.new;
    cmd.commandID = NSUUID.UUID.UUIDString;
    cmd.action = action;
    cmd.agentID = @"codex";
    cmd.taskID = taskID;
    cmd.text = text;
    return cmd;
}

static NSDictionary *CPBridgeWaitCommand(NSString *base, NSString *token, NSString *commandID,
                                         NSString *wantState, NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    NSDictionary *last = nil;
    while ([deadline timeIntervalSinceNow] > 0) {
        NSInteger status = 0;
        last = CPBridgeTestRequest(@"GET", [NSString stringWithFormat:@"%@/api/commands/%@", base, commandID],
                                   token, nil, &status, nil);
        if (status == 200 && [last[@"command"][@"state"] isEqualToString:wantState]) return last;
        usleep(20000);
    }
    return last;
}

static BOOL CPBridgeTestWaitSSE(int fd, NSMutableString *bodyOut, NSString *needle, NSTimeInterval timeout) {
    if ([bodyOut containsString:needle]) return YES;
    uint8_t tmp[4096];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n < 0) {
            if (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) continue;
            break;
        }
        if (n == 0) break;
        NSString *chunk = [[NSString alloc] initWithBytes:tmp length:(NSUInteger)n encoding:NSUTF8StringEncoding];
        if (chunk) [bodyOut appendString:chunk];
        if ([bodyOut containsString:needle]) return YES;
    }
    return [bodyOut containsString:needle];
}

static NSDictionary *CPBridgeFindAgent(NSDictionary *snap, NSString *agentID) {
    NSArray *agents = [snap[@"agents"] isKindOfClass:NSArray.class] ? snap[@"agents"] : @[];
    for (id row in agents) {
        if ([row isKindOfClass:NSDictionary.class] && [row[@"agentID"] isEqualToString:agentID]) return row;
    }
    return nil;
}

static NSDictionary *CPBridgeFindTask(NSDictionary *agent, NSString *taskID) {
    NSArray *tasks = [agent[@"tasks"] isKindOfClass:NSArray.class] ? agent[@"tasks"] : @[];
    for (id row in tasks) {
        if ([row isKindOfClass:NSDictionary.class] && [row[@"taskID"] isEqualToString:taskID]) return row;
    }
    return nil;
}

static void CPActivityNotify(CPFakeCodexTransport *transport, NSString *method, NSDictionary *params) {
    [transport deliverJSON:@{@"jsonrpc": @"2.0", @"method": method, @"params": params ?: @{}}];
}

// 排空两条队列:先 driver(dispatch_sync 到它的串行队列),再 Bridge。全程不睡墙钟。
static void CPActivitySettle(CPCodexDriver *driver, CPBridgeServer *bridge) {
    [driver isManagedTaskID:@"drain"];
    [bridge activityEventCountForTesting];
}

static NSArray<NSDictionary *> *CPActivityEntriesOf(CPBridgeServer *bridge, NSString *taskID) {
    NSDictionary *stream = [bridge activityStreamJSONForAgentID:@"codex" taskID:taskID];
    id rows = stream[@"entries"];
    return [rows isKindOfClass:NSArray.class] ? rows : @[];
}

static NSArray<NSString *> *CPActivityKindsOf(NSArray<NSDictionary *> *entries) {
    NSMutableArray<NSString *> *kinds = NSMutableArray.array;
    for (NSDictionary *row in entries) [kinds addObject:row[@"kind"] ?: @""];
    return kinds;
}

static BOOL CPActivitySeqMonotonic(NSArray<NSDictionary *> *entries) {
    NSInteger previous = 0;
    for (NSDictionary *row in entries) {
        NSInteger seq = [row[@"seq"] integerValue];
        if (seq <= previous) return NO;
        previous = seq;
    }
    return entries.count > 0;
}

static NSDictionary *CPActivityLastSSEEvent(NSString *body) {
    NSDictionary *last = nil;
    for (NSString *frame in [body componentsSeparatedByString:@"\n\n"]) {
        NSRange marker = [frame rangeOfString:@"event: activity\ndata: "];
        if (marker.location == NSNotFound) continue;
        NSDictionary *obj = CPJSONLine([frame substringFromIndex:NSMaxRange(marker)]);
        if (obj) last = obj;
    }
    return last;
}

BOOL CPAnotherInstanceIsRunning(void) {
    NSString *bundleIdentifier = @"com.codexpulse.menubar";
    pid_t currentPID = NSProcessInfo.processInfo.processIdentifier;
    for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
        if (application.processIdentifier == currentPID) continue;
        BOOL sameBundle = [application.bundleIdentifier isEqualToString:bundleIdentifier];
        BOOL sameExecutable = [application.executableURL.lastPathComponent isEqualToString:@"CodexPulse"];
        if (sameBundle || sameExecutable) {
            [application activateWithOptions:0];
            return YES;
        }
    }
    return NO;
}


int CPRunUISelfTests(int argc, const char *argv[]) {
            CPRunningSelfTests = YES;
            CPTodoUseIsolatedStore = YES;
            [NSApplication sharedApplication];

            CPWorkbenchCardController *card = CPWorkbenchCardController.new;
            // 展开状态来自用户 defaults,几何断言必须确定:统一按收起态测试。
            card.todoExpanded = NO;
            [card applyTodoExpandedState];
            NSScreen *screen = CPTargetScreen();
            NSRect visible = screen ? screen.visibleFrame : NSZeroRect;
            BOOL hasScreen = !NSEqualRects(visible, NSZeroRect);
            NSRect testVisible = hasScreen ? visible : NSMakeRect(0, 0, 1680, 1050);
            NSRect cardFrame = [card targetFrameInVisibleRect:testVisible];
            BOOL centered = fabs(NSMidX(cardFrame) - NSMidX(testVisible)) <= 1.0 &&
                            fabs(NSMidY(cardFrame) - NSMidY(testVisible)) <= 1.0;
            BOOL draggableHeader = [card.card.subviews.firstObject isKindOfClass:CPDraggableHeaderView.class];

            // Workbench structural / geometry checks
            BOOL cardMasksToBounds = card.card.layer.masksToBounds;
            BOOL shadowCarrierNoMasks = !card.shadowCarrier.layer.masksToBounds;
            BOOL cardIsChildOfShadowCarrier = card.card.superview == card.shadowCarrier;
            BOOL windowHasWorkbenchInset = fabs(card.window.frame.size.width - (CPCardWidth + CPWorkbenchInset * 2.0)) <= 0.5 &&
                                           fabs(card.window.frame.size.height - (card.cardHeight + CPWorkbenchInset * 2.0)) <= 0.5;
            BOOL fixedCardSize = fabs(card.card.frame.size.width - 520.0) <= 0.5 &&
                                 fabs(card.card.frame.size.height - (360.0 + CPTodoCollapsedHeight)) <= 0.5; // 内容区 360 + 收起态 Todo 卡片 42
            NSStackView *columnsStack = (NSStackView *)card.leftColumn.superview;
            BOOL twoColumn = [columnsStack isKindOfClass:NSStackView.class] &&
                             columnsStack.arrangedSubviews.count == 2 &&
                             card.middleColumn.superview == columnsStack;
            BOOL rightOverlayHidden = card.rightColumn.hidden &&
                                      card.rightColumn.superview == card.middleColumn;

            // Bugfix 回归：不同长度 Agent 名称的状态灯必须落在同一固定列。
            CPAgent *shortNameAgent = CPTestAgent(@"short-name", @[CPTestTask(@"short-task", CPStatusWorking, 1)]);
            shortNameAgent.name = @"A";
            CPAgent *longNameAgent = CPTestAgent(@"long-name", @[CPTestTask(@"long-task", CPStatusWaiting, 2)]);
            longNameAgent.name = @"VeryLongAgentName";
            [card renderAgents:@[shortNameAgent, longNameAgent]];
            [card.leftColumn layoutSubtreeIfNeeded];
            BOOL agentStatusDotsAligned = NO;
            if (card.agentStack.arrangedSubviews.count >= 3) {
                NSButton *shortRow = (NSButton *)card.agentStack.arrangedSubviews[1];
                NSButton *longRow = (NSButton *)card.agentStack.arrangedSubviews[2];
                NSStackView *shortContent = (NSStackView *)shortRow.subviews.firstObject;
                NSStackView *longContent = (NSStackView *)longRow.subviews.firstObject;
                if ([shortContent isKindOfClass:NSStackView.class] && [longContent isKindOfClass:NSStackView.class] &&
                    shortContent.arrangedSubviews.count == 3 && longContent.arrangedSubviews.count == 3) {
                    NSView *shortDot = shortContent.arrangedSubviews.lastObject;
                    NSView *longDot = longContent.arrangedSubviews.lastObject;
                    NSRect shortDotFrame = [shortDot convertRect:shortDot.bounds toView:card.agentStack];
                    NSRect longDotFrame = [longDot convertRect:longDot.bounds toView:card.agentStack];
                    agentStatusDotsAligned = fabs(NSMidX(shortDotFrame) - NSMidX(longDotFrame)) <= 0.5;
                }
            }

            // Bugfix 回归：打开“需关注”详情后，悬浮球角标应通过通知立即清除。
            NSString *bugSuite = [NSString stringWithFormat:@"com.codexpulse.bugfix-ui.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *bugDefaults = [[NSUserDefaults alloc] initWithSuiteName:bugSuite];
            [bugDefaults removePersistentDomainForName:bugSuite];
            CPReviewStore *bugStore = [[CPReviewStore alloc] initWithDefaults:bugDefaults];
            CPTask *attentionTaskUI = CPTestTask(@"attention-ui", CPStatusAttention, 3000);
            CPAgent *attentionAgentUI = CPTestAgent(@"attention-agent-ui", @[attentionTaskUI]);
            CPWorkbenchCardController *bugCard = CPWorkbenchCardController.new;
            bugCard.reviewStore = bugStore;
            [bugCard renderAgents:@[attentionAgentUI]];
            CPDockWindowController *bugDock = CPDockWindowController.new;
            bugDock.reviewStore = bugStore;
            [bugDock setMode:0];
            [bugDock renderWithAgents:@[attentionAgentUI] selectedAgent:attentionAgentUI];
            BOOL attentionBadgeInitiallyVisible = !bugDock.badgeView.hidden;
            id bugToken = [NSNotificationCenter.defaultCenter addObserverForName:@"CPTaskReviewed"
                                                                          object:nil
                                                                           queue:nil
                                                                      usingBlock:^(NSNotification *note) {
                (void)note;
                [bugDock renderWithAgents:@[attentionAgentUI] selectedAgent:attentionAgentUI];
            }];
            CPWorkbenchTaskRowButton *attentionRow = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            attentionRow.agentID = attentionAgentUI.agentID;
            attentionRow.taskID = attentionTaskUI.taskID;
            [bugCard taskClicked:attentionRow];
            BOOL attentionBadgeClearsOnOpen = attentionBadgeInitiallyVisible && bugDock.badgeView.hidden &&
                                              [bugStore isTaskReviewed:attentionTaskUI agentID:attentionAgentUI.agentID];
            [NSNotificationCenter.defaultCenter removeObserver:bugToken];
            [bugDefaults removePersistentDomainForName:bugSuite];
            [bugDefaults synchronize];

            NSArray<CPAgent *> *agents = [CPStateReader.new readAgents];
            CPDockWindowController *dock = CPDockWindowController.new;
            [dock renderWithAgents:agents selectedAgent:agents.firstObject];
            [dock setMode:1];
            [dock.barView layoutSubtreeIfNeeded];
            [dock.pill layoutSubtreeIfNeeded];

            BOOL labeledWorkbench = [dock.barLogoButton.title isEqualToString:@"工作台"] &&
                                    [dock.barLogoButton.toolTip containsString:@"工作台"];
            // Dock bar 只放真实(非占位)Agent:Kimi 已接入真实数据源,预期数量按当前 agents 动态计算。
            NSInteger expectedRealAgents = 0;
            for (CPAgent *a in agents) if (!a.placeholder) expectedRealAgents++;
            BOOL onlyRealAgents = dock.barAgentStack.arrangedSubviews.count == (NSUInteger)expectedRealAgents;
            NSButton *agentButton = (NSButton *)dock.barAgentStack.arrangedSubviews.firstObject;
            BOOL labeledAgent = [agentButton isKindOfClass:NSButton.class] &&
                                [agentButton.title hasPrefix:@"Codex · "] &&
                                agentButton.toolTip.length > 0;
            NSPoint buttonCenter = NSMakePoint(NSMidX(dock.barLogoButton.bounds), NSMidY(dock.barLogoButton.bounds));
            NSPoint pillPoint = [dock.barLogoButton convertPoint:buttonCenter toView:dock.pill];
            BOOL buttonReceivesClick = [dock.pill hitTest:pillPoint] == dock.barLogoButton;

            // HUD structural / geometry checks
            CPHUDWindowController *hud = CPHUDWindowController.new;
            NSRect collapsedFrame = [hud collapsedFrameInVisibleRect:testVisible];
            NSRect expandedFrame = [hud expandedFrameInVisibleRect:testVisible];
            NSSize collapsedSize = collapsedFrame.size;
            NSSize expandedSize = expandedFrame.size;
            BOOL hudCollapsed6x72 = fabs(collapsedSize.width - CPHUDCollapsedWidth) <= 0.5 &&
                                    fabs(collapsedSize.height - CPHUDCollapsedHeight) <= 0.5;
            BOOL hudCollapsedOnMainScreen = fabs(collapsedFrame.origin.x - (NSMaxX(testVisible) - CPHUDCollapsedWidth)) <= 0.5 &&
                                            fabs(collapsedFrame.origin.y - (NSMaxY(testVisible) - CPHUDCollapsedHeight)) <= 0.5;
            BOOL hudExpandedSizeOK = fabs(expandedSize.width - (CPHUDContentWidth + CPHUDInset * 2.0)) <= 0.5 &&
                                     fabs(expandedSize.height - (CPHUDContentHeight + CPHUDInset * 2.0)) <= 0.5;
            BOOL hudExpandedOnMainScreen = fabs(expandedFrame.origin.x - (NSMaxX(testVisible) - expandedSize.width)) <= 0.5 &&
                                           fabs(expandedFrame.origin.y - (NSMaxY(testVisible) - expandedSize.height)) <= 0.5;
            BOOL shadowCarrierScales = hud.shadowCarrier.autoresizingMask == (NSViewWidthSizable | NSViewHeightSizable);
            BOOL handleAnchoredTopRight = hud.handleView.autoresizingMask == (NSViewMinXMargin | NSViewMinYMargin);
            BOOL contentNotSizable = hud.visualView.autoresizingMask == NSViewNotSizable;
            BOOL hudClickViewIsBackgroundView = [hud.backgroundClickView isKindOfClass:CPHUDBackgroundView.class] &&
                                                hud.backgroundClickView.superview == hud.container;

            [hud expand];
            [hud.shadowCarrier layoutSubtreeIfNeeded];
            NSRect visualFrame = hud.visualView.frame;
            BOOL hudVisualFrameExact = fabs(visualFrame.origin.x - CPHUDInset) <= 0.5 &&
                                       fabs(visualFrame.origin.y - CPHUDInset) <= 0.5 &&
                                       fabs(visualFrame.size.width - CPHUDContentWidth) <= 0.5 &&
                                       fabs(visualFrame.size.height - CPHUDContentHeight) <= 0.5;
            BOOL hudExpandedHandleHidden = hud.handleView.hidden;

            // 快速进出回归:展开动画进行中立即收回、再立即展开,旧的 completion 不得
            // 把 visualView 隐藏或把手重新显示(动画代际守卫)。
            CPHUDWindowController *hudRapid = CPHUDWindowController.new;
            [hudRapid.window orderFrontRegardless];
            [hudRapid expand];
            [hudRapid collapse];
            [hudRapid expand];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
            BOOL hudRapidOK = hudRapid.expanded && !hudRapid.visualView.hidden && hudRapid.handleView.hidden;
            [hudRapid.window orderOut:nil];

            // M2: CPAgentStatusButton rings, reduce-motion, HUD per-agent scoping
            NSString *uiSuite = [NSString stringWithFormat:@"com.codexpulse.uitest.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *uiDefaults = [[NSUserDefaults alloc] initWithSuiteName:uiSuite];
            [uiDefaults removePersistentDomainForName:uiSuite];
            CPReviewStore *uiStore = [[CPReviewStore alloc] initWithDefaults:uiDefaults];

            BOOL ringColorsOK = YES;
            BOOL blueDoubleOK = YES;
            BOOL reduceMotionOK = YES;
            NSArray<NSNumber *> *allStatuses = @[@(CPDisplayStatusFailed), @(CPDisplayStatusWaiting),
                                                 @(CPDisplayStatusCompletedPendingReview), @(CPDisplayStatusWorking),
                                                 @(CPDisplayStatusIdle)];
            for (NSNumber *st in allStatuses) {
                CPDisplayStatus s = (CPDisplayStatus)st.integerValue;
                CPAgentStatusButton *b = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
                b.reduceMotion = YES;
                [b updateWithAgent:CPTestAgent(@"ring-test", @[]) displayStatus:s selected:NO];
                if (!CGColorEqualToColor(b.ringLayer.strokeColor, CPDisplayStatusColor(s).CGColor)) ringColorsOK = NO;
                BOOL expectDouble = s == CPDisplayStatusCompletedPendingReview;
                if (b.innerRingLayer.hidden != !expectDouble) blueDoubleOK = NO;
                if (expectDouble && !CGColorEqualToColor(b.innerRingLayer.strokeColor, CPBlue().CGColor)) blueDoubleOK = NO;
                // reduce motion:无任何 CAAnimation,8 对波层全隐藏,只保留固定状态环。
                if (b.ringLayer.animationKeys.count != 0 || b.innerRingLayer.animationKeys.count != 0 ||
                    b.ringLayer.hidden || b.rippleLayers.count != CPRippleLayerCount ||
                    b.rippleTroughLayers.count != CPRippleLayerCount) reduceMotionOK = NO;
                for (NSInteger li = 0; li < CPRippleLayerCount; li++) {
                    if (!b.rippleLayers[(NSUInteger)li].hidden || b.rippleLayers[(NSUInteger)li].animationKeys.count != 0 ||
                        !b.rippleTroughLayers[(NSUInteger)li].hidden || b.rippleTroughLayers[(NSUInteger)li].animationKeys.count != 0)
                        reduceMotionOK = NO;
                }
            }
            // 8 层定稿涟漪:选中时常开,层间错峰 duration/8(基准 12s 即 1.5s),周期取定稿时长表。
            CPAgentStatusButton *motionBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
            motionBtn.reduceMotion = NO;
            [motionBtn updateWithAgent:CPTestAgent(@"motion-test", @[]) displayStatus:CPDisplayStatusWorking selected:YES];
            CGFloat motionDuration = CPRippleDurationForStatus(CPDisplayStatusWorking);
            BOOL motionAnimOK = YES;
            for (NSInteger li = 0; li < CPRippleLayerCount; li++) {
                CAAnimation *crest = [motionBtn.rippleLayers[(NSUInteger)li]
                                      animationForKey:[NSString stringWithFormat:@"ripple%ld", (long)li]];
                CAAnimation *trough = [motionBtn.rippleTroughLayers[(NSUInteger)li]
                                       animationForKey:[NSString stringWithFormat:@"trough%ld", (long)li]];
                CGFloat expectOffset = motionDuration * (CGFloat)li / (CGFloat)CPRippleLayerCount;
                if (!crest || !trough ||
                    fabs(crest.timeOffset - expectOffset) > 0.01 ||
                    fabs(crest.duration - motionDuration) > 0.01 ||
                    fabs(trough.duration - motionDuration) > 0.01 ||
                    crest.repeatCount <= 1000.0f || trough.repeatCount <= 1000.0f) motionAnimOK = NO;
            }
            // 未选中:涟漪静止(无动画、波层隐藏)。
            CPAgentStatusButton *stillBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
            stillBtn.reduceMotion = NO;
            [stillBtn updateWithAgent:CPTestAgent(@"still-test", @[]) displayStatus:CPDisplayStatusWorking selected:NO];
            for (NSInteger li = 0; li < CPRippleLayerCount; li++) {
                if (stillBtn.rippleLayers[(NSUInteger)li].animationKeys.count != 0 ||
                    !stillBtn.rippleLayers[(NSUInteger)li].hidden) motionAnimOK = NO;
            }
            // 曲线必须与 CPRippleView 同一定稿规范:scale 1.0→1.55,透明度 0→峰值→长尾巴→0,
            // lineWidth 2.0→0.5,缓入缓出控制点 (0.45,0.08,0.35,1)。
            CAAnimation *ripple0 = [motionBtn.rippleLayers.firstObject animationForKey:@"ripple0"];
            if ([ripple0 isKindOfClass:CAAnimationGroup.class]) {
                CAAnimationGroup *g = (CAAnimationGroup *)ripple0;
                CABasicAnimation *scale = nil, *thin = nil;
                CAKeyframeAnimation *fade = nil;
                for (CAAnimation *anim in g.animations) {
                    CAPropertyAnimation *pa = (CAPropertyAnimation *)anim;
                    if ([pa.keyPath isEqualToString:@"transform.scale"]) scale = (CABasicAnimation *)anim;
                    if ([pa.keyPath isEqualToString:@"opacity"]) fade = (CAKeyframeAnimation *)anim;
                    if ([pa.keyPath isEqualToString:@"lineWidth"]) thin = (CABasicAnimation *)anim;
                }
                float cp1[2] = {0, 0}, cp2[2] = {0, 0};
                [g.timingFunction getControlPointAtIndex:1 values:cp1];
                [g.timingFunction getControlPointAtIndex:2 values:cp2];
                CGFloat peak = fade.values.count > 1 ? [(NSNumber *)fade.values[1] doubleValue] : 0.0;
                BOOL fadeMonotoneTail = fade.values.count == 6 &&
                                        peak > [(NSNumber *)fade.values[2] doubleValue] &&
                                        [(NSNumber *)fade.values[2] doubleValue] > [(NSNumber *)fade.values[3] doubleValue] &&
                                        [(NSNumber *)fade.values[3] doubleValue] > [(NSNumber *)fade.values[4] doubleValue] &&
                                        [(NSNumber *)fade.values[4] doubleValue] > 0.0 &&
                                        fabs([(NSNumber *)fade.values[0] doubleValue]) < 0.001 &&
                                        fabs([(NSNumber *)fade.values[5] doubleValue]) < 0.001;
                motionAnimOK = motionAnimOK && scale && fade && thin && fadeMonotoneTail &&
                               fabs([(NSNumber *)scale.fromValue doubleValue] - 1.0) < 0.01 &&
                               fabs([(NSNumber *)scale.toValue doubleValue] - 1.55) < 0.01 &&
                               peak >= 0.15 && peak <= 0.30 && // 白峰峰值 alpha ~0.22(范围断言)
                               fabs([(NSNumber *)thin.fromValue doubleValue] - 2.0) < 0.01 &&
                               fabs([(NSNumber *)thin.toValue doubleValue] - 0.5) < 0.01 &&
                               fabs(cp1[0] - 0.45) < 0.01 && fabs(cp1[1] - 0.08) < 0.01 &&
                               fabs(cp2[0] - 0.35) < 0.01 && fabs(cp2[1] - 1.0) < 0.01;
            } else {
                motionAnimOK = NO;
            }
            // 波层 z 序:白峰/黑谷在状态环之下(iconView 是 subview,天然压在所有波层之上)。
            motionAnimOK = motionAnimOK &&
                           [motionBtn.layer.sublayers indexOfObject:motionBtn.rippleTroughLayers.firstObject] <
                               [motionBtn.layer.sublayers indexOfObject:motionBtn.ringLayer] &&
                           [motionBtn.layer.sublayers indexOfObject:motionBtn.rippleLayers.lastObject] <
                               [motionBtn.layer.sublayers indexOfObject:motionBtn.ringLayer];
            CPAgentStatusButton *blueBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
            blueBtn.reduceMotion = NO;
            [blueBtn updateWithAgent:CPTestAgent(@"blue-test", @[]) displayStatus:CPDisplayStatusCompletedPendingReview selected:YES];
            BOOL blueAnimOK = [blueBtn.innerRingLayer.animationKeys containsObject:@"rippleInner"] &&
                              CGColorEqualToColor(blueBtn.ringLayer.strokeColor, CPBlue().CGColor) &&
                              CGColorEqualToColor(blueBtn.innerRingLayer.strokeColor, CPBlue().CGColor) &&
                              CGColorEqualToColor(blueBtn.rippleLayers.firstObject.strokeColor, NSColor.whiteColor.CGColor) &&
                              CGColorEqualToColor(blueBtn.rippleTroughLayers.firstObject.strokeColor, NSColor.blackColor.CGColor);
            for (NSInteger li = 0; li < CPRippleLayerCount; li++) {
                if (![blueBtn.rippleLayers[(NSUInteger)li].animationKeys
                      containsObject:[NSString stringWithFormat:@"ripple%ld", (long)li]]) blueAnimOK = NO;
            }

            // 方向 A 选中态回归:背景完全透明、无描边(borderWidth=0)、无左侧指示条 view、
            // 状态环实色(opacity≈1)且线宽 2;图标 ≤14pt。
            CPAgentStatusButton *selBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 30)];
            selBtn.reduceMotion = YES;
            [selBtn updateWithAgent:CPTestAgent(@"sel-test", @[]) displayStatus:CPDisplayStatusWorking selected:YES];
            CGColorRef selBtnBg = selBtn.layer.backgroundColor;
            BOOL selectionNoVeilOK = (!selBtnBg || CGColorGetAlpha(selBtnBg) == 0.0) &&
                                     selBtn.layer.borderWidth == 0.0 &&
                                     fabs(selBtn.ringLayer.opacity - 1.0) < 0.01 &&
                                     fabs(selBtn.ringLayer.lineWidth - 2.0) < 0.01 &&
                                     selBtn.iconView.frame.size.width <= 14.0;
            CPAgentStatusButton *hovBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 30)];
            hovBtn.reduceMotion = YES;
            [hovBtn updateWithAgent:CPTestAgent(@"hov-test", @[]) displayStatus:CPDisplayStatusWorking selected:NO];
            NSEvent *noEvent = nil; // 仅触发 hover 状态翻转,事件本身不被使用
            [hovBtn mouseEntered:noEvent];
            CGColorRef hovBg = hovBtn.layer.backgroundColor;
            // hover 未选中项:只把环透明度提到 ~0.55,背景蒙层 alpha 必须 ≤0.03,不起涟漪。
            BOOL hoverSubtleOK = (!hovBg || CGColorGetAlpha(hovBg) <= 0.03) &&
                                 fabs(hovBtn.ringLayer.opacity - 0.55) < 0.01 &&
                                 hovBtn.rippleLayers.firstObject.animationKeys.count == 0;
            [hovBtn mouseExited:noEvent];
            hoverSubtleOK = hoverSubtleOK && fabs(hovBtn.ringLayer.opacity - 0.28) < 0.01;

            CPHUDWindowController *hud2 = CPHUDWindowController.new;
            hud2.reviewStore = uiStore;
            CPAgent *agentA = CPTestAgent(@"agent-a", @[CPTestTask(@"a1", CPStatusWorking, 1),
                                                        CPTestTask(@"a2", CPStatusWaiting, 2)]);
            CPAgent *agentB = CPTestAgent(@"agent-b", @[CPTestTask(@"b1", CPStatusWorking, 1)]);
            [hud2 updateWithAgents:@[agentA, agentB] selectedAgent:agentB];
            BOOL hudAgentScope = [hud2.selectedAgent.agentID isEqualToString:@"agent-b"] &&
                                 hud2.taskList.arrangedSubviews.count == 1;
            if (hudAgentScope) {
                NSView *row = hud2.taskList.arrangedSubviews.firstObject;
                NSStackView *hStack = (NSStackView *)row.subviews.firstObject;
                NSStackView *labelStack = hStack.arrangedSubviews.count > 1 ? (NSStackView *)hStack.arrangedSubviews[1] : nil;
                NSTextField *titleLabel = labelStack.arrangedSubviews.count ? (NSTextField *)labelStack.arrangedSubviews.firstObject : nil;
                hudAgentScope = [titleLabel isKindOfClass:NSTextField.class] &&
                                [titleLabel.stringValue isEqualToString:@"b1"];
            }
            CPAgent *agentANew = CPTestAgent(@"agent-a", @[CPTestTask(@"a9", CPStatusWorking, 9)]);
            CPAgent *agentBNew = CPTestAgent(@"agent-b", @[CPTestTask(@"b9", CPStatusWorking, 9)]);
            [hud2 updateWithAgents:@[agentANew, agentBNew] selectedAgent:agentB]; // stale pointer, same agentID
            BOOL hudSelectByID = hud2.selectedAgent == agentBNew;
            // Agent 环颜色跟随最近更新的任务；较旧失败项不会压住较新的完成状态。
            CPAgent *urgent = CPTestAgent(@"urgent", @[CPTestTask(@"u1", CPStatusWorking, 1),
                                                       CPTestTask(@"u2", CPStatusFailed, 2),
                                                       CPTestTask(@"u3", CPStatusCompleted, 3)]);
            CPAgent *calm = CPTestAgent(@"calm", @[CPTestTask(@"c1", CPStatusWorking, 1)]);
            [hud2 updateWithAgents:@[urgent, calm] selectedAgent:calm];
            CPAgentStatusButton *urgentBtn = (CPAgentStatusButton *)hud2.agentList.arrangedSubviews.firstObject;
            BOOL agentUrgencyOK = [urgentBtn isKindOfClass:CPAgentStatusButton.class] &&
                                  CGColorEqualToColor(urgentBtn.ringLayer.strokeColor, CPBlue().CGColor) &&
                                  fabs(CPRippleDurationForStatus(CPDisplayStatusForTasks(urgent.tasks, @"urgent", uiStore)) -
                                       CPRippleDurationForStatus(CPDisplayStatusCompletedPendingReview)) < 0.01;
            [uiDefaults removePersistentDomainForName:uiSuite];
            [uiDefaults synchronize];

            BOOL m2ui = ringColorsOK && blueDoubleOK && reduceMotionOK && motionAnimOK && blueAnimOK &&
                        selectionNoVeilOK && hoverSubtleOK && hudAgentScope && hudSelectByID && agentUrgencyOK;

            // M3: detail drawer + two-stage Esc + review only on real detail open
            NSString *m3Suite = [NSString stringWithFormat:@"com.codexpulse.drawertest.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *m3Defaults = [[NSUserDefaults alloc] initWithSuiteName:m3Suite];
            [m3Defaults removePersistentDomainForName:m3Suite];
            CPWorkbenchCardController *card2 = CPWorkbenchCardController.new;
            card2.reviewStore = [[CPReviewStore alloc] initWithDefaults:m3Defaults];
            CPAgent *workAgent = CPTestAgent(@"w-agent", @[CPTestTask(@"w1", CPStatusWorking, 1),
                                                           CPTestTask(@"w2", CPStatusCompleted, 2)]);
            [card2 renderAgents:@[workAgent]];
            BOOL drawerInitiallyHidden = card2.rightColumn.hidden;
            BOOL renderDoesNotMark = ![card2.reviewStore isTaskReviewed:workAgent.tasks[1] agentID:@"w-agent"] &&
                                     ![card2.reviewStore isTaskReviewed:workAgent.tasks[0] agentID:@"w-agent"];

            CPWorkbenchTaskRowButton *fakeRow = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            fakeRow.agentID = @"w-agent";
            fakeRow.taskID = @"w2"; // completed task w2
            [card2 taskClicked:fakeRow];
            BOOL drawerShownOnClick = !card2.rightColumn.hidden &&
                                      card2.rightColumn.superview == card2.middleColumn;
            BOOL reviewMarkedOnOpen = [card2.reviewStore isTaskReviewed:workAgent.tasks[1] agentID:@"w-agent"];

            // ghost: 点击时 taskID 已不在当前数据 → 不动作、不伪造已查看、不改选中
            CPTask *keptTask = card2.selectedTask;
            CPWorkbenchTaskRowButton *ghostRow = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            ghostRow.agentID = @"w-agent";
            ghostRow.taskID = @"ghost-gone";
            [card2 taskClicked:ghostRow];
            BOOL m3GhostOK = card2.selectedTask == keptTask &&
                             !card2.rightColumn.hidden &&
                             ![card2.reviewStore isTaskReviewed:CPTestTask(@"ghost-gone", CPStatusCompleted, 1) agentID:@"w-agent"];

            [card2.window orderFrontRegardless];
            [card2 handleEscape];
            BOOL firstEscDrawerOnly = card2.rightColumn.hidden && card2.window.isVisible;
            [card2 handleEscape];
            BOOL secondEscClosesWorkbench = !card2.window.isVisible;
            [m3Defaults removePersistentDomainForName:m3Suite];
            [m3Defaults synchronize];

            BOOL m3ui = drawerInitiallyHidden && renderDoesNotMark && drawerShownOnClick &&
                        reviewMarkedOnOpen && m3GhostOK && firstEscDrawerOnly && secondEscClosesWorkbench;

            // M3 entries: every entry shows-and-fronts, never toggles closed
            CPWorkbenchCardController *card3 = CPWorkbenchCardController.new;
            card3.todoExpanded = NO;
            [card3 applyTodoExpandedState];
            NSRect fakeDockRect = NSMakeRect(NSMaxX(testVisible) - 56, NSMidY(testVisible), 56, 56);
            [card3 showNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            [card3 showNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            [card3 showNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            NSRect expectedTarget = [card3 targetFrameNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            BOOL reshowVisible = card3.window.isVisible;
            BOOL reshowCentered = NSEqualRects(card3.window.frame, expectedTarget);
            BOOL reshowFixedSize = fabs(card3.window.frame.size.width - (CPCardWidth + CPWorkbenchInset * 2.0)) <= 0.5 &&
                                   fabs(card3.window.frame.size.height - (card3.cardHeight + CPWorkbenchInset * 2.0)) <= 0.5;
            BOOL m3entries = reshowVisible && reshowCentered && reshowFixedSize;

            // M4: refresh stability — ID-based remapping, no defaults writes, no stacked animations
            NSString *m4Suite = [NSString stringWithFormat:@"com.codexpulse.refreshtest.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *m4Defaults = [[NSUserDefaults alloc] initWithSuiteName:m4Suite];
            [m4Defaults removePersistentDomainForName:m4Suite];
            CPWorkbenchCardController *card4 = CPWorkbenchCardController.new;
            card4.reviewStore = [[CPReviewStore alloc] initWithDefaults:m4Defaults];
            CPAgent *m4Agent = CPTestAgent(@"m4-agent", @[CPTestTask(@"m4t1", CPStatusWorking, 1),
                                                          CPTestTask(@"m4t2", CPStatusCompleted, 2)]);
            [card4 renderAgents:@[m4Agent]];
            CPWorkbenchTaskRowButton *m4Row = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            m4Row.agentID = @"m4-agent";
            m4Row.taskID = @"m4t2";
            [card4 taskClicked:m4Row]; // open detail drawer for completed task
            CPAgent *m4AgentNew = CPTestAgent(@"m4-agent", @[CPTestTask(@"m4t1", CPStatusWorking, 3),
                                                             CPTestTask(@"m4t2", CPStatusCompleted, 4)]);
            [card4 renderAgents:@[m4AgentNew]]; // refresh with new instances, same IDs
            BOOL refreshNewInstances = card4.selectedAgent == m4AgentNew &&
                                       card4.selectedTask == m4AgentNew.tasks[1];
            BOOL drawerKeptOnRefresh = !card4.rightColumn.hidden;
            BOOL refreshNoMark = ![card4.reviewStore isTaskReviewed:m4AgentNew.tasks[1] agentID:@"m4-agent"] &&
                                 ![card4.reviewStore isTaskReviewed:m4AgentNew.tasks[0] agentID:@"m4-agent"];

            CPAgent *m4Other = CPTestAgent(@"m4-other", @[CPTestTask(@"o1", CPStatusWorking, 1)]);
            [card4 renderAgents:@[m4Other]]; // agent disappears → fallback, drawer closed
            BOOL agentFallback = card4.selectedAgent == m4Other &&
                                 card4.selectedTask == nil &&
                                 card4.rightColumn.hidden;

            [card4 renderAgents:@[m4AgentNew]]; // reselect m4-agent
            CPWorkbenchTaskRowButton *m4Row0 = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            m4Row0.agentID = @"m4-agent";
            m4Row0.taskID = @"m4t1";
            [card4 taskClicked:m4Row0]; // open m4t1 detail
            CPAgent *m4AgentShrunk = CPTestAgent(@"m4-agent", @[CPTestTask(@"m4t2", CPStatusCompleted, 4)]);
            [card4 renderAgents:@[m4AgentShrunk]]; // selected task disappears
            BOOL taskGoneClosesDrawer = card4.selectedTask == nil && card4.rightColumn.hidden;

            CPHUDWindowController *hud3 = CPHUDWindowController.new;
            hud3.reviewStore = [[CPReviewStore alloc] initWithDefaults:m4Defaults];
            CPAgent *hAgent = CPTestAgent(@"h-agent", @[CPTestTask(@"h1", CPStatusWorking, 1)]);
            for (NSInteger i = 0; i < 3; i++) [hud3 updateWithAgents:@[hAgent] selectedAgent:hAgent];
            BOOL hudNoDupButtons = hud3.agentList.arrangedSubviews.count == 1;
            CPAgentStatusButton *hBtn = (CPAgentStatusButton *)hud3.agentList.arrangedSubviews.firstObject;
            hBtn.reduceMotion = NO;
            hBtn.animationsPaused = NO; // HUD 收起默认暂停涟漪;本用例直接驱动按钮,先解除暂停
            for (NSInteger i = 0; i < 3; i++) {
                [hBtn updateWithAgent:hAgent displayStatus:CPDisplayStatusWorking selected:YES];
            }
            BOOL singleRippleKeys = [hBtn.rippleLayers.firstObject.animationKeys isEqualToArray:@[@"ripple0"]] &&
                                    [hBtn.rippleTroughLayers.firstObject.animationKeys isEqualToArray:@[@"trough0"]] &&
                                    [hBtn.rippleLayers.lastObject.animationKeys isEqualToArray:@[@"ripple7"]] &&
                                    hBtn.ringLayer.animationKeys.count == 0 &&
                                    hBtn.innerRingLayer.animationKeys.count == 0;

            CPDockWindowController *dock4 = CPDockWindowController.new;
            [dock4 renderWithAgents:@[hAgent] selectedAgent:hAgent];
            __block BOOL dockCallbackFired = NO;
            dock4.onPillClicked = ^{ dockCallbackFired = YES; };
            [dock4 setMode:0];
            BOOL dockOrbVisible = !dock4.floatingPill.hidden && dock4.barView.hidden;
            [dock4 setMode:1];
            BOOL dockBarVisible = !dock4.barView.hidden && dock4.floatingPill.hidden;
            [dock4 barLogoClicked:nil];
            BOOL dockCallbackOK = dockCallbackFired;

            BOOL sqliteReadonly = (SQLITE_OPEN_READONLY != 0) && (SQLITE_OPEN_READWRITE != SQLITE_OPEN_READONLY);
            BOOL singleInstanceGuard = &CPAnotherInstanceIsRunning != NULL;
            [m4Defaults removePersistentDomainForName:m4Suite];
            [m4Defaults synchronize];

            BOOL m4ui = refreshNewInstances && drawerKeptOnRefresh && refreshNoMark &&
                        agentFallback && taskGoneClosesDrawer && hudNoDupButtons && singleRippleKeys &&
                        dockOrbVisible && dockBarVisible && dockCallbackOK && sqliteReadonly && singleInstanceGuard;

            // M5: 深色动态 token、窗口强制深色、标题截断、任务卡数量上限与空态
            NSAppearance *aquaApp = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
            NSAppearance *darkApp = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            NSColor * (^resolveWith)(NSColor *, NSAppearance *) = ^NSColor *(NSColor *c, NSAppearance *app) {
                __block NSColor *rgb = nil;
                [app performAsCurrentDrawingAppearance:^{
                    rgb = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                }];
                return rgb;
            };
            NSColor *fgAqua = resolveWith(CPFg(), aquaApp);
            NSColor *fgDarkAqua = resolveWith(CPFg(), darkApp);
            NSColor *surfaceAqua = resolveWith(CPSurface(), aquaApp);
            NSColor *surfaceDarkAqua = resolveWith(CPSurface(), darkApp);
            CGFloat fgar = 0, fgdr = 0, sgdr = 0, sgdg = 0, sgdb = 0;
            [fgAqua getRed:&fgar green:NULL blue:NULL alpha:NULL];
            [fgDarkAqua getRed:&fgdr green:NULL blue:NULL alpha:NULL];
            [surfaceDarkAqua getRed:&sgdr green:&sgdg blue:&sgdb alpha:NULL];
            BOOL dynamicTokensOK = fabs(fgar - fgdr) > 0.001 &&
                                   !CGColorEqualToColor(surfaceAqua.CGColor, surfaceDarkAqua.CGColor);
            BOOL darkBaseOK = fgdr > 0.8 && sgdr < 0.3 && sgdg < 0.3 && sgdb < 0.3; // 主基调为深色
            BOOL contrastAdjustOK = CPContrastAdjustChannel(0.9) > 0.9 && CPContrastAdjustChannel(0.2) < 0.2;
            BOOL darkWindowsOK = [card.window.appearance.name isEqualToString:NSAppearanceNameDarkAqua] &&
                                 [hud.window.appearance.name isEqualToString:NSAppearanceNameDarkAqua] &&
                                 [dock.window.appearance.name isEqualToString:NSAppearanceNameDarkAqua];

            NSString *longTitle = [@"" stringByPaddingToLength:200 withString:@"超长任务标题" startingAtIndex:0];
            NSString *cleaned = CPCleanTitle((const unsigned char *)longTitle.UTF8String);
            BOOL cleanTruncates = cleaned.length <= 59 && [cleaned hasSuffix:@"…"];
            CPTask *longTask = CPTestTask(@"lt", CPStatusWorking, 1);
            longTask.title = longTitle;
            CPAgent *manyAgent = CPTestAgent(@"many", @[longTask,
                                                         CPTestTask(@"m2", CPStatusWorking, 2),
                                                         CPTestTask(@"m3", CPStatusWaiting, 3),
                                                         CPTestTask(@"m4", CPStatusWorking, 4),
                                                         CPTestTask(@"m5", CPStatusWorking, 5)]);
            CPHUDWindowController *hud5 = CPHUDWindowController.new;
            [hud5 updateWithAgents:@[manyAgent] selectedAgent:manyAgent];
            BOOL taskCapOK = hud5.taskList.arrangedSubviews.count == 5 && // 全部任务建卡,滚动浏览不设上限
                             [hud5.moreLabel.stringValue isEqualToString:@"共 5 个活动 · 可滚动查看"]; // 轻量滑动提示进底行
            BOOL titleTruncates = cleanTruncates;
            if (taskCapOK) {
                NSView *row = hud5.taskList.arrangedSubviews.firstObject;
                NSStackView *hStack = (NSStackView *)row.subviews.firstObject;
                NSStackView *labelStack = hStack.arrangedSubviews.count > 1 ? (NSStackView *)hStack.arrangedSubviews[1] : nil;
                NSTextField *titleLabel = labelStack.arrangedSubviews.count ? (NSTextField *)labelStack.arrangedSubviews.firstObject : nil;
                titleTruncates = titleTruncates &&
                                 [titleLabel isKindOfClass:NSTextField.class] &&
                                 titleLabel.lineBreakMode == NSLineBreakByTruncatingTail &&
                                 titleLabel.maximumNumberOfLines == 1 &&
                                 titleLabel.intrinsicContentSize.width > 150.0; // 内容超宽,靠截断不破版
            }
            CPAgent *emptyAgent = CPTestAgent(@"empty", @[]);
            [hud5 updateWithAgents:@[emptyAgent] selectedAgent:emptyAgent];
            NSView *emptyView = hud5.taskList.arrangedSubviews.firstObject;
            BOOL emptyStateOK = hud5.taskList.arrangedSubviews.count == 1 &&
                                [emptyView isKindOfClass:NSTextField.class] &&
                                [((NSTextField *)emptyView).stringValue isEqualToString:@"当前没有任务"];

            CPWorkbenchCardController *card5 = CPWorkbenchCardController.new;
            card5.reviewStore = [[CPReviewStore alloc] initWithDefaults:m4Defaults];
            [card5 renderAgents:@[manyAgent]];
            BOOL workTitleTruncates = NO;
            if (card5.taskStack.arrangedSubviews.count > 1) {
                NSButton *rowBtn = (NSButton *)card5.taskStack.arrangedSubviews[1];
                NSStackView *hStack = (NSStackView *)rowBtn.subviews.firstObject;
                NSStackView *textStack = hStack.arrangedSubviews.count > 1 ? (NSStackView *)hStack.arrangedSubviews[1] : nil;
                NSTextField *rowTitle = textStack.arrangedSubviews.count ? (NSTextField *)textStack.arrangedSubviews.firstObject : nil;
                workTitleTruncates = [rowTitle isKindOfClass:NSTextField.class] &&
                                     rowTitle.lineBreakMode == NSLineBreakByTruncatingTail;
            }

            BOOL m5ui = dynamicTokensOK && darkBaseOK && contrastAdjustOK && darkWindowsOK &&
                        titleTruncates && taskCapOK && emptyStateOK && workTitleTruncates;

            // M7: 悬浮球安全边距窗口、8 层明暗成对涟漪、角标规则与计数 helper
            NSString *m7Suite = [NSString stringWithFormat:@"com.codexpulse.orbtest.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *m7Defaults = [[NSUserDefaults alloc] initWithSuiteName:m7Suite];
            [m7Defaults removePersistentDomainForName:m7Suite];
            CPReviewStore *m7Store = [[CPReviewStore alloc] initWithDefaults:m7Defaults];

            CPDockWindowController *dock7 = CPDockWindowController.new;
            dock7.reviewStore = m7Store;
            [dock7 setMode:0];
            NSRect orbFrame = dock7.floatingPill.frame;
            NSRect pillBounds = dock7.pill.bounds;
            BOOL orbWindowLarger = dock7.window.frame.size.width >= CPOrbSize + 2 * CPOrbMargin - 0.5 &&
                                   dock7.window.frame.size.height >= CPOrbSize + 2 * CPOrbMargin - 0.5;
            BOOL orbCentered = fabs(NSMidX(orbFrame) - NSMidX(pillBounds)) <= 0.5 &&
                               fabs(NSMidY(orbFrame) - NSMidY(pillBounds)) <= 0.5;
            BOOL orbMarginOK = NSMinX(orbFrame) >= CPOrbMargin - 0.5 && NSMinY(orbFrame) >= CPOrbMargin - 0.5;
            // 涟漪最大扩散(1.55 倍)必须完整落在窗口安全边距内,不被裁切。
            CGFloat rippleHalf = dock7.orbRippleView.bounds.size.width / 2.0;
            BOOL hoverNotClipped = (NSMidX(orbFrame) - rippleHalf) >= -0.5 &&
                                   (NSMidX(orbFrame) + rippleHalf) <= pillBounds.size.width + 0.5 &&
                                   (NSMidY(orbFrame) - rippleHalf) >= -0.5 &&
                                   (NSMidY(orbFrame) + rippleHalf) <= pillBounds.size.height + 0.5;

            // M1: 定稿涟漪参数表 — 状态差异只调周期,失败 8s 最快、待机 14s 最慢,严格单调递增。
            BOOL m1ParamsOK = YES;
            NSArray<NSNumber *> *m1Statuses = @[@(CPDisplayStatusFailed), @(CPDisplayStatusWaiting),
                                                @(CPDisplayStatusCompletedPendingReview), @(CPDisplayStatusWorking),
                                                @(CPDisplayStatusIdle)];
            CGFloat prevDuration = 0.0;
            for (NSNumber *st in m1Statuses) {
                CPDisplayStatus s = (CPDisplayStatus)st.integerValue;
                CGFloat d = CPRippleDurationForStatus(s);
                if (d < 8.0 || d > 14.0 || d <= prevDuration) m1ParamsOK = NO;
                prevDuration = d;
            }
            // 汇聚优先级:failed > waiting > pending-review > working > idle。
            CPAgent *m1Idle = CPTestAgent(@"m1-idle", @[CPTestTask(@"i", CPStatusIdle, 1)]);
            CPAgent *m1Work = CPTestAgent(@"m1-work", @[CPTestTask(@"w", CPStatusWorking, 1)]);
            CPAgent *m1Fail = CPTestAgent(@"m1-fail", @[CPTestTask(@"f", CPStatusFailed, 1)]);
            BOOL m1OverallOK = CPDisplayStatusForAgents(@[m1Idle], m7Store) == CPDisplayStatusIdle &&
                               CPDisplayStatusForAgents(@[m1Idle, m1Work], m7Store) == CPDisplayStatusWorking &&
                               CPDisplayStatusForAgents(@[m1Work, m1Fail], m7Store) == CPDisplayStatusFailed &&
                               CPDisplayStatusForAgents(@[], m7Store) == CPDisplayStatusIdle;

            dock7.orbReduceMotion = NO;
            dock7.orbHovered = NO;
            [dock7 renderWithAgents:@[m1Work] selectedAgent:m1Work]; // 运行中:绿色稳定中速
            [dock7 updateOrbRipples];
            // 8 层明暗成对错拍:层间错峰 duration/8(12s 基准即 1.5s),周期取定稿时长表(运行中 = Working)。
            BOOL orbRippleOK = dock7.orbRippleView.rippleLayers.count == CPRippleLayerCount &&
                               dock7.orbRippleView.rippleTroughLayers.count == CPRippleLayerCount;
            CGFloat orbDuration = CPRippleDurationForStatus(CPDisplayStatusWorking);
            for (NSInteger li = 0; li < CPRippleLayerCount; li++) {
                CAAnimation *crest = [dock7.orbRippleView.rippleLayers[(NSUInteger)li]
                                      animationForKey:[NSString stringWithFormat:@"ripple%ld", (long)li]];
                CAAnimation *trough = [dock7.orbRippleView.rippleTroughLayers[(NSUInteger)li]
                                       animationForKey:[NSString stringWithFormat:@"trough%ld", (long)li]];
                CGFloat expectOffset = orbDuration * (CGFloat)li / (CGFloat)CPRippleLayerCount;
                if (!crest || !trough ||
                    fabs(crest.timeOffset - expectOffset) > 0.01 ||
                    fabs(crest.duration - orbDuration) > 0.01 ||
                    crest.repeatCount <= 1000.0f || trough.repeatCount <= 1000.0f) orbRippleOK = NO;
            }
            // 波层 z 序在图标之下:涟漪组件先于球体加入 pill。
            orbRippleOK = orbRippleOK &&
                          [dock7.pill.subviews indexOfObject:dock7.orbRippleView] <
                              [dock7.pill.subviews indexOfObject:dock7.floatingPill];
            // 动画曲线与定稿规范一致:scale 1.0 → 1.55,透明度 0 → 峰值(悬浮球 ~0.28)→ 长尾巴 → 0,
            // 缓入缓出控制点 (0.45,0.08,0.35,1)。
            BOOL orbRippleCurveOK = NO;
            CAAnimation *orbA = [dock7.orbRippleView.rippleLayers.firstObject animationForKey:@"ripple0"];
            if ([orbA isKindOfClass:CAAnimationGroup.class]) {
                CAAnimationGroup *g = (CAAnimationGroup *)orbA;
                CABasicAnimation *scale = nil;
                CAKeyframeAnimation *fade = nil;
                for (CAAnimation *anim in g.animations) {
                    CAPropertyAnimation *pa = (CAPropertyAnimation *)anim;
                    if ([pa.keyPath isEqualToString:@"transform.scale"]) scale = (CABasicAnimation *)anim;
                    if ([pa.keyPath isEqualToString:@"opacity"]) fade = (CAKeyframeAnimation *)anim;
                }
                float ocp1[2] = {0, 0}, ocp2[2] = {0, 0};
                [g.timingFunction getControlPointAtIndex:1 values:ocp1];
                [g.timingFunction getControlPointAtIndex:2 values:ocp2];
                CGFloat orbPeak = fade.values.count > 1 ? [(NSNumber *)fade.values[1] doubleValue] : 0.0;
                orbRippleCurveOK = scale && fade && fade.values.count == 6 &&
                                   fabs([(NSNumber *)scale.fromValue doubleValue] - 1.0) < 0.01 &&
                                   fabs([(NSNumber *)scale.toValue doubleValue] - CPRippleScaleTo) < 0.01 &&
                                   orbPeak >= 0.20 && orbPeak <= 0.40 && // 悬浮球峰值略高(范围断言)
                                   fabs([(NSNumber *)fade.values[0] doubleValue]) < 0.001 &&
                                   fabs([(NSNumber *)fade.values[5] doubleValue]) < 0.001 &&
                                   fabs(ocp1[0] - 0.45) < 0.01 && fabs(ocp1[1] - 0.08) < 0.01 &&
                                   fabs(ocp2[0] - 0.35) < 0.01 && fabs(ocp2[1] - 1.0) < 0.01;
            }
            // 涟漪 layer 几何:组件居中于球心,layer position 必须在组件中心、anchorPoint (0.5,0.5)、
            // path 与 layer bounds 同心,否则 transform.scale 不绕球心,弧线会漂移。
            CGPoint orbCenterPt = CGPointMake(NSMidX(orbFrame), NSMidY(orbFrame));
            NSRect rvFrame = dock7.orbRippleView.frame;
            BOOL orbRippleGeo = fabs(NSMidX(rvFrame) - orbCenterPt.x) <= 0.5 &&
                                fabs(NSMidY(rvFrame) - orbCenterPt.y) <= 0.5;
            CGPoint rvCenter = CGPointMake(NSMidX(dock7.orbRippleView.bounds), NSMidY(dock7.orbRippleView.bounds));
            for (CAShapeLayer *rl in @[dock7.orbRippleView.rippleLayers.firstObject,
                                       dock7.orbRippleView.rippleTroughLayers.firstObject,
                                       dock7.orbRippleView.baseRingLayer]) {
                if (fabs(rl.position.x - rvCenter.x) > 0.5 || fabs(rl.position.y - rvCenter.y) > 0.5) orbRippleGeo = NO;
                if (fabs(rl.anchorPoint.x - 0.5) > 0.01 || fabs(rl.anchorPoint.y - 0.5) > 0.01) orbRippleGeo = NO;
                if (!rl.path) { orbRippleGeo = NO; continue; }
                CGRect pb = CGPathGetBoundingBox(rl.path);
                // CGPathGetBoundingBox 对贝塞尔圆按控制点外扩,只需验证与 bounds 同心且尺寸接近。
                if (fabs(CGRectGetMidX(pb) - CGRectGetMidX(rl.bounds)) > 1.0 ||
                    fabs(CGRectGetMidY(pb) - CGRectGetMidY(rl.bounds)) > 1.0) orbRippleGeo = NO;
                if (pb.size.width > rl.bounds.size.width + 8.0 || pb.size.height > rl.bounds.size.height + 8.0) orbRippleGeo = NO;
            }
            // 明暗成对:白峰/黑谷描边;固定基础环为当前状态色(运行中为绿)低透明度。
            BOOL orbRippleColorOK = CGColorEqualToColor(dock7.orbRippleView.rippleLayers.firstObject.strokeColor,
                                                        NSColor.whiteColor.CGColor) &&
                                    CGColorEqualToColor(dock7.orbRippleView.rippleTroughLayers.firstObject.strokeColor,
                                                        NSColor.blackColor.CGColor) &&
                                    !dock7.orbRippleView.baseRingLayer.hidden;
            {
                NSColor *baseStroke = [[NSColor colorWithCGColor:dock7.orbRippleView.baseRingLayer.strokeColor]
                                       colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                NSColor *green = [CPGreen() colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                orbRippleColorOK = orbRippleColorOK && baseStroke && green &&
                                   fabs(baseStroke.redComponent - green.redComponent) < 0.02 &&
                                   fabs(baseStroke.greenComponent - green.greenComponent) < 0.02 &&
                                   fabs(baseStroke.blueComponent - green.blueComponent) < 0.02;
            }
            // 各状态基础环颜色/时长可配置:失败红、等待橙、待查验蓝、运行绿、待机青。
            BOOL m1StatusColorsOK = YES;
            NSDictionary<NSNumber *, NSColor *> *expectColors = @{
                @(CPDisplayStatusFailed): CPRed(),
                @(CPDisplayStatusWaiting): CPOrange(),
                @(CPDisplayStatusCompletedPendingReview): CPBlue(),
                @(CPDisplayStatusIdle): CPDisplayStatusColor(CPDisplayStatusIdle),
            };
            for (NSNumber *st in m1Statuses) {
                CPDisplayStatus s = (CPDisplayStatus)st.integerValue;
                CPRippleView *rv = [[CPRippleView alloc] initWithRingDiameter:60 lineWidth:1.5];
                rv.displayStatus = s;
                [rv updateRipples];
                NSColor *expect = [expectColors[st] ?: CPGreen() colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                NSColor *baseStroke = [[NSColor colorWithCGColor:rv.baseRingLayer.strokeColor]
                                       colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                if (!baseStroke || !expect ||
                    fabs(baseStroke.redComponent - expect.redComponent) > 0.02 ||
                    fabs(baseStroke.greenComponent - expect.greenComponent) > 0.02 ||
                    fabs(baseStroke.blueComponent - expect.blueComponent) > 0.02) m1StatusColorsOK = NO;
                CAAnimation *anim = [rv.rippleLayers.firstObject animationForKey:@"ripple0"];
                if (!anim || fabs(anim.duration - CPRippleDurationForStatus(s)) > 0.01) m1StatusColorsOK = NO;
            }
            dock7.orbReduceMotion = YES;
            [dock7 updateOrbRipples];
            // reduce motion:无任何 CAAnimation,8 对波层全隐藏,只留固定状态环(实色)。
            BOOL orbReduceOK = dock7.orbRippleView.baseRingLayer.animationKeys.count == 0 &&
                               !dock7.orbRippleView.baseRingLayer.hidden;
            {
                NSColor *baseStroke = [[NSColor colorWithCGColor:dock7.orbRippleView.baseRingLayer.strokeColor]
                                       colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
                orbReduceOK = orbReduceOK && baseStroke && baseStroke.alphaComponent > 0.95; // 实色固定环
            }
            for (NSInteger li = 0; li < CPRippleLayerCount; li++) {
                if (!dock7.orbRippleView.rippleLayers[(NSUInteger)li].hidden ||
                    dock7.orbRippleView.rippleLayers[(NSUInteger)li].animationKeys.count != 0 ||
                    !dock7.orbRippleView.rippleTroughLayers[(NSUInteger)li].hidden ||
                    dock7.orbRippleView.rippleTroughLayers[(NSUInteger)li].animationKeys.count != 0) orbReduceOK = NO;
            }
            dock7.orbReduceMotion = NO;
            dock7.orbHovered = YES; // hover/drag 时隐藏动效
            [dock7 updateOrbRipples];
            BOOL orbHoverWeakens = dock7.orbRippleView.rippleLayers.firstObject.animationKeys.count == 0 &&
                                   dock7.orbRippleView.rippleLayers.firstObject.hidden &&
                                   dock7.orbRippleView.rippleTroughLayers.firstObject.hidden;
            dock7.orbHovered = NO;

            CPAgent *idleAgent = CPTestAgent(@"m7-idle", @[CPTestTask(@"i1", CPStatusIdle, 1)]);
            [dock7 renderWithAgents:@[idleAgent] selectedAgent:idleAgent];
            BOOL badgeZeroHidden = dock7.badgeView.hidden;
            CPAgent *twoAgent = CPTestAgent(@"m7-two", @[CPTestTask(@"t1", CPStatusWaiting, 1),
                                                         CPTestTask(@"t2", CPStatusFailed, 2)]);
            [dock7 renderWithAgents:@[twoAgent] selectedAgent:twoAgent];
            BOOL badgeCircle = !dock7.badgeView.hidden &&
                               fabs(dock7.badgeView.frame.size.width - dock7.badgeView.frame.size.height) <= 0.5 &&
                               [dock7.badgeLabel.stringValue isEqualToString:@"2"];
            BOOL badgeCentered = NSEqualRects(dock7.badgeLabel.frame, dock7.badgeView.bounds) &&
                                 dock7.badgeLabel.alignment == NSTextAlignmentCenter;
            BOOL badgeInWindow = NSMaxX(dock7.badgeView.frame) <= CPOrbWindowSize + 0.5 &&
                                 NSMaxY(dock7.badgeView.frame) <= CPOrbWindowSize + 0.5 &&
                                 NSMinX(dock7.badgeView.frame) >= -0.5 && NSMinY(dock7.badgeView.frame) >= -0.5;
            NSMutableArray<CPTask *> *twelve = NSMutableArray.array;
            for (NSInteger i = 0; i < 12; i++) [twelve addObject:CPTestTask([NSString stringWithFormat:@"w%ld", (long)i], CPStatusWaiting, i + 1)];
            CPAgent *twelveAgent = CPTestAgent(@"m7-twelve", twelve);
            [dock7 renderWithAgents:@[twelveAgent] selectedAgent:twelveAgent];
            BOOL badgeCapsule = dock7.badgeView.frame.size.width > dock7.badgeView.frame.size.height + 0.5 &&
                                [dock7.badgeLabel.stringValue isEqualToString:@"12"];
            NSMutableArray<CPTask *> *hundred = NSMutableArray.array;
            for (NSInteger i = 0; i < 100; i++) [hundred addObject:CPTestTask([NSString stringWithFormat:@"h%ld", (long)i], CPStatusFailed, i + 1)];
            CPAgent *hundredAgent = CPTestAgent(@"m7-hundred", hundred);
            [dock7 renderWithAgents:@[hundredAgent] selectedAgent:hundredAgent];
            BOOL badgeOverflow = [dock7.badgeLabel.stringValue isEqualToString:@"99+"];

            CPTask *reviewed = CPTestTask(@"c2", CPStatusCompleted, 5);
            [m7Store markTaskReviewed:reviewed agentID:@"m7-mix"];
            CPAgent *mixAgent = CPTestAgent(@"m7-mix", @[CPTestTask(@"f1", CPStatusFailed, 1),
                                                         CPTestTask(@"a1", CPStatusAttention, 2),
                                                         CPTestTask(@"w1", CPStatusWaiting, 3),
                                                         CPTestTask(@"c1", CPStatusCompleted, 4),
                                                         reviewed,
                                                         CPTestTask(@"k1", CPStatusWorking, 6),
                                                         CPTestTask(@"e1", CPStatusIdle, 7)]);
            BOOL badgeHelperSemantics = CPBadgeCountForAgents(@[mixAgent], m7Store) == 4;
            [m7Defaults removePersistentDomainForName:m7Suite];
            [m7Defaults synchronize];

            BOOL m7ui = orbWindowLarger && orbCentered && orbMarginOK && hoverNotClipped &&
                        m1ParamsOK && m1OverallOK && m1StatusColorsOK && orbRippleCurveOK &&
                        orbRippleOK && orbRippleGeo && orbRippleColorOK && orbReduceOK && orbHoverWeakens &&
                        badgeZeroHidden && badgeCircle && badgeCentered && badgeInWindow &&
                        badgeCapsule && badgeOverflow && badgeHelperSemantics;

            // M8: HUD 重排 — 尺寸/字号/不透明深卡/rail 隔离/任务卡/几何
            CPHUDWindowController *hud8 = CPHUDWindowController.new;
            hud8.reviewStore = [[CPReviewStore alloc] initWithDefaults:m7Defaults];
            BOOL hudSizeOK = CPHUDContentWidth >= 380.0 && CPHUDContentWidth <= 420.0 &&
                             CPHUDContentHeight >= 240.0 && CPHUDContentHeight <= 260.0;
            CGColorRef hudBg = hud8.visualView.layer.backgroundColor;
            BOOL hudOpaqueDark = hudBg && CGColorGetAlpha(hudBg) == 1.0 && hud8.visualView.layer.masksToBounds;
            {
                // 背景为深色 token(亮度低)
                const CGFloat *comp = CGColorGetComponents(hudBg);
                CGFloat lum = comp[0] * 0.299 + comp[1] * 0.587 + comp[2] * 0.114;
                hudOpaqueDark = hudOpaqueDark && lum < 0.35;
            }
            BOOL hudCarrierNoClip = !hud8.shadowCarrier.layer.masksToBounds && !hud8.window.hasShadow;

            CPTask *longT = CPTestTask(@"m8-long", CPStatusWorking, 100);
            longT.title = [@"" stringByPaddingToLength:160 withString:@"超长HUD任务标题" startingAtIndex:0];
            longT.activity = @"正在编译 main.m";
            CPAgent *hudAgentA = CPTestAgent(@"m8-a", @[longT,
                                                        CPTestTask(@"a2", CPStatusWaiting, 90),
                                                        CPTestTask(@"a3", CPStatusWorking, 80)]);
            CPAgent *hudAgentB = CPTestAgent(@"m8-b", @[CPTestTask(@"b-only", CPStatusFailed, 95)]);
            [hud8 updateWithAgents:@[hudAgentA, hudAgentB] selectedAgent:hudAgentA];

            BOOL hudCapOK = hud8.taskList.arrangedSubviews.count == 3; // 全部任务建卡,滑动提示在底行
            BOOL hudSummaryOK = [hud8.moreLabel.stringValue isEqualToString:@"共 3 个活动 · 可滚动查看"];
            BOOL hudMinFontOK = YES;
            BOOL hudNoPathOK = YES;
            BOOL hudTitleTruncOK = NO;
            {
                NSMutableArray<NSTextField *> *labels = NSMutableArray.array;
                NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithArray:hud8.visualView.subviews];
                while (queue.count) {
                    NSView *v = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if ([v isKindOfClass:NSTextField.class]) [labels addObject:(NSTextField *)v];
                    [queue addObjectsFromArray:v.subviews];
                }
                for (NSTextField *l in labels) {
                    if (l.stringValue.length && l.font.pointSize < 11.0) hudMinFontOK = NO;
                    if ([l.stringValue containsString:@"/"]) hudNoPathOK = NO; // 不含项目路径
                }
                NSView *firstCard = hud8.taskList.arrangedSubviews.firstObject;
                NSStackView *hStack = (NSStackView *)firstCard.subviews.firstObject;
                NSStackView *textStack = hStack.arrangedSubviews.count > 1 ? (NSStackView *)hStack.arrangedSubviews[1] : nil;
                NSTextField *titleL = textStack.arrangedSubviews.count ? (NSTextField *)textStack.arrangedSubviews.firstObject : nil;
                hudTitleTruncOK = [titleL isKindOfClass:NSTextField.class] &&
                                  titleL.lineBreakMode == NSLineBreakByTruncatingTail &&
                                  titleL.maximumNumberOfLines == 1;
            }

            // rail 只含 Agent 状态按钮;右侧仅显示选中 Agent;切换即时生效
            BOOL hudRailOK = hud8.agentList.arrangedSubviews.count == 2;
            for (NSView *v in hud8.agentList.arrangedSubviews) {
                if (![v isKindOfClass:CPAgentStatusButton.class]) hudRailOK = NO;
                if ([v isKindOfClass:NSButton.class] && ((NSButton *)v).title.length != 0) hudRailOK = NO;
            }
            BOOL hudScopeOK = [hud8.agentNameLabel.stringValue isEqualToString:@"m8-a"];
            CPAgentStatusButton *btnB = (CPAgentStatusButton *)hud8.agentList.arrangedSubviews[1];
            [hud8 agentButtonClicked:btnB];
            hudScopeOK = hudScopeOK && [hud8.agentNameLabel.stringValue isEqualToString:@"m8-b"] &&
                         hud8.taskList.arrangedSubviews.count == 1;
            if (hudScopeOK) {
                NSView *cardV = hud8.taskList.arrangedSubviews.firstObject;
                NSStackView *hStack = (NSStackView *)cardV.subviews.firstObject;
                NSStackView *textStack = hStack.arrangedSubviews.count > 1 ? (NSStackView *)hStack.arrangedSubviews[1] : nil;
                NSTextField *titleL = textStack.arrangedSubviews.count ? (NSTextField *)textStack.arrangedSubviews.firstObject : nil;
                hudScopeOK = [titleL.stringValue isEqualToString:@"b-only"];
            }
            BOOL hudRailSelected = NO;
            BOOL hudRailHitOK = NO;
            if (hud8.agentList.arrangedSubviews.count > 1) {
                // render 后按钮为重建的新实例,重新取回检查选中态与 hit-test。
                CPAgentStatusButton *newBtnB = (CPAgentStatusButton *)hud8.agentList.arrangedSubviews[1];
                // 方向 A 选中态:无蒙层(背景透明)、无描边、无指示条,状态环实色(opacity≈1)且线宽 2。
                CGColorRef selBg = newBtnB.layer.backgroundColor;
                hudRailSelected = newBtnB.statusSelected &&
                                  (!selBg || CGColorGetAlpha(selBg) == 0.0) &&
                                  newBtnB.layer.borderWidth == 0.0 &&
                                  fabs(newBtnB.ringLayer.opacity - 1.0) < 0.01 &&
                                  fabs(newBtnB.ringLayer.lineWidth - 2.0) < 0.01;
                [hud8 expand]; // hit-test 需要卡片可见(hidden=NO)
                [hud8.visualView layoutSubtreeIfNeeded];
                NSPoint btnCenter = NSMakePoint(NSMidX(newBtnB.bounds), NSMidY(newBtnB.bounds));
                NSPoint inCard = [newBtnB convertPoint:btnCenter toView:hud8.visualView];
                hudRailHitOK = [hud8.visualView hitTest:inCard] == newBtnB;
            }

            // 空状态
            CPAgent *hudEmpty = CPTestAgent(@"m8-empty", @[]);
            [hud8 updateWithAgents:@[hudEmpty] selectedAgent:hudEmpty];
            NSView *emptyV = hud8.taskList.arrangedSubviews.firstObject;
            BOOL hudEmptyOK = hud8.taskList.arrangedSubviews.count == 1 &&
                              [emptyV isKindOfClass:NSTextField.class] &&
                              [((NSTextField *)emptyV).stringValue isEqualToString:@"当前没有任务"];

            // 展开/收回几何 + tracking area
            NSRect hud8Collapsed = [hud8 collapsedFrameInVisibleRect:testVisible];
            NSRect hud8Expanded = [hud8 expandedFrameInVisibleRect:testVisible];
            BOOL hudGeoOK = fabs(hud8Collapsed.size.width - 6.0) <= 0.5 && fabs(hud8Collapsed.size.height - 72.0) <= 0.5 &&
                            fabs(NSMaxX(hud8Collapsed) - NSMaxX(testVisible)) <= 0.5 &&
                            fabs(NSMaxY(hud8Collapsed) - NSMaxY(testVisible)) <= 0.5 &&
                            fabs(NSMaxX(hud8Expanded) - NSMaxX(testVisible)) <= 0.5 &&
                            fabs(NSMaxY(hud8Expanded) - NSMaxY(testVisible)) <= 0.5 &&
                            hud8.trackingArea != nil;

            // 展开后把手必须消失，避免右上角出现额外竖条“障碍物”。
            BOOL hudHandleTabOK = hud8.handleView.hidden;

            // 状态图例:底行右侧 14x14「?」小圆钮(无系统默认按钮样式、无「按钮」文字),
            // hover/点击在其上方展开浮层:五行速查(7px 色点 + 状态名)+ 底部说明行,移走收回。
            BOOL legendOK = hud8.legendButton != nil &&
                            !hud8.legendButton.bordered &&
                            [hud8.legendButton.title isEqualToString:@"?"] &&
                            fabs(hud8.legendButton.bounds.size.width - 14.0) <= 0.5 &&
                            fabs(hud8.legendButton.bounds.size.height - 14.0) <= 0.5 &&
                            hud8.moreLabel.superview == hud8.bottomBar &&
                            hud8.legendButton.superview == hud8.bottomBar &&
                            (hud8.legendPanel == nil || !hud8.legendPanel.isVisible);
            [hud8 legendClicked:nil]; // 键盘可达入口:切换展开
            legendOK = legendOK && hud8.legendPanel != nil && hud8.legendPanel.isVisible;
            {
                NSMutableArray<NSString *> *legendTexts = NSMutableArray.array;
                NSInteger dotCount = 0;
                NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithArray:hud8.legendPanel.contentView.subviews];
                while (queue.count) {
                    NSView *v = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if ([v isKindOfClass:NSTextField.class]) [legendTexts addObject:((NSTextField *)v).stringValue];
                    if ([v isKindOfClass:NSImageView.class]) dotCount++;
                    [queue addObjectsFromArray:v.subviews];
                }
                legendOK = legendOK && dotCount == 5 &&
                           [legendTexts containsObject:@"失败"] &&
                           [legendTexts containsObject:@"等待处理"] &&
                           [legendTexts containsObject:@"已就绪"] &&
                           [legendTexts containsObject:@"运行中"] &&
                           [legendTexts containsObject:@"待机"] &&
                           [legendTexts containsObject:@"Agent 环跟随最近更新的任务"] &&
                           ![legendTexts containsObject:@"按钮"];
            }
            [hud8 hideLegend];
            legendOK = legendOK && !hud8.legendPanel.isVisible;

            BOOL m8ui = hudSizeOK && hudOpaqueDark && hudCarrierNoClip && hudCapOK && hudSummaryOK && hudMinFontOK &&
                        hudNoPathOK && hudTitleTruncOK && hudRailOK && hudScopeOK && hudRailSelected &&
                        hudRailHitOK && hudEmptyOK && hudGeoOK && hudHandleTabOK && legendOK;

            // M9: 工作台任务详情抽屉 — 全宽/两列 grid/截断/格式/Esc/刷新
            CPWorkbenchCardController *card9 = CPWorkbenchCardController.new;
            card9.reviewStore = [[CPReviewStore alloc] initWithDefaults:m7Defaults];
            CPTask *bigTask = CPTestTask(@"m9-t1", CPStatusCompleted, 1751966040);
            bigTask.title = [@"" stringByPaddingToLength:160 withString:@"超长详情标题" startingAtIndex:0];
            bigTask.tokensUsed = 2632254;
            bigTask.activity = [@"" stringByPaddingToLength:300 withString:@"正在执行构建脚本并验证输出产物 " startingAtIndex:0];
            CPAgent *agent9 = CPTestAgent(@"m9-agent", @[bigTask]);
            [card9 renderAgents:@[agent9]];
            CPWorkbenchTaskRowButton *row9 = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            row9.agentID = @"m9-agent";
            row9.taskID = @"m9-t1";
            [card9 taskClicked:row9];
            [card9.window orderFrontRegardless];
            [card9.card layoutSubtreeIfNeeded];

            CGFloat stackW = card9.detailStack.frame.size.width;
            BOOL m9FullWidth = stackW > 100.0;
            for (NSView *v in card9.detailStack.arrangedSubviews) {
                // 全部接近横向填满(容差含文本场内边距),不得缩成窄列
                if (v.frame.size.width < stackW - 30.0) m9FullWidth = NO;
            }
            BOOL m9GridOK = NO;
            NSTextField *m9Title = nil;
            NSTextField *m9ActivityBody = nil;
            for (NSView *v in card9.detailStack.arrangedSubviews) {
                if ([v isKindOfClass:NSStackView.class]) {
                    NSStackView *sv = (NSStackView *)v;
                    if (sv.orientation == NSUserInterfaceLayoutOrientationHorizontal && sv.arrangedSubviews.count == 2) m9GridOK = YES;
                }
                if ([v isKindOfClass:NSTextField.class]) {
                    NSTextField *l = (NSTextField *)v;
                    if (l.font.pointSize >= 14.0 && !m9Title) m9Title = l;
                }
                // 活动子卡片内的正文(4 行上限)
                for (NSView *sub in v.subviews) {
                    if ([sub isKindOfClass:NSTextField.class] && ((NSTextField *)sub).maximumNumberOfLines == 4) {
                        m9ActivityBody = (NSTextField *)sub;
                    }
                }
            }
            BOOL m9TitleTruncOK = m9Title && m9Title.maximumNumberOfLines == 2 &&
                                  m9Title.lineBreakMode == NSLineBreakByTruncatingTail;
            BOOL m9ActivityTruncOK = m9ActivityBody && m9ActivityBody.lineBreakMode == NSLineBreakByTruncatingTail;
            BOOL m9TokensOK = [CPFormatTokens(2632254) isEqualToString:@"2.63M"] &&
                              [CPFormatTokens(12400) isEqualToString:@"12.4k"] &&
                              [CPFormatTokens(900) isEqualToString:@"900"];
            NSString *dateCN = CPFormatDateCN([NSDate dateWithTimeIntervalSince1970:1751966040]);
            BOOL m9DateOK = [dateCN containsString:@"月"] && [dateCN containsString:@"日"];

            // 空项目/空活动显示 —
            CPTask *emptyFields = CPTestTask(@"m9-t1", CPStatusCompleted, 1751966040);
            emptyFields.projectName = @"";
            emptyFields.activity = @"";
            CPAgent *agent9b = CPTestAgent(@"m9-agent", @[emptyFields]);
            [card9 renderAgents:@[agent9b]]; // 同 ID 映射,抽屉保持并刷新
            BOOL m9DashOK = NO;
            {
                NSInteger dashCount = 0;
                NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithArray:card9.rightColumn.subviews];
                while (queue.count) {
                    NSView *v = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).stringValue isEqualToString:@"—"]) dashCount++;
                    [queue addObjectsFromArray:v.subviews];
                }
                m9DashOK = dashCount >= 2; // 项目 + 活动
            }

            // 左上返回胶囊 hit-test 不被遮挡；详情底部提供第二次点击的 Agent 直达按钮。
            [card9.rightColumn layoutSubtreeIfNeeded];
            NSPoint backC = NSMakePoint(NSMidX(card9.detailBackButton.bounds), NSMidY(card9.detailBackButton.bounds));
            NSPoint backInCol = [card9.detailBackButton convertPoint:backC toView:card9.rightColumn];
            BOOL m9BackHitOK = [card9.rightColumn hitTest:backInCol] == card9.detailBackButton;
            NSRect backF = [card9.detailBackButton convertRect:card9.detailBackButton.bounds toView:card9.rightColumn];
            // 返回胶囊:56×28(宽>高)、圆角 14、hairline 描边 + 极淡底色,
            // 内容含 chevron 图标与「返回」文字,热区与可视区域一致。
            BOOL m9BackHasLabel = NO;
            BOOL m9BackHasChevron = NO;
            {
                NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithArray:card9.detailBackButton.subviews];
                while (queue.count) {
                    NSView *v = queue.firstObject;
                    [queue removeObjectAtIndex:0];
                    if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).stringValue isEqualToString:@"返回"]) m9BackHasLabel = YES;
                    if ([v isKindOfClass:NSImageView.class]) m9BackHasChevron = YES;
                    [queue addObjectsFromArray:v.subviews];
                }
            }
            CGColorRef backBg = card9.detailBackButton.layer.backgroundColor;
            BOOL m9BackVisible = !card9.detailBackButton.isHidden && card9.detailBackButton.alphaValue == 1.0 &&
                                 backF.size.width == 56.0 && backF.size.height == 28.0 &&
                                 backF.size.width > backF.size.height && // 横向胶囊
                                 NSContainsRect(card9.rightColumn.bounds, backF) &&
                                 card9.detailBackButton.layer.cornerRadius == 14.0 &&
                                 card9.detailBackButton.layer.borderWidth > 0.0 &&
                                 backBg && CGColorGetAlpha(backBg) > 0.0 &&
                                 m9BackHasLabel && m9BackHasChevron &&
                                 [card9.detailBackButton.accessibilityLabel isEqualToString:@"返回任务列表"];
            NSView *head9 = card9.detailStack.arrangedSubviews.firstObject;
            NSTextField *titleLbl = nil;
            for (NSView *v in head9.subviews) {
                if ([v isKindOfClass:NSTextField.class]) { titleLbl = (NSTextField *)v; break; }
            }
            NSRect titleF = titleLbl ? [titleLbl convertRect:titleLbl.bounds toView:card9.rightColumn] : NSZeroRect;
            NSSize backLocalSize = card9.detailBackButton.bounds.size;
            BOOL m9BackTopLeft = titleLbl != nil &&
                                 fabs(backF.origin.x - 12.0) <= 2.0 &&
                                 !NSIntersectsRect(backF, titleF) &&
                                 titleF.origin.x >= NSMaxX(backF) + 4.0 &&
                                 fabs(backLocalSize.width - 56.0) <= 1.0 &&  // 热区 ≥ 可视区域(此处一致)
                                 fabs(backLocalSize.height - 28.0) <= 1.0;
            BOOL m9DirectOpen = card9.detailOpenAgentButton != nil &&
                                [card9.detailOpenAgentButton.title isEqualToString:@"在 m9-agent 中打开"] &&
                                card9.detailOpenAgentButton.action == @selector(openSelectedTaskInAgent:) &&
                                !card9.rightColumn.hidden;
            if (m9DirectOpen) {
                NSRect openF = [card9.detailOpenAgentButton convertRect:card9.detailOpenAgentButton.bounds
                                                                 toView:card9.rightColumn];
                NSPoint openCenter = NSMakePoint(NSMidX(card9.detailOpenAgentButton.bounds),
                                                 NSMidY(card9.detailOpenAgentButton.bounds));
                NSPoint openInCol = [card9.detailOpenAgentButton convertPoint:openCenter toView:card9.rightColumn];
                m9DirectOpen = NSContainsRect(card9.rightColumn.bounds, openF) &&
                               [card9.rightColumn hitTest:openInCol] == card9.detailOpenAgentButton;
            }

            // 刷新保持/消失
            BOOL m9RefreshKeep = !card9.rightColumn.hidden && card9.selectedTask == emptyFields;
            CPAgent *agent9c = CPTestAgent(@"m9-agent", @[CPTestTask(@"m9-other", CPStatusWorking, 1)]);
            [card9 renderAgents:@[agent9c]]; // 任务消失 → 关抽屉
            BOOL m9RefreshGone = card9.rightColumn.hidden && card9.selectedTask == nil;

            // Esc 两阶段
            [card9 renderAgents:@[agent9]];
            CPWorkbenchTaskRowButton *row9b = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            row9b.agentID = @"m9-agent";
            row9b.taskID = @"m9-t1";
            [card9 taskClicked:row9b];
            [card9.window orderFrontRegardless];
            [card9 handleEscape];
            BOOL m9Esc1 = card9.rightColumn.hidden && card9.window.isVisible;
            [card9 handleEscape];
            BOOL m9Esc2 = !card9.window.isVisible;

            // 工作台键盘可达性(真实 Esc 前提):必须是可成为 key 的面板、非 nonactivating 配置,且 show 时激活并 makeKey。
            BOOL m9Keyable = [card9.window isKindOfClass:CPWorkbenchPanel.class] &&
                             card9.window.canBecomeKeyWindow &&
                             !(card9.window.styleMask & NSWindowStyleMaskNonactivatingPanel);
            card9.lastShowMadeKey = NO;
            [card9 showNearDockRect:NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize) edge:NSRectEdgeMaxX];
            BOOL m9ShowMakesKey = card9.lastShowMadeKey;

            // 详情打开时点击不得穿透到下层任务列表(命中被详情容器吞掉);关闭后下层恢复可点。
            [card9 renderAgents:@[agent9]];
            CPWorkbenchTaskRowButton *row9c = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            row9c.agentID = @"m9-agent";
            row9c.taskID = @"m9-t1";
            [card9 taskClicked:row9c];
            [card9.card layoutSubtreeIfNeeded];
            NSPoint midPt = NSMakePoint(NSMidX(card9.middleColumn.bounds), NSMidY(card9.middleColumn.bounds));
            NSView *hitOpen = [card9.middleColumn hitTest:midPt];
            BOOL m9BarrierOpen = [card9.rightColumn isKindOfClass:CPClickBarrierView.class] &&
                                 hitOpen != nil && [hitOpen isDescendantOf:card9.rightColumn];
            // 互斥(不只靠挡板):任务列表整体隐藏、hitTest 落不到 row、
            // row tooltip 与自有 tracking area 全部停用。
            BOOL m9MutexOpen = card9.taskScrollView.isHidden &&
                               ![hitOpen isDescendantOf:card9.taskScrollView];
            for (NSView *r in card9.taskStack.arrangedSubviews) {
                if (r.toolTip.length) m9MutexOpen = NO;
                for (NSTrackingArea *ta in r.trackingAreas) {
                    if (ta.owner == r) m9MutexOpen = NO;
                }
            }
            [card9 closeDetailDrawer];
            NSView *hitClosed = [card9.middleColumn hitTest:midPt];
            BOOL m9BarrierRestored = hitClosed != nil &&
                                     ![hitClosed isDescendantOf:card9.rightColumn] &&
                                     [hitClosed isDescendantOf:card9.taskScrollView];
            // 关闭后完整恢复:列表可见、row 可 hit、tooltip 与 tracking area 还原。
            BOOL m9MutexRestored = !card9.taskScrollView.isHidden;
            for (NSView *r in card9.taskStack.arrangedSubviews) {
                BOOL hasTracking = NO;
                for (NSTrackingArea *ta in r.trackingAreas) {
                    if (ta.owner == r) hasTracking = YES;
                }
                if (!r.toolTip.length || !hasTracking) m9MutexRestored = NO;
            }

            BOOL m9ui = m9FullWidth && m9GridOK && m9TitleTruncOK && m9ActivityTruncOK && m9TokensOK &&
                        m9DateOK && m9DashOK && m9BackHitOK && m9BackVisible && m9BackTopLeft && m9DirectOpen &&
                        m9RefreshKeep && m9RefreshGone && m9Esc1 && m9Esc2 &&
                        m9Keyable && m9ShowMakesKey && m9BarrierOpen && m9BarrierRestored &&
                        m9MutexOpen && m9MutexRestored;

            // M10: 工作台任务列表 NSScrollView 化
            CPWorkbenchCardController *card10 = CPWorkbenchCardController.new;
            card10.reviewStore = [[CPReviewStore alloc] initWithDefaults:m7Defaults];
            NSMutableArray<CPTask *> *many10 = NSMutableArray.array;
            for (NSInteger i = 0; i < 10; i++) [many10 addObject:CPTestTask([NSString stringWithFormat:@"s%ld", (long)i], CPStatusWorking, i + 1)];
            CPAgent *agent10 = CPTestAgent(@"m10-agent", many10);
            [card10 renderAgents:@[agent10]];
            [card10.window orderFrontRegardless];
            [card10.card layoutSubtreeIfNeeded];

            BOOL m10ScrollStruct = [card10.taskStack isDescendantOf:card10.taskScrollView.documentView] &&
                                   card10.taskScrollView.hasVerticalScroller &&
                                   !card10.taskScrollView.hasHorizontalScroller &&
                                   !card10.taskScrollView.drawsBackground;
            BOOL m10HeaderFixed = ![card10.centerTitle isDescendantOf:card10.taskScrollView];
            CGFloat clipW = card10.taskScrollView.contentView.bounds.size.width;
            CGFloat clipH = card10.taskScrollView.contentView.bounds.size.height;
            CGFloat contentH = [card10.taskStack fittingSize].height;
            BOOL m10Scrollable = card10.taskStack.arrangedSubviews.count == 10 && contentH > clipH;
            NSView *firstRow = card10.taskStack.arrangedSubviews.firstObject;
            NSView *lastRow = card10.taskStack.arrangedSubviews.lastObject;
            BOOL m10FirstRowOK = firstRow.frame.origin.y <= 0.5; // 首行顶部对齐,完整显示
            CGFloat bottomInset = contentH - NSMaxY(lastRow.frame);
            BOOL m10LastRowOK = bottomInset >= 10.0 && bottomInset <= 12.0; // 底部内边距 10–12
            BOOL m10WidthOK = fabs(card10.taskStack.frame.size.width - clipW) <= 1.0 &&
                              fabs(firstRow.frame.size.width - clipW) <= 1.0; // 横向 fill 不溢出

            BOOL m10ui = m10ScrollStruct && m10HeaderFixed && m10Scrollable &&
                         m10FirstRowOK && m10LastRowOK && m10WidthOK;

            // L2: hover 蒙层残留回归 — wash 只动 overlay opacity,hover 不再新增描边;
            // 正常进出清零;窗口移动(鼠标静止相对移出)、隐藏、移出父视图等收不到
            // mouseExited 的场景必须强制复位,model opacity 终态必为 0。
            NSWindow *hoverWin = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 120, 120)
                                                             styleMask:NSWindowStyleMaskBorderless
                                                               backing:NSBackingStoreBuffered
                                                                 defer:NO];
            CPHoverButton *hoverBtn = [CPHoverButton buttonWithTitle:@"" target:nil action:nil];
            hoverBtn.frame = NSMakeRect(10, 10, 28, 28);
            [hoverWin.contentView addSubview:hoverBtn];
            [hoverWin orderFrontRegardless];
            [hoverBtn cpSetHovered:YES];
            BOOL hoverShown = hoverBtn.cpHoverOverlay.opacity > 0.05 &&
                              hoverBtn.layer.borderWidth == 0.0; // hover 不再加描边
            [hoverBtn cpSetHovered:NO];
            BOOL hoverExitCleared = hoverBtn.cpHoverOverlay.opacity == 0.0;
            // 窗口移动到远离真实鼠标的位置:tracking area 不会补发 exited,必须靠重校验清零。
            [hoverBtn cpSetHovered:YES];
            NSPoint realMouse = NSEvent.mouseLocation;
            [hoverWin setFrameOrigin:NSMakePoint(realMouse.x + 800.0, realMouse.y + 800.0)];
            BOOL hoverMoveCleared = hoverBtn.cpHoverOverlay.opacity == 0.0;
            [hoverBtn cpSetHovered:YES];
            hoverBtn.hidden = YES; // 收不到 mouseExited:viewDidHide 兜底
            BOOL hoverHideCleared = hoverBtn.cpHoverOverlay.opacity == 0.0;
            hoverBtn.hidden = NO;
            [hoverBtn cpSetHovered:YES];
            [hoverBtn removeFromSuperview]; // 刷新重建时旧按钮被移除
            BOOL hoverRemoveCleared = hoverBtn.cpHoverOverlay.opacity == 0.0;
            [hoverWin orderOut:nil];
            BOOL hoverResidualOK = hoverShown && hoverExitCleared && hoverMoveCleared &&
                                   hoverHideCleared && hoverRemoveCleared;

            // Todo:独立轻量待办 — 数据层 CRUD/裁剪/排序/持久化/预留字段,
            // UI 栏常驻参与布局(绝不 overlay),计数只在 Todo 栏内,不进 Agent 提醒聚合。
            NSString *todoTestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"codexpulse-todo-selftest.sqlite"];
            [[NSFileManager defaultManager] removeItemAtPath:todoTestPath error:nil];
            CPTodoStore *todoStore = [[CPTodoStore alloc] initWithPath:todoTestPath];
            CPTodo *t1 = [todoStore addTodoWithTitle:@"第一条"];
            CPTodo *t2 = [todoStore addTodoWithTitle:@"  第二条  "];
            BOOL todoAdd = t1 && t2 && todoStore.allTodos.count == 2 && todoStore.pendingCount == 2 &&
                           [t2.title isEqualToString:@"第二条"]; // 首尾空白裁剪
            BOOL todoBlankIgnored = [todoStore addTodoWithTitle:@"   "] == nil && todoStore.allTodos.count == 2;
            [todoStore setTodo:t1.todoID completed:YES];
            BOOL todoComplete = todoStore.pendingCount == 1 &&
                                todoStore.allTodos.firstObject.todoID == t2.todoID; // 未完成在前,完成沉底
            [todoStore setTodo:t1.todoID completed:NO];
            BOOL todoRestore = todoStore.pendingCount == 2;
            [todoStore updateTodo:t2.todoID title:@"第二条改"];
            CPTodo *t2After = nil;
            for (CPTodo *t in todoStore.allTodos) if (t.todoID == t2.todoID) t2After = t;
            BOOL todoEdit = [t2After.title isEqualToString:@"第二条改"];
            [todoStore deleteTodo:t1.todoID];
            BOOL todoDelete = todoStore.allTodos.count == 1 && todoStore.pendingCount == 1;
            CPTodoStore *todoReopen = [[CPTodoStore alloc] initWithPath:todoTestPath]; // 重开库验证持久化
            CPTodo *t2Persisted = todoReopen.allTodos.firstObject;
            BOOL todoPersist = todoReopen.allTodos.count == 1 && [t2Persisted.title isEqualToString:@"第二条改"];
            BOOL todoAgentNull = t2Persisted.agentID == nil && t2Persisted.threadID == nil; // 预留字段恒 NULL
            // schema 版本:新建库经 0→1 迁移后 user_version 必须为 1
            int todoUV = -1;
            sqlite3 *todoVerDB = NULL;
            if (sqlite3_open_v2(todoTestPath.UTF8String, &todoVerDB, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                sqlite3_stmt *todoVerStmt = NULL;
                if (sqlite3_prepare_v2(todoVerDB, "PRAGMA user_version", -1, &todoVerStmt, NULL) == SQLITE_OK &&
                    sqlite3_step(todoVerStmt) == SQLITE_ROW) {
                    todoUV = sqlite3_column_int(todoVerStmt, 0);
                }
                if (todoVerStmt) sqlite3_finalize(todoVerStmt);
            }
            if (todoVerDB) sqlite3_close(todoVerDB);
            BOOL todoUserVersion = todoUV == 1;

            CPWorkbenchCardController *todoCard = CPWorkbenchCardController.new;
            todoCard.todoExpanded = NO;
            [todoCard applyTodoExpandedState];
            [todoCard.window orderFrontRegardless];
            [todoCard.card layoutSubtreeIfNeeded];
            BOOL todoStrip = !todoCard.todoContainer.hidden &&
                             fabs(todoCard.todoHeightConstraint.constant - CPTodoCollapsedHeight) <= 0.5 &&
                             todoCard.todoExpandedContent.hidden; // 收起态:卡片头常驻、内容隐藏
            // body(三列容器,即 columns stack 的父视图)底部钉在 Todo 栏顶部,任何状态下都不重叠。
            NSView *todoBody = todoCard.leftColumn.superview.superview;
            BOOL todoNoOverlay = fabs(todoBody.frame.origin.y - NSMaxY(todoCard.todoContainer.frame)) <= 0.5;
            todoCard.todoExpanded = YES;
            [todoCard applyTodoExpandedState];
            // 展开时窗口 setFrame:animate:YES,先泵 runloop 等动画收尾,断言不读到中间帧。
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
            NSScreen *todoScreen = todoCard.window.screen ?: CPTargetScreen();
            // 与生产同一套定位契约:展开后窗口必须等于 CPCenteredRectInVisibleFrame 的结果
            // (空间不足时按 20pt 安全边距钳制,而非越出屏幕);不再用"必须绝对居中"的过时假设。
            NSRect todoExpected = todoScreen ? CPCenteredRectInVisibleFrame(todoScreen.visibleFrame,
                                                                            todoCard.window.frame.size) : NSZeroRect;
            BOOL todoAutoReposition = !todoScreen || NSEqualRects(todoCard.window.frame, todoExpected);
            BOOL todoExpand = !todoCard.todoExpandedContent.hidden &&
                              fabs(todoCard.todoHeightConstraint.constant - (CPTodoCollapsedHeight + CPTodoExpandedExtra)) <= 0.5 &&
                              fabs(todoCard.window.frame.size.height - (todoCard.cardHeight + CPWorkbenchInset * 2.0)) <= 0.5;
            [todoCard.card layoutSubtreeIfNeeded];
            BOOL todoExpandNoOverlay = fabs(todoBody.frame.origin.y - NSMaxY(todoCard.todoContainer.frame)) <= 0.5 &&
                                       fabs(todoBody.frame.size.height - (360.0 - 49.0 - CPTodoCardMargin)) <= 1.0; // 展开后任务区高度不变(卡片底部 12 留白)
            todoCard.todoExpanded = NO;
            [todoCard applyTodoExpandedState];

            // 方案 B 卡片结构:与"最近活动"同族(表面色底 + 10px 圆角 + 1px hairline 描边);
            // 空库时计数 pill 整体收起,不留空胶囊。
            BOOL todoCardStyle = fabs(todoCard.todoContainer.layer.cornerRadius - 10.0) <= 0.5 &&
                                 fabs(todoCard.todoContainer.layer.borderWidth - 1.0) <= 0.5 &&
                                 CGColorEqualToColor(todoCard.todoContainer.layer.backgroundColor, CPSurface().CGColor) &&
                                 todoCard.todoCountPill.hidden;

            [todoCard.todoStore addTodoWithTitle:@"UI 条目"];
            [todoCard renderTodos];
            BOOL todoUICount = todoCard.todoStack.arrangedSubviews.count == 1 &&
                               [todoCard.todoCountLabel.stringValue isEqualToString:@"1 项待办"] &&
                               !todoCard.todoCountPill.hidden; // 有计数时 pill 显示
            // Todo 计数与 Agent 提醒聚合完全隔离:同一 agents 输入,加 Todo 前后角标不变。
            CPAgent *todoBadgeAgent = CPTestAgent(@"todo-badge", @[CPTestTask(@"tb1", CPStatusWaiting, 100)]);
            CPReviewStore *todoBadgeReview = [[CPReviewStore alloc] initWithDefaults:[[NSUserDefaults alloc] initWithSuiteName:@"todo-selftest"]];
            NSInteger badgeBefore = CPBadgeCountForAgents(@[todoBadgeAgent], todoBadgeReview);
            [todoCard.todoStore addTodoWithTitle:@"不应计入角标"];
            BOOL todoBadgeIsolated = badgeBefore == CPBadgeCountForAgents(@[todoBadgeAgent], todoBadgeReview);

            // 方案 B 视觉 token/结构断言(对照原型 .vB,非注释宣称)
            // 层次:工作台 CPBg 底 + Todo 卡片 CPSurface,两色必须不同,层次真实存在。
            BOOL todoLayeringOK = CGColorEqualToColor(todoCard.card.layer.backgroundColor, CPBg().CGColor) &&
                                  CGColorEqualToColor(todoCard.todoContainer.layer.backgroundColor, CPSurface().CGColor) &&
                                  !CGColorEqualToColor(todoCard.card.layer.backgroundColor,
                                                       todoCard.todoContainer.layer.backgroundColor);
            // hairline:卡片/输入框描边为 8% 白 CPHairline,且不等于亮一档的 CPBorder。
            NSColor *hairlineDark = resolveWith(CPHairline(), darkApp);
            BOOL todoHairlineOK = hairlineDark && fabs(hairlineDark.alphaComponent - 0.08) < 0.01 &&
                                  fabs(hairlineDark.redComponent - 1.0) < 0.01 &&
                                  CGColorEqualToColor(todoCard.todoContainer.layer.borderColor, CPHairline().CGColor) &&
                                  CGColorEqualToColor(todoCard.todoInputWrap.layer.borderColor, CPHairline().CGColor) &&
                                  !CGColorEqualToColor(todoCard.todoContainer.layer.borderColor, CPBorder().CGColor);
            // 输入聚焦:描边 CPAccent + 光环;失焦恢复 hairline。
            [todoCard cpUpdateTodoInputFocus:YES];
            BOOL todoFocusOK = CGColorEqualToColor(todoCard.todoInputWrap.layer.borderColor, CPAccent().CGColor) &&
                               todoCard.todoInputWrap.layer.shadowOpacity > 0.0;
            [todoCard cpUpdateTodoInputFocus:NO];
            todoFocusOK = todoFocusOK &&
                          CGColorEqualToColor(todoCard.todoInputWrap.layer.borderColor, CPHairline().CGColor);
            // 输入框左侧常驻「＋」,且排在输入框左边。
            [todoCard.todoInputWrap layoutSubtreeIfNeeded];
            NSTextField *plusLabel = nil;
            for (NSView *v in todoCard.todoInputWrap.subviews) {
                if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).stringValue isEqualToString:@"＋"]) plusLabel = (NSTextField *)v;
            }
            BOOL todoPlusOK = plusLabel != nil && NSMaxX(plusLabel.frame) <= NSMinX(todoCard.todoInput.frame) + 0.5;
            // 行结构:hover 同时放行编辑铅笔 + 删除垃圾桶,非 hover 全隐藏;行高 30。
            [todoCard renderTodos];
            CPTodoRowView *rowB = (CPTodoRowView *)todoCard.todoStack.arrangedSubviews.firstObject;
            BOOL todoRowActionsOK = [rowB isKindOfClass:CPTodoRowView.class] &&
                                    rowB.cpEditButton != nil && rowB.cpDeleteButton != nil &&
                                    rowB.cpEditButton.alphaValue == 0.0 && rowB.cpDeleteButton.alphaValue == 0.0;
            NSEvent *rowNilEvent = nil; // 仅触发行 hover 状态翻转,事件本身不被使用
            [rowB mouseEntered:rowNilEvent];
            todoRowActionsOK = todoRowActionsOK &&
                               rowB.cpEditButton.alphaValue == 1.0 && rowB.cpDeleteButton.alphaValue == 1.0 &&
                               rowB.cpHoverOverlay.opacity > 0.02; // 5% 白 wash overlay
            [rowB mouseExited:rowNilEvent];
            todoRowActionsOK = todoRowActionsOK &&
                               rowB.cpEditButton.alphaValue == 0.0 && rowB.cpDeleteButton.alphaValue == 0.0 &&
                               rowB.cpHoverOverlay.opacity == 0.0;
            [todoCard.card layoutSubtreeIfNeeded];
            BOOL todoSizesOK = CPTodoStripHeight >= 32.0 &&
                               fabs(rowB.frame.size.height - CPTodoRowHeight) <= 0.5 && CPTodoRowHeight >= 30.0;
            // 勾选配色:未完成 muted 空心、完成 CPGreen;正文未完成 CPFg2、完成 muted。
            NSButton *checkPending = nil, *titlePending = nil;
            for (NSView *v in rowB.subviews) {
                if (![v isKindOfClass:NSButton.class]) continue;
                NSButton *b = (NSButton *)v;
                if (b.action == @selector(toggleTodo:)) checkPending = b;
                else if (b.action == @selector(startTodoEdit:) && [b isMemberOfClass:CPHoverButton.class]) titlePending = b;
            }
            NSColor *pendingTitleColor = [titlePending.attributedTitle attribute:NSForegroundColorAttributeName
                                                                         atIndex:0 effectiveRange:NULL];
            BOOL todoColorsOK = checkPending && titlePending &&
                                CGColorEqualToColor(checkPending.contentTintColor.CGColor, CPMuted().CGColor) &&
                                CGColorEqualToColor(pendingTitleColor.CGColor, CPFg2().CGColor);
            [todoCard.todoStore setTodo:checkPending.tag completed:YES];
            [todoCard renderTodos];
            CPTodoRowView *rowDone = (CPTodoRowView *)todoCard.todoStack.arrangedSubviews.lastObject; // 完成沉底
            NSButton *checkDone = nil, *titleDone = nil;
            for (NSView *v in rowDone.subviews) {
                if (![v isKindOfClass:NSButton.class]) continue;
                NSButton *b = (NSButton *)v;
                if (b.action == @selector(toggleTodo:)) checkDone = b;
                else if (b.action == @selector(startTodoEdit:) && [b isMemberOfClass:CPHoverButton.class]) titleDone = b;
            }
            NSColor *doneTitleColor = [titleDone.attributedTitle attribute:NSForegroundColorAttributeName
                                                                   atIndex:0 effectiveRange:NULL];
            todoColorsOK = todoColorsOK && checkDone && titleDone &&
                           CGColorEqualToColor(checkDone.contentTintColor.CGColor, CPGreen().CGColor) &&
                           CGColorEqualToColor(doneTitleColor.CGColor, CPMuted().CGColor);
            // 计数 pill:10.5pt;空库:空状态文案 + pill 收起(新控制器 = 新的隔离空库)。
            BOOL todoPillOK = fabs(todoCard.todoCountLabel.font.pointSize - 10.5) < 0.1;
            CPWorkbenchCardController *emptyCard = CPWorkbenchCardController.new;
            emptyCard.todoExpanded = YES;
            [emptyCard applyTodoExpandedState];
            NSView *emptyRow = emptyCard.todoStack.arrangedSubviews.firstObject;
            BOOL todoEmptyOK = emptyCard.todoStack.arrangedSubviews.count == 1 &&
                               [emptyRow isKindOfClass:NSTextField.class] &&
                               [((NSTextField *)emptyRow).stringValue isEqualToString:@"暂无待办，随手记一条"] &&
                               emptyCard.todoCountPill.hidden;
            [emptyCard.window orderOut:nil];
            BOOL todoBStyle = todoLayeringOK && todoHairlineOK && todoFocusOK && todoPlusOK &&
                              todoRowActionsOK && todoSizesOK && todoColorsOK && todoPillOK && todoEmptyOK;

            // L3a: Todo 收起几何回归 — collapsed shell 精确 34pt(= strip,无内部空尾),
            // strip/wash overlay 完整覆盖整个 shell;收起 chevron.down、展开 chevron.up;
            // strip hover = 4% 白 wash,不新增描边。
            [todoCard.card layoutSubtreeIfNeeded];
            CPHoverButton *stripBtn = (CPHoverButton *)todoCard.todoStripButton;
            BOOL todoCollapsedGeo = fabs(todoCard.todoHeightConstraint.constant - 34.0) <= 0.5 &&
                                    CPTodoCollapsedHeight == CPTodoStripHeight &&
                                    NSEqualRects(stripBtn.frame, todoCard.todoContainer.bounds) &&
                                    NSEqualRects(stripBtn.cpHoverOverlay.frame, stripBtn.layer.bounds) &&
                                    stripBtn.layer.borderWidth == 0.0;
            [stripBtn cpSetHovered:YES];
            todoCollapsedGeo = todoCollapsedGeo &&
                               fabs(stripBtn.cpHoverOverlay.opacity - 0.04) < 0.001 &&
                               stripBtn.layer.borderWidth == 0.0; // hover 不加描边
            [stripBtn cpSetHovered:NO];
            todoCollapsedGeo = todoCollapsedGeo && stripBtn.cpHoverOverlay.opacity == 0.0;
            BOOL todoChevronOK = [todoCard.todoChevronSymbolName isEqualToString:@"chevron.down"]; // 收起向下
            todoCard.todoExpanded = YES;
            [todoCard applyTodoExpandedState];
            todoChevronOK = todoChevronOK && [todoCard.todoChevronSymbolName isEqualToString:@"chevron.up"]; // 展开向上
            todoCard.todoExpanded = NO;
            [todoCard applyTodoExpandedState];
            [todoCard.window orderOut:nil];

            // L3b: 滚动残留回归 — 鼠标静止、clip bounds 改变(滚动)时旧行 hover 立即清零:
            // model/presentation 均为 0、无残留 animationKeys、Todo 行尾动作组 alpha 归 0;
            // 递增代际取消 pending revalidate。
            CPHoverButton *scrollRowA = (CPHoverButton *)card10.taskStack.arrangedSubviews[0];
            CPHoverButton *scrollRowB = (CPHoverButton *)card10.taskStack.arrangedSubviews[1];
            [scrollRowA cpSetHovered:YES];
            BOOL scrollHoverShown = scrollRowA.cpHoverOverlay.opacity > 0.0;
            NSInteger genBefore = card10.hoverRevalidateGeneration;
            [[NSNotificationCenter defaultCenter] postNotificationName:NSViewBoundsDidChangeNotification
                                                                object:card10.taskScrollView.contentView];
            CALayer *scrollPresA = (CALayer *)scrollRowA.cpHoverOverlay.presentationLayer ?: scrollRowA.cpHoverOverlay;
            BOOL scrollClearsHover = scrollRowA.cpHoverOverlay.opacity == 0.0 &&
                                     scrollPresA.opacity == 0.0 &&
                                     scrollRowA.cpHoverOverlay.animationKeys.count == 0 && // immediate:不重启退出动画
                                     card10.hoverRevalidateGeneration > genBefore;
            // Todo 行滚动清理:行 wash 与编辑/删除动作组同步归 0。
            CPTodoRowView *todoScrollRow = (CPTodoRowView *)todoCard.todoStack.arrangedSubviews.firstObject;
            [todoScrollRow cpSetRowHovered:YES];
            BOOL todoRowHoverShown = todoScrollRow.cpHoverOverlay.opacity > 0.0 &&
                                     todoScrollRow.cpEditButton.alphaValue == 1.0;
            [[NSNotificationCenter defaultCenter] postNotificationName:NSViewBoundsDidChangeNotification
                                                                object:todoCard.todoScrollView.contentView];
            scrollClearsHover = scrollClearsHover && todoRowHoverShown &&
                                todoScrollRow.cpHoverOverlay.opacity == 0.0 &&
                                todoScrollRow.cpHoverOverlay.animationKeys.count == 0 &&
                                todoScrollRow.cpEditButton.alphaValue == 0.0 &&
                                todoScrollRow.cpDeleteButton.alphaValue == 0.0;
            // Todo 子按钮命中恢复:revalidate 命中删除钮时,必须同时恢复行 hover 与动作组。
            [todoCard cpRestoreHoverForHitView:todoScrollRow.cpDeleteButton];
            BOOL todoRowRestoreOK = todoScrollRow.cpHoverOverlay.opacity > 0.0 &&
                                    todoScrollRow.cpEditButton.alphaValue == 1.0 &&
                                    todoScrollRow.cpDeleteButton.alphaValue == 1.0;
            [todoCard cpClearAllHoverImmediately];
            // 窗口失焦:立即清理 + 递增代际,取消滚动后尚未触发的 pending revalidate。
            [[NSNotificationCenter defaultCenter] postNotificationName:NSViewBoundsDidChangeNotification
                                                                object:card10.taskScrollView.contentView];
            NSInteger genAfterScroll = card10.hoverRevalidateGeneration;
            [[NSNotificationCenter defaultCenter] postNotificationName:NSWindowDidResignKeyNotification
                                                                object:card10.window];
            BOOL resignCancelsPending = card10.hoverRevalidateGeneration > genAfterScroll;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            NSInteger hoveredAfterScroll = 0;
            for (NSView *v in card10.taskStack.arrangedSubviews) {
                if ([v isKindOfClass:CPHoverButton.class] &&
                    ((CPHoverButton *)v).cpHoverOverlay.opacity > 0.0) hoveredAfterScroll++;
            }
            // 停止后按真实鼠标位置重校验:任何时刻最多只有实际鼠标下的一个 row hover。
            scrollClearsHover = scrollClearsHover && hoveredAfterScroll <= 1 && resignCancelsPending;
            [card10 cpClearAllHoverImmediately];

            // L3c: 快速 A→B→A 切换 — 动画可中断不堆积,最终 model/presentation 状态准确。
            [scrollRowA cpSetHovered:YES];
            [scrollRowA cpSetHovered:NO];
            [scrollRowB cpSetHovered:YES];
            [scrollRowB cpSetHovered:NO];
            [scrollRowA cpSetHovered:YES];
            BOOL rapidModelA = fabs(scrollRowA.cpHoverOverlay.opacity - scrollRowA.cpHoverWash) < 0.001;
            BOOL rapidModelB = scrollRowB.cpHoverOverlay.opacity == 0.0;
            BOOL rapidKeysA = scrollRowA.cpHoverOverlay.animationKeys.count <= 1;
            BOOL rapidKeysB = scrollRowB.cpHoverOverlay.animationKeys.count <= 1;
            BOOL rapidHoverOK = rapidModelA && rapidModelB && rapidKeysA && rapidKeysB;
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
            CALayer *presA = (CALayer *)scrollRowA.cpHoverOverlay.presentationLayer ?: scrollRowA.cpHoverOverlay;
            CALayer *presB = (CALayer *)scrollRowB.cpHoverOverlay.presentationLayer ?: scrollRowB.cpHoverOverlay;
            BOOL rapidPresA = fabs(presA.opacity - scrollRowA.cpHoverWash) < 0.01; // 收敛到终态
            BOOL rapidPresB = presB.opacity < 0.01; // 退出动画收敛到 0,不弹回
            rapidHoverOK = rapidHoverOK && rapidPresA && rapidPresB;
            [scrollRowA cpSetHovered:NO];
            BOOL hoverMotionOK = scrollHoverShown && scrollClearsHover && todoRowRestoreOK && rapidHoverOK;

            BOOL todoUI = todoAdd && todoBlankIgnored && todoComplete && todoRestore && todoEdit && todoDelete &&
                          todoPersist && todoAgentNull && todoUserVersion && todoStrip && todoNoOverlay && todoExpand &&
                          todoAutoReposition && todoExpandNoOverlay && todoCardStyle && todoUICount && todoBadgeIsolated &&
                          todoBStyle && todoCollapsedGeo && todoChevronOK;

            // Perf UI: 同签名跳过渲染、状态变化触发渲染(AppDelegate 合入路径,无窗口亦可断言计数)
            AppDelegate *perfDelegate = AppDelegate.new;
            CPAgent *perfA1 = CPTestAgent(@"perf-agent", @[CPTestTask(@"p1", CPStatusWorking, 100)]);
            NSString *perfSig1 = CPAgentsSignature(@[perfA1]);
            [perfDelegate applyAgents:@[perfA1] signature:perfSig1];
            [perfDelegate applyAgents:@[perfA1] signature:perfSig1]; // 同签名:必须跳过
            CPAgent *perfA2 = CPTestAgent(@"perf-agent", @[CPTestTask(@"p1", CPStatusCompleted, 200)]);
            [perfDelegate applyAgents:@[perfA2] signature:CPAgentsSignature(@[perfA2])]; // 变化:必须渲染
            BOOL perfSkipOK = perfDelegate.appliedRefreshCount == 2;

            // Perf UI: 8 层无限涟漪的去抖与可见性暂停
            // 相同参数重复 updateRipples 不重建动画(对象同一,相位不重启);参数变化才重建。
            CPRippleView *rvPerf = [[CPRippleView alloc] initWithRingDiameter:52 lineWidth:0.75];
            rvPerf.displayStatus = CPDisplayStatusWorking;
            [rvPerf updateRipples];
            CAAnimation *firstRun = [rvPerf.rippleLayers.firstObject animationForKey:@"ripple0"];
            [rvPerf updateRipples];
            BOOL rippleNoRestart = firstRun != nil &&
                                   firstRun == [rvPerf.rippleLayers.firstObject animationForKey:@"ripple0"];
            rvPerf.displayStatus = CPDisplayStatusFailed;
            [rvPerf updateRipples];
            BOOL rippleRestartsOnChange = firstRun != [rvPerf.rippleLayers.firstObject animationForKey:@"ripple0"];
            // HUD rail:收起(默认)时涟漪暂停、展开时恢复(可见性驱动,保留设计效果)。
            CPHUDWindowController *hudPerf = CPHUDWindowController.new;
            CPAgent *perfHudAgent = CPTestAgent(@"perf-hud", @[CPTestTask(@"ph1", CPStatusWorking, 1)]);
            [hudPerf updateWithAgents:@[perfHudAgent] selectedAgent:perfHudAgent];
            CPAgentStatusButton *perfBtn = (CPAgentStatusButton *)hudPerf.agentList.arrangedSubviews.firstObject;
            BOOL hudPausedWhenCollapsed = perfBtn.animationsPaused &&
                                          perfBtn.rippleLayers.firstObject.animationKeys.count == 0;
            perfBtn.reduceMotion = NO; // 排除系统 reduce-motion 干扰,断言确定性
            [hudPerf.window orderFrontRegardless]; // 窗口不可见时动画 completion 不会回投,收起收尾收不到
            [hudPerf expand];
            BOOL hudResumesOnExpand = !perfBtn.animationsPaused &&
                                      perfBtn.rippleLayers.firstObject.animationKeys.count > 0;
            [hudPerf collapse];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
            BOOL hudRepausesOnCollapse = perfBtn.animationsPaused &&
                                         perfBtn.rippleLayers.firstObject.animationKeys.count == 0;
            [hudPerf.window orderOut:nil];
            BOOL perfUI = perfSkipOK && rippleNoRestart && rippleRestartsOnChange &&
                          hudPausedWhenCollapsed && hudResumesOnExpand && hudRepausesOnCollapse;

            // M13: HUD 任务卡直达所属 Agent(独立 action/按 taskID 重解析/已查看标记/降级) + 任务区滚动
            NSString *m13Suite = [NSString stringWithFormat:@"com.codexpulse.hudtasktest.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *m13Defaults = [[NSUserDefaults alloc] initWithSuiteName:m13Suite];
            [m13Defaults removePersistentDomainForName:m13Suite];
            CPReviewStore *m13Store = [[CPReviewStore alloc] initWithDefaults:m13Defaults];

            CPHUDWindowController *hud13 = CPHUDWindowController.new;
            hud13.reviewStore = m13Store;
            CPTask *m13Done = CPTestTask(@"c1", CPStatusCompleted, 100);
            CPTask *m13Working = CPTestTask(@"k1", CPStatusWorking, 90);
            CPTask *m13Failed = CPTestTask(@"f1", CPStatusFailed, 80);
            CPAgent *m13Codex = CPTestAgent(@"codex", @[m13Done, m13Working, m13Failed,
                                                        CPTestTask(@"w1", CPStatusWaiting, 70)]);
            CPAgent *m13Other = CPTestAgent(@"kimi", @[CPTestTask(@"u1", CPStatusWorking, 60)]);
            [hud13 updateWithAgents:@[m13Codex, m13Other] selectedAgent:m13Codex];

            // 1) 任务卡 action 不再是 hudClicked:,且稳定携带 taskID。
            NSView *cardV13 = hud13.taskList.arrangedSubviews.firstObject;
            BOOL m13ActionOK = [cardV13 isKindOfClass:CPHUDTaskCardButton.class] &&
                               ((NSButton *)cardV13).action == @selector(taskCardClicked:) &&
                               ((NSButton *)cardV13).action != @selector(hudClicked:) &&
                               ((NSButton *)cardV13).target == hud13 &&
                               [((CPHUDTaskCardButton *)cardV13).taskID isEqualToString:@"c1"];

            // 2) 注入假 opener(绝不真的打开 Codex/Kimi),断言解析到正确 agent/task;
            //    completed/attention/failed/waiting 成功打开后标记已查看并广播 CPTaskReviewed。
            __block NSInteger m13OpenerCalls = 0;
            __block CPAgent *m13OpenedAgent = nil;
            __block CPTask *m13OpenedTask = nil;
            __block BOOL m13OpenResult = YES;
            hud13.taskOpener = ^BOOL(CPAgent *agent, CPTask *task) {
                m13OpenerCalls++;
                m13OpenedAgent = agent;
                m13OpenedTask = task;
                return m13OpenResult;
            };
            __block NSInteger m13ReviewedNotes = 0;
            id m13Token = [NSNotificationCenter.defaultCenter addObserverForName:@"CPTaskReviewed"
                                                                          object:nil queue:nil
                                                                      usingBlock:^(NSNotification *n) { m13ReviewedNotes++; }];
            __block BOOL m13WorkbenchFired = NO;
            hud13.onClicked = ^{ m13WorkbenchFired = YES; };

            [hud13 taskCardClicked:(CPHUDTaskCardButton *)cardV13]; // completed → 打开成功
            BOOL m13ResolveOK = m13OpenerCalls == 1 &&
                                m13OpenedAgent == m13Codex &&
                                [m13OpenedTask.taskID isEqualToString:@"c1"];
            BOOL m13ReviewMarked = [m13Store isTaskReviewed:m13Done agentID:@"codex"] && m13ReviewedNotes == 1;

            // working 状态成功打开不标记已查看(不属于提醒类)。
            CPHUDTaskCardButton *workingCard = (CPHUDTaskCardButton *)hud13.taskList.arrangedSubviews[1];
            [hud13 taskCardClicked:workingCard];
            BOOL m13WorkingNotMarked = m13OpenerCalls == 2 &&
                                       [m13OpenedTask.taskID isEqualToString:@"k1"] &&
                                       ![m13Store isTaskReviewed:m13Working agentID:@"codex"] &&
                                       m13ReviewedNotes == 1;

            // 3) 打不开所属 Agent 时回退工作台,且不提前伪造已查看。
            m13OpenResult = NO;
            CPHUDTaskCardButton *failedCard = (CPHUDTaskCardButton *)hud13.taskList.arrangedSubviews[2];
            [hud13 taskCardClicked:failedCard];
            BOOL m13FallbackOK = m13OpenerCalls == 3 && m13WorkbenchFired &&
                                 ![m13Store isTaskReviewed:m13Failed agentID:@"codex"] &&
                                 m13ReviewedNotes == 1;

            // 4) 卡片携带的 taskID 已不在当前数据(刷新后旧卡):不动作、不伪造。
            m13WorkbenchFired = NO;
            CPHUDTaskCardButton *ghostCard = [CPHUDTaskCardButton buttonWithTitle:@"" target:hud13 action:@selector(taskCardClicked:)];
            ghostCard.taskID = @"ghost";
            [hud13 taskCardClicked:ghostCard];
            BOOL m13StaleOK = m13OpenerCalls == 3 && !m13WorkbenchFired && m13ReviewedNotes == 1;
            [NSNotificationCenter.defaultCenter removeObserver:m13Token];

            // 5) 任务区为原生 NSScrollView:全部任务可达、overlay scroller、翻转 stack、内容超出可视高度。
            [hud13.window orderFrontRegardless];
            [hud13.visualView layoutSubtreeIfNeeded];
            BOOL m13ScrollStruct = hud13.taskScrollView.documentView == hud13.taskList &&
                                   hud13.taskScrollView.hasVerticalScroller &&
                                   !hud13.taskScrollView.hasHorizontalScroller &&
                                   hud13.taskScrollView.autohidesScrollers &&
                                   hud13.taskScrollView.scrollerStyle == NSScrollerStyleOverlay &&
                                   !hud13.taskScrollView.drawsBackground &&
                                   [hud13.taskList isFlipped];
            CGFloat m13ContentH = [hud13.taskList fittingSize].height;
            CGFloat m13ClipH = hud13.taskScrollView.contentView.bounds.size.height;
            BOOL m13Scrollable = hud13.taskList.arrangedSubviews.count == 4 &&
                                 m13ContentH > m13ClipH &&
                                 fabs(m13ClipH - CPHUDTaskAreaHeight) <= 1.0; // 默认露出约 2 张卡
            // 滚到底部后重建内容(刷新/切换 Agent)必须回到顶部。
            [hud13.taskScrollView.contentView scrollToPoint:NSMakePoint(0, m13ContentH)];
            [hud13 updateWithAgents:@[m13Codex, m13Other] selectedAgent:m13Codex];
            [hud13.visualView layoutSubtreeIfNeeded];
            BOOL m13BackToTop = fabs(hud13.taskScrollView.contentView.bounds.origin.y) <= 0.5;
            [hud13.window orderOut:nil];

            // 6) 空任务状态仍正常。
            CPAgent *m13Empty = CPTestAgent(@"m13-empty", @[]);
            [hud13 updateWithAgents:@[m13Empty] selectedAgent:m13Empty];
            NSView *m13EmptyV = hud13.taskList.arrangedSubviews.firstObject;
            BOOL m13EmptyOK = hud13.taskList.arrangedSubviews.count == 1 &&
                              [m13EmptyV isKindOfClass:NSTextField.class] &&
                              [((NSTextField *)m13EmptyV).stringValue isEqualToString:@"当前没有任务"] &&
                              hud13.moreLabel.stringValue.length == 0;

            [m13Defaults removePersistentDomainForName:m13Suite];
            [m13Defaults synchronize];

            BOOL m13ui = m13ActionOK && m13ResolveOK && m13ReviewMarked && m13WorkingNotMarked &&
                         m13FallbackOK && m13StaleOK && m13ScrollStruct && m13Scrollable &&
                         m13BackToTop && m13EmptyOK;

            // C-4: 统一主屏策略 + 屏幕参数变化后悬浮球 reclamp（单屏可验证）。
            NSScreen *policyScreen = CPTargetScreen();
            BOOL screenPolicyOK = policyScreen != nil && policyScreen == NSScreen.screens.firstObject;
            AppDelegate *screenAd = AppDelegate.new;
            screenAd.dock = CPDockWindowController.new;
            screenAd.card = CPWorkbenchCardController.new;
            screenAd.hud = CPHUDWindowController.new;
            [screenAd.dock show];
            screenAd.dock.freeX = -5000;
            screenAd.dock.freeY = -5000;
            screenAd.dock.docked = NO;
            [NSNotificationCenter.defaultCenter addObserver:screenAd
                                                   selector:@selector(screenParametersChanged:)
                                                       name:NSApplicationDidChangeScreenParametersNotification
                                                     object:nil];
            [NSNotificationCenter.defaultCenter postNotificationName:NSApplicationDidChangeScreenParametersNotification
                                                              object:NSApp];
            NSRect reclampVisible = policyScreen ? policyScreen.visibleFrame : NSZeroRect;
            NSRect orbRect = NSMakeRect(screenAd.dock.freeX, screenAd.dock.freeY, CPOrbSize, CPOrbSize);
            BOOL screenReclampOK = policyScreen != nil && NSContainsRect(reclampVisible, orbRect);
            [NSNotificationCenter.defaultCenter removeObserver:screenAd
                                                          name:NSApplicationDidChangeScreenParametersNotification
                                                        object:nil];

            // Bugfix: 贴边悬浮球探出/收回热区必须对齐可见球体,刷新不得把探出态打回细条。
            CPDockWindowController *dockPeek = CPDockWindowController.new;
            [dockPeek setMode:0];
            NSScreen *peekScreen = CPTargetScreen();
            NSRect peekVisible = peekScreen ? peekScreen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
            dockPeek.freeX = NSMaxX(peekVisible) - CPOrbSize;
            dockPeek.freeY = NSMidY(peekVisible) - CPOrbSize / 2.0;
            [dockPeek snapToEdge];
            BOOL dockPeekStrip = dockPeek.docked && !dockPeek.peeked && dockPeek.floatingPill.hidden &&
                                 fabs(dockPeek.window.frame.size.width - CPHotZone) <= 0.5 &&
                                 NSEqualRects(dockPeek.trackingArea.rect, dockPeek.pill.bounds);
            CPDockWindowController *dockSnap = CPDockWindowController.new;
            [dockSnap setMode:0];
            CGFloat snapRight = NSMaxX(peekVisible) - CPOrbSize;
            dockSnap.freeY = NSMidY(peekVisible) - CPOrbSize / 2.0;
            dockSnap.freeX = snapRight - 50.0; // 间隙 50pt,宽于阈值,不应吸附
            [dockSnap snapToEdge];
            BOOL snapFarKeepsFree = !dockSnap.docked;
            dockSnap.freeX = snapRight - 20.0; // 间隙 20pt,进入 24pt 阈值,应吸附
            [dockSnap snapToEdge];
            BOOL snapNearDocks = dockSnap.docked && dockSnap.dockEdge == NSRectEdgeMaxX;
            BOOL dockSnapRangeOK = snapFarKeepsFree && snapNearDocks;
            [dockPeek peek:YES];
            BOOL dockPeekTracksOrb = dockPeek.peeked && !dockPeek.floatingPill.hidden &&
                                     fabs(dockPeek.window.frame.size.width - CPOrbWindowSize) <= 0.5 &&
                                     NSEqualRects(dockPeek.trackingArea.rect, dockPeek.floatingPill.frame) &&
                                     !NSEqualRects(dockPeek.trackingArea.rect, dockPeek.pill.bounds);
            [dockPeek renderWithAgents:@[] selectedAgent:nil];
            BOOL dockPeekSurvivesRefresh = dockPeek.peeked && !dockPeek.floatingPill.hidden &&
                                           fabs(dockPeek.window.frame.size.width - CPOrbWindowSize) <= 0.5 &&
                                           NSEqualRects(dockPeek.trackingArea.rect, dockPeek.floatingPill.frame);
            [dockPeek unpeek];
            BOOL dockUnpeekStrip = dockPeek.docked && !dockPeek.peeked && dockPeek.floatingPill.hidden &&
                                   fabs(dockPeek.window.frame.size.width - CPHotZone) <= 0.5 &&
                                   NSEqualRects(dockPeek.trackingArea.rect, dockPeek.pill.bounds);
            BOOL dockPeekOK = dockPeekStrip && dockPeekTracksOrb && dockPeekSurvivesRefresh && dockUnpeekStrip && dockSnapRangeOK;

            // 配对卡(菜单栏「连接手机…」):码只在内存、二维码必须能被扫回原文、
            // Bridge 没起来时要明说而不是画一个扫不通的空码。
            CPPairingSheetController *pairSheet = CPPairingSheetController.new;
            __block NSInteger pairIssueCount = 0;
            __block NSString *pairFakeCode = @"482019";
            pairSheet.codeTTL = 180.0;
            pairSheet.codeProvider = ^NSString *(BOOL regenerate) {
                pairIssueCount += 1;
                if (regenerate) pairFakeCode = @"137025";
                return pairFakeCode;
            };
            pairSheet.baseURLProvider = ^NSString *{ return @"http://192.168.1.7:8787"; };
            [pairSheet show];
            BOOL pairURLOK = [pairSheet.encodedURL isEqualToString:@"http://192.168.1.7:8787/?code=482019"];
            // 六位码在界面上分两组显示,但承载进二维码的必须是原始连续六位。
            BOOL pairCodeGrouped = [pairSheet.hintLabel.stringValue containsString:@"秒后失效"] &&
                                   [pairSheet.encodedURL hasSuffix:@"code=482019"];
            BOOL pairQRPresent = pairSheet.qrView.image != nil;
            BOOL pairQRNativeSize = NO;
            BOOL pairQRScannable = NO;
            if (pairSheet.qrView.image) {
                // 整数倍放大:尺寸必须是 CIQRCodeGenerator 原生模块数的整数倍,不是恰好 168。
                NSSize size = pairSheet.qrView.image.size;
                pairQRNativeSize = size.width == size.height && size.width > 0 && size.width <= 168.0;
                CIImage *ci = [CIImage imageWithData:[pairSheet.qrView.image TIFFRepresentation]];
                CIDetector *det = [CIDetector detectorOfType:CIDetectorTypeQRCode context:nil
                                                     options:@{CIDetectorAccuracy: CIDetectorAccuracyHigh}];
                for (CIFeature *f in [det featuresInImage:ci]) {
                    if ([f isKindOfClass:CIQRCodeFeature.class]) {
                        pairQRScannable = [((CIQRCodeFeature *)f).messageString isEqualToString:pairSheet.encodedURL];
                        break;
                    }
                }
            }
            [pairSheet regenerate:nil];
            BOOL pairRegenerates = [pairSheet.encodedURL hasSuffix:@"code=137025"] && pairIssueCount >= 2;

            // 配对成功后不该让用户自己关卡片:确认态要撤掉已失效的码并显示设备名。
            [pairSheet showPairedWithDeviceName:@"我的 iPhone"];
            BOOL pairPairedState = pairSheet.qrView.image == nil &&
                                   pairSheet.encodedURL == nil &&
                                   [pairSheet.hintLabel.stringValue containsString:@"我的 iPhone"] &&
                                   [pairSheet.hintLabel.stringValue containsString:@"已连接"];

            CPPairingSheetController *pairDown = CPPairingSheetController.new;
            pairDown.codeProvider = ^NSString *(BOOL regenerate) { (void)regenerate; return nil; };
            pairDown.baseURLProvider = ^NSString *{ return nil; };
            [pairDown show];
            BOOL pairNoBridgeExplicit = pairDown.qrView.image == nil &&
                                        pairDown.encodedURL == nil &&
                                        pairDown.hintLabel.stringValue.length > 0;
            [pairSheet close];
            [pairDown close];
            BOOL pairingUI = pairURLOK && pairCodeGrouped && pairQRPresent && pairQRNativeSize &&
                             pairQRScannable && pairRegenerates && pairPairedState && pairNoBridgeExplicit;

            BOOL passed = pairingUI && centered && draggableHeader && labeledWorkbench && onlyRealAgents && labeledAgent && buttonReceivesClick &&
                          agentStatusDotsAligned && attentionBadgeClearsOnOpen &&
                          cardMasksToBounds && shadowCarrierNoMasks && cardIsChildOfShadowCarrier && windowHasWorkbenchInset &&
                          fixedCardSize && twoColumn && rightOverlayHidden &&
                          hudCollapsed6x72 && hudCollapsedOnMainScreen && hudExpandedSizeOK && hudExpandedOnMainScreen &&
                          shadowCarrierScales && handleAnchoredTopRight && contentNotSizable && hudClickViewIsBackgroundView &&
                          hudVisualFrameExact && hudExpandedHandleHidden && m2ui && m3ui && m3entries && m4ui && m5ui && m7ui && m8ui && m9ui && m10ui &&
                          hoverResidualOK && hoverMotionOK && todoUI && perfUI && m13ui &&
                          screenPolicyOK && screenReclampOK && dockPeekOK;
            NSMutableString *result = [NSMutableString stringWithFormat:
                @"Lantai UI self-test: center=%@ drag=%@ workbench-label=%@ real-agents=%@ agent-label=%@ button-hit=%@ "
                @"card-mask=%@ carrier-mask=%@ card-child=%@ win-inset=%@ card-520x402=%@ two-column=%@ right-overlay=%@ "
                @"hud-6x72=%@ hud-collapsed-pos=%@ hud-expanded-size=%@ hud-expanded-pos=%@ "
                @"hud-carrier-scale=%@ hud-handle-tr=%@ hud-content-fixed=%@ hud-bg-click=%@ "
                @"hud-visual-frame=%@ hud-expanded-handle-hidden=%@\n",
                centered ? @"OK" : @"FAIL",
                draggableHeader ? @"OK" : @"FAIL",
                labeledWorkbench ? @"OK" : @"FAIL",
                onlyRealAgents ? @"OK" : @"FAIL",
                labeledAgent ? @"OK" : @"FAIL",
                buttonReceivesClick ? @"OK" : @"FAIL",
                cardMasksToBounds ? @"OK" : @"FAIL",
                shadowCarrierNoMasks ? @"OK" : @"FAIL",
                cardIsChildOfShadowCarrier ? @"OK" : @"FAIL",
                windowHasWorkbenchInset ? @"OK" : @"FAIL",
                fixedCardSize ? @"OK" : @"FAIL",
                twoColumn ? @"OK" : @"FAIL",
                rightOverlayHidden ? @"OK" : @"FAIL",
                hudCollapsed6x72 ? @"OK" : @"FAIL",
                hudCollapsedOnMainScreen ? @"OK" : @"FAIL",
                hudExpandedSizeOK ? @"OK" : @"FAIL",
                hudExpandedOnMainScreen ? @"OK" : @"FAIL",
                shadowCarrierScales ? @"OK" : @"FAIL",
                handleAnchoredTopRight ? @"OK" : @"FAIL",
                contentNotSizable ? @"OK" : @"FAIL",
                hudClickViewIsBackgroundView ? @"OK" : @"FAIL",
                hudVisualFrameExact ? @"OK" : @"FAIL",
                hudExpandedHandleHidden ? @"OK" : @"FAIL"];
            [result appendFormat:@"M2 UI self-test: ring-colors=%@ blue-double=%@ reduce-motion=%@ ripple-anim=%@ ripple-blue=%@ hud-agent-scope=%@ hud-select-by-id=%@ agent-latest-task=%@\n",
                ringColorsOK ? @"OK" : @"FAIL",
                blueDoubleOK ? @"OK" : @"FAIL",
                reduceMotionOK ? @"OK" : @"FAIL",
                motionAnimOK ? @"OK" : @"FAIL",
                blueAnimOK ? @"OK" : @"FAIL",
                hudAgentScope ? @"OK" : @"FAIL",
                hudSelectByID ? @"OK" : @"FAIL",
                agentUrgencyOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"Bugfix UI self-test: agent-dot-column=%@ attention-badge-clears=%@ dock-peek-strip=%@ dock-peek-tracks-orb=%@ dock-peek-survives-refresh=%@ dock-unpeek-strip=%@ dock-snap-range=%@\n",
                agentStatusDotsAligned ? @"OK" : @"FAIL",
                attentionBadgeClearsOnOpen ? @"OK" : @"FAIL",
                dockPeekStrip ? @"OK" : @"FAIL",
                dockPeekTracksOrb ? @"OK" : @"FAIL",
                dockPeekSurvivesRefresh ? @"OK" : @"FAIL",
                dockUnpeekStrip ? @"OK" : @"FAIL",
                dockSnapRangeOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"M3 UI self-test: drawer-init-hidden=%@ render-no-mark=%@ drawer-on-click=%@ review-on-open=%@ stale-row=%@ esc-drawer=%@ esc-workbench=%@\n",
                drawerInitiallyHidden ? @"OK" : @"FAIL",
                renderDoesNotMark ? @"OK" : @"FAIL",
                drawerShownOnClick ? @"OK" : @"FAIL",
                reviewMarkedOnOpen ? @"OK" : @"FAIL",
                m3GhostOK ? @"OK" : @"FAIL",
                firstEscDrawerOnly ? @"OK" : @"FAIL",
                secondEscClosesWorkbench ? @"OK" : @"FAIL"];
            [result appendFormat:@"M3 entries self-test: reshow-visible=%@ reshow-centered=%@ reshow-fixed-size=%@\n",
                reshowVisible ? @"OK" : @"FAIL",
                reshowCentered ? @"OK" : @"FAIL",
                reshowFixedSize ? @"OK" : @"FAIL"];
            [result appendFormat:@"M4 UI self-test: refresh-new-instances=%@ drawer-kept=%@ refresh-no-mark=%@ agent-fallback=%@ task-gone-close=%@ hud-no-dup=%@ single-ripple=%@ dock-orb=%@ dock-bar=%@ dock-callback=%@ sqlite-readonly=%@ single-instance=%@\n",
                refreshNewInstances ? @"OK" : @"FAIL",
                drawerKeptOnRefresh ? @"OK" : @"FAIL",
                refreshNoMark ? @"OK" : @"FAIL",
                agentFallback ? @"OK" : @"FAIL",
                taskGoneClosesDrawer ? @"OK" : @"FAIL",
                hudNoDupButtons ? @"OK" : @"FAIL",
                singleRippleKeys ? @"OK" : @"FAIL",
                dockOrbVisible ? @"OK" : @"FAIL",
                dockBarVisible ? @"OK" : @"FAIL",
                dockCallbackOK ? @"OK" : @"FAIL",
                sqliteReadonly ? @"OK" : @"FAIL",
                singleInstanceGuard ? @"OK" : @"FAIL"];
            [result appendFormat:@"M5 UI self-test: dynamic-tokens=%@ dark-base=%@ contrast-adjust=%@ dark-windows=%@ title-truncate=%@ task-cap=%@ empty-state=%@ work-title-truncate=%@\n",
                dynamicTokensOK ? @"OK" : @"FAIL",
                darkBaseOK ? @"OK" : @"FAIL",
                contrastAdjustOK ? @"OK" : @"FAIL",
                darkWindowsOK ? @"OK" : @"FAIL",
                titleTruncates ? @"OK" : @"FAIL",
                taskCapOK ? @"OK" : @"FAIL",
                emptyStateOK ? @"OK" : @"FAIL",
                workTitleTruncates ? @"OK" : @"FAIL"];
            [result appendFormat:@"M7 UI self-test: orb-window=%@ orb-centered=%@ orb-margin=%@ hover-no-clip=%@ ripple-params=%@ ripple-overall=%@ ripple-status-colors=%@ orb-ripple=%@ orb-ripple-curve=%@ orb-ripple-geo=%@ orb-ripple-color=%@ orb-reduce=%@ orb-hover-weak=%@ badge-zero=%@ badge-circle=%@ badge-centered=%@ badge-in-window=%@ badge-capsule=%@ badge-overflow=%@ badge-helper=%@\n",
                orbWindowLarger ? @"OK" : @"FAIL",
                orbCentered ? @"OK" : @"FAIL",
                orbMarginOK ? @"OK" : @"FAIL",
                hoverNotClipped ? @"OK" : @"FAIL",
                m1ParamsOK ? @"OK" : @"FAIL",
                m1OverallOK ? @"OK" : @"FAIL",
                m1StatusColorsOK ? @"OK" : @"FAIL",
                orbRippleOK ? @"OK" : @"FAIL",
                orbRippleCurveOK ? @"OK" : @"FAIL",
                orbRippleGeo ? @"OK" : @"FAIL",
                orbRippleColorOK ? @"OK" : @"FAIL",
                orbReduceOK ? @"OK" : @"FAIL",
                orbHoverWeakens ? @"OK" : @"FAIL",
                badgeZeroHidden ? @"OK" : @"FAIL",
                badgeCircle ? @"OK" : @"FAIL",
                badgeCentered ? @"OK" : @"FAIL",
                badgeInWindow ? @"OK" : @"FAIL",
                badgeCapsule ? @"OK" : @"FAIL",
                badgeOverflow ? @"OK" : @"FAIL",
                badgeHelperSemantics ? @"OK" : @"FAIL"];
            [result appendFormat:@"M8 UI self-test: hud-size=%@ hud-opaque-dark=%@ hud-carrier-noclip=%@ hud-cap2=%@ hud-summary=%@ hud-min-font=%@ hud-no-path=%@ hud-title-trunc=%@ hud-rail=%@ hud-scope=%@ hud-rail-selected=%@ hud-rail-hit=%@ hud-empty=%@ hud-geo=%@ hud-handle-tab=%@ legend=%@\n",
                hudSizeOK ? @"OK" : @"FAIL",
                hudOpaqueDark ? @"OK" : @"FAIL",
                hudCarrierNoClip ? @"OK" : @"FAIL",
                hudCapOK ? @"OK" : @"FAIL",
                hudSummaryOK ? @"OK" : @"FAIL",
                hudMinFontOK ? @"OK" : @"FAIL",
                hudNoPathOK ? @"OK" : @"FAIL",
                hudTitleTruncOK ? @"OK" : @"FAIL",
                hudRailOK ? @"OK" : @"FAIL",
                hudScopeOK ? @"OK" : @"FAIL",
                hudRailSelected ? @"OK" : @"FAIL",
                hudRailHitOK ? @"OK" : @"FAIL",
                hudEmptyOK ? @"OK" : @"FAIL",
                hudGeoOK ? @"OK" : @"FAIL",
                hudHandleTabOK ? @"OK" : @"FAIL",
                legendOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"M5 UI self-test(动画生命周期): hud-rapid-toggle=%@\n",
                hudRapidOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"M9 UI self-test: detail-fullwidth=%@ detail-grid=%@ detail-title-trunc=%@ detail-activity-trunc=%@ detail-tokens=%@ detail-date=%@ detail-dash=%@ detail-back-hit=%@ detail-back-visible=%@ detail-back-topleft=%@ detail-direct-open=%@ detail-refresh-keep=%@ detail-refresh-gone=%@ detail-esc1=%@ detail-esc2=%@ workbench-keyable=%@ show-makes-key=%@ detail-barrier=%@ detail-barrier-restore=%@ detail-mutex-open=%@ detail-mutex-restored=%@\n",
                m9FullWidth ? @"OK" : @"FAIL",
                m9GridOK ? @"OK" : @"FAIL",
                m9TitleTruncOK ? @"OK" : @"FAIL",
                m9ActivityTruncOK ? @"OK" : @"FAIL",
                m9TokensOK ? @"OK" : @"FAIL",
                m9DateOK ? @"OK" : @"FAIL",
                m9DashOK ? @"OK" : @"FAIL",
                m9BackHitOK ? @"OK" : @"FAIL",
                m9BackVisible ? @"OK" : @"FAIL",
                m9BackTopLeft ? @"OK" : @"FAIL",
                m9DirectOpen ? @"OK" : @"FAIL",
                m9RefreshKeep ? @"OK" : @"FAIL",
                m9RefreshGone ? @"OK" : @"FAIL",
                m9Esc1 ? @"OK" : @"FAIL",
                m9Esc2 ? @"OK" : @"FAIL",
                m9Keyable ? @"OK" : @"FAIL",
                m9ShowMakesKey ? @"OK" : @"FAIL",
                m9BarrierOpen ? @"OK" : @"FAIL",
                m9BarrierRestored ? @"OK" : @"FAIL",
                m9MutexOpen ? @"OK" : @"FAIL",
                m9MutexRestored ? @"OK" : @"FAIL"];
            [result appendFormat:@"M10 UI self-test: task-scroll=%@ header-fixed=%@ scrollable=%@ first-row=%@ last-row-inset=%@ width-follow=%@\n",
                m10ScrollStruct ? @"OK" : @"FAIL",
                m10HeaderFixed ? @"OK" : @"FAIL",
                m10Scrollable ? @"OK" : @"FAIL",
                m10FirstRowOK ? @"OK" : @"FAIL",
                m10LastRowOK ? @"OK" : @"FAIL",
                m10WidthOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"L2 UI self-test(hover 残留): hover-shown=%@ exit-cleared=%@ window-move-cleared=%@ hide-cleared=%@ remove-cleared=%@\n",
                hoverShown ? @"OK" : @"FAIL",
                hoverExitCleared ? @"OK" : @"FAIL",
                hoverMoveCleared ? @"OK" : @"FAIL",
                hoverHideCleared ? @"OK" : @"FAIL",
                hoverRemoveCleared ? @"OK" : @"FAIL"];
            [result appendFormat:@"Todo self-test: add=%@ blank-ignored=%@ complete=%@ restore=%@ edit=%@ delete=%@ persist=%@ agent-null=%@ user-version=%@ strip=%@ no-overlay=%@ expand=%@ auto-reposition=%@ expand-no-overlay=%@ card-style=%@ ui-count=%@ badge-isolated=%@\n",
                todoAdd ? @"OK" : @"FAIL",
                todoBlankIgnored ? @"OK" : @"FAIL",
                todoComplete ? @"OK" : @"FAIL",
                todoRestore ? @"OK" : @"FAIL",
                todoEdit ? @"OK" : @"FAIL",
                todoDelete ? @"OK" : @"FAIL",
                todoPersist ? @"OK" : @"FAIL",
                todoAgentNull ? @"OK" : @"FAIL",
                todoUserVersion ? @"OK" : @"FAIL",
                todoStrip ? @"OK" : @"FAIL",
                todoNoOverlay ? @"OK" : @"FAIL",
                todoExpand ? @"OK" : @"FAIL",
                todoAutoReposition ? @"OK" : @"FAIL",
                todoExpandNoOverlay ? @"OK" : @"FAIL",
                todoCardStyle ? @"OK" : @"FAIL",
                todoUICount ? @"OK" : @"FAIL",
                todoBadgeIsolated ? @"OK" : @"FAIL"];
            [result appendFormat:@"Todo B self-test: layering=%@ hairline=%@ focus=%@ plus=%@ row-actions=%@ sizes=%@ colors=%@ pill=%@ empty=%@\n",
                todoLayeringOK ? @"OK" : @"FAIL",
                todoHairlineOK ? @"OK" : @"FAIL",
                todoFocusOK ? @"OK" : @"FAIL",
                todoPlusOK ? @"OK" : @"FAIL",
                todoRowActionsOK ? @"OK" : @"FAIL",
                todoSizesOK ? @"OK" : @"FAIL",
                todoColorsOK ? @"OK" : @"FAIL",
                todoPillOK ? @"OK" : @"FAIL",
                todoEmptyOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"L3 UI self-test(hover 动效/滚动残留): collapsed-geo=%@ chevron=%@ scroll-shown=%@ scroll-clears=%@ todo-row-restore=%@ rapid-aba=%@\n",
                todoCollapsedGeo ? @"OK" : @"FAIL",
                todoChevronOK ? @"OK" : @"FAIL",
                scrollHoverShown ? @"OK" : @"FAIL",
                scrollClearsHover ? @"OK" : @"FAIL",
                todoRowRestoreOK ? @"OK" : @"FAIL",
                rapidHoverOK ? @"OK" : @"FAIL"];
            if (!rapidHoverOK) {
                [result appendFormat:@"  diagnostic: modelA=%d modelB=%d keysA=%d keysB=%d presA=%d presB=%d (countA=%lu keys=%@)\n",
                 rapidModelA ? 1 : 0, rapidModelB ? 1 : 0, rapidKeysA ? 1 : 0, rapidKeysB ? 1 : 0,
                 rapidPresA ? 1 : 0, rapidPresB ? 1 : 0,
                 (unsigned long)scrollRowA.cpHoverOverlay.animationKeys.count,
                 [scrollRowA.cpHoverOverlay.animationKeys componentsJoinedByString:@","]];
            }
            [result appendFormat:@"Perf UI self-test: signature-skip=%@ ripple-no-restart=%@ ripple-restart-on-change=%@ hud-paused-collapsed=%@ hud-resume-expand=%@ hud-repause-collapse=%@\n",
                perfSkipOK ? @"OK" : @"FAIL",
                rippleNoRestart ? @"OK" : @"FAIL",
                rippleRestartsOnChange ? @"OK" : @"FAIL",
                hudPausedWhenCollapsed ? @"OK" : @"FAIL",
                hudResumesOnExpand ? @"OK" : @"FAIL",
                hudRepausesOnCollapse ? @"OK" : @"FAIL"];
            [result appendFormat:@"M13 UI self-test(HUD 任务直达+滚动): card-action=%@ resolve=%@ review-marked=%@ working-not-marked=%@ workbench-fallback=%@ stale-card=%@ scroll-struct=%@ scrollable=%@ back-to-top=%@ empty=%@\n",
                m13ActionOK ? @"OK" : @"FAIL",
                m13ResolveOK ? @"OK" : @"FAIL",
                m13ReviewMarked ? @"OK" : @"FAIL",
                m13WorkingNotMarked ? @"OK" : @"FAIL",
                m13FallbackOK ? @"OK" : @"FAIL",
                m13StaleOK ? @"OK" : @"FAIL",
                m13ScrollStruct ? @"OK" : @"FAIL",
                m13Scrollable ? @"OK" : @"FAIL",
                m13BackToTop ? @"OK" : @"FAIL",
                m13EmptyOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"C4 UI self-test(多屏): screen-policy=%@ screen-reclamp=%@\n",
                screenPolicyOK ? @"OK" : @"FAIL",
                screenReclampOK ? @"OK" : @"FAIL"];
            [result appendFormat:@"Pairing UI self-test: url=%@ hint=%@ qr=%@ qr-native=%@ qr-scannable=%@ regenerate=%@ paired-state=%@ no-bridge=%@\n",
                pairURLOK ? @"OK" : @"FAIL",
                pairCodeGrouped ? @"OK" : @"FAIL",
                pairQRPresent ? @"OK" : @"FAIL",
                pairQRNativeSize ? @"OK" : @"FAIL",
                pairQRScannable ? @"OK" : @"FAIL",
                pairRegenerates ? @"OK" : @"FAIL",
                pairPairedState ? @"OK" : @"FAIL",
                pairNoBridgeExplicit ? @"OK" : @"FAIL"];
            if (!centered) {
                [result appendFormat:@"  diagnostic: testVisible=%@ cardFrame=%@ hasScreen=%@\n",
                 NSStringFromRect(testVisible), NSStringFromRect(cardFrame), hasScreen ? @"YES" : @"NO"];
            }
            if (!todoAutoReposition) {
                [result appendFormat:@"  diagnostic: todoScreen=%@ todoWindow=%@\n",
                 NSStringFromRect(todoScreen.visibleFrame), NSStringFromRect(todoCard.window.frame)];
            }
            fputs(result.UTF8String, stdout);
            fflush(stdout);
            if (argc > 2) {
                NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
                [result writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return passed ? 0 : 3;
}

static BOOL CPRunControlSettingsSelfTest(void) {
    NSString *suite = [NSString stringWithFormat:@"com.codexpulse.control-settings.%d",
                       NSProcessInfo.processInfo.processIdentifier];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];

    NSString *dirA = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"lantai-cs-a-%d", NSProcessInfo.processInfo.processIdentifier]];
    NSString *dirB = [NSTemporaryDirectory() stringByAppendingPathComponent:
                      [NSString stringWithFormat:@"lantai-cs-b-%d", NSProcessInfo.processInfo.processIdentifier]];
    [[NSFileManager defaultManager] createDirectoryAtPath:dirA withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dirB withIntermediateDirectories:YES attributes:nil error:nil];

    CPWorkdirStore *store = [[CPWorkdirStore alloc] initWithDefaults:defaults];
    CPWorkdirEntry *added = [store addPath:dirA name:@"项目甲"];
    BOOL storeAdd = added.workdirID.length && [added.name isEqualToString:@"项目甲"] &&
                    [added.path isEqualToString:dirA.stringByStandardizingPath] && store.allEntries.count == 1;
    BOOL storeRename = [store renameEntry:added.workdirID to:@"项目甲改"] &&
                       [[store entryWithID:added.workdirID].name isEqualToString:@"项目甲改"];
    CPWorkdirEntry *dup = [store addPath:dirA name:@"重复"];
    BOOL storeDup = [dup.workdirID isEqualToString:added.workdirID] && store.allEntries.count == 1;
    CPWorkdirEntry *second = [store addPath:dirB name:@"项目乙"];
    BOOL storeSecond = second.workdirID.length && ![second.workdirID isEqualToString:added.workdirID] &&
                       store.allEntries.count == 2;
    BOOL storeHit = [store entryWithID:added.workdirID] != nil;
    BOOL storeMiss = [store entryWithID:@"no-such-id"] == nil;
    BOOL storeRemove = [store removeEntry:second.workdirID] && store.allEntries.count == 1 &&
                       [store entryWithID:second.workdirID] == nil;

    NSString *malSuite = [NSString stringWithFormat:@"com.codexpulse.control-settings-mal.%d",
                          NSProcessInfo.processInfo.processIdentifier];
    NSUserDefaults *malDefaults = [[NSUserDefaults alloc] initWithSuiteName:malSuite];
    [malDefaults removePersistentDomainForName:malSuite];
    NSString *junkFile = [dirA stringByAppendingPathComponent:@"not-a-dir"];
    [@"x" writeToFile:junkFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [malDefaults setObject:@[
        @{ @"name": @"缺 ID", @"path": dirA },
        @{ @"workdirID": @"wd-dup", @"name": @"先到", @"path": dirA },
        @{ @"workdirID": @"wd-dup", @"name": @"重复", @"path": dirA },
        @{ @"workdirID": @"wd-gone", @"name": @"不存在", @"path": @"/tmp/lantai-no-such-workdir" },
        @{ @"workdirID": @"wd-file", @"name": @"是文件", @"path": junkFile },
        @{ @"workdirID": @"wd-ok", @"name": @"合法", @"path": dirA },
        @{ @"workdirID": @12, @"name": @"类型错", @"path": dirA },
    ] forKey:CPWorkdirStore.defaultsKey];
    CPWorkdirStore *malStore = [[CPWorkdirStore alloc] initWithDefaults:malDefaults];
    NSArray<CPWorkdirEntry *> *malEntries = malStore.allEntries;
    BOOL storeMalformed = malEntries.count == 2 &&
        [malEntries[0].workdirID isEqualToString:@"wd-dup"] &&
        [malEntries[0].name isEqualToString:@"先到"] &&
        [malEntries[1].workdirID isEqualToString:@"wd-ok"];
    BOOL storeMissingPath = [malStore entryWithID:@"wd-gone"] == nil &&
                            [malStore entryWithID:@"wd-file"] == nil;

    CPBridgeServer *bridge = CPBridgeServer.new;
    bridge.persistPort = NO;
    bridge.loopbackOnly = YES;
    bridge.defaults = defaults;
    NSDictionary *beforeSnap = [bridge snapshotDictionary];
    NSArray *beforeWds = [beforeSnap[@"workdirs"] isKindOfClass:NSArray.class] ? beforeSnap[@"workdirs"] : @[];
    CPWorkdirEntry *snapEntry = [store addPath:dirB name:@"快照项目"];
    NSDictionary *fullSnap = [bridge snapshotDictionary];
    NSArray *fullWds = [fullSnap[@"workdirs"] isKindOfClass:NSArray.class] ? fullSnap[@"workdirs"] : @[];
    BOOL foundSnap = NO;
    for (NSDictionary *row in fullWds) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        if ([row[@"workdirID"] isEqualToString:snapEntry.workdirID]) {
            foundSnap = [row[@"name"] isEqualToString:@"快照项目"] && row[@"path"] == nil;
            break;
        }
    }
    BOOL snapFollows = fullWds.count == beforeWds.count + 1 && foundSnap;
    [bridge publishSnapshotNow];

    [NSApplication sharedApplication];
    NSString *emptySuite = [NSString stringWithFormat:@"com.codexpulse.control-settings-ui-empty.%d",
                            NSProcessInfo.processInfo.processIdentifier];
    NSUserDefaults *emptyDefaults = [[NSUserDefaults alloc] initWithSuiteName:emptySuite];
    [emptyDefaults removePersistentDomainForName:emptySuite];
    CPControlSettingsController *emptyPanel = CPControlSettingsController.new;
    emptyPanel.workdirStore = [[CPWorkdirStore alloc] initWithDefaults:emptyDefaults];
    emptyPanel.devicesProvider = ^NSArray<NSDictionary *> *{ return @[]; };
    [emptyPanel reload];
    BOOL emptyGuide = emptyPanel.devicesEmptyLabel.stringValue.length > 0 &&
                      emptyPanel.devicesEmptyLabel.superview != nil &&
                      emptyPanel.displayedDeviceIDs.count == 0 &&
                      emptyPanel.projectsEmptyLabel.stringValue.length > 0 &&
                      emptyPanel.projectsEmptyLabel.superview != nil;

    __block NSString *setDevice = nil;
    __block BOOL setValue = NO;
    __block NSInteger setCount = 0;
    __block NSString *revoked = nil;
    NSMutableArray<NSDictionary *> *liveDevices = [@[
        @{ @"deviceId": @"dev-a", @"deviceName": @"厨房 iPhone", @"createdAt": @(1786630000.0), @"canControl": @NO },
        @{ @"deviceId": @"dev-b", @"deviceName": @"口袋 iPhone", @"createdAt": @(1786700000.0), @"canControl": @YES },
    ] mutableCopy];
    NSString *uiSuite = [NSString stringWithFormat:@"com.codexpulse.control-settings-ui.%d",
                         NSProcessInfo.processInfo.processIdentifier];
    NSUserDefaults *uiDefaults = [[NSUserDefaults alloc] initWithSuiteName:uiSuite];
    [uiDefaults removePersistentDomainForName:uiSuite];
    CPControlSettingsController *panel = CPControlSettingsController.new;
    panel.workdirStore = [[CPWorkdirStore alloc] initWithDefaults:uiDefaults];
    panel.devicesProvider = ^NSArray<NSDictionary *> *{ return liveDevices; };
    panel.setControlHandler = ^BOOL(NSString *deviceId, BOOL canControl) {
        setDevice = deviceId;
        setValue = canControl;
        setCount += 1;
        for (NSUInteger i = 0; i < liveDevices.count; i++) {
            NSMutableDictionary *row = [liveDevices[i] mutableCopy];
            if ([row[@"deviceId"] isEqualToString:deviceId]) {
                row[@"canControl"] = canControl ? @YES : @NO;
                liveDevices[i] = row;
                return YES;
            }
        }
        return NO;
    };
    panel.revokeHandler = ^BOOL(NSString *deviceId) {
        revoked = deviceId;
        [liveDevices filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *row, NSDictionary *bindings) {
            (void)bindings;
            return ![row[@"deviceId"] isEqualToString:deviceId];
        }]];
        return YES;
    };
    [panel reload];
    BOOL listsDevices = panel.displayedDeviceIDs.count == 2 &&
                        [panel.displayedDeviceIDs[0] isEqualToString:@"dev-a"] &&
                        [panel.displayedDeviceIDs[1] isEqualToString:@"dev-b"] &&
                        panel.devicesEmptyLabel.superview == nil;
    BOOL switchState = panel.controlSwitches.count == 2 &&
                       panel.controlSwitches[0].state == NSControlStateValueOff &&
                       panel.controlSwitches[1].state == NSControlStateValueOn;
    [panel.controlSwitches[0] performClick:nil];
    BOOL toggleCalls = setCount == 1 && [setDevice isEqualToString:@"dev-a"] && setValue &&
                       panel.controlSwitches[0].state == NSControlStateValueOn;
    [panel revokeAtIndex:1];
    BOOL revokeCalls = [revoked isEqualToString:@"dev-b"] && panel.displayedDeviceIDs.count == 1 &&
                       [panel.displayedDeviceIDs[0] isEqualToString:@"dev-a"];

    [panel addPathForTesting:dirA];
    BOOL projectRender = panel.displayedWorkdirIDs.count == 1 &&
                         panel.projectNameLabels.count == 1 &&
                         [panel.projectNameLabels[0].stringValue isEqualToString:dirA.lastPathComponent] &&
                         panel.projectPathLabels.count == 1 &&
                         [panel.projectPathLabels[0].stringValue containsString:dirA.lastPathComponent] &&
                         panel.projectsEmptyLabel.superview == nil;
    [panel removeProjectAtIndex:0];
    BOOL projectRemoved = panel.displayedWorkdirIDs.count == 0 &&
                          panel.projectsEmptyLabel.superview != nil;

    // 以上断言只看逻辑状态,曾经全过而面板一片空白:滚动区的 documentView 没关掉
    // translatesAutoresizingMaskIntoConstraints,行对象建出来了却是零尺寸。所以这里量几何。
    [panel show];
    [panel.window.contentView layoutSubtreeIfNeeded];
    // 注意:不能用 convertRect:toView:nil 判可见性。祖先全是零尺寸时它照样返回一个看似
    // 合理的位置(实测 doc/stack/row 全为 0×0,而开关仍报 74×18),所以必须直接量行与 doc。
    NSButton *probeSwitch = panel.controlSwitches.firstObject;
    NSView *probeRow = probeSwitch.superview;
    NSView *probeStack = probeRow.superview;
    NSView *probeDoc = probeStack.superview;
    BOOL geoVisible = probeSwitch != nil &&
                      probeRow.frame.size.width > 300.0 &&
                      probeRow.frame.size.height > 20.0 &&
                      probeStack.frame.size.height > 20.0 &&
                      probeDoc.frame.size.width > 300.0 &&
                      probeDoc.frame.size.height >= probeStack.frame.size.height;

    // 点面板外面收起,但挂着 sheet 时不许收。文件对话框实测 880pt 宽而面板只有 400pt,
    // 「添加」按钮落在 panel.frame 外面;它又由另一个进程绘制,全局监听收得到那次点击,
    // 于是点「添加」先把面板关掉,项目永远加不上。
    NSRect panelFrame = panel.window.frame;
    NSPoint inside = NSMakePoint(NSMidX(panelFrame), NSMidY(panelFrame));
    NSPoint outside = NSMakePoint(NSMaxX(panelFrame) + 120.0, NSMidY(panelFrame));
    BOOL dismissInside = [panel shouldDismissForClickAt:inside];
    BOOL dismissOutside = [panel shouldDismissForClickAt:outside];

    NSWindow *fakeSheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 880, 448)
                                                     styleMask:NSWindowStyleMaskTitled
                                                       backing:NSBackingStoreBuffered
                                                         defer:NO];
    [panel.window beginSheet:fakeSheet completionHandler:nil];
    BOOL dismissWithSheet = [panel shouldDismissForClickAt:outside];
    BOOL sheetAttached = panel.window.attachedSheet != nil;
    [panel.window endSheet:fakeSheet];

    BOOL clickDismiss = !dismissInside && dismissOutside && sheetAttached && !dismissWithSheet;

    NSTextField *emptyLabel = panel.projectsEmptyLabel;
    NSRect emptyInWindow = [emptyLabel convertRect:emptyLabel.bounds toView:nil];
    // stack.alignment = Width 对有固有尺寸的标签不生效时,标签会浮到尾部,文字看着右偏。
    BOOL geoLeft = emptyInWindow.origin.x > 14.0 && emptyInWindow.origin.x < 30.0;

    // documentView 不翻转时,内容比可视区矮会被压到底部;这里要求空状态文字贴着可视区上沿。
    NSView *emptyClip = emptyLabel.superview.superview.superview;
    NSRect clipInWindow = [emptyClip convertRect:emptyClip.bounds toView:nil];
    BOOL geoTop = [emptyClip isKindOfClass:NSClipView.class] &&
                  (NSMaxY(clipInWindow) - NSMaxY(emptyInWindow)) < 12.0;

    [emptyPanel close];
    [panel close];
    [defaults removePersistentDomainForName:suite];
    [malDefaults removePersistentDomainForName:malSuite];
    [emptyDefaults removePersistentDomainForName:emptySuite];
    [uiDefaults removePersistentDomainForName:uiSuite];
    [[NSFileManager defaultManager] removeItemAtPath:dirA error:nil];
    [[NSFileManager defaultManager] removeItemAtPath:dirB error:nil];

    BOOL storeOK = storeAdd && storeRename && storeDup && storeSecond && storeHit && storeMiss &&
                   storeRemove && storeMalformed && storeMissingPath;
    BOOL panelOK = emptyGuide && listsDevices && switchState && toggleCalls && revokeCalls &&
                   projectRender && projectRemoved && geoVisible && geoLeft && geoTop && clickDismiss;
    BOOL snapOK = snapFollows;
    BOOL ok = storeOK && panelOK && snapOK;
    printf("Control settings self-test: store-add=%s store-rename=%s store-dup=%s store-remove=%s store-malformed=%s store-missing-path=%s store-lookup=%s empty-guide=%s list-devices=%s switch-state=%s toggle=%s revoke=%s project-list=%s project-remove=%s geo-visible=%s geo-left=%s geo-top=%s click-dismiss=%s snapshot-follow=%s\n",
           storeAdd ? "OK" : "FAIL",
           storeRename ? "OK" : "FAIL",
           storeDup ? "OK" : "FAIL",
           storeRemove ? "OK" : "FAIL",
           storeMalformed ? "OK" : "FAIL",
           storeMissingPath ? "OK" : "FAIL",
           (storeHit && storeMiss) ? "OK" : "FAIL",
           emptyGuide ? "OK" : "FAIL",
           listsDevices ? "OK" : "FAIL",
           switchState ? "OK" : "FAIL",
           toggleCalls ? "OK" : "FAIL",
           revokeCalls ? "OK" : "FAIL",
           projectRender ? "OK" : "FAIL",
           projectRemoved ? "OK" : "FAIL",
           geoVisible ? "OK" : "FAIL",
           geoLeft ? "OK" : "FAIL",
           geoTop ? "OK" : "FAIL",
           clickDismiss ? "OK" : "FAIL",
           snapOK ? "OK" : "FAIL");
    return ok;
}

int CPRunSelfTests(int argc, const char *argv[]) {
            NSArray<CPAgent *> *agents = [CPStateReader.new readAgents];
            NSInteger taskCount = 0;
            NSInteger workingCount = 0, attentionCount = 0, completedCount = 0, failedCount = 0, idleCount = 0;
            for (CPAgent *a in agents) {
                taskCount += a.tasks.count;
                if (a.placeholder) continue;
                for (CPTask *task in a.tasks) {
                    if (task.status == CPStatusWorking) workingCount++;
                    else if (task.status == CPStatusAttention || task.status == CPStatusWaiting) attentionCount++;
                    else if (task.status == CPStatusCompleted) completedCount++;
                    else if (task.status == CPStatusFailed) failedCount++;
                    else idleCount++;
                }
            }
            printf("Lantai self-test: %lu agents, %ld tasks, local read OK\n", (unsigned long)agents.count, (long)taskCount);
            printf("Real task states: working=%ld attention=%ld completed=%ld failed=%ld idle=%ld\n",
                   (long)workingCount, (long)attentionCount, (long)completedCount, (long)failedCount, (long)idleCount);
            BOOL internalThreadsFiltered = strstr(CPCodexVisibleThreadsSQL, "thread_source,'') <> 'subagent'") != NULL &&
                                           strstr(CPCodexVisibleThreadsSQL, "COALESCE(source,'') NOT LIKE") != NULL;
            printf("Task visibility self-test: internal-subagents=%s\n", internalThreadsFiltered ? "FILTERED" : "FAIL");

            // M2: CPReviewStore + CPDisplayStatus priority, isolated NSUserDefaults suite.
            NSString *suite = [NSString stringWithFormat:@"com.codexpulse.selftest.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *testDefaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
            [testDefaults removePersistentDomainForName:suite];
            CPReviewStore *store = [[CPReviewStore alloc] initWithDefaults:testDefaults];

            CPTask *done = CPTestTask(@"t1", CPStatusCompleted, 1000);
            BOOL reviewUnseenFirst = ![store isTaskReviewed:done agentID:@"codex"];
            [store markTaskReviewed:done agentID:@"codex"];
            BOOL reviewMarked = [store isTaskReviewed:done agentID:@"codex"];
            done.updatedAt = [NSDate dateWithTimeIntervalSince1970:2000];
            BOOL reviewResetOnNewSignature = ![store isTaskReviewed:done agentID:@"codex"];
            CPTask *sameIDDifferentAgent = CPTestTask(@"t1", CPStatusCompleted, 1000);
            BOOL reviewAgentIsolated = [store isTaskReviewed:sameIDDifferentAgent agentID:@"codex"] &&
                                       ![store isTaskReviewed:sameIDDifferentAgent agentID:@"kimi"];
            CPTask *attentionTask = CPTestTask(@"attention", CPStatusAttention, 3000);
            CPAgent *attentionAgent = CPTestAgent(@"attention-agent", @[attentionTask]);
            BOOL attentionBadgeUnseen = CPBadgeCountForAgents(@[attentionAgent], store) == 1;
            [store markTaskReviewed:attentionTask agentID:attentionAgent.agentID];
            BOOL attentionBadgeReviewed = CPBadgeCountForAgents(@[attentionAgent], store) == 0;

            BOOL prFailed = CPDisplayStatusForTasks(@[CPTestTask(@"a", CPStatusWorking, 1),
                                                      CPTestTask(@"b", CPStatusCompleted, 1),
                                                      CPTestTask(@"c", CPStatusAttention, 1),
                                                      CPTestTask(@"d", CPStatusFailed, 1)], @"x", store) == CPDisplayStatusFailed;
            BOOL prWaiting = CPDisplayStatusForTasks(@[CPTestTask(@"a", CPStatusWorking, 1),
                                                       CPTestTask(@"b", CPStatusCompleted, 1),
                                                       CPTestTask(@"c", CPStatusWaiting, 1)], @"x", store) == CPDisplayStatusWaiting;
            BOOL prAttention = CPDisplayStatusForTasks(@[CPTestTask(@"c", CPStatusAttention, 1),
                                                         CPTestTask(@"a", CPStatusWorking, 1)], @"x", store) == CPDisplayStatusWaiting;
            BOOL prBlue = CPDisplayStatusForTasks(@[CPTestTask(@"b", CPStatusCompleted, 1),
                                                    CPTestTask(@"a", CPStatusWorking, 1)], @"x", store) == CPDisplayStatusCompletedPendingReview;
            BOOL prWorking = CPDisplayStatusForTasks(@[CPTestTask(@"a", CPStatusWorking, 1),
                                                       CPTestTask(@"e", CPStatusIdle, 1)], @"x", store) == CPDisplayStatusWorking;
            BOOL prIdle = CPDisplayStatusForTasks(@[CPTestTask(@"e", CPStatusIdle, 1)], @"x", store) == CPDisplayStatusIdle &&
                          CPDisplayStatusForTasks(@[], @"x", store) == CPDisplayStatusIdle;
            BOOL latestWorking = CPDisplayStatusForTasks(@[CPTestTask(@"old-wait", CPStatusWaiting, 1),
                                                            CPTestTask(@"new-work", CPStatusWorking, 2)], @"x", store) == CPDisplayStatusWorking;
            CPTask *reviewedComplete = CPTestTask(@"reviewed-complete", CPStatusCompleted, 4);
            [store markTaskReviewed:reviewedComplete agentID:@"x"];
            BOOL completedStaysVisible = CPDisplayStatusForTasks(@[reviewedComplete], @"x", store) == CPDisplayStatusCompletedPendingReview;

            NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000.0];
            NSDate *oldStart = [NSDate dateWithTimeIntervalSince1970:900.0];
            NSDate *completedAt = [NSDate dateWithTimeIntervalSince1970:950.0];
            NSDate *newerLog = [NSDate dateWithTimeIntervalSince1970:999.5];
            BOOL completedPersists = CPInferTaskStatus(newerLog, oldStart, completedAt, NO, nil, now) == CPStatusCompleted;
            NSDate *resumedAt = [NSDate dateWithTimeIntervalSince1970:990.0];
            BOOL resumedBecomesWorking = CPInferTaskStatus(newerLog, resumedAt, completedAt, NO, nil, now) == CPStatusWorking;
            BOOL pendingAttentionStays = CPInferTaskStatus(newerLog, resumedAt, completedAt, YES, nil, now) == CPStatusAttention;
            NSDate *failedAt = [NSDate dateWithTimeIntervalSince1970:995.0];
            BOOL failurePersists = CPInferTaskStatus(failedAt, resumedAt, completedAt, NO, failedAt, now) == CPStatusFailed;
            BOOL noEventIsIdle = CPInferTaskStatus(nil, nil, nil, NO, nil, now) == CPStatusIdle;

            [testDefaults removePersistentDomainForName:suite];
            [testDefaults synchronize];

            BOOL m2 = reviewUnseenFirst && reviewMarked && reviewResetOnNewSignature && reviewAgentIsolated &&
                      attentionBadgeUnseen && attentionBadgeReviewed &&
                      prFailed && prWaiting && prAttention && prBlue && prWorking && prIdle &&
                      latestWorking && completedStaysVisible && completedPersists && resumedBecomesWorking &&
                      pendingAttentionStays && failurePersists && noEventIsIdle;
            NSString *m2line = [NSString stringWithFormat:
                @"M2 self-test: review-unseen=%@ review-marked=%@ review-resign=%@ review-agent-isolated=%@ "
                @"badge-attention-unseen=%@ badge-attention-reviewed=%@ prio-failed=%@ prio-waiting=%@ "
                @"prio-attention=%@ prio-blue=%@ prio-working=%@ prio-idle=%@ latest-working=%@ completed-visible=%@ completed-persists=%@ resumed-working=%@ pending-attention=%@ failure-persists=%@ no-event-idle=%@\n",
                reviewUnseenFirst ? @"OK" : @"FAIL", reviewMarked ? @"OK" : @"FAIL",
                reviewResetOnNewSignature ? @"OK" : @"FAIL", reviewAgentIsolated ? @"OK" : @"FAIL",
                attentionBadgeUnseen ? @"OK" : @"FAIL", attentionBadgeReviewed ? @"OK" : @"FAIL",
                prFailed ? @"OK" : @"FAIL", prWaiting ? @"OK" : @"FAIL", prAttention ? @"OK" : @"FAIL",
                prBlue ? @"OK" : @"FAIL", prWorking ? @"OK" : @"FAIL", prIdle ? @"OK" : @"FAIL",
                latestWorking ? @"OK" : @"FAIL", completedStaysVisible ? @"OK" : @"FAIL",
                completedPersists ? @"OK" : @"FAIL", resumedBecomesWorking ? @"OK" : @"FAIL",
                pendingAttentionStays ? @"OK" : @"FAIL", failurePersists ? @"OK" : @"FAIL",
                noEventIsIdle ? @"OK" : @"FAIL"];
            fputs(m2line.UTF8String, stdout);

            // 首启动豁免历史 Completed:空 defaults + 含 completed/waiting 的 fixture →
            // 批量标记后 badge 不含 completed,waiting 仍计;标志键写上后再次调用不重复改写。
            NSString *gfSuite = [NSString stringWithFormat:@"com.codexpulse.grandfather.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *gfDefaults = [[NSUserDefaults alloc] initWithSuiteName:gfSuite];
            [gfDefaults removePersistentDomainForName:gfSuite];
            CPReviewStore *gfStore = [[CPReviewStore alloc] initWithDefaults:gfDefaults];
            CPTask *gfDone = CPTestTask(@"old-done", CPStatusCompleted, 100);
            CPTask *gfWait = CPTestTask(@"old-wait", CPStatusWaiting, 90);
            CPTask *gfFail = CPTestTask(@"old-fail", CPStatusFailed, 80);
            CPAgent *gfAgent = CPTestAgent(@"codex", @[gfDone, gfWait, gfFail]);
            NSInteger gfBadgeBefore = CPBadgeCountForAgents(@[gfAgent], gfStore);
            CPGrandfatherCompletedReviewsIfNeeded(gfDefaults, gfStore, @[gfAgent]);
            BOOL grandfatherCompleted = gfBadgeBefore == 3 &&
                [gfStore isTaskReviewed:gfDone agentID:@"codex"] &&
                ![gfStore isTaskReviewed:gfWait agentID:@"codex"] &&
                ![gfStore isTaskReviewed:gfFail agentID:@"codex"] &&
                CPBadgeCountForAgents(@[gfAgent], gfStore) == 2 &&
                [gfDefaults boolForKey:CPReviewGrandfatheredKey];
            // 再次调用不得清掉 Waiting 的未读,也不得重复写入已有签名以外的副作用。
            CPGrandfatherCompletedReviewsIfNeeded(gfDefaults, gfStore, @[gfAgent]);
            BOOL grandfatherIdempotent = grandfatherCompleted &&
                CPBadgeCountForAgents(@[gfAgent], gfStore) == 2 &&
                ![gfStore isTaskReviewed:gfWait agentID:@"codex"];
            printf("Badge grandfather self-test: grandfather-completed=%s idempotent=%s\n",
                   grandfatherCompleted ? "OK" : "FAIL",
                   grandfatherIdempotent ? "OK" : "FAIL");
            [gfDefaults removePersistentDomainForName:gfSuite];
            [gfDefaults synchronize];

            // 任务路由：Codex 线程深链;Kimi 按 sourceKind 分流(desktop 深链 / CLI 降级);未知 Agent 降级为应用唤起。
            CPTask *routeTask = CPTestTask(@"thread-123", CPStatusWorking, 1);
            routeTask.sourceKind = @"codex";
            CPAgent *routeCodex = CPTestAgent(@"codex", @[routeTask]);
            CPAgent *routeKimi = CPTestAgent(@"kimi", @[routeTask]);
            CPAgent *routeUnknown = CPTestAgent(@"unknown", @[routeTask]);
            BOOL codexRouteOK = [CPDeepLinkForAgentTask(routeCodex, routeTask).absoluteString
                                 isEqualToString:@"codex://threads/thread-123"];
            // Kimi Code CLI 无安全精确 resume:必须明确返回 nil(降级唤起客户端),不伪造成功。
            routeTask.sourceKind = @"kimi-cli";
            BOOL kimiCLIRouteOK = CPDeepLinkForAgentTask(routeKimi, routeTask) == nil;
            // Kimi App client:本机注册了 kimi-work:// scheme 才给深链,否则 nil 走唤起降级。
            CPTask *routeDesktopTask = CPTestTask(@"kimi-client-u1", CPStatusWorking, 1);
            routeDesktopTask.sourceKind = @"kimi-client";
            CPAgent *routeKimiDesktop = CPTestAgent(@"kimi", @[routeDesktopTask]);
            BOOL kimiSchemeRegistered = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"kimi-work://"]] != nil;
            NSURL *desktopLink = CPDeepLinkForAgentTask(routeKimiDesktop, routeDesktopTask);
            BOOL kimiDesktopRouteOK = kimiSchemeRegistered
                ? [desktopLink.absoluteString isEqualToString:@"kimi-work://chat/u1"]
                : desktopLink == nil;
            BOOL unknownRouteOK = CPDeepLinkForAgentTask(routeUnknown, routeTask) == nil;
            routeKimi.placeholder = YES;
            BOOL placeholderRouteOK = CPDeepLinkForAgentTask(routeKimi, routeTask) == nil;
            BOOL taskRoutingOK = codexRouteOK && kimiCLIRouteOK && kimiDesktopRouteOK && unknownRouteOK && placeholderRouteOK;
            NSString *routingLine = [NSString stringWithFormat:
                @"Task routing self-test: codex-thread=%@ kimi-cli-fallback=%@ kimi-desktop-link=%@ unknown-fallback=%@ placeholder-fallback=%@\n",
                codexRouteOK ? @"OK" : @"FAIL", kimiCLIRouteOK ? @"OK" : @"FAIL", kimiDesktopRouteOK ? @"OK" : @"FAIL",
                unknownRouteOK ? @"OK" : @"FAIL", placeholderRouteOK ? @"OK" : @"FAIL"];
            fputs(routingLine.UTF8String, stdout);

            // K: Kimi 真实接入 —— 全部用 /tmp 隔离 fixture,CP_KIMI_CLI_ROOT / CP_KIMI_DESKTOP_ROOT 覆盖数据根,
            // 绝不读写真实 Kimi 数据;断言只用长度/状态/计数,输出不含用户 prompt 明文。
            NSString *kFixture = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-kimi-fixture-%d", NSProcessInfo.processInfo.processIdentifier]];
            NSFileManager *kfm = NSFileManager.defaultManager;
            [kfm removeItemAtPath:kFixture error:nil];
            NSString *kCLIRoot = [kFixture stringByAppendingPathComponent:@"cli"];
            NSString *kDesktopRoot = [kFixture stringByAppendingPathComponent:@"desktop"];
            long long kNowMs = (long long)(NSDate.date.timeIntervalSince1970 * 1000);

            // K0: Kimi App 客户端权威索引 fixture。只构造 readClientTasks 查询所需的最小 schema,
            // 验证 conversation_key 状态映射、conversation_id 路由、workspace 与 wire 活动时间。
            NSString *kClientRoot = [kFixture stringByAppendingPathComponent:@"client"];
            [kfm createDirectoryAtPath:kClientRoot withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *kClientDB = [kClientRoot stringByAppendingPathComponent:@"conversations.sqlite"];
            NSString *kClientStatus = [kClientRoot stringByAppendingPathComponent:@"conversation-statuses.json"];
            NSString *kClientWire1 = [kClientRoot stringByAppendingPathComponent:@"wire-1.jsonl"];
            NSString *kClientWire2 = [kClientRoot stringByAppendingPathComponent:@"wire-2.jsonl"];
            [[NSString stringWithFormat:@"{\"type\":\"llm.request\",\"time\":%lld}\n", kNowMs - 500]
                writeToFile:kClientWire1 atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [[NSString stringWithFormat:@"{\"type\":\"turn.ended\",\"reason\":\"completed\",\"time\":%lld}\n", kNowMs - 5000]
                writeToFile:kClientWire2 atomically:YES encoding:NSUTF8StringEncoding error:nil];
            sqlite3 *kClientHandle = NULL;
            sqlite3_open(kClientDB.UTF8String, &kClientHandle);
            sqlite3_exec(kClientHandle,
                "CREATE TABLE conversations (conversation_key TEXT, conversation_id TEXT, title TEXT, workspace_path TEXT, created_at_ms INTEGER, updated_at_ms INTEGER, kernel_records_path TEXT)",
                NULL, NULL, NULL);
            sqlite3_stmt *kClientInsert = NULL;
            sqlite3_prepare_v2(kClientHandle, "INSERT INTO conversations VALUES (?,?,?,?,?,?,?)", -1, &kClientInsert, NULL);
            void (^kInsertClient)(NSString *, NSString *, NSString *, NSString *, long long, NSString *) =
                ^(NSString *key, NSString *cid, NSString *title, NSString *workspace, long long updated, NSString *wirePath) {
                    sqlite3_reset(kClientInsert);
                    sqlite3_clear_bindings(kClientInsert);
                    sqlite3_bind_text(kClientInsert, 1, key.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(kClientInsert, 2, cid.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(kClientInsert, 3, title.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_text(kClientInsert, 4, workspace.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_bind_int64(kClientInsert, 5, updated - 10000);
                    sqlite3_bind_int64(kClientInsert, 6, updated);
                    sqlite3_bind_text(kClientInsert, 7, wirePath.UTF8String, -1, SQLITE_TRANSIENT);
                    sqlite3_step(kClientInsert);
                };
            kInsertClient(@"client-key-1", @"client-id-1", @"Kimi 客户端运行中", @"/tmp/client-project", kNowMs - 1000, kClientWire1);
            kInsertClient(@"client-key-2", @"client-id-2", @"Kimi 客户端已完成", @"", kNowMs - 6000, kClientWire2);
            // K0b: status=running 但 updatedAt/wire 活动已超过 15 分钟 → 不得强制 working
            NSString *kClientWireStale = [kClientRoot stringByAppendingPathComponent:@"wire-stale.jsonl"];
            [[NSString stringWithFormat:@"{\"type\":\"llm.request\",\"time\":%lld}\n", kNowMs - 7200000]
                writeToFile:kClientWireStale atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [kfm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:(kNowMs - 7200000) / 1000.0]}
                  ofItemAtPath:kClientWireStale error:nil];
            kInsertClient(@"client-key-stale", @"client-id-stale", @"Kimi 客户端陈旧 running", @"/tmp/client-stale", kNowMs - 7200000, kClientWireStale);
            sqlite3_finalize(kClientInsert);
            sqlite3_close(kClientHandle);
            [@"{\"client-key-1\":\"running\",\"client-key-2\":\"completed\",\"client-key-stale\":\"running\"}"
                writeToFile:kClientStatus atomically:YES encoding:NSUTF8StringEncoding error:nil];
            setenv("CP_KIMI_CLIENT_DB", kClientDB.UTF8String, 1);
            setenv("CP_KIMI_CLIENT_STATUS", kClientStatus.UTF8String, 1);
            CPKimiSource *kClientSource = [[CPKimiSource alloc] initWithCache:CPStateCache.new];
            CPAgent *kClientAgent = [kClientSource readAgent];
            CPTask *kClientRunning = nil, *kClientCompleted = nil, *kClientRunningStale = nil;
            for (CPTask *t in kClientAgent.tasks) {
                if ([t.taskID isEqualToString:@"kimi-client-client-id-1"]) kClientRunning = t;
                if ([t.taskID isEqualToString:@"kimi-client-client-id-2"]) kClientCompleted = t;
                if ([t.taskID isEqualToString:@"kimi-client-client-id-stale"]) kClientRunningStale = t;
            }
            BOOL kClientRunningStaleOK = kClientRunningStale && kClientRunningStale.status != CPStatusWorking;
            BOOL kClientOK = kClientAgent.tasks.count == 3 && kClientSource.lastClientCount == 3 &&
                kClientRunning.status == CPStatusWorking && kClientCompleted.status == CPStatusCompleted &&
                kClientRunningStaleOK &&
                [kClientRunning.projectName isEqualToString:@"client-project"] &&
                [kClientCompleted.projectName isEqualToString:@"Kimi"] &&
                [kClientRunning.sourceKind isEqualToString:@"kimi-client"];
            printf("Kimi client self-test: sqlite-index=%s status-map=%s source-split=%s client-running-stale=%s\n",
                   kClientAgent.tasks.count == 3 ? "OK" : "FAIL",
                   (kClientRunning.status == CPStatusWorking && kClientCompleted.status == CPStatusCompleted) ? "OK" : "FAIL",
                   kClientOK ? "OK" : "FAIL",
                   kClientRunningStaleOK ? "OK" : "FAIL");
            unsetenv("CP_KIMI_CLIENT_DB");
            unsetenv("CP_KIMI_CLIENT_STATUS");

            // fixture 写入 helper(仅本段使用)
            void (^kWriteCLI)(NSString *, NSString *, NSDictionary *, NSString *) =
                ^(NSString *root, NSString *sessionID, NSDictionary *state, NSString *wire) {
                NSString *dir = [[root stringByAppendingPathComponent:@"wd_proj1"] stringByAppendingPathComponent:sessionID];
                [kfm createDirectoryAtPath:[dir stringByAppendingPathComponent:@"agents/main"] withIntermediateDirectories:YES attributes:nil error:nil];
                NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
                [data writeToFile:[dir stringByAppendingPathComponent:@"state.json"] atomically:YES];
                if (wire) [wire writeToFile:[dir stringByAppendingPathComponent:@"agents/main/wire.jsonl"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            };
            void (^kWriteDesktop)(NSString *, NSString *, NSString *, NSString *) =
                ^(NSString *root, NSString *uuid, NSString *context, NSString *wire) {
                NSString *dir = [[root stringByAppendingPathComponent:@"hash1"] stringByAppendingPathComponent:uuid];
                [kfm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                if (context) [context writeToFile:[dir stringByAppendingPathComponent:@"context.jsonl"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                if (wire) [wire writeToFile:[dir stringByAppendingPathComponent:@"wire.jsonl"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            };

            // K1: CLI v2 schema(epoch 毫秒 + cwd + id + lastTurnReason=completed)
            kWriteCLI(kCLIRoot, @"session_a1", @{
                @"id": @"session_a1", @"version": @2, @"archived": @NO,
                @"cwd": @"/tmp/proj-alpha", @"createdAt": @(kNowMs - 600000), @"updatedAt": @(kNowMs - 300000),
                @"isCustomTitle": @NO, @"lastPrompt": @"修复登录页崩溃问题", @"lastTurnReason": @"completed",
            }, nil);
            // K2: CLI v1 schema(ISO 时间 + workDir,无 id/archived)
            kWriteCLI(kCLIRoot, @"session_b1", @{
                @"title": @"New Session", @"isCustomTitle": @NO, @"lastPrompt": @"整理本周纪要",
                @"workDir": @"/tmp/proj-beta", @"createdAt": @"2026-08-05T09:10:01.159Z", @"updatedAt": @"2026-08-05T09:11:01.159Z",
            }, nil);
            // K3: 归档会话不展示
            kWriteCLI(kCLIRoot, @"session_arch", @{
                @"id": @"session_arch", @"version": @2, @"archived": @YES, @"cwd": @"/tmp/proj-arch",
                @"createdAt": @(kNowMs - 1000), @"updatedAt": @(kNowMs - 1000), @"lastTurnReason": @"completed",
            }, nil);
            // K4: 自定义标题(isCustomTitle=YES 用 title)
            kWriteCLI(kCLIRoot, @"session_c1", @{
                @"id": @"session_c1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-gamma",
                @"createdAt": @(kNowMs - 900000), @"updatedAt": @(kNowMs - 400000),
                @"isCustomTitle": @YES, @"title": @"我的自定义会话名", @"lastPrompt": @"另一条 prompt",
            }, nil);
            // K5: 超长 lastPrompt 标题必须清洗+截断(≤59 字符),不得铺进 UI
            NSString *kLongPrompt = [@"" stringByPaddingToLength:500 withString:@"长" startingAtIndex:0];
            kWriteCLI(kCLIRoot, @"session_d1", @{
                @"id": @"session_d1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-delta",
                @"createdAt": @(kNowMs - 900000), @"updatedAt": @(kNowMs - 500000),
                @"isCustomTitle": @NO, @"lastPrompt": kLongPrompt, @"lastTurnReason": @"completed",
            }, nil);
            // K6: 状态映射 —— working(活跃 turn 证据 + 新鲜 updatedAt)
            kWriteCLI(kCLIRoot, @"session_e1", @{
                @"id": @"session_e1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-eps",
                @"createdAt": @(kNowMs - 60000), @"updatedAt": @(kNowMs - 1000),
                @"isCustomTitle": @NO, @"lastPrompt": @"进行中的任务",
            }, @"{\"type\":\"llm.request\",\"time\":1789000000000}\n");
            // K7: 状态映射 —— failed(明确 error)
            kWriteCLI(kCLIRoot, @"session_f1", @{
                @"id": @"session_f1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-zeta",
                @"createdAt": @(kNowMs - 800000), @"updatedAt": @(kNowMs - 700000),
                @"isCustomTitle": @NO, @"lastPrompt": @"出错任务", @"lastTurnReason": @"error",
            }, nil);
            // K8: 旧会话不永 working(wire 有活跃 turn 证据但全部活动时间超过阈值 → idle)
            kWriteCLI(kCLIRoot, @"session_g1", @{
                @"id": @"session_g1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-eta",
                @"createdAt": @(kNowMs - 10000000), @"updatedAt": @(kNowMs - 7200000),
                @"isCustomTitle": @NO, @"lastPrompt": @"陈旧任务",
            }, [NSString stringWithFormat:@"{\"type\":\"llm.request\",\"time\":%lld}\n", kNowMs - 7200000]);
            // 真实陈旧会话的 wire mtime 也是旧的,fixture 显式回拨
            [kfm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:(kNowMs - 7200000) / 1000.0]}
                  ofItemAtPath:[kCLIRoot stringByAppendingPathComponent:@"wd_proj1/session_g1/agents/main/wire.jsonl"] error:nil];
            // K18: 长回合 freshness —— state.updatedAt 已 2 小时前,但 wire 尾部事件 10 分钟前
            // (freshness = max(updatedAt, wire.lastEventAt),长回合不得误判 idle);wire 文件 mtime 回拨排除 mtime 干扰
            kWriteCLI(kCLIRoot, @"session_h1", @{
                @"id": @"session_h1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-theta",
                @"createdAt": @(kNowMs - 10000000), @"updatedAt": @(kNowMs - 7200000),
                @"isCustomTitle": @NO, @"lastPrompt": @"长回合任务",
            }, [NSString stringWithFormat:@"{\"type\":\"llm.request\",\"time\":%lld}\n", kNowMs - 600000]);
            [kfm setAttributes:@{NSFileModificationDate: [NSDate dateWithTimeIntervalSince1970:(kNowMs - 7200000) / 1000.0]}
                  ofItemAtPath:[kCLIRoot stringByAppendingPathComponent:@"wd_proj1/session_h1/agents/main/wire.jsonl"] error:nil];
            // K19: 仅被触碰的陈旧会话 —— updatedAt 与 wire 事件都 2 小时前,仅 wire mtime 新鲜(刚写入)
            // → 必须 idle(mtime 不得计入活跃度)
            kWriteCLI(kCLIRoot, @"session_i1", @{
                @"id": @"session_i1", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-iota",
                @"createdAt": @(kNowMs - 10000000), @"updatedAt": @(kNowMs - 7200000),
                @"isCustomTitle": @NO, @"lastPrompt": @"被触碰的陈旧任务",
            }, [NSString stringWithFormat:@"{\"type\":\"llm.request\",\"time\":%lld}\n", kNowMs - 7200000]);
            // desktop:waiting(TurnBegin + StepInterrupted 未结束) + 坏行防御 + 跨源去重样本
            kWriteDesktop(kDesktopRoot, @"desk-1",
                @"{\"role\": \"_system_prompt\", \"content\": \"sys\"}\n这不是合法 json 行\n{\"role\": \"user\", \"content\": \"桌面端任务标题\"}\n{\"role\": \"user\"}\n",
                [NSString stringWithFormat:@"{\"type\": \"metadata\"}\n{\"timestamp\": %.3f, \"message\": {\"type\": \"TurnBegin\", \"payload\": {\"user_input\": \"hi\"}}}\n{\"timestamp\": %.3f, \"message\": {\"type\": \"StepInterrupted\", \"payload\": {}}}\n",
                    (kNowMs - 3000) / 1000.0, (kNowMs - 2500) / 1000.0]);
            // desktop:与 CLI 同一 raw session id → 去重(CLI 优先)
            kWriteDesktop(kDesktopRoot, @"a1",
                @"{\"role\": \"user\", \"content\": \"重复会话\"}\n",
                @"{\"timestamp\": 1789000000.0, \"message\": {\"type\": \"TurnEnd\", \"payload\": {}}}\n");
            // desktop:缺 wire.jsonl → 整会话跳过
            kWriteDesktop(kDesktopRoot, @"desk-broken", @"{\"role\": \"user\", \"content\": \"x\"}\n", nil);

            setenv("CP_KIMI_CLI_ROOT", kCLIRoot.UTF8String, 1);
            setenv("CP_KIMI_DESKTOP_ROOT", kDesktopRoot.UTF8String, 1);
            CPKimiSource *kSource = [[CPKimiSource alloc] initWithCache:CPStateCache.new];
            CPAgent *kimiA = [kSource readAgent];
            CPTask *(^kFind)(NSString *) = ^(NSString *taskID) {
                for (CPTask *t in kimiA.tasks) if ([t.taskID isEqualToString:taskID]) return t;
                return (CPTask *)nil;
            };
            CPTask *kA1 = kFind(@"kimi-cli-session_a1");
            BOOL k1 = kA1 && kA1.status == CPStatusCompleted &&
                      [kA1.projectPath isEqualToString:@"/tmp/proj-alpha"] && [kA1.projectName isEqualToString:@"proj-alpha"] &&
                      fabs(kA1.createdAt.timeIntervalSince1970 * 1000 - (kNowMs - 600000)) < 1 &&
                      [kA1.title isEqualToString:@"修复登录页崩溃问题"] && [kA1.sourceKind isEqualToString:@"kimi-cli"];
            CPTask *kB1 = kFind(@"kimi-cli-session_b1");
            BOOL k2 = kB1 && kB1.status == CPStatusIdle && // v1 无 lastTurnReason/无线 wire → idle
                      [kB1.projectName isEqualToString:@"proj-beta"] &&
                      fabs(kB1.updatedAt.timeIntervalSince1970 - 1785921061.159) < 1; // ISO 解析出正确 epoch
            BOOL k3 = kFind(@"kimi-cli-session_arch") == nil;
            CPTask *kC1 = kFind(@"kimi-cli-session_c1");
            BOOL k4 = kC1 && [kC1.title isEqualToString:@"我的自定义会话名"];
            CPTask *kD1 = kFind(@"kimi-cli-session_d1");
            BOOL k5 = kD1 && kD1.title.length <= 59 && [kD1.title hasSuffix:@"…"];
            CPTask *kE1 = kFind(@"kimi-cli-session_e1");
            BOOL k6 = kE1 && kE1.status == CPStatusWorking && [kE1.activity containsString:@"Kimi Code CLI"];
            CPTask *kF1 = kFind(@"kimi-cli-session_f1");
            BOOL k7 = kF1 && kF1.status == CPStatusFailed;
            CPTask *kG1 = kFind(@"kimi-cli-session_g1");
            BOOL k8 = kG1 && kG1.status == CPStatusIdle;
            CPTask *kH1 = kFind(@"kimi-cli-session_h1");
            BOOL k18 = kH1 && kH1.status == CPStatusWorking; // 长回合:wire 事件 10 分钟前保活(mtime 已回拨)
            CPTask *kI1 = kFind(@"kimi-cli-session_i1");
            BOOL k19 = kI1 && kI1.status == CPStatusIdle; // 仅 mtime 新鲜的陈旧会话不得误活
            CPTask *kDesk1 = kFind(@"kimi-desktop-desk-1");
            BOOL k9 = kDesk1 && kDesk1.status == CPStatusWaiting &&
                      [kDesk1.title isEqualToString:@"桌面端任务标题"] && // 坏行/缺字段行被跳过
                      [kDesk1.sourceKind isEqualToString:@"kimi-desktop"];
            BOOL k10 = kFind(@"kimi-desktop-a1") == nil && kFind(@"kimi-desktop-desk-broken") == nil; // 去重 + 缺文件跳过
            // 排序:updatedAt 降序,最新的是 working 的 session_e1
            BOOL k11 = kimiA.tasks.count >= 1 && kimiA.tasks.firstObject == kE1;
            // 缓存:同一 source 再读,文件未变 → 全部命中解析缓存,不产生新解析条目
            NSUInteger kCacheBefore = kSource.cache.entries.count;
            [kSource readAgent];
            BOOL k12 = kSource.cache.entries.count == kCacheBefore; // cache hit(无重新解析)
            // mtime+size 变化 → 重新解析
            NSString *kE1State = [[kCLIRoot stringByAppendingPathComponent:@"wd_proj1/session_e1/state.json"] copy];
            NSMutableDictionary *kE1Dict = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:kE1State] options:0 error:nil] mutableCopy];
            kE1Dict[@"lastTurnReason"] = @"completed";
            kE1Dict[@"updatedAt"] = @(kNowMs); // 改变大小,确保缓存失效
            [[NSJSONSerialization dataWithJSONObject:kE1Dict options:0 error:nil] writeToFile:kE1State atomically:YES];
            // wire 同步改为 turn 已结束(真实 completed 会话尾部即有 turn.ended)
            [@"{\"type\":\"turn.ended\",\"reason\":\"completed\",\"time\":1789000001000}\n"
                writeToFile:[[kCLIRoot stringByAppendingPathComponent:@"wd_proj1/session_e1/agents/main/wire.jsonl"] copy]
                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
            CPAgent *kimiA3 = [kSource readAgent];
            CPTask *kE1c = nil;
            for (CPTask *t in kimiA3.tasks) if ([t.taskID isEqualToString:@"kimi-cli-session_e1"]) kE1c = t;
            BOOL k13 = kE1c && kE1c.status == CPStatusCompleted; // invalidate 后重解析,状态从 working 变 completed
            // 空态:空根目录 → 零任务、非占位、idle
            NSString *kEmptyRoot = [kFixture stringByAppendingPathComponent:@"empty"];
            [kfm createDirectoryAtPath:kEmptyRoot withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("CP_KIMI_CLI_ROOT", kEmptyRoot.UTF8String, 1);
            setenv("CP_KIMI_DESKTOP_ROOT", kEmptyRoot.UTF8String, 1);
            CPAgent *kimiEmpty = [[[CPKimiSource alloc] initWithCache:CPStateCache.new] readAgent];
            BOOL k14 = kimiEmpty && kimiEmpty.tasks.count == 0 && !kimiEmpty.placeholder && kimiEmpty.status == CPStatusIdle;
            // 上限 50 + 降序:独立 root 造 55 个会话
            NSString *kCapRoot = [kFixture stringByAppendingPathComponent:@"cap"];
            for (int i = 0; i < 55; i++) {
                kWriteCLI(kCapRoot, [NSString stringWithFormat:@"session_cap%02d", i], @{
                    @"id": [NSString stringWithFormat:@"session_cap%02d", i], @"version": @2, @"archived": @NO,
                    @"cwd": @"/tmp/proj-cap", @"createdAt": @(kNowMs - 100000 + i * 1000), @"updatedAt": @(kNowMs - 100000 + i * 1000),
                    @"isCustomTitle": @NO, @"lastPrompt": @"cap", @"lastTurnReason": @"completed",
                }, nil);
            }
            setenv("CP_KIMI_CLI_ROOT", kCapRoot.UTF8String, 1);
            CPAgent *kimiCap = [[[CPKimiSource alloc] initWithCache:CPStateCache.new] readAgent];
            BOOL k15 = kimiCap.tasks.count == 50 &&
                       [kimiCap.tasks.firstObject.taskID isEqualToString:@"kimi-cli-session_cap54"] &&
                       [kimiCap.tasks.lastObject.taskID isEqualToString:@"kimi-cli-session_cap05"];
            // K16: 缓存容量与连续刷新稳定性 —— 600 个会话(跨过 512 旧边界)连续 3 轮 readAgent,
            // 缓存条目数必须 >512 且逐轮稳定(容量不足会顺序淘汰/抖动重读)。
            NSString *kLruRoot = [kFixture stringByAppendingPathComponent:@"lru"];
            for (int i = 0; i < 600; i++) {
                kWriteCLI(kLruRoot, [NSString stringWithFormat:@"session_lru%03d", i], @{
                    @"id": [NSString stringWithFormat:@"session_lru%03d", i], @"version": @2, @"archived": @NO,
                    @"cwd": @"/tmp/proj-lru", @"createdAt": @(kNowMs - 700000 + i * 1000), @"updatedAt": @(kNowMs - 700000 + i * 1000),
                    @"isCustomTitle": @NO, @"lastPrompt": @"lru", @"lastTurnReason": @"completed",
                }, nil);
            }
            setenv("CP_KIMI_CLI_ROOT", kLruRoot.UTF8String, 1);
            setenv("CP_KIMI_DESKTOP_ROOT", kEmptyRoot.UTF8String, 1);
            CPKimiSource *kLruSource = [[CPKimiSource alloc] initWithCache:CPStateCache.new];
            [kLruSource readAgent];
            NSUInteger kLruCount1 = kLruSource.cache.entries.count;
            NSTimeInterval kLruSecond = NSDate.date.timeIntervalSince1970;
            [kLruSource readAgent];
            kLruSecond = NSDate.date.timeIntervalSince1970 - kLruSecond;
            NSUInteger kLruCount2 = kLruSource.cache.entries.count;
            NSTimeInterval kLruThird = NSDate.date.timeIntervalSince1970;
            [kLruSource readAgent];
            kLruThird = NSDate.date.timeIntervalSince1970 - kLruThird;
            NSUInteger kLruCount3 = kLruSource.cache.entries.count;
            // 命中证明用解析计数而非墙钟(命中路径的 LRU 队列维护本身有 O(n) 开销,时长不可比):
            // 同一 CPStateCache 对 600 个 state 文件走两轮 objectForPath,解析器必须只被调用 600 次。
            CPStateCache *kHitCache = CPStateCache.new;
            __block NSInteger kHitParses = 0;
            for (int round = 0; round < 2; round++) {
                for (int i = 0; i < 600; i++) {
                    NSString *sp = [kLruRoot stringByAppendingPathComponent:
                        [NSString stringWithFormat:@"wd_proj1/session_lru%03d/state.json", i]];
                    [kHitCache objectForPath:sp parser:^id(NSString *p) { kHitParses++; return @""; }];
                }
            }
            BOOL k16 = kLruCount1 > 512 && kLruCount1 == 600 && // 600 state 全部入缓存(无 wire 文件),跨过 512 边界
                       kLruCount1 == kLruCount2 && kLruCount2 == kLruCount3 && // 稳定命中,无抖动
                       kHitParses == 600 && kHitCache.entries.count == 600; // 第二轮零重解析,容量不抖动
            // 墙钟单独报,且只挡数量级退化(如缓存被整表清空导致每轮重解析)。
            // 机器忙不忙是环境事实:自测常与构建或其他任务同时跑,0.5s 这种紧边界会让正确实现随机变红。
            // 上面那几条解析计数断言才是真正守住性能的东西,它们与负载无关。
            BOOL k16t = kLruSecond < 3.0 && kLruThird < 3.0;
            fprintf(stdout, "K16 timing: second=%.4fs third=%.4fs\n", kLruSecond, kLruThird);
            // K16b: LRU 逐出语义 —— 小容量缓存超容量只逐出最久未用,绝不清空全表
            CPStateCache *kTiny = CPStateCache.new;
            kTiny.capacity = 4;
            __block NSInteger kParseCount = 0;
            NSString *kTinyDir = [kFixture stringByAppendingPathComponent:@"tiny"];
            [kfm createDirectoryAtPath:kTinyDir withIntermediateDirectories:YES attributes:nil error:nil];
            for (int i = 0; i < 6; i++) {
                NSString *fp = [kTinyDir stringByAppendingPathComponent:[NSString stringWithFormat:@"f%d.json", i]];
                [@"{}" writeToFile:fp atomically:YES encoding:NSUTF8StringEncoding error:nil];
                [kTiny objectForPath:fp parser:^id(NSString *p) { kParseCount++; return @""; }];
            }
            NSString *kTinyNewest = [kTinyDir stringByAppendingPathComponent:@"f5.json"];
            NSString *kTinyOldest = [kTinyDir stringByAppendingPathComponent:@"f0.json"];
            NSInteger kParseBefore = kParseCount;
            [kTiny objectForPath:kTinyNewest parser:^id(NSString *p) { kParseCount++; return @""; }]; // 命中,不重解析
            BOOL k16b = kTiny.entries.count == 4 && kTiny.entries[kTinyOldest] == nil && // 最久未用被逐出
                        kTiny.entries[kTinyNewest] != nil && kParseCount == kParseBefore; // 热条目稳定命中
            k16 = k16 && k16b;
            // K17: desktop context 头部纳入 path+mtime+size 缓存 —— 内容变化(大小不同)后标题随之更新
            setenv("CP_KIMI_CLI_ROOT", kCLIRoot.UTF8String, 1);
            setenv("CP_KIMI_DESKTOP_ROOT", kDesktopRoot.UTF8String, 1);
            NSString *kDeskCtx = [kDesktopRoot stringByAppendingPathComponent:@"hash1/desk-1/context.jsonl"];
            [@"{\"role\": \"_system_prompt\", \"content\": \"sys\"}\n{\"role\": \"user\", \"content\": \"桌面端改后标题!!\"}\n"
                writeToFile:kDeskCtx atomically:YES encoding:NSUTF8StringEncoding error:nil];
            CPAgent *kimiA4 = [kSource readAgent];
            CPTask *kDesk1b = nil;
            for (CPTask *t in kimiA4.tasks) if ([t.taskID isEqualToString:@"kimi-desktop-desk-1"]) kDesk1b = t;
            BOOL k17 = kDesk1b && [kDesk1b.title isEqualToString:@"桌面端改后标题!!"]; // invalidate 后重解析
            unsetenv("CP_KIMI_CLI_ROOT");
            unsetenv("CP_KIMI_DESKTOP_ROOT");
            [kfm removeItemAtPath:kFixture error:nil];

            BOOL kimiOK = kClientOK && k1 && k2 && k3 && k4 && k5 && k6 && k7 && k8 && k9 && k10 && k11 && k12 && k13 && k14 && k15 &&
                          k16 && k16t && k17 && k18 && k19;
            NSString *kLine = [NSString stringWithFormat:
                @"Kimi self-test: cli-v2=%@ cli-v1=%@ archived-filter=%@ custom-title=%@ title-truncate=%@ status-working=%@ status-failed=%@ stale-not-working=%@ desktop-waiting=%@ dedupe-skip=%@ sort-desc=%@ cache-hit=%@ cache-invalidate=%@ empty-state=%@ cap50=%@ lru-stable=%@ lru-timing=%@ desktop-context-cache=%@ long-turn-working=%@ touched-stale-idle=%@\n",
                k1 ? @"OK" : @"FAIL", k2 ? @"OK" : @"FAIL", k3 ? @"OK" : @"FAIL", k4 ? @"OK" : @"FAIL",
                k5 ? @"OK" : @"FAIL", k6 ? @"OK" : @"FAIL", k7 ? @"OK" : @"FAIL", k8 ? @"OK" : @"FAIL",
                k9 ? @"OK" : @"FAIL", k10 ? @"OK" : @"FAIL", k11 ? @"OK" : @"FAIL", k12 ? @"OK" : @"FAIL",
                k13 ? @"OK" : @"FAIL", k14 ? @"OK" : @"FAIL", k15 ? @"OK" : @"FAIL", k16 ? @"OK" : @"FAIL",
                k16t ? @"OK" : @"FAIL",
                k17 ? @"OK" : @"FAIL", k18 ? @"OK" : @"FAIL", k19 ? @"OK" : @"FAIL"];
            fputs(kLine.UTF8String, stdout);

            // M6: CPCleanTitle 脏文本清洗
            BOOL ctDirty = [CPCleanTitle((const unsigned char *)"想让你设计一个loop [11] user: <in-app-browser-context>秘密上下文</in-app-browser-context>")
                            isEqualToString:@"想让你设计一个loop"];
            BOOL ctLooseTag = [CPCleanTitle((const unsigned char *)"<in-app-browser-context> 修复登录页崩溃")
                               isEqualToString:@"修复登录页崩溃"];
            BOOL ctTranscript = [CPCleanTitle((const unsigned char *)"The following is the Codex agent history.\n>>> TRANSCRIPT START\n[3] user: 帮我修复构建错误\n>>> TRANSCRIPT END")
                                 isEqualToString:@"帮我修复构建错误"];
            BOOL ctPlain = [CPCleanTitle((const unsigned char *)"普通标题") isEqualToString:@"普通标题"];
            BOOL ctNil = [CPCleanTitle(NULL) isEqualToString:@"未命名任务"];
            NSString *longRaw = [@"" stringByPaddingToLength:100 withString:@"a" startingAtIndex:0];
            NSString *ctLong = CPCleanTitle((const unsigned char *)longRaw.UTF8String);
            BOOL ctTrunc = ctLong.length == 59 && [ctLong hasSuffix:@"…"];
            BOOL ctMdLink = [CPCleanTitle((const unsigned char *)"[投资事件档案建立](chatgpt-conversation://abc123)")
                             isEqualToString:@"投资事件档案建立"];
            BOOL ctMdMulti = [CPCleanTitle((const unsigned char *)"[方案一](chatgpt-conversation://x) 和 [方案二](https://example.com \"标题\") 比较")
                              isEqualToString:@"方案一 和 方案二 比较"];
            BOOL ctBareURI = [CPCleanTitle((const unsigned char *)"整理纪要 chatgpt-conversation://deadbeef")
                              isEqualToString:@"整理纪要"];
            NSString *mdLongRaw = [NSString stringWithFormat:@"[%@](chatgpt-conversation://x)", [@"" stringByPaddingToLength:100 withString:@"b" startingAtIndex:0]];
            NSString *ctMdLong = CPCleanTitle((const unsigned char *)mdLongRaw.UTF8String);
            BOOL ctMdTrunc = ctMdLong.length == 59 && [ctMdLong hasSuffix:@"…"];
            BOOL m6 = ctDirty && ctLooseTag && ctTranscript && ctPlain && ctNil && ctTrunc &&
                      ctMdLink && ctMdMulti && ctBareURI && ctMdTrunc;
            NSString *m6line = [NSString stringWithFormat:
                @"M6 self-test: clean-dirty=%@ clean-loose-tag=%@ clean-transcript=%@ clean-plain=%@ clean-nil=%@ clean-truncate=%@ clean-mdlink=%@ clean-mdlink-multi=%@ clean-bare-uri=%@ clean-mdlink-truncate=%@\n",
                ctDirty ? @"OK" : @"FAIL", ctLooseTag ? @"OK" : @"FAIL", ctTranscript ? @"OK" : @"FAIL",
                ctPlain ? @"OK" : @"FAIL", ctNil ? @"OK" : @"FAIL", ctTrunc ? @"OK" : @"FAIL",
                ctMdLink ? @"OK" : @"FAIL", ctMdMulti ? @"OK" : @"FAIL",
                ctBareURI ? @"OK" : @"FAIL", ctMdTrunc ? @"OK" : @"FAIL"];
            fputs(m6line.UTF8String, stdout);

            // Perf: 刷新合并闸门 / 可见数据签名 / rollout 解析缓存(确定性行为断言,无 profiling 日志)
            CPRefreshGate *gate = CPRefreshGate.new;
            BOOL gateOK = [gate beginRefresh] &&                    // 首个请求获准
                          gate.inFlight &&
                          ![gate beginRefresh] &&                   // 在途时第二个请求被合并
                          [gate endRefreshAndShouldRunAgain] &&     // 合并的 pending 要求补跑
                          [gate beginRefresh] &&
                          ![gate endRefreshAndShouldRunAgain] &&    // 无 pending 不补跑
                          !gate.inFlight;
            CPAgent *sigA = CPTestAgent(@"sig", @[CPTestTask(@"s1", CPStatusWorking, 100)]);
            CPAgent *sigB = CPTestAgent(@"sig", @[CPTestTask(@"s1", CPStatusWorking, 100)]);
            BOOL sigSame = [CPAgentsSignature(@[sigA]) isEqualToString:CPAgentsSignature(@[sigB])];
            CPAgent *sigStatus = CPTestAgent(@"sig", @[CPTestTask(@"s1", CPStatusCompleted, 100)]);
            CPAgent *sigTime = CPTestAgent(@"sig", @[CPTestTask(@"s1", CPStatusWorking, 200)]);
            CPTask *sigTokensTask = CPTestTask(@"s1", CPStatusWorking, 100);
            sigTokensTask.tokensUsed = 42;
            CPAgent *sigTokens = CPTestAgent(@"sig", @[sigTokensTask]);
            BOOL sigDiff = ![CPAgentsSignature(@[sigA]) isEqualToString:CPAgentsSignature(@[sigStatus])] &&
                           ![CPAgentsSignature(@[sigA]) isEqualToString:CPAgentsSignature(@[sigTime])] &&
                           ![CPAgentsSignature(@[sigA]) isEqualToString:CPAgentsSignature(@[sigTokens])];

            NSString *rollPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"codexpulse-rollout-cache-test.jsonl"];
            [[NSFileManager defaultManager] removeItemAtPath:rollPath error:nil];
            [@"{\"type\":\"event_msg\",\"timestamp\":\"2026-08-10T15:00:00.000Z\",\"payload\":{\"type\":\"task_started\"}}\n"
                writeToFile:rollPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            CPStateReader *cacheReader = CPStateReader.new;
            CPRolloutState *rs1 = [cacheReader rolloutStateForPath:rollPath];
            CPRolloutState *rs2 = [cacheReader rolloutStateForPath:rollPath];
            BOOL rollCacheHit = rs1 && rs1 == rs2 && rs1.lastStarted != nil; // 文件未变:复用同一解析结果
            NSString *rollExisting = [NSString stringWithContentsOfFile:rollPath encoding:NSUTF8StringEncoding error:nil];
            [[rollExisting stringByAppendingString:
              @"{\"type\":\"event_msg\",\"timestamp\":\"2026-08-10T15:01:00.000Z\",\"payload\":{\"type\":\"task_complete\"}}\n"]
                writeToFile:rollPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            CPRolloutState *rs3 = [cacheReader rolloutStateForPath:rollPath];
            BOOL rollCacheInvalidate = rs3 && rs3 != rs1 && rs3.lastComplete != nil; // 文件变化:重新解析
            [[NSFileManager defaultManager] removeItemAtPath:rollPath error:nil];

            BOOL perfOK = gateOK && sigSame && sigDiff && rollCacheHit && rollCacheInvalidate;

            // 回归:Kimi 静态 fixture 两轮读取签名必须一致(替代原 placeholder 静态回归):
            // 否则静态数据也会每 3s 变签名、签名跳过机制失效。
            NSString *stabRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-kimi-stab-%d", NSProcessInfo.processInfo.processIdentifier]];
            NSString *stabStateDir = [[stabRoot stringByAppendingPathComponent:@"wd_s/session_stab"] stringByAppendingPathComponent:@"agents/main"];
            [[NSFileManager defaultManager] createDirectoryAtPath:stabStateDir withIntermediateDirectories:YES attributes:nil error:nil];
            long long stabNowMs = (long long)(NSDate.date.timeIntervalSince1970 * 1000);
            [[NSJSONSerialization dataWithJSONObject:@{
                @"id": @"session_stab", @"version": @2, @"archived": @NO, @"cwd": @"/tmp/proj-stab",
                @"createdAt": @(stabNowMs - 2000), @"updatedAt": @(stabNowMs - 1000),
                @"isCustomTitle": @NO, @"lastPrompt": @"稳定签名", @"lastTurnReason": @"completed",
            } options:0 error:nil] writeToFile:[stabRoot stringByAppendingPathComponent:@"wd_s/session_stab/state.json"] atomically:YES];
            setenv("CP_KIMI_CLI_ROOT", stabRoot.UTF8String, 1);
            setenv("CP_KIMI_DESKTOP_ROOT", stabRoot.UTF8String, 1);
            CPStateReader *stabReader = CPStateReader.new;
            CPAgent *stabK1 = nil, *stabK2 = nil;
            for (CPAgent *a in [stabReader readAgents]) if ([a.agentID isEqualToString:@"kimi"]) stabK1 = a;
            for (CPAgent *a in [stabReader readAgents]) if ([a.agentID isEqualToString:@"kimi"]) stabK2 = a;
            BOOL kimiSigStable = stabK1 && stabK2 && stabK1.tasks.count == 1 &&
                                 [CPAgentsSignature(@[stabK1]) isEqualToString:CPAgentsSignature(@[stabK2])];
            unsetenv("CP_KIMI_CLI_ROOT");
            unsetenv("CP_KIMI_DESKTOP_ROOT");
            [[NSFileManager defaultManager] removeItemAtPath:stabRoot error:nil];
            perfOK = perfOK && kimiSigStable;
            NSString *perfLine = [NSString stringWithFormat:
                @"Perf self-test: refresh-gate=%@ signature-same=%@ signature-diff=%@ rollout-cache-hit=%@ rollout-cache-invalidate=%@ kimi-signature-stable=%@\n",
                gateOK ? @"OK" : @"FAIL", sigSame ? @"OK" : @"FAIL", sigDiff ? @"OK" : @"FAIL",
                rollCacheHit ? @"OK" : @"FAIL", rollCacheInvalidate ? @"OK" : @"FAIL",
                kimiSigStable ? @"OK" : @"FAIL"];
            fputs(perfLine.UTF8String, stdout);

            // Todo schema:新建库经 0→1 迁移后 user_version=1,写路径仍可用。
            NSString *todoSchemaPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-todo-schema-%d.sqlite", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] removeItemAtPath:todoSchemaPath error:nil];
            CPTodoStore *todoSchemaStore = [[CPTodoStore alloc] initWithPath:todoSchemaPath];
            CPTodo *todoSchemaItem = [todoSchemaStore addTodoWithTitle:@"schema-v1"];
            int todoSchemaUV = -1;
            sqlite3 *todoSchemaDB = NULL;
            if (sqlite3_open_v2(todoSchemaPath.UTF8String, &todoSchemaDB, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
                sqlite3_stmt *todoSchemaStmt = NULL;
                if (sqlite3_prepare_v2(todoSchemaDB, "PRAGMA user_version", -1, &todoSchemaStmt, NULL) == SQLITE_OK &&
                    sqlite3_step(todoSchemaStmt) == SQLITE_ROW) {
                    todoSchemaUV = sqlite3_column_int(todoSchemaStmt, 0);
                }
                if (todoSchemaStmt) sqlite3_finalize(todoSchemaStmt);
            }
            if (todoSchemaDB) sqlite3_close(todoSchemaDB);
            BOOL todoSchemaOK = todoSchemaStore && todoSchemaItem && todoSchemaUV == 1;
            printf("Todo schema self-test: user-version=%s\n", todoSchemaOK ? "OK" : "FAIL");
            [[NSFileManager defaultManager] removeItemAtPath:todoSchemaPath error:nil];

            // C-2: Codex state_*/logs_* glob 取最高版本 + 缺失时 health=Missing。
            NSString *codexGlobRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-codex-glob-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] removeItemAtPath:codexGlobRoot error:nil];
            [[NSFileManager defaultManager] createDirectoryAtPath:codexGlobRoot withIntermediateDirectories:YES attributes:nil error:nil];
            [@"" writeToFile:[codexGlobRoot stringByAppendingPathComponent:@"state_4.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"" writeToFile:[codexGlobRoot stringByAppendingPathComponent:@"state_5.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"" writeToFile:[codexGlobRoot stringByAppendingPathComponent:@"logs_1.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"" writeToFile:[codexGlobRoot stringByAppendingPathComponent:@"logs_2.sqlite"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [@"" writeToFile:[codexGlobRoot stringByAppendingPathComponent:@"state_5.sqlite.bak"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *pickedState = CPCodexHighestVersionedSQLite(codexGlobRoot, @"state");
            NSString *pickedLogs = CPCodexHighestVersionedSQLite(codexGlobRoot, @"logs");
            BOOL codexGlobOK = [pickedState.lastPathComponent isEqualToString:@"state_5.sqlite"] &&
                               [pickedLogs.lastPathComponent isEqualToString:@"logs_2.sqlite"];
            [[NSFileManager defaultManager] removeItemAtPath:codexGlobRoot error:nil];

            NSString *codexMissingRoot = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-codex-missing-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] removeItemAtPath:codexMissingRoot error:nil];
            [[NSFileManager defaultManager] createDirectoryAtPath:codexMissingRoot withIntermediateDirectories:YES attributes:nil error:nil];
            setenv("CP_CODEX_ROOT", codexMissingRoot.fileSystemRepresentation, 1);
            CPAgent *codexMissingAgent = [[[CPCodexSource alloc] initWithCache:CPStateCache.new] readAgent];
            BOOL codexHealthMissingOK = codexMissingAgent.health == CPAgentHealthMissing &&
                                        codexMissingAgent.tasks.count == 0 &&
                                        !codexMissingAgent.placeholder;
            unsetenv("CP_CODEX_ROOT");
            [[NSFileManager defaultManager] removeItemAtPath:codexMissingRoot error:nil];
            printf("Codex health self-test: codex-glob=%s codex-health-missing=%s\n",
                   codexGlobOK ? "OK" : "FAIL", codexHealthMissingOK ? "OK" : "FAIL");

            // Bridge:临时 fixture + 内存配对,不碰用户待办库和 Keychain。
            NSString *bridgeTodoPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-bridge-todo-%d.sqlite", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] removeItemAtPath:bridgeTodoPath error:nil];
            NSString *bridgeMobile = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"codexpulse-bridge-mobile-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] removeItemAtPath:bridgeMobile error:nil];
            [[NSFileManager defaultManager] createDirectoryAtPath:[bridgeMobile stringByAppendingPathComponent:@"assets"]
                                      withIntermediateDirectories:YES attributes:nil error:nil];
            [@"<!doctype html><title>lantai</title>" writeToFile:[bridgeMobile stringByAppendingPathComponent:@"index.html"]
                                                      atomically:YES encoding:NSUTF8StringEncoding error:nil];

            CPTask *secretTask = CPTestTask(@"bridge-task", CPStatusWorking, 4000);
            secretTask.title = [NSString stringWithFormat:@"改 %@/proj", NSHomeDirectory()];
            secretTask.projectName = @"Codex Pulse";
            secretTask.projectPath = @"/Users/someone/secret-project";
            secretTask.rolloutPath = @"/Users/someone/.codex/sessions/rollout.jsonl";
            secretTask.sourceKind = @"codex";
            secretTask.activity = [NSString stringWithFormat:@"正在读取 %@/Documents/secret.m 以及 /Users/otherperson/code", NSHomeDirectory()];
            secretTask.tokensUsed = 42;
            CPAgent *okAgent = CPTestAgent(@"codex", @[secretTask]);
            okAgent.name = @"Codex";
            okAgent.health = CPAgentHealthOK;
            okAgent.status = CPStatusWorking;
            CPAgent *missingAgent = CPTestAgent(@"kimi", @[]);
            missingAgent.name = @"Kimi";
            missingAgent.health = CPAgentHealthMissing;
            missingAgent.status = CPStatusIdle;

            NSString *bridgeWdSuite = [NSString stringWithFormat:@"com.codexpulse.bridge-wd-empty.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *bridgeWdDefaults = [[NSUserDefaults alloc] initWithSuiteName:bridgeWdSuite];
            [bridgeWdDefaults removePersistentDomainForName:bridgeWdSuite];
            CPBridgeServer *bridge = CPBridgeServer.new;
            bridge.loopbackOnly = YES;
            bridge.persistPort = NO;
            bridge.portMin = 0;
            bridge.portMax = 0;
            bridge.defaults = bridgeWdDefaults;
            bridge.mobileDirectory = bridgeMobile;
            bridge.todoStore = [[CPTodoStore alloc] initWithPath:bridgeTodoPath];
            bridge.latestAgents = @[okAgent, missingAgent];
            bridge.pairing.inMemoryOnly = YES;
            BOOL bridgeStarted = [bridge start] && bridge.port > 0;
            usleep(50000);
            NSString *bridgeBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)bridge.port];

            NSInteger healthStatus = 0;
            NSDictionary *healthJSON = CPBridgeTestRequest(@"GET", [bridgeBase stringByAppendingString:@"/api/health"], nil, nil, &healthStatus, nil);
            BOOL bridgeHealth = healthStatus == 200 && [healthJSON[@"ok"] boolValue] &&
                                [healthJSON[@"serverName"] isEqualToString:@"澜台"] &&
                                [healthJSON[@"protocol"] integerValue] == 1;

            NSInteger unauthStatus = 0;
            NSDictionary *unauthJSON = CPBridgeTestRequest(@"GET", [bridgeBase stringByAppendingString:@"/api/snapshot"], nil, nil, &unauthStatus, nil);
            BOOL bridgeUnauth = unauthStatus == 401 && [unauthJSON[@"error"] isEqualToString:@"unauthorized"];
            NSInteger badTokenStatus = 0;
            NSDictionary *badTokenJSON = CPBridgeTestRequest(@"GET", [bridgeBase stringByAppendingString:@"/api/snapshot"], @"not-a-token", nil, &badTokenStatus, nil);
            BOOL bridgeBadToken = badTokenStatus == 401 && [badTokenJSON[@"error"] isEqualToString:@"unauthorized"];

            NSInteger badCodeStatus = 0;
            NSDictionary *badCodeJSON = CPBridgeTestRequest(@"POST", [bridgeBase stringByAppendingString:@"/api/pair"], nil,
                                                            @{@"code": @"000000", @"deviceName": @"iPhone"}, &badCodeStatus, nil);
            BOOL bridgeBadCode = badCodeStatus == 403 && [badCodeJSON[@"error"] isEqualToString:@"bad_code"];

            NSString *liveCode = [bridge.pairing issuePairingCode];
            NSInteger pairStatus = 0;
            NSDictionary *pairJSON = CPBridgeTestRequest(@"POST", [bridgeBase stringByAppendingString:@"/api/pair"], nil,
                                                         @{@"code": liveCode ?: @"", @"deviceName": @"iPhone"}, &pairStatus, nil);
            NSString *bridgeToken = [pairJSON[@"token"] isKindOfClass:NSString.class] ? pairJSON[@"token"] : nil;
            BOOL bridgePair = pairStatus == 200 && bridgeToken.length > 0 &&
                              [pairJSON[@"serverName"] isEqualToString:@"澜台"] &&
                              [pairJSON[@"deviceId"] isKindOfClass:NSString.class];
            NSInteger reusedCodeStatus = 0;
            CPBridgeTestRequest(@"POST", [bridgeBase stringByAppendingString:@"/api/pair"], nil,
                                @{@"code": liveCode ?: @"", @"deviceName": @"iPhone"}, &reusedCodeStatus, nil);
            BOOL bridgeCodeConsumed = reusedCodeStatus == 403;

            NSData *snapRaw = nil;
            NSInteger snapStatus = 0;
            NSDictionary *snapJSON = CPBridgeTestRequest(@"GET", [bridgeBase stringByAppendingString:@"/api/snapshot"],
                                                         bridgeToken, nil, &snapStatus, &snapRaw);
            NSString *snapText = snapRaw.length ? [[NSString alloc] initWithData:snapRaw encoding:NSUTF8StringEncoding] : @"";
            NSArray *snapAgents = [snapJSON[@"agents"] isKindOfClass:NSArray.class] ? snapJSON[@"agents"] : @[];
            NSDictionary *snapCodex = nil, *snapKimi = nil;
            for (id row in snapAgents) {
                if (![row isKindOfClass:NSDictionary.class]) continue;
                if ([row[@"agentID"] isEqualToString:@"codex"]) snapCodex = row;
                if ([row[@"agentID"] isEqualToString:@"kimi"]) snapKimi = row;
            }
            BOOL bridgeSnapshot = snapStatus == 200 && snapCodex &&
                                  [snapCodex[@"health"] isEqualToString:@"ok"] &&
                                  [snapCodex[@"status"] isEqualToString:@"working"] &&
                                  [snapCodex[@"displayStatus"] isEqualToString:@"working"] &&
                                  [snapCodex[@"capabilities"] isEqualToArray:@[@"observe"]];
            BOOL bridgeHealthMissing = [snapKimi[@"health"] isEqualToString:@"missing"] &&
                                       [[snapKimi[@"tasks"] isKindOfClass:NSArray.class] ? snapKimi[@"tasks"] : @[] count] == 0;
            BOOL bridgeNoAbsPath = snapText.length > 0 &&
                                   [snapText rangeOfString:@"/Users/"].location == NSNotFound &&
                                   [snapText rangeOfString:@"projectPath"].location == NSNotFound &&
                                   [snapText rangeOfString:@"rolloutPath"].location == NSNotFound &&
                                   [snapText rangeOfString:bridgeToken].location == NSNotFound &&
                                   [snapText rangeOfString:NSHomeDirectory()].location == NSNotFound;
            NSDictionary *snapTask = [snapCodex[@"tasks"] isKindOfClass:NSArray.class] ? [snapCodex[@"tasks"] firstObject] : nil;
            BOOL bridgeHomeRedacted = [snapTask[@"activity"] isKindOfClass:NSString.class] &&
                                      [snapTask[@"activity"] containsString:@"~/Documents/secret.m"] &&
                                      [snapTask[@"title"] containsString:@"~/proj"];

            NSString *op1 = NSUUID.UUID.UUIDString;
            NSInteger createStatus = 0;
            NSDictionary *createJSON = CPBridgeTestRequest(@"POST", [bridgeBase stringByAppendingString:@"/api/todos"],
                                                           bridgeToken, @{@"opID": op1, @"title": @"  Bridge 待办  "},
                                                           &createStatus, nil);
            NSInteger todoID = [createJSON[@"todo"][@"todoID"] integerValue];
            BOOL bridgeTodoCreate = createStatus == 200 && todoID > 0 &&
                                    [createJSON[@"todo"][@"title"] isEqualToString:@"Bridge 待办"] &&
                                    [createJSON[@"todo"][@"completed"] boolValue] == NO;
            NSInteger createAgainStatus = 0;
            NSDictionary *createAgainJSON = CPBridgeTestRequest(@"POST", [bridgeBase stringByAppendingString:@"/api/todos"],
                                                                bridgeToken, @{@"opID": op1, @"title": @"  Bridge 待办  "},
                                                                &createAgainStatus, nil);
            BOOL bridgeIdempotent = createAgainStatus == 200 &&
                                    [createAgainJSON[@"todo"][@"todoID"] integerValue] == todoID &&
                                    bridge.todoStore.allTodos.count == 1;
            NSInteger emptyStatus = 0;
            NSDictionary *emptyJSON = CPBridgeTestRequest(@"POST", [bridgeBase stringByAppendingString:@"/api/todos"],
                                                          bridgeToken, @{@"opID": NSUUID.UUID.UUIDString, @"title": @"   "},
                                                          &emptyStatus, nil);
            BOOL bridgeEmptyTitle = emptyStatus == 400 && [emptyJSON[@"error"] isEqualToString:@"empty_title"];

            NSString *op2 = NSUUID.UUID.UUIDString;
            NSInteger patchStatus = 0;
            NSDictionary *patchJSON = CPBridgeTestRequest(@"PATCH", [NSString stringWithFormat:@"%@/api/todos/%ld", bridgeBase, (long)todoID],
                                                          bridgeToken, @{@"opID": op2, @"completed": @YES},
                                                          &patchStatus, nil);
            BOOL bridgeTodoPatch = patchStatus == 200 && [patchJSON[@"todo"][@"completed"] boolValue];
            NSInteger patchAgainStatus = 0;
            CPBridgeTestRequest(@"PATCH", [NSString stringWithFormat:@"%@/api/todos/%ld", bridgeBase, (long)todoID],
                                bridgeToken, @{@"opID": op2, @"completed": @YES}, &patchAgainStatus, nil);
            BOOL bridgePatchIdempotent = patchAgainStatus == 200 && bridge.todoStore.pendingCount == 0;

            NSInteger missingPatchStatus = 0;
            NSDictionary *missingPatchJSON = CPBridgeTestRequest(@"PATCH", [bridgeBase stringByAppendingString:@"/api/todos/999999"],
                                                                 bridgeToken, @{@"opID": NSUUID.UUID.UUIDString, @"title": @"x"},
                                                                 &missingPatchStatus, nil);
            BOOL bridgeTodoMissing = missingPatchStatus == 404 && [missingPatchJSON[@"error"] isEqualToString:@"not_found"];

            NSString *op3 = NSUUID.UUID.UUIDString;
            NSInteger delStatus = 0;
            NSDictionary *delJSON = CPBridgeTestRequest(@"DELETE", [NSString stringWithFormat:@"%@/api/todos/%ld", bridgeBase, (long)todoID],
                                                        bridgeToken, @{@"opID": op3}, &delStatus, nil);
            BOOL bridgeTodoDelete = delStatus == 200 && [delJSON[@"ok"] boolValue] && bridge.todoStore.allTodos.count == 0;
            NSInteger delAgainStatus = 0;
            NSDictionary *delAgainJSON = CPBridgeTestRequest(@"DELETE", [NSString stringWithFormat:@"%@/api/todos/%ld", bridgeBase, (long)todoID],
                                                             bridgeToken, @{@"opID": op3}, &delAgainStatus, nil);
            BOOL bridgeDeleteIdempotent = delAgainStatus == 200 && [delAgainJSON[@"ok"] boolValue];

            CPBridgePairing *lockPairing = CPBridgePairing.new;
            lockPairing.inMemoryOnly = YES;
            lockPairing.lockoutDuration = 600;
            [lockPairing issuePairingCode];
            int lockFailures = 0;
            for (int i = 0; i < 5; i++) {
                NSDictionary *fail = [lockPairing pairWithCode:@"000000" deviceName:@"x"];
                if ([fail[@"status"] integerValue] == 403 || [fail[@"status"] integerValue] == 429) lockFailures++;
            }
            NSDictionary *locked = [lockPairing pairWithCode:[lockPairing issuePairingCode] deviceName:@"x"];
            BOOL bridgeLockout = lockFailures == 5 && [locked[@"status"] integerValue] == 429 &&
                                 [locked[@"error"] isEqualToString:@"too_many_attempts"];

            NSTask *curl = [[NSTask alloc] init];
            curl.launchPath = @"/usr/bin/curl";
            curl.arguments = @[@"-sS", [bridgeBase stringByAppendingString:@"/api/health"]];
            NSPipe *curlPipe = [NSPipe pipe];
            curl.standardOutput = curlPipe;
            curl.standardError = [NSPipe pipe];
            [curl launch];
            [curl waitUntilExit];
            NSData *curlData = curlPipe.fileHandleForReading.readDataToEndOfFile;
            NSString *curlBody = [[NSString alloc] initWithData:curlData encoding:NSUTF8StringEncoding];
            BOOL bridgeCurl = curl.terminationStatus == 0 && [curlBody containsString:@"\"ok\":true"];

            NSInteger sseNoTokStatus = 0;
            NSDictionary *sseNoTokJSON = CPBridgeTestRequest(@"GET", [bridgeBase stringByAppendingString:@"/api/events"], nil, nil, &sseNoTokStatus, nil);
            BOOL bridgeSSEMissing = sseNoTokStatus == 401 && [sseNoTokJSON[@"error"] isEqualToString:@"unauthorized"];
            NSInteger sseBadStatus = 0;
            NSDictionary *sseBadJSON = CPBridgeTestRequest(@"GET", [bridgeBase stringByAppendingString:@"/api/events?token=not-a-token"], nil, nil, &sseBadStatus, nil);
            BOOL bridgeSSEBad = sseBadStatus == 401 && [sseBadJSON[@"error"] isEqualToString:@"unauthorized"];
            NSInteger snapQueryStatus = 0;
            CPBridgeTestRequest(@"GET", [NSString stringWithFormat:@"%@/api/snapshot?token=%@", bridgeBase, bridgeToken ?: @""],
                                nil, nil, &snapQueryStatus, nil);
            BOOL bridgeSSEQueryNotLeaked = snapQueryStatus == 401;
            NSMutableString *sseBody = NSMutableString.string;
            NSInteger sseOKStatus = 0;
            NSString *encodedToken = [bridgeToken stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
            int sseFD = CPBridgeTestRawGET(bridge.port, [NSString stringWithFormat:@"/api/events?token=%@", encodedToken], &sseOKStatus, sseBody);
            BOOL bridgeSSEQuery = sseOKStatus == 200 && [sseBody containsString:@"event: snapshot"] &&
                                  [sseBody containsString:@"\"agentID\":\"codex\""];
            int serverSSEFD = [bridge firstSSEFileDescriptorForTesting];
            struct timeval sndTV;
            memset(&sndTV, 0, sizeof(sndTV));
            socklen_t sndLen = sizeof(sndTV);
            BOOL bridgeSndTimeout = serverSSEFD >= 0 &&
                                    getsockopt(serverSSEFD, SOL_SOCKET, SO_SNDTIMEO, &sndTV, &sndLen) == 0 &&
                                    sndTV.tv_sec >= 1;
            if (sseFD >= 0) close(sseFD);

            [bridge stop];
            [bridge.pairing clearAllDevices];
            [bridgeWdDefaults removePersistentDomainForName:bridgeWdSuite];
            [[NSFileManager defaultManager] removeItemAtPath:bridgeTodoPath error:nil];
            [[NSFileManager defaultManager] removeItemAtPath:bridgeMobile error:nil];

            BOOL bridgeOK = bridgeStarted && bridgeHealth && bridgeUnauth && bridgeBadToken &&
                            bridgeBadCode && bridgePair && bridgeCodeConsumed && bridgeSnapshot &&
                            bridgeHealthMissing && bridgeNoAbsPath && bridgeHomeRedacted &&
                            bridgeTodoCreate &&
                            bridgeIdempotent && bridgeEmptyTitle && bridgeTodoPatch &&
                            bridgePatchIdempotent && bridgeTodoMissing && bridgeTodoDelete &&
                            bridgeDeleteIdempotent && bridgeLockout && bridgeCurl &&
                            bridgeSSEMissing && bridgeSSEBad && bridgeSSEQuery &&
                            bridgeSSEQueryNotLeaked && bridgeSndTimeout;
            printf("Bridge self-test: start=%s health=%s unauth=%s pair=%s snapshot=%s missing=%s no-path=%s redact=%s todo=%s idempotent=%s lockout=%s curl=%s sse=%s sndtimeo=%s\n",
                   bridgeStarted ? "OK" : "FAIL", bridgeHealth ? "OK" : "FAIL",
                   (bridgeUnauth && bridgeBadToken) ? "OK" : "FAIL",
                   (bridgePair && bridgeBadCode && bridgeCodeConsumed) ? "OK" : "FAIL",
                   bridgeSnapshot ? "OK" : "FAIL", bridgeHealthMissing ? "OK" : "FAIL",
                   bridgeNoAbsPath ? "OK" : "FAIL", bridgeHomeRedacted ? "OK" : "FAIL",
                   (bridgeTodoCreate && bridgeTodoPatch && bridgeTodoDelete && bridgeEmptyTitle && bridgeTodoMissing) ? "OK" : "FAIL",
                   (bridgeIdempotent && bridgePatchIdempotent && bridgeDeleteIdempotent) ? "OK" : "FAIL",
                   bridgeLockout ? "OK" : "FAIL", bridgeCurl ? "OK" : "FAIL",
                   (bridgeSSEMissing && bridgeSSEBad && bridgeSSEQuery && bridgeSSEQueryNotLeaked) ? "OK" : "FAIL",
                   bridgeSndTimeout ? "OK" : "FAIL");

            // Bridge 控制通道:独立 fixture,不复用上一组待办/配对状态。
            CPTask *managedTask = CPTestTask(@"managed-1", CPStatusWorking, 5000);
            CPTask *desktopTask = CPTestTask(@"desktop-1", CPStatusWorking, 4000);
            CPAgent *ctrlCodex = CPTestAgent(@"codex", @[managedTask, desktopTask]);
            ctrlCodex.name = @"Codex";
            CPAgent *ctrlKimi = CPTestAgent(@"kimi", @[CPTestTask(@"kimi-1", CPStatusIdle, 1)]);
            ctrlKimi.name = @"Kimi";
            CPAgent *ctrlSick = CPTestAgent(@"sick", @[CPTestTask(@"sick-1", CPStatusIdle, 1)]);
            ctrlSick.name = @"Sick";

            CPStubControlDriver *codexDriver = CPStubControlDriver.new;
            codexDriver.agentID = @"codex";
            codexDriver.managedTaskIDs = @[@"managed-1"];
            codexDriver.resultTaskID = @"spawned-1";
            CPStubControlDriver *sickDriver = CPStubControlDriver.new;
            sickDriver.agentID = @"sick";
            sickDriver.healthy = NO;
            sickDriver.controlCapabilities = @[@"control"];
            CPAgentControlRegistry *registry = CPAgentControlRegistry.new;
            [registry registerDriver:codexDriver];
            [registry registerDriver:sickDriver];

            NSString *ctrlWorkdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                     [NSString stringWithFormat:@"lantai-ctrl-wd-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] createDirectoryAtPath:ctrlWorkdir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *ctrlWorkdirID = @"wd-test-1";
            NSString *ctrlSuite = [NSString stringWithFormat:@"com.codexpulse.bridge-workdir.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *ctrlDefaults = [[NSUserDefaults alloc] initWithSuiteName:ctrlSuite];
            [ctrlDefaults removePersistentDomainForName:ctrlSuite];
            [ctrlDefaults setObject:@[ @{ @"workdirID": ctrlWorkdirID, @"name": @"测试项目", @"path": ctrlWorkdir } ]
                             forKey:CPControlWorkdirsDefaultsKey];

            CPBridgeServer *ctrl = CPBridgeServer.new;
            ctrl.loopbackOnly = YES;
            ctrl.persistPort = NO;
            ctrl.portMin = 0;
            ctrl.portMax = 0;
            ctrl.defaults = ctrlDefaults;
            ctrl.latestAgents = @[ctrlCodex, ctrlKimi, ctrlSick];
            ctrl.pairing.inMemoryOnly = YES;
            ctrl.controlRegistry = registry;
            BOOL ctrlStarted = [ctrl start] && ctrl.port > 0;
            usleep(50000);
            NSString *ctrlBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)ctrl.port];

            NSInteger ctrlUnauthStatus = 0;
            NSDictionary *ctrlUnauthJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                               nil, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                      @"agentID": @"codex", @"text": @"hi"},
                                                               &ctrlUnauthStatus, nil);
            BOOL ctrlUnauth = ctrlUnauthStatus == 401 && [ctrlUnauthJSON[@"error"] isEqualToString:@"unauthorized"];

            NSString *ctrlCode = [ctrl.pairing issuePairingCode];
            NSInteger ctrlPairStatus = 0;
            NSDictionary *ctrlPairJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/pair"], nil,
                                                             @{@"code": ctrlCode ?: @"", @"deviceName": @"iPhone"},
                                                             &ctrlPairStatus, nil);
            NSString *ctrlToken = [ctrlPairJSON[@"token"] isKindOfClass:NSString.class] ? ctrlPairJSON[@"token"] : nil;
            NSString *ctrlDeviceID = [ctrlPairJSON[@"deviceId"] isKindOfClass:NSString.class] ? ctrlPairJSON[@"deviceId"] : nil;
            CPBridgeDevice *listed = ctrl.pairing.pairedDevices.firstObject;
            BOOL ctrlPairedDefault = ctrlPairStatus == 200 && ctrlToken.length && listed && !listed.canControl && !listed.token.length;

            NSInteger ctrlForbiddenStatus = 0;
            NSDictionary *ctrlForbiddenJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                                  ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                               @"agentID": @"codex", @"text": @"hi"},
                                                                  &ctrlForbiddenStatus, nil);
            BOOL ctrlForbidden = ctrlForbiddenStatus == 403 && [ctrlForbiddenJSON[@"error"] isEqualToString:@"control_not_permitted"];
            BOOL ctrlGranted = [ctrl.pairing setDevice:ctrlDeviceID canControl:YES];
            BOOL listedNow = ctrl.pairing.pairedDevices.firstObject.canControl;

            NSInteger badActionStatus = 0;
            NSDictionary *badActionJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                              ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"explode",
                                                                           @"agentID": @"codex", @"text": @"hi"},
                                                              &badActionStatus, nil);
            BOOL ctrlBadAction = badActionStatus == 400 && [badActionJSON[@"error"] isEqualToString:@"bad_action"];

            NSInteger missingAgentStatus = 0;
            NSDictionary *missingAgentJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                                 ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                              @"agentID": @"ghost", @"text": @"hi"},
                                                                 &missingAgentStatus, nil);
            BOOL ctrlAgentMissing = missingAgentStatus == 404 && [missingAgentJSON[@"error"] isEqualToString:@"agent_not_found"];

            NSInteger noDriverStatus = 0;
            NSDictionary *noDriverJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                             ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                          @"agentID": @"kimi", @"text": @"hi"},
                                                             &noDriverStatus, nil);
            BOOL ctrlNoDriver = noDriverStatus == 503 && [noDriverJSON[@"error"] isEqualToString:@"driver_unavailable"];

            NSInteger sickStatus = 0;
            NSDictionary *sickJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                         ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                      @"agentID": @"sick", @"text": @"hi"},
                                                         &sickStatus, nil);
            BOOL ctrlUnhealthy = sickStatus == 503 && [sickJSON[@"error"] isEqualToString:@"driver_unavailable"];

            NSInteger missingTaskStatus = 0;
            NSDictionary *missingTaskJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                                ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"steer",
                                                                             @"agentID": @"codex", @"text": @"more"},
                                                                &missingTaskStatus, nil);
            BOOL ctrlMissingTask = missingTaskStatus == 400 && [missingTaskJSON[@"error"] isEqualToString:@"missing_task"];

            NSInteger emptyTextStatus = 0;
            NSDictionary *emptyTextJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                              ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                           @"agentID": @"codex", @"text": @"   "},
                                                              &emptyTextStatus, nil);
            BOOL ctrlEmptyText = emptyTextStatus == 400 && [emptyTextJSON[@"error"] isEqualToString:@"empty_text"];

            NSInteger missWdStatus = 0;
            NSDictionary *missWdJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                           ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                        @"agentID": @"codex", @"text": @"没带目录"},
                                                           &missWdStatus, nil);
            BOOL wdMissing = missWdStatus == 400 && [missWdJSON[@"error"] isEqualToString:@"missing_workdir"];

            NSInteger badWdStatus = 0;
            NSDictionary *badWdJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                          ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                       @"agentID": @"codex", @"workdirID": @"no-such-wd",
                                                                       @"text": @"未知目录"},
                                                          &badWdStatus, nil);
            BOOL wdUnknown = badWdStatus == 400 && [badWdJSON[@"error"] isEqualToString:@"unknown_workdir"];

            NSInteger steerNoWdStatus = 0;
            NSDictionary *steerNoWdJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                              ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"steer",
                                                                           @"agentID": @"codex", @"taskID": @"managed-1",
                                                                           @"text": @"补充"},
                                                              &steerNoWdStatus, nil);
            NSString *steerNoWdID = [steerNoWdJSON[@"command"][@"commandID"] isKindOfClass:NSString.class]
                ? steerNoWdJSON[@"command"][@"commandID"] : nil;
            NSDictionary *steerNoWdDone = CPBridgeWaitCommand(ctrlBase, ctrlToken, steerNoWdID, @"succeeded", 2.0);
            BOOL wdSteerOk = steerNoWdStatus == 202 &&
                [steerNoWdJSON[@"command"][@"state"] isEqualToString:@"accepted"] &&
                [steerNoWdDone[@"command"][@"state"] isEqualToString:@"succeeded"];
            codexDriver.executeCount = 0;

            NSInteger unmanagedStatus = 0;
            NSDictionary *unmanagedJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                              ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"steer",
                                                                           @"agentID": @"codex", @"taskID": @"desktop-1", @"text": @"more"},
                                                              &unmanagedStatus, nil);
            BOOL ctrlNotManaged = unmanagedStatus == 409 && [unmanagedJSON[@"error"] isEqualToString:@"not_managed"];

            NSInteger snapCtrlStatus = 0;
            NSDictionary *snapCtrl = CPBridgeTestRequest(@"GET", [ctrlBase stringByAppendingString:@"/api/snapshot"],
                                                         ctrlToken, nil, &snapCtrlStatus, nil);
            NSDictionary *snapCtrlCodex = CPBridgeFindAgent(snapCtrl, @"codex");
            NSDictionary *snapCtrlKimi = CPBridgeFindAgent(snapCtrl, @"kimi");
            NSDictionary *snapCtrlSick = CPBridgeFindAgent(snapCtrl, @"sick");
            BOOL ctrlCapsHealthy = snapCtrlStatus == 200 &&
                [snapCtrlCodex[@"capabilities"] isEqualToArray:@[@"observe", @"control", @"interrupt"]] &&
                [snapCtrlCodex[@"controlRoute"] isEqualToString:@"native"];
            BOOL ctrlCapsUnhealthy = [snapCtrlSick[@"capabilities"] isEqualToArray:@[@"observe"]] &&
                [snapCtrlSick[@"controlRoute"] isEqualToString:@"none"] &&
                [snapCtrlKimi[@"capabilities"] isEqualToArray:@[@"observe"]] &&
                [snapCtrlKimi[@"controlRoute"] isEqualToString:@"none"];
            sickDriver.healthy = YES;
            NSDictionary *snapSickUp = CPBridgeTestRequest(@"GET", [ctrlBase stringByAppendingString:@"/api/snapshot"],
                                                           ctrlToken, nil, nil, nil);
            BOOL ctrlCapsFlippedOn = [CPBridgeFindAgent(snapSickUp, @"sick")[@"capabilities"]
                                      isEqualToArray:@[@"observe", @"control"]];
            sickDriver.healthy = NO;
            NSDictionary *snapSickDown = CPBridgeTestRequest(@"GET", [ctrlBase stringByAppendingString:@"/api/snapshot"],
                                                             ctrlToken, nil, nil, nil);
            BOOL ctrlCapsFlippedOff = [CPBridgeFindAgent(snapSickDown, @"sick")[@"capabilities"]
                                       isEqualToArray:@[@"observe"]];
            BOOL ctrlManagedField = [CPBridgeFindTask(snapCtrlCodex, @"managed-1")[@"managed"] boolValue] &&
                                    ![CPBridgeFindTask(snapCtrlCodex, @"desktop-1")[@"managed"] boolValue] &&
                                    ![CPBridgeFindTask(snapCtrlKimi, @"kimi-1")[@"managed"] boolValue];

            NSMutableString *ctrlSSEBody = NSMutableString.string;
            NSInteger ctrlSSEStatus = 0;
            NSString *ctrlEncoded = [ctrlToken stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
            int ctrlSSEFD = CPBridgeTestRawGET(ctrl.port, [NSString stringWithFormat:@"/api/events?token=%@", ctrlEncoded],
                                               &ctrlSSEStatus, ctrlSSEBody);

            codexDriver.delay = 0.25;
            NSString *startOp = NSUUID.UUID.UUIDString;
            NSInteger startStatus = 0;
            NSDictionary *startJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                          ctrlToken, @{@"opID": startOp, @"action": @"start",
                                                                       @"agentID": @"codex", @"workdirID": ctrlWorkdirID,
                                                                       @"text": @"写一段说明"},
                                                          &startStatus, nil);
            NSString *startCommandID = [startJSON[@"command"][@"commandID"] isKindOfClass:NSString.class]
                ? startJSON[@"command"][@"commandID"] : nil;
            BOOL ctrlAccepted = startStatus == 202 && [startJSON[@"command"][@"state"] isEqualToString:@"accepted"] &&
                                startCommandID.length && [startJSON[@"command"][@"action"] isEqualToString:@"start"] &&
                                startJSON[@"command"][@"taskID"] == NSNull.null;

            NSInteger replayStatus = 0;
            NSDictionary *replayJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                           ctrlToken, @{@"opID": startOp, @"action": @"start",
                                                                        @"agentID": @"codex", @"workdirID": ctrlWorkdirID,
                                                                        @"text": @"写一段说明"},
                                                           &replayStatus, nil);
            BOOL ctrlIdempotent = replayStatus == 202 &&
                [replayJSON[@"command"][@"commandID"] isEqualToString:startCommandID] &&
                codexDriver.executeCount == 1;

            NSInteger busyStatus = 0;
            NSDictionary *busyJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                         ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                      @"agentID": @"codex", @"workdirID": ctrlWorkdirID,
                                                                      @"text": @"另一条"},
                                                         &busyStatus, nil);
            BOOL ctrlBusy = busyStatus == 409 && [busyJSON[@"error"] isEqualToString:@"busy"];

            // 急停不受 busy 约束:start 还在飞的时候必须仍能打断,否则最该打断的场景恰好按不动。
            NSInteger interruptStatus = 0;
            NSDictionary *interruptJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                              ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"interrupt",
                                                                           @"agentID": @"codex", @"taskID": @"managed-1"},
                                                              &interruptStatus, nil);
            BOOL ctrlInterruptNotBlocked = interruptStatus == 202 &&
                [interruptJSON[@"command"][@"state"] isEqualToString:@"accepted"];

            NSDictionary *succeededJSON = CPBridgeWaitCommand(ctrlBase, ctrlToken, startCommandID, @"succeeded", 2.0);
            BOOL ctrlSucceeded = [succeededJSON[@"command"][@"state"] isEqualToString:@"succeeded"] &&
                                 [succeededJSON[@"command"][@"taskID"] isEqualToString:@"spawned-1"];

            BOOL ctrlSSECommand = ctrlSSEStatus == 200 &&
                CPBridgeTestWaitSSE(ctrlSSEFD, ctrlSSEBody, @"event: command", 1.0);
            if (ctrlSSEFD >= 0) close(ctrlSSEFD);

            codexDriver.delay = 0;
            codexDriver.shouldSucceed = NO;
            codexDriver.failMessage = @"boom";
            NSInteger failStatus = 0;
            NSDictionary *failJSON = CPBridgeTestRequest(@"POST", [ctrlBase stringByAppendingString:@"/api/commands"],
                                                         ctrlToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                      @"agentID": @"codex", @"workdirID": ctrlWorkdirID,
                                                                      @"text": @"会失败"},
                                                         &failStatus, nil);
            NSString *failCommandID = [failJSON[@"command"][@"commandID"] isKindOfClass:NSString.class]
                ? failJSON[@"command"][@"commandID"] : nil;
            NSDictionary *failedJSON = CPBridgeWaitCommand(ctrlBase, ctrlToken, failCommandID, @"failed", 2.0);
            BOOL ctrlFailed = failStatus == 202 &&
                [failedJSON[@"command"][@"state"] isEqualToString:@"failed"] &&
                [failedJSON[@"command"][@"errorMessage"] isEqualToString:@"boom"];

            [ctrl stop];
            [ctrl.pairing clearAllDevices];

            BOOL controlOK = ctrlStarted && ctrlUnauth && ctrlPairedDefault && ctrlForbidden &&
                             ctrlGranted && listedNow && ctrlBadAction && ctrlAgentMissing &&
                             ctrlNoDriver && ctrlUnhealthy && ctrlMissingTask && ctrlEmptyText &&
                             ctrlNotManaged && ctrlAccepted && ctrlIdempotent && ctrlBusy &&
                             ctrlInterruptNotBlocked &&
                             ctrlSucceeded && ctrlFailed && ctrlCapsHealthy && ctrlCapsUnhealthy &&
                             ctrlCapsFlippedOn && ctrlCapsFlippedOff && ctrlManagedField && ctrlSSECommand;
            printf("Bridge control self-test: unauth=%s forbidden=%s bad_action=%s agent=%s nodriver=%s unhealthy=%s missing_task=%s empty_text=%s not_managed=%s accepted=%s idempotent=%s busy=%s interrupt-priority=%s succeeded=%s failed=%s caps=%s managed=%s sse=%s\n",
                   ctrlUnauth ? "OK" : "FAIL",
                   (ctrlForbidden && ctrlGranted && listedNow) ? "OK" : "FAIL",
                   ctrlBadAction ? "OK" : "FAIL",
                   ctrlAgentMissing ? "OK" : "FAIL",
                   ctrlNoDriver ? "OK" : "FAIL",
                   ctrlUnhealthy ? "OK" : "FAIL",
                   ctrlMissingTask ? "OK" : "FAIL",
                   ctrlEmptyText ? "OK" : "FAIL",
                   ctrlNotManaged ? "OK" : "FAIL",
                   ctrlAccepted ? "OK" : "FAIL",
                   ctrlIdempotent ? "OK" : "FAIL",
                   ctrlBusy ? "OK" : "FAIL",
                   ctrlInterruptNotBlocked ? "OK" : "FAIL",
                   ctrlSucceeded ? "OK" : "FAIL",
                   ctrlFailed ? "OK" : "FAIL",
                   (ctrlCapsHealthy && ctrlCapsUnhealthy && ctrlCapsFlippedOn && ctrlCapsFlippedOff) ? "OK" : "FAIL",
                   ctrlManagedField ? "OK" : "FAIL",
                   ctrlSSECommand ? "OK" : "FAIL");

            BOOL wdResolved = [codexDriver.lastCommand.workdir isEqualToString:ctrlWorkdir];

            NSArray *snapWorkdirs = [snapCtrl[@"workdirs"] isKindOfClass:NSArray.class] ? snapCtrl[@"workdirs"] : nil;
            NSDictionary *snapWd0 = snapWorkdirs.count ? snapWorkdirs[0] : nil;
            BOOL wdSnapshot = snapWorkdirs.count == 1 &&
                [snapWd0[@"workdirID"] isEqualToString:ctrlWorkdirID] &&
                [snapWd0[@"name"] isEqualToString:@"测试项目"] &&
                snapWd0[@"path"] == nil &&
                !CPJSONLeaksWorkdir(snapCtrl, ctrlWorkdir);

            BOOL wdNoLeak = !CPJSONLeaksWorkdir(startJSON, ctrlWorkdir) &&
                            !CPJSONLeaksWorkdir(succeededJSON, ctrlWorkdir) &&
                            !CPJSONLeaksWorkdir(failedJSON, ctrlWorkdir) &&
                            ![ctrlSSEBody containsString:ctrlWorkdir] &&
                            ![ctrlSSEBody containsString:@"\"workdir\""];

            [ctrl stop];
            [ctrl.pairing clearAllDevices];
            [ctrlDefaults removePersistentDomainForName:ctrlSuite];

            NSString *emptySuite = [NSString stringWithFormat:@"com.codexpulse.bridge-workdir-empty.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *emptyDefaults = [[NSUserDefaults alloc] initWithSuiteName:emptySuite];
            [emptyDefaults removePersistentDomainForName:emptySuite];
            CPStubControlDriver *emptyDriver = CPStubControlDriver.new;
            emptyDriver.agentID = @"codex";
            CPAgentControlRegistry *emptyReg = CPAgentControlRegistry.new;
            [emptyReg registerDriver:emptyDriver];
            CPBridgeServer *emptyBridge = CPBridgeServer.new;
            emptyBridge.loopbackOnly = YES;
            emptyBridge.persistPort = NO;
            emptyBridge.portMin = 0;
            emptyBridge.portMax = 0;
            emptyBridge.defaults = emptyDefaults;
            emptyBridge.latestAgents = @[ctrlCodex];
            emptyBridge.pairing.inMemoryOnly = YES;
            emptyBridge.controlRegistry = emptyReg;
            BOOL emptyStarted = [emptyBridge start];
            usleep(30000);
            NSString *emptyBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)emptyBridge.port];
            NSString *emptyCode = [emptyBridge.pairing issuePairingCode];
            NSInteger emptyPairStatus = 0;
            NSDictionary *emptyPair = CPBridgeTestRequest(@"POST", [emptyBase stringByAppendingString:@"/api/pair"], nil,
                                                          @{@"code": emptyCode ?: @"", @"deviceName": @"iPhone"},
                                                          &emptyPairStatus, nil);
            NSString *emptyToken = emptyPair[@"token"];
            NSString *emptyDevice = emptyPair[@"deviceId"];
            [emptyBridge.pairing setDevice:emptyDevice canControl:YES];
            NSInteger emptyMissStatus = 0;
            NSDictionary *emptyMissJSON = CPBridgeTestRequest(@"POST", [emptyBase stringByAppendingString:@"/api/commands"],
                                                              emptyToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                            @"agentID": @"codex", @"text": @"空名单"},
                                                              &emptyMissStatus, nil);
            NSInteger emptyUnknownStatus = 0;
            NSDictionary *emptyUnknownJSON = CPBridgeTestRequest(@"POST", [emptyBase stringByAppendingString:@"/api/commands"],
                                                                 emptyToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                               @"agentID": @"codex", @"workdirID": @"wd-x",
                                                                               @"text": @"空名单"},
                                                                 &emptyUnknownStatus, nil);
            BOOL wdEmpty = emptyStarted &&
                emptyMissStatus == 400 && [emptyMissJSON[@"error"] isEqualToString:@"missing_workdir"] &&
                emptyUnknownStatus == 400 && [emptyUnknownJSON[@"error"] isEqualToString:@"unknown_workdir"];
            [emptyBridge stop];
            [emptyBridge.pairing clearAllDevices];
            [emptyDefaults removePersistentDomainForName:emptySuite];

            NSString *junkFile = [ctrlWorkdir stringByAppendingPathComponent:@"not-a-dir"];
            [@"x" writeToFile:junkFile atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSString *malSuite = [NSString stringWithFormat:@"com.codexpulse.bridge-workdir-mal.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *malDefaults = [[NSUserDefaults alloc] initWithSuiteName:malSuite];
            [malDefaults removePersistentDomainForName:malSuite];
            [malDefaults setObject:@[
                @{ @"name": @"缺 ID", @"path": ctrlWorkdir },
                @{ @"workdirID": @"wd-dup", @"name": @"先到", @"path": ctrlWorkdir },
                @{ @"workdirID": @"wd-dup", @"name": @"重复", @"path": ctrlWorkdir },
                @{ @"workdirID": @"wd-gone", @"name": @"不存在", @"path": @"/tmp/lantai-no-such-workdir" },
                @{ @"workdirID": @"wd-file", @"name": @"是文件", @"path": junkFile },
                @{ @"workdirID": @"wd-ok", @"name": @"合法", @"path": ctrlWorkdir },
            ] forKey:CPControlWorkdirsDefaultsKey];
            CPStubControlDriver *malDriver = CPStubControlDriver.new;
            malDriver.agentID = @"codex";
            CPAgentControlRegistry *malReg = CPAgentControlRegistry.new;
            [malReg registerDriver:malDriver];
            CPBridgeServer *malBridge = CPBridgeServer.new;
            malBridge.loopbackOnly = YES;
            malBridge.persistPort = NO;
            malBridge.portMin = 0;
            malBridge.portMax = 0;
            malBridge.defaults = malDefaults;
            malBridge.latestAgents = @[ctrlCodex];
            malBridge.pairing.inMemoryOnly = YES;
            malBridge.controlRegistry = malReg;
            BOOL malStarted = [malBridge start];
            usleep(30000);
            NSString *malBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)malBridge.port];
            NSString *malCode = [malBridge.pairing issuePairingCode];
            NSDictionary *malPair = CPBridgeTestRequest(@"POST", [malBase stringByAppendingString:@"/api/pair"], nil,
                                                        @{@"code": malCode ?: @"", @"deviceName": @"iPhone"}, nil, nil);
            [malBridge.pairing setDevice:malPair[@"deviceId"] canControl:YES];
            NSDictionary *malSnap = CPBridgeTestRequest(@"GET", [malBase stringByAppendingString:@"/api/snapshot"],
                                                        malPair[@"token"], nil, nil, nil);
            NSArray *malWds = [malSnap[@"workdirs"] isKindOfClass:NSArray.class] ? malSnap[@"workdirs"] : @[];
            BOOL wdMalformed = malStarted && malWds.count == 2 &&
                [malWds[0][@"workdirID"] isEqualToString:@"wd-dup"] &&
                [malWds[0][@"name"] isEqualToString:@"先到"] &&
                [malWds[1][@"workdirID"] isEqualToString:@"wd-ok"] &&
                malWds[0][@"path"] == nil;
            NSInteger malOKStatus = 0;
            CPBridgeTestRequest(@"POST", [malBase stringByAppendingString:@"/api/commands"],
                                malPair[@"token"], @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                     @"agentID": @"codex", @"workdirID": @"wd-ok", @"text": @"用合法项"},
                                &malOKStatus, nil);
            BOOL wdMalformedUsable = malOKStatus == 202 && [malDriver.lastCommand.workdir isEqualToString:ctrlWorkdir];
            [malBridge stop];
            [malBridge.pairing clearAllDevices];
            [malDefaults removePersistentDomainForName:malSuite];
            [[NSFileManager defaultManager] removeItemAtPath:ctrlWorkdir error:nil];

            BOOL workdirOK = wdMissing && wdUnknown && wdResolved && wdSnapshot && wdNoLeak &&
                             wdSteerOk && wdEmpty && wdMalformed && wdMalformedUsable;
            printf("Bridge workdir self-test: missing=%s unknown=%s resolved=%s snapshot=%s no-path=%s steer=%s empty=%s malformed=%s\n",
                   wdMissing ? "OK" : "FAIL",
                   wdUnknown ? "OK" : "FAIL",
                   wdResolved ? "OK" : "FAIL",
                   wdSnapshot ? "OK" : "FAIL",
                   wdNoLeak ? "OK" : "FAIL",
                   wdSteerOk ? "OK" : "FAIL",
                   wdEmpty ? "OK" : "FAIL",
                   (wdMalformed && wdMalformedUsable) ? "OK" : "FAIL");

            NSString *driverWorkdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                       [NSString stringWithFormat:@"lantai-codex-wd-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] createDirectoryAtPath:driverWorkdir withIntermediateDirectories:YES attributes:nil error:nil];

            CPCodexDriver *missingBin = [[CPCodexDriver alloc] initWithTransport:nil binaryPath:nil];
            BOOL cdMissing = !missingBin.isHealthy;
            [missingBin shutdown];

            CPFakeCodexTransport *okTx = CPFakeCodexTransport.new;
            CPCodexDriver *okDriver = CPMakeCodexDriver(okTx);
            [okDriver startNow];
            BOOL cdHandshakeOK = okDriver.isHealthy;
            [okTx simulateClose];
            BOOL cdClosed = !okDriver.isHealthy;
            [okDriver shutdown];

            CPFakeCodexTransport *failTx = CPFakeCodexTransport.new;
            failTx.autoHandshake = NO;
            CPCodexDriver *failDriver = CPMakeCodexDriver(failTx);
            [failDriver startNow];
            NSDictionary *initReq = CPJSONLine(failTx.sent.firstObject);
            if (initReq[@"id"]) {
                [failTx deliverJSON:@{@"jsonrpc": @"2.0", @"id": initReq[@"id"],
                                      @"error": @{@"code": @(-32000), @"message": @"nope"}}];
            }
            usleep(30000);
            BOOL cdHandshakeFail = !failDriver.isHealthy;
            [failDriver shutdown];

            CPFakeCodexTransport *nfTx = CPFakeCodexTransport.new;
            __block NSInteger nfCount = 0;
            nfTx.responder = ^NSDictionary *(NSDictionary *req) {
                NSString *method = req[@"method"];
                if ([method isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                nfCount += 1;
                return @{@"jsonrpc": @"2.0", @"id": req[@"id"],
                         @"error": @{@"code": @(-32601), @"message": @"Method not found"}};
            };
            CPCodexDriver *nfDriver = CPMakeCodexDriver(nfTx);
            [nfDriver startNow];
            __block BOOL nfDone = NO;
            __block BOOL nfOK = YES;
            CPAgentCommand *nfCmd = CPMakeCmd(CPCommandActionStart, nil, @"x");
            nfCmd.workdir = driverWorkdir;
            [nfDriver executeCommand:nfCmd completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)err; (void)tid;
                nfOK = ok;
                nfDone = YES;
            }];
            CPWaitFlag(&nfDone, 2.0);
            usleep(20000);
            BOOL cdMethodMissing = !nfOK && !nfDriver.isHealthy && nfCount > 0;
            [nfDriver shutdown];

            CPFakeCodexTransport *toTx = CPFakeCodexTransport.new;
            toTx.responder = ^NSDictionary *(NSDictionary *req) {
                if ([req[@"method"] isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                return nil;
            };
            CPCodexDriver *toDriver = CPMakeCodexDriver(toTx);
            toDriver.requestTimeout = 0.25;
            [toDriver startNow];
            __block BOOL toDone = NO;
            __block BOOL toOK = YES;
            __block NSString *toErr = nil;
            CPAgentCommand *toCmd = CPMakeCmd(CPCommandActionStart, nil, @"timeout");
            toCmd.workdir = driverWorkdir;
            [toDriver executeCommand:toCmd completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)tid;
                toOK = ok;
                toErr = err;
                toDone = YES;
            }];
            BOOL cdTimeout = CPWaitFlag(&toDone, 2.0) && !toOK && toErr.length;
            [toDriver shutdown];

            CPFakeCodexTransport *stTx = CPFakeCodexTransport.new;
            stTx.responder = ^NSDictionary *(NSDictionary *req) {
                NSString *method = req[@"method"];
                if ([method isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                if ([method isEqualToString:@"thread/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"thread": @{@"id": @"thr-1"}}};
                }
                if ([method isEqualToString:@"turn/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"turn": @{@"id": @"turn-1"}}};
                }
                if ([method isEqualToString:@"turn/steer"] || [method isEqualToString:@"turn/interrupt"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"turnId": @"turn-1"}};
                }
                return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{}};
            };
            CPCodexDriver *stDriver = CPMakeCodexDriver(stTx);
            [stDriver startNow];
            __block BOOL stDone = NO;
            __block BOOL stOK = NO;
            __block NSString *stTask = nil;
            CPAgentCommand *stCmd = CPMakeCmd(CPCommandActionStart, nil, @"开始");
            stCmd.workdir = driverWorkdir;
            [stDriver executeCommand:stCmd completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)err;
                stOK = ok;
                stTask = tid;
                stDone = YES;
            }];
            CPWaitFlag(&stDone, 2.0);
            BOOL cdStartOK = stOK && [stTask isEqualToString:@"thr-1"] && [stDriver isManagedTaskID:@"thr-1"];
            NSDictionary *threadStart = CPFindSentMethod(stTx.sent, @"thread/start");
            // 只传 cwd:审批与沙箱策略必须留给用户自己的 ~/.codex 配置决定,写死会让同一个项目
            // 在手机上比在桌面端更受限。这两个键出现即失败。
            BOOL cdStartCwd = [threadStart[@"params"][@"cwd"] isEqualToString:driverWorkdir] &&
                              threadStart[@"params"][@"approvalPolicy"] == nil &&
                              threadStart[@"params"][@"sandbox"] == nil;

            [stTx deliverJSON:@{@"jsonrpc": @"2.0", @"method": @"turn/started",
                                @"params": @{@"threadId": @"thr-1", @"turn": @{@"id": @"turn-live"}}}];
            usleep(20000);
            __block BOOL steerDone = NO;
            __block BOOL steerOK = NO;
            [stDriver executeCommand:CPMakeCmd(CPCommandActionSteer, @"thr-1", @"补充")
                          completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)err; (void)tid;
                steerOK = ok;
                steerDone = YES;
            }];
            CPWaitFlag(&steerDone, 2.0);
            NSDictionary *steerSent = CPFindSentMethod(stTx.sent, @"turn/steer");
            BOOL cdSteer = steerOK && [steerSent[@"params"][@"expectedTurnId"] isEqualToString:@"turn-live"];

            NSUInteger sentBeforeInterrupt = stTx.sent.count;
            __block BOOL intDone = NO;
            __block BOOL intOK = NO;
            [stDriver executeCommand:CPMakeCmd(CPCommandActionInterrupt, @"thr-1", nil)
                          completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)err; (void)tid;
                intOK = ok;
                intDone = YES;
            }];
            CPWaitFlag(&intDone, 2.0);
            NSDictionary *intSent = nil;
            for (NSUInteger i = sentBeforeInterrupt; i < stTx.sent.count; i++) {
                NSDictionary *msg = CPJSONLine(stTx.sent[i]);
                if ([msg[@"method"] isEqualToString:@"turn/interrupt"]) { intSent = msg; break; }
            }
            BOOL cdInterrupt = intOK && [intSent[@"params"][@"turnId"] isEqualToString:@"turn-live"];

            [stTx deliverJSON:@{@"jsonrpc": @"2.0", @"method": @"turn/completed",
                                @"params": @{@"threadId": @"thr-1", @"turn": @{@"id": @"turn-live"}}}];
            usleep(20000);
            NSUInteger sentAfterComplete = stTx.sent.count;
            __block BOOL postSteerDone = NO;
            __block BOOL postSteerOK = YES;
            __block NSString *postSteerErr = nil;
            [stDriver executeCommand:CPMakeCmd(CPCommandActionSteer, @"thr-1", @"晚了")
                          completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)tid;
                postSteerOK = ok;
                postSteerErr = err;
                postSteerDone = YES;
            }];
            CPWaitFlag(&postSteerDone, 2.0);
            __block BOOL postIntDone = NO;
            __block BOOL postIntOK = YES;
            __block NSString *postIntErr = nil;
            [stDriver executeCommand:CPMakeCmd(CPCommandActionInterrupt, @"thr-1", nil)
                          completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)tid;
                postIntOK = ok;
                postIntErr = err;
                postIntDone = YES;
            }];
            CPWaitFlag(&postIntDone, 2.0);
            BOOL sentEmptyTurn = NO;
            for (NSUInteger i = sentAfterComplete; i < stTx.sent.count; i++) {
                NSDictionary *msg = CPJSONLine(stTx.sent[i]);
                NSString *method = msg[@"method"];
                if ([method isEqualToString:@"turn/steer"] || [method isEqualToString:@"turn/interrupt"]) sentEmptyTurn = YES;
            }
            BOOL cdNoActive = !postSteerOK && postSteerErr.length && !postIntOK && postIntErr.length && !sentEmptyTurn;
            [stDriver shutdown];

            CPFakeCodexTransport *stepTx = CPFakeCodexTransport.new;
            stepTx.responder = ^NSDictionary *(NSDictionary *req) {
                NSString *method = req[@"method"];
                if ([method isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                if ([method isEqualToString:@"thread/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"thread": @{@"id": @"thr-2"}}};
                }
                if ([method isEqualToString:@"turn/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"],
                             @"error": @{@"code": @(-32000), @"message": @"turn failed"}};
                }
                return nil;
            };
            CPCodexDriver *stepDriver = CPMakeCodexDriver(stepTx);
            [stepDriver startNow];
            __block BOOL stepDone = NO;
            __block BOOL stepOK = YES;
            __block NSString *stepErr = nil;
            CPAgentCommand *stepCmd = CPMakeCmd(CPCommandActionStart, nil, @"第二步会失败");
            stepCmd.workdir = driverWorkdir;
            [stepDriver executeCommand:stepCmd completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)tid;
                stepOK = ok;
                stepErr = err;
                stepDone = YES;
            }];
            CPWaitFlag(&stepDone, 2.0);
            BOOL cdTurnFail = !stepOK && [stepErr containsString:@"turn/start"];
            [stepDriver shutdown];

            CPFakeCodexTransport *badWdTx = CPFakeCodexTransport.new;
            CPCodexDriver *badWdDriver = CPMakeCodexDriver(badWdTx);
            [badWdDriver startNow];
            __block BOOL badWdDone = NO;
            __block BOOL badWdOK = YES;
            __block NSString *badWdErr = nil;
            [badWdDriver executeCommand:CPMakeCmd(CPCommandActionStart, nil, @"无目录")
                             completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)tid;
                badWdOK = ok;
                badWdErr = err;
                badWdDone = YES;
            }];
            CPWaitFlag(&badWdDone, 2.0);
            BOOL cdBadWorkdir = !badWdOK && [badWdErr containsString:@"工作目录无效"] &&
                                CPFindSentMethod(badWdTx.sent, @"thread/start") == nil;
            [badWdDriver shutdown];

            CPFakeCodexTransport *apprTx = CPFakeCodexTransport.new;
            CPCodexDriver *apprDriver = CPMakeCodexDriver(apprTx);
            [apprDriver startNow];
            NSUInteger sentBeforeApproval = apprTx.sent.count;
            [apprTx deliverJSON:@{@"jsonrpc": @"2.0", @"id": @99,
                                  @"method": @"item/commandExecution/requestApproval",
                                  @"params": @{@"threadId": @"t", @"turnId": @"u"}}];
            usleep(30000);
            BOOL cdApproval = NO;
            for (NSUInteger i = sentBeforeApproval; i < apprTx.sent.count; i++) {
                NSDictionary *msg = CPJSONLine(apprTx.sent[i]);
                if ([msg[@"id"] isEqual:@99] && [msg[@"result"][@"decision"] isEqualToString:@"decline"]) {
                    cdApproval = YES;
                    break;
                }
            }
            [apprDriver shutdown];

            CPCodexJSONLBuffer *framing = CPCodexJSONLBuffer.new;
            NSArray *half = [framing appendBytes:"{\"a\":1" length:6];
            NSString *two = @"}\n{\"b\":2}\n";
            NSArray *rest = [framing appendBytes:two.UTF8String length:two.length];
            NSMutableString *longLine = [NSMutableString stringWithString:@"{\"k\":\""];
            for (int i = 0; i < 8000; i++) [longLine appendString:@"x"];
            [longLine appendString:@"\"}\n"];
            NSArray *longParsed = [framing appendBytes:longLine.UTF8String length:longLine.length];
            BOOL cdFraming = half.count == 0 && rest.count == 2 &&
                [rest[0] isEqualToString:@"{\"a\":1}"] &&
                [rest[1] isEqualToString:@"{\"b\":2}"] &&
                longParsed.count == 1 && [longParsed[0] hasPrefix:@"{\"k\":\""] &&
                ((NSString *)longParsed[0]).length > 8000;

            NSString *liveMark = @"skip";
            BOOL liveOK = YES;
            NSString *realBin = CPCodexFindBinary();
            if (realBin.length) {
                CPCodexDriver *live = [[CPCodexDriver alloc] initWithTransport:nil binaryPath:realBin];
                live.requestTimeout = 8.0;
                [live startNow];
                NSDate *liveDeadline = [NSDate dateWithTimeIntervalSinceNow:8.0];
                while (!live.isHealthy && [liveDeadline timeIntervalSinceNow] > 0) usleep(20000);
                liveOK = live.isHealthy;
                liveMark = liveOK ? @"OK" : @"FAIL";
                [live shutdown];
            }

            [[NSFileManager defaultManager] removeItemAtPath:driverWorkdir error:nil];

            BOOL codexDriverOK = cdMissing && cdHandshakeOK && cdHandshakeFail && cdClosed &&
                                 cdMethodMissing && cdTimeout && cdStartOK && cdStartCwd &&
                                 cdTurnFail && cdSteer && cdNoActive && cdInterrupt &&
                                 cdBadWorkdir && cdApproval && cdFraming && liveOK;
            printf("Codex driver self-test: missing-bin=%s handshake=%s handshake-fail=%s exit=%s method-missing=%s timeout=%s start=%s start-cwd=%s turn-fail=%s steer=%s no-active=%s interrupt=%s bad-workdir=%s approval=%s framing=%s live=%s\n",
                   cdMissing ? "OK" : "FAIL",
                   cdHandshakeOK ? "OK" : "FAIL",
                   cdHandshakeFail ? "OK" : "FAIL",
                   cdClosed ? "OK" : "FAIL",
                   cdMethodMissing ? "OK" : "FAIL",
                   cdTimeout ? "OK" : "FAIL",
                   cdStartOK ? "OK" : "FAIL",
                   cdStartCwd ? "OK" : "FAIL",
                   cdTurnFail ? "OK" : "FAIL",
                   cdSteer ? "OK" : "FAIL",
                   cdNoActive ? "OK" : "FAIL",
                   cdInterrupt ? "OK" : "FAIL",
                   cdBadWorkdir ? "OK" : "FAIL",
                   cdApproval ? "OK" : "FAIL",
                   cdFraming ? "OK" : "FAIL",
                   liveMark.UTF8String);

            // 实时活动流:真 driver 折叠 + 真 Bridge 限流,transport 是假的,不跑真 turn、不花钱。
            NSString *actWorkdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"lantai-activity-wd-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] createDirectoryAtPath:actWorkdir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *actSuite = [NSString stringWithFormat:@"com.codexpulse.activity.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *actDefaults = [[NSUserDefaults alloc] initWithSuiteName:actSuite];
            [actDefaults removePersistentDomainForName:actSuite];

            CPFakeCodexTransport *actTx = CPFakeCodexTransport.new;
            __block NSInteger actThreadSeq = 0;
            actTx.responder = ^NSDictionary *(NSDictionary *req) {
                NSString *method = req[@"method"];
                if ([method isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                if ([method isEqualToString:@"thread/start"]) {
                    actThreadSeq += 1;
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"],
                             @"result": @{@"thread": @{@"id": [NSString stringWithFormat:@"thr-%ld", (long)actThreadSeq]}}};
                }
                if ([method isEqualToString:@"turn/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"turn": @{@"id": @"turn-1"}}};
                }
                return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{}};
            };
            CPCodexDriver *actDriver = CPMakeCodexDriver(actTx);
            CPAgentControlRegistry *actReg = CPAgentControlRegistry.new;
            [actReg registerDriver:actDriver];
            CPBridgeServer *actBridge = CPBridgeServer.new;
            actBridge.loopbackOnly = YES;
            actBridge.persistPort = NO;
            actBridge.portMin = 0;
            actBridge.portMax = 0;
            actBridge.defaults = actDefaults;
            actBridge.pairing.inMemoryOnly = YES;
            actBridge.controlRegistry = actReg;
            // 自测靠显式冲刷推进,不拿墙钟当断言;闸门本身另有一项专门验。
            actBridge.activityFlushInterval = 5.0;
            __weak CPBridgeServer *actWeakBridge = actBridge;
            actDriver.onActivityEntry = ^(CPActivityEntry *entry) { [actWeakBridge ingestActivityEntry:entry]; };
            actDriver.onActivityFlush = ^(NSString *a, NSString *t) { [actWeakBridge flushActivityForAgentID:a taskID:t]; };
            actDriver.onActivityLive = ^(NSString *a, BOOL live) { [actWeakBridge setActivityLive:live forAgentID:a]; };
            [actDriver startNow];
            BOOL actStarted = [actBridge start] && actBridge.port > 0;
            usleep(30000);

            NSString *(^actStartThread)(void) = ^NSString *{
                __block NSString *taskID = nil;
                __block BOOL done = NO;
                CPAgentCommand *cmd = CPMakeCmd(CPCommandActionStart, nil, @"go");
                cmd.workdir = actWorkdir;
                cmd.workdirName = @"澜台";
                [actDriver executeCommand:cmd completion:^(BOOL ok, NSString *err, NSString *rid) {
                    (void)err;
                    taskID = ok ? rid : nil;
                    done = YES;
                }];
                CPWaitFlag(&done, 2.0);
                return taskID;
            };

            NSString *actMain = actStartThread() ?: @"thr-1";
            NSString *actEditedFile = [actWorkdir stringByAppendingPathComponent:@"Sources/x.m"];

            CPActivityNotify(actTx, @"item/agentMessage/delta",
                             @{@"threadId": actMain, @"itemId": @"it-say", @"delta": @"你"});
            CPActivityNotify(actTx, @"item/agentMessage/delta",
                             @{@"threadId": actMain, @"itemId": @"it-say", @"delta": @"好"});
            CPActivityNotify(actTx, @"item/reasoning/summaryTextDelta",
                             @{@"threadId": actMain, @"itemId": @"it-think", @"summaryIndex": @0, @"delta": @"先看"});
            CPActivityNotify(actTx, @"item/reasoning/textDelta",
                             @{@"threadId": actMain, @"itemId": @"it-think", @"contentIndex": @0, @"delta": @"代码"});
            CPActivityNotify(actTx, @"item/started",
                             @{@"threadId": actMain, @"turnId": @"turn-1", @"startedAtMs": @0,
                               @"item": @{@"id": @"it-run", @"type": @"commandExecution",
                                          @"command": [NSString stringWithFormat:@"rg -n workdirID %@/Sources", actWorkdir],
                                          @"cwd": actWorkdir, @"commandActions": @[], @"status": @"inProgress"}});
            CPActivityNotify(actTx, @"item/commandExecution/outputDelta",
                             @{@"threadId": actMain, @"itemId": @"it-run", @"delta": @"12 matches"});
            CPActivityNotify(actTx, @"item/fileChange/patchUpdated",
                             @{@"threadId": actMain, @"itemId": @"it-edit",
                               @"changes": @[ @{@"path": actEditedFile, @"kind": @{@"type": @"update"},
                                                @"diff": @"--- a\n+++ b\n+新增\n-删除"} ]});
            CPActivityNotify(actTx, @"turn/plan/updated",
                             @{@"threadId": actMain, @"turnId": @"turn-1",
                               @"plan": @[ @{@"step": @"读代码", @"status": @"completed"},
                                           @{@"step": @"改代码", @"status": @"inProgress"} ]});
            CPActivityNotify(actTx, @"thread/tokenUsage/updated",
                             @{@"threadId": actMain, @"turnId": @"turn-1",
                               @"tokenUsage": @{@"total": @{@"totalTokens": @48213, @"inputTokens": @40000,
                                                            @"outputTokens": @8213, @"cachedInputTokens": @0,
                                                            @"reasoningOutputTokens": @0},
                                                @"last": @{@"totalTokens": @1}}});
            CPActivityNotify(actTx, @"warning", @{@"threadId": actMain, @"message": @"磁盘快满了"});
            CPActivityNotify(actTx, @"guardianWarning", @{@"threadId": actMain, @"message": @"守卫拦了一下"});
            CPActivityNotify(actTx, @"error",
                             @{@"threadId": actMain, @"turnId": @"turn-1", @"willRetry": @YES,
                               @"error": @{@"message": @"网络中断", @"additionalDetails": @"稍后重试"}});
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];

            NSArray<NSDictionary *> *actFolded = CPActivityEntriesOf(actBridge, actMain);
            NSArray<NSString *> *actKinds = CPActivityKindsOf(actFolded);
            NSArray<NSString *> *actWantKinds = @[@"say", @"think", @"run", @"edit", @"plan", @"usage",
                                                  @"note", @"note", @"note"];
            BOOL actFoldSay = actFolded.count == 9 && [actKinds isEqualToArray:actWantKinds] &&
                              [actFolded[0][@"text"] isEqualToString:@"你好"] && actFolded[0][@"detail"] == nil;
            BOOL actFoldThink = [actFolded[1][@"text"] isEqualToString:@"先看代码"];
            BOOL actFoldRun = [actFolded[2][@"text"] isEqualToString:@"rg -n workdirID 澜台/Sources"] &&
                              [actFolded[2][@"detail"] isEqualToString:@"12 matches"];
            BOOL actFoldEdit = [actFolded[3][@"text"] isEqualToString:@"改动 澜台/Sources/x.m"] &&
                               [actFolded[3][@"detail"] containsString:@"~ 澜台/Sources/x.m"];
            BOOL actFoldPlan = [actFolded[4][@"text"] isEqualToString:@"计划 1/2"] &&
                               [actFolded[4][@"detail"] containsString:@"✓ 读代码"] &&
                               [actFolded[4][@"detail"] containsString:@"▶ 改代码"];
            BOOL actFoldUsage = [actFolded[5][@"text"] isEqualToString:@"token 用量 48213"];
            BOOL actFoldNote = [actFolded[6][@"text"] isEqualToString:@"磁盘快满了"] &&
                               [actFolded[7][@"text"] isEqualToString:@"守卫拦了一下"] &&
                               [actFolded[8][@"text"] isEqualToString:@"网络中断"] &&
                               [actFolded[8][@"detail"] isEqualToString:@"稍后重试"];

            // 无关通知一律安静丢弃,而且不占 seq:下一条真事件的 seq 必须紧接着来。
            NSInteger actSeqBeforeNoise = [actFolded.lastObject[@"seq"] integerValue];
            for (NSString *noise in @[@"account/updated", @"fs/changed", @"thread/status/changed",
                                      @"thread/realtime/transcript/delta", @"fuzzyFileSearch/sessionUpdated",
                                      @"item/mcpToolCall/progress", @"mcpServer/startupStatus/updated",
                                      @"windows/worldWritableWarning"]) {
                CPActivityNotify(actTx, noise, @{@"threadId": actMain, @"itemId": @"noise", @"delta": @"x"});
            }
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            NSArray<NSDictionary *> *actAfterNoise = CPActivityEntriesOf(actBridge, actMain);
            BOOL actDropsNoise = actAfterNoise.count == 9;

            // 限流:同 kind 连续 delta 必须合并成一条,而且这一条在闸门到点前不许推出去。
            NSInteger actEventsBeforeBurst = [actBridge activityEventCountForTesting];
            for (int i = 0; i < 100; i++) {
                CPActivityNotify(actTx, @"item/agentMessage/delta",
                                 @{@"threadId": actMain, @"itemId": @"it-burst", @"delta": @"x"});
            }
            CPActivitySettle(actDriver, actBridge);
            BOOL actGated = [actBridge activityEventCountForTesting] == actEventsBeforeBurst;
            [actBridge flushActivityNowForTesting];
            NSArray<NSDictionary *> *actAfterBurst = CPActivityEntriesOf(actBridge, actMain);
            NSDictionary *actBurstEntry = actAfterBurst.lastObject;
            BOOL actCoalesce = actAfterBurst.count == 10 &&
                               [actBurstEntry[@"kind"] isEqualToString:@"say"] &&
                               [actBurstEntry[@"text"] length] == 100 &&
                               [actBurstEntry[@"seq"] integerValue] == actSeqBeforeNoise + 1 &&
                               [actBridge activityEventCountForTesting] == actEventsBeforeBurst + 1;
            BOOL actSeqOK = CPActivitySeqMonotonic(actAfterBurst) &&
                            [actAfterBurst.firstObject[@"seq"] integerValue] == 1;

            // 40 条上限:第 41 条挤掉最旧的,seq 不复用也不回退。
            NSString *actCapTask = actStartThread() ?: @"thr-2";
            for (int i = 0; i < 45; i++) {
                CPActivityNotify(actTx, @"warning",
                                 @{@"threadId": actCapTask, @"message": [NSString stringWithFormat:@"告警 %d", i]});
            }
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            NSArray<NSDictionary *> *actCapped = CPActivityEntriesOf(actBridge, actCapTask);
            BOOL actCapEntries = actCapped.count == 40 &&
                                 [actCapped.firstObject[@"seq"] integerValue] == 6 &&
                                 [actCapped.lastObject[@"seq"] integerValue] == 45 &&
                                 [actCapped.firstObject[@"text"] isEqualToString:@"告警 5"];

            // 截断:text 砍头留 400,detail 砍头留尾 2000——命令输出的价值在末尾。
            NSString *actTruncTask = actStartThread() ?: @"thr-3";
            NSMutableString *actLongSay = NSMutableString.string;
            for (int i = 0; i < 500; i++) [actLongSay appendString:@"说"];
            CPActivityNotify(actTx, @"item/agentMessage/delta",
                             @{@"threadId": actTruncTask, @"itemId": @"it-long-say", @"delta": actLongSay});
            NSMutableString *actLongOut = NSMutableString.string;
            for (int i = 0; i < 2990; i++) [actLongOut appendString:@"a"];
            [actLongOut appendString:@"结尾在这里"];
            CPActivityNotify(actTx, @"item/started",
                             @{@"threadId": actTruncTask, @"turnId": @"turn-1", @"startedAtMs": @0,
                               @"item": @{@"id": @"it-long-run", @"type": @"commandExecution",
                                          @"command": @"make test", @"cwd": actWorkdir,
                                          @"commandActions": @[], @"status": @"inProgress"}});
            CPActivityNotify(actTx, @"item/commandExecution/outputDelta",
                             @{@"threadId": actTruncTask, @"itemId": @"it-long-run", @"delta": actLongOut});
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            NSArray<NSDictionary *> *actTruncated = CPActivityEntriesOf(actBridge, actTruncTask);
            NSString *actTruncText = actTruncated.firstObject[@"text"];
            NSString *actTruncDetail = actTruncated.lastObject[@"detail"];
            BOOL actTruncate = actTruncated.count == 2 &&
                               actTruncText.length == 400 && [actTruncText hasSuffix:@"…"] &&
                               actTruncDetail.length == 2000 &&
                               [actTruncDetail hasPrefix:@"…"] &&
                               [actTruncDetail hasSuffix:@"结尾在这里"];

            // 路径脱敏:workdir 前缀换项目名,其余 /Users/<名> 换 ~。
            NSString *actLeakyPath = [NSString stringWithFormat:
                @"cat %@/Sources/y.m %@/Documents/secret.m /Users/otherperson/code/z.m",
                actWorkdir, NSHomeDirectory()];
            CPActivityNotify(actTx, @"item/agentMessage/delta",
                             @{@"threadId": actTruncTask, @"itemId": @"it-path", @"delta": actLeakyPath});
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            NSString *actRedactedText = CPActivityEntriesOf(actBridge, actTruncTask).lastObject[@"text"];
            BOOL actRedact = [actRedactedText containsString:@"澜台/Sources/y.m"] &&
                             [actRedactedText containsString:@"~/Documents/secret.m"] &&
                             [actRedactedText containsString:@"~/code/z.m"] &&
                             ![actRedactedText containsString:actWorkdir] &&
                             ![actRedactedText containsString:@"/Users/"];

            // 第二层脱敏单独钉一遍:绕开 driver 直接喂 Bridge,推送前它自己也必须兜住。
            CPActivityEntry *actRawEntry = CPActivityEntry.new;
            actRawEntry.agentID = @"codex";
            actRawEntry.taskID = actTruncTask;
            actRawEntry.kind = CPActivityKindNote;
            actRawEntry.merge = CPActivityMergeDistinct;
            actRawEntry.text = [NSString stringWithFormat:@"未脱敏 %@/Documents/raw.m", NSHomeDirectory()];
            actRawEntry.detail = @"/Users/otherperson/raw/deep.m";
            actRawEntry.at = NSDate.date.timeIntervalSince1970;
            [actBridge ingestActivityEntry:actRawEntry];
            [actBridge flushActivityNowForTesting];
            NSDictionary *actRawRow = CPActivityEntriesOf(actBridge, actTruncTask).lastObject;
            BOOL actBridgeRedact = [actRawRow[@"text"] containsString:@"~/Documents/raw.m"] &&
                                   [actRawRow[@"detail"] isEqualToString:@"~/raw/deep.m"] &&
                                   ![actRawRow[@"text"] containsString:@"/Users/"];

            // 非托管任务没有流:桌面端会话不是澜台拉起的,driver 连它的通知都不折叠。
            CPActivityNotify(actTx, @"item/agentMessage/delta",
                             @{@"threadId": @"desktop-act", @"itemId": @"it-desktop", @"delta": @"不该出现"});
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            BOOL actNoUnmanagedStream = [actBridge activityStreamJSONForAgentID:@"codex" taskID:@"desktop-act"] == nil;

            CPTask *actManagedTask = CPTestTask(actMain, CPStatusWorking, 9000);
            CPTask *actDesktopTask = CPTestTask(@"desktop-act", CPStatusWorking, 8000);
            CPAgent *actAgent = CPTestAgent(@"codex", @[actManagedTask, actDesktopTask]);
            actAgent.name = @"Codex";
            actBridge.latestAgents = @[actAgent];
            NSDictionary *actSnap = [actBridge snapshotDictionary];
            NSDictionary *actSnapAgent = CPBridgeFindAgent(actSnap, @"codex");
            NSDictionary *actSnapManaged = CPBridgeFindTask(actSnapAgent, actMain);
            NSDictionary *actSnapDesktop = CPBridgeFindTask(actSnapAgent, @"desktop-act");
            BOOL actSnapStream = [actSnapManaged[@"managed"] boolValue] &&
                                 [actSnapManaged[@"stream"] isKindOfClass:NSDictionary.class] &&
                                 [actSnapManaged[@"stream"][@"live"] boolValue] &&
                                 [actSnapManaged[@"stream"][@"entries"] count] == 10 &&
                                 ![actSnapDesktop[@"managed"] boolValue] &&
                                 actSnapDesktop[@"stream"] == nil;

            // SSE 批次:seq 等于本批最后一条,且推给手机的 JSON 里不含 /Users/。
            NSString *actCode = [actBridge.pairing issuePairingCode];
            NSString *actBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)actBridge.port];
            NSDictionary *actPair = CPBridgeTestRequest(@"POST", [actBase stringByAppendingString:@"/api/pair"], nil,
                                                        @{@"code": actCode ?: @"", @"deviceName": @"iPhone"}, nil, nil);
            NSString *actToken = [actPair[@"token"] isKindOfClass:NSString.class] ? actPair[@"token"] : @"";
            NSString *actEncoded = [actToken stringByAddingPercentEncodingWithAllowedCharacters:
                                    NSCharacterSet.URLQueryAllowedCharacterSet] ?: @"";
            NSMutableString *actSSEBody = NSMutableString.string;
            NSInteger actSSEStatus = 0;
            int actSSEFD = CPBridgeTestRawGET(actBridge.port,
                                              [NSString stringWithFormat:@"/api/events?token=%@", actEncoded],
                                              &actSSEStatus, actSSEBody);
            for (int i = 0; i < 3; i++) {
                CPActivityNotify(actTx, @"item/agentMessage/delta",
                                 @{@"threadId": actMain,
                                   @"itemId": [NSString stringWithFormat:@"it-sse-%d", i],
                                   @"delta": [NSString stringWithFormat:@"第 %d 段 %@/a.m", i, NSHomeDirectory()]});
            }
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            BOOL actSSESeen = actSSEStatus == 200 &&
                              CPBridgeTestWaitSSE(actSSEFD, actSSEBody, @"event: activity", 2.0);
            NSDictionary *actSSEEvent = CPActivityLastSSEEvent(actSSEBody);
            NSArray *actSSEEntries = [actSSEEvent[@"entries"] isKindOfClass:NSArray.class] ? actSSEEvent[@"entries"] : @[];
            BOOL actSSEBatch = actSSESeen && actSSEEntries.count == 3 &&
                               [actSSEEvent[@"agentID"] isEqualToString:@"codex"] &&
                               [actSSEEvent[@"taskID"] isEqualToString:actMain] &&
                               [actSSEEvent[@"live"] boolValue] &&
                               [actSSEEvent[@"seq"] integerValue] == [[actSSEEntries lastObject][@"seq"] integerValue] &&
                               [actSSEEvent[@"seq"] integerValue] == 13;
            BOOL actSSENoPath = actSSEBody.length > 0 && ![actSSEBody containsString:@"/Users/"] &&
                                ![actSSEBody containsString:actWorkdir];

            // 250ms 闸门本身:断言「到点后确实会自己推出去」,给足富余,不卡死墙钟。
            actBridge.activityFlushInterval = 0.05;
            NSString *actTimerTask = actStartThread() ?: @"thr-4";
            NSInteger actEventsBeforeTimer = [actBridge activityEventCountForTesting];
            CPActivityNotify(actTx, @"item/agentMessage/delta",
                             @{@"threadId": actTimerTask, @"itemId": @"it-timer", @"delta": @"自动推送"});
            CPActivitySettle(actDriver, actBridge);
            NSDate *actTimerDeadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
            while ([actBridge activityEventCountForTesting] == actEventsBeforeTimer &&
                   [actTimerDeadline timeIntervalSinceNow] > 0) {
                usleep(10000);
            }
            BOOL actTimerPush = [actBridge activityEventCountForTesting] > actEventsBeforeTimer;
            actBridge.activityFlushInterval = 5.0;

            // 10 个任务上限:再开 10 个托管线程,最早那个的流被淘汰。
            NSString *actNewest = nil;
            for (int i = 0; i < 10; i++) {
                NSString *taskID = actStartThread();
                if (!taskID.length) continue;
                actNewest = taskID;
                CPActivityNotify(actTx, @"item/agentMessage/delta",
                                 @{@"threadId": taskID, @"itemId": @"it-x", @"delta": @"占位"});
            }
            CPActivitySettle(actDriver, actBridge);
            [actBridge flushActivityNowForTesting];
            BOOL actCapStreams = actNewest.length &&
                                 [actBridge activityStreamJSONForAgentID:@"codex" taskID:actMain] == nil &&
                                 [actBridge activityStreamJSONForAgentID:@"codex" taskID:actNewest] != nil;

            // live 翻转:app-server 没了要标降级,已有条目一条都不许清。
            NSArray<NSDictionary *> *actBeforeDown = CPActivityEntriesOf(actBridge, actNewest);
            [actTx simulateClose];
            CPActivitySettle(actDriver, actBridge);
            NSDictionary *actDownStream = [actBridge activityStreamJSONForAgentID:@"codex" taskID:actNewest];
            NSDictionary *actDownEvent = nil;
            if (actSSEFD >= 0) {
                CPBridgeTestWaitSSE(actSSEFD, actSSEBody, @"\"live\":false", 2.0);
                actDownEvent = CPActivityLastSSEEvent(actSSEBody);
            }
            BOOL actLiveFlip = !actDriver.isHealthy &&
                               ![actDownStream[@"live"] boolValue] &&
                               [actDownStream[@"entries"] count] == actBeforeDown.count &&
                               actBeforeDown.count > 0 &&
                               actDownEvent != nil && ![actDownEvent[@"live"] boolValue];
            [actDriver shutdown];
            if (actSSEFD >= 0) close(actSSEFD);
            [actBridge stop];
            [actBridge.pairing clearAllDevices];
            [actDefaults removePersistentDomainForName:actSuite];
            [[NSFileManager defaultManager] removeItemAtPath:actWorkdir error:nil];

            BOOL activityOK = actStarted && actFoldSay && actFoldThink && actFoldRun && actFoldEdit &&
                              actFoldPlan && actFoldUsage && actFoldNote && actDropsNoise &&
                              actGated && actCoalesce && actSeqOK && actCapEntries && actTruncate &&
                              actRedact && actBridgeRedact && actNoUnmanagedStream && actSnapStream && actSSEBatch &&
                              actSSENoPath && actTimerPush && actCapStreams && actLiveFlip;

            // 模型目录:真 driver + 假 transport + 真 Bridge。不跑真 turn、不碰用户 defaults。
            NSString *modelWorkdir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"lantai-model-wd-%d", NSProcessInfo.processInfo.processIdentifier]];
            [[NSFileManager defaultManager] createDirectoryAtPath:modelWorkdir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *modelSuite = [NSString stringWithFormat:@"com.codexpulse.models.%d", NSProcessInfo.processInfo.processIdentifier];
            NSUserDefaults *modelDefaults = [[NSUserDefaults alloc] initWithSuiteName:modelSuite];
            [modelDefaults removePersistentDomainForName:modelSuite];
            NSString *modelWorkdirID = @"wd-model-1";
            [modelDefaults setObject:@[ @{ @"workdirID": modelWorkdirID, @"name": @"澜台", @"path": modelWorkdir } ]
                              forKey:CPControlWorkdirsDefaultsKey];

            NSDictionary *modelCatalog = @{
                @"data": @[
                    @{ @"id": @"gpt-5.6-sol", @"model": @"gpt-5.6-sol", @"displayName": @"GPT-5.6-Sol",
                       @"description": @"Latest frontier", @"hidden": @NO, @"isDefault": @YES },
                    @{ @"id": @"hidden-x", @"model": @"hidden-x", @"displayName": @"Hidden",
                       @"description": @"should drop", @"hidden": @YES, @"isDefault": @NO },
                    @{ @"id": @"gpt-plain", @"model": @"gpt-plain", @"displayName": @"Plain",
                       @"description": @"ok", @"hidden": @NO, @"isDefault": @NO },
                    @{ @"id": @"sparse-id", @"hidden": @NO },
                    @{ @"displayName": @"No ID", @"hidden": @NO },
                    @"not-a-dict",
                ]
            };

            CPFakeCodexTransport *modelTx = CPFakeCodexTransport.new;
            modelTx.autoHandshake = NO;
            __block NSInteger modelThreadSeq = 0;
            modelTx.responder = ^NSDictionary *(NSDictionary *req) {
                NSString *method = req[@"method"];
                if ([method isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                if ([method isEqualToString:@"model/list"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": modelCatalog};
                }
                if ([method isEqualToString:@"thread/start"]) {
                    modelThreadSeq += 1;
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"],
                             @"result": @{@"thread": @{@"id": [NSString stringWithFormat:@"mthr-%ld", (long)modelThreadSeq]},
                                          @"model": req[@"params"][@"model"] ?: @"inherited"}};
                }
                if ([method isEqualToString:@"turn/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"turn": @{@"id": @"mturn-1"}}};
                }
                return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{}};
            };
            CPCodexDriver *modelDriver = CPMakeCodexDriver(modelTx);
            CPAgentControlRegistry *modelReg = CPAgentControlRegistry.new;
            [modelReg registerDriver:modelDriver];
            CPBridgeServer *modelBridge = CPBridgeServer.new;
            modelBridge.loopbackOnly = YES;
            modelBridge.persistPort = NO;
            modelBridge.portMin = 0;
            modelBridge.portMax = 0;
            modelBridge.defaults = modelDefaults;
            modelBridge.pairing.inMemoryOnly = YES;
            modelBridge.controlRegistry = modelReg;
            CPAgent *modelAgent = CPTestAgent(@"codex", @[]);
            modelAgent.name = @"Codex";
            CPAgent *modelKimi = CPTestAgent(@"kimi", @[]);
            modelKimi.name = @"Kimi";
            modelBridge.latestAgents = @[modelAgent, modelKimi];
            [modelDriver startNow];
            BOOL modelBridgeOK = [modelBridge start] && modelBridge.port > 0;
            usleep(30000);

            NSArray<CPAgentModel *> *parsed = modelDriver.availableModels;
            BOOL modelParseHidden = parsed.count == 3 &&
                [parsed[0].modelID isEqualToString:@"gpt-5.6-sol"] &&
                [parsed[0].name isEqualToString:@"GPT-5.6-Sol"] &&
                [parsed[0].descriptionText isEqualToString:@"Latest frontier"] &&
                parsed[0].isDefault &&
                [parsed[1].modelID isEqualToString:@"gpt-plain"] &&
                !parsed[1].isDefault &&
                [parsed[2].modelID isEqualToString:@"sparse-id"] &&
                [parsed[2].name isEqualToString:@"sparse-id"] &&
                parsed[2].descriptionText.length == 0 &&
                !parsed[2].isDefault;

            NSDictionary *modelSnap = [modelBridge snapshotDictionary];
            NSDictionary *modelSnapCodex = CPBridgeFindAgent(modelSnap, @"codex");
            NSDictionary *modelSnapKimi = CPBridgeFindAgent(modelSnap, @"kimi");
            NSArray *snapModels = [modelSnapCodex[@"models"] isKindOfClass:NSArray.class] ? modelSnapCodex[@"models"] : nil;
            NSDictionary *snapModel0 = snapModels.count ? snapModels[0] : nil;
            BOOL modelSnapShape = snapModels.count == 3 &&
                [snapModel0[@"modelID"] isEqualToString:@"gpt-5.6-sol"] &&
                [snapModel0[@"name"] isEqualToString:@"GPT-5.6-Sol"] &&
                [snapModel0[@"description"] isEqualToString:@"Latest frontier"] &&
                [snapModel0[@"isDefault"] boolValue] &&
                snapModel0[@"path"] == nil &&
                [modelSnapKimi[@"models"] isKindOfClass:NSArray.class] &&
                [modelSnapKimi[@"models"] count] == 0 &&
                !CPJSONLeaksWorkdir(modelSnap, modelWorkdir);

            CPFakeCodexTransport *failListTx = CPFakeCodexTransport.new;
            failListTx.autoHandshake = NO;
            failListTx.responder = ^NSDictionary *(NSDictionary *req) {
                NSString *method = req[@"method"];
                if ([method isEqualToString:@"initialize"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"userAgent": @"t"}};
                }
                if ([method isEqualToString:@"model/list"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"],
                             @"error": @{@"code": @(-32601), @"message": @"Method not found"}};
                }
                if ([method isEqualToString:@"thread/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"thread": @{@"id": @"fail-thr"}}};
                }
                if ([method isEqualToString:@"turn/start"]) {
                    return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{@"turn": @{@"id": @"fail-turn"}}};
                }
                return @{@"jsonrpc": @"2.0", @"id": req[@"id"], @"result": @{}};
            };
            CPCodexDriver *failListDriver = CPMakeCodexDriver(failListTx);
            [failListDriver startNow];
            __block BOOL failListStartDone = NO;
            __block BOOL failListStartOK = NO;
            CPAgentCommand *failListCmd = CPMakeCmd(CPCommandActionStart, nil, @"仍能开工");
            failListCmd.workdir = modelWorkdir;
            [failListDriver executeCommand:failListCmd completion:^(BOOL ok, NSString *err, NSString *tid) {
                (void)err; (void)tid;
                failListStartOK = ok;
                failListStartDone = YES;
            }];
            CPWaitFlag(&failListStartDone, 2.0);
            BOOL modelListFail = failListDriver.isHealthy &&
                                 failListDriver.availableModels.count == 0 &&
                                 failListStartOK;
            [failListDriver shutdown];

            CPStubControlDriver *emptyStub = CPStubControlDriver.new;
            emptyStub.agentID = @"codex";
            emptyStub.healthy = NO;
            CPAgentModel *stale = CPAgentModel.new;
            stale.modelID = @"stale-model";
            stale.name = @"不该出现";
            emptyStub.availableModels = @[stale];
            CPAgentControlRegistry *modelEmptyReg = CPAgentControlRegistry.new;
            [modelEmptyReg registerDriver:emptyStub];
            modelBridge.controlRegistry = modelEmptyReg;
            NSArray *emptyModels = CPBridgeFindAgent([modelBridge snapshotDictionary], @"codex")[@"models"];
            BOOL modelSnapEmpty = [emptyModels isKindOfClass:NSArray.class] && emptyModels.count == 0;
            modelBridge.controlRegistry = modelReg;

            NSString *modelCode = [modelBridge.pairing issuePairingCode];
            NSString *modelBase = [NSString stringWithFormat:@"http://127.0.0.1:%ld", (long)modelBridge.port];
            NSDictionary *modelPair = CPBridgeTestRequest(@"POST", [modelBase stringByAppendingString:@"/api/pair"], nil,
                                                          @{@"code": modelCode ?: @"", @"deviceName": @"iPhone"}, nil, nil);
            NSString *modelToken = [modelPair[@"token"] isKindOfClass:NSString.class] ? modelPair[@"token"] : @"";
            NSString *modelDeviceID = [modelPair[@"deviceId"] isKindOfClass:NSString.class] ? modelPair[@"deviceId"] : @"";
            [modelBridge.pairing setDevice:modelDeviceID canControl:YES];

            NSInteger modelStartStatus = 0;
            NSUInteger sentBeforeModelStart = modelTx.sent.count;
            NSDictionary *modelStartJSON = CPBridgeTestRequest(@"POST", [modelBase stringByAppendingString:@"/api/commands"],
                                                               modelToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                             @"agentID": @"codex", @"workdirID": modelWorkdirID,
                                                                             @"modelID": @"gpt-5.6-sol", @"text": @"用 Sol"},
                                                               &modelStartStatus, nil);
            NSString *modelCommandID = modelStartJSON[@"command"][@"commandID"];
            if (modelCommandID.length) CPBridgeWaitCommand(modelBase, modelToken, modelCommandID, @"succeeded", 2.0);
            NSDictionary *modelThreadStart = nil;
            for (NSUInteger i = sentBeforeModelStart; i < modelTx.sent.count; i++) {
                NSDictionary *msg = CPJSONLine(modelTx.sent[i]);
                if ([msg[@"method"] isEqualToString:@"thread/start"]) { modelThreadStart = msg; break; }
            }
            BOOL modelStartOK = modelStartStatus == 202 &&
                [modelThreadStart[@"params"][@"cwd"] isEqualToString:modelWorkdir] &&
                [modelThreadStart[@"params"][@"model"] isEqualToString:@"gpt-5.6-sol"] &&
                !CPJSONLeaksWorkdir(modelStartJSON, modelWorkdir);

            NSInteger modelBareStatus = 0;
            NSUInteger sentBeforeBare = modelTx.sent.count;
            NSDictionary *modelBareJSON = CPBridgeTestRequest(@"POST", [modelBase stringByAppendingString:@"/api/commands"],
                                                              modelToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                            @"agentID": @"codex", @"workdirID": modelWorkdirID,
                                                                            @"text": @"沿用默认"},
                                                              &modelBareStatus, nil);
            NSString *bareCommandID = modelBareJSON[@"command"][@"commandID"];
            if (bareCommandID.length) CPBridgeWaitCommand(modelBase, modelToken, bareCommandID, @"succeeded", 2.0);
            NSDictionary *bareThreadStart = nil;
            for (NSUInteger i = sentBeforeBare; i < modelTx.sent.count; i++) {
                NSDictionary *msg = CPJSONLine(modelTx.sent[i]);
                if ([msg[@"method"] isEqualToString:@"thread/start"]) { bareThreadStart = msg; break; }
            }
            BOOL modelNoKey = modelBareStatus == 202 &&
                bareThreadStart[@"params"][@"cwd"] != nil &&
                bareThreadStart[@"params"][@"model"] == nil;

            NSInteger unknownModelStatus = 0;
            NSDictionary *unknownModelJSON = CPBridgeTestRequest(@"POST", [modelBase stringByAppendingString:@"/api/commands"],
                                                                 modelToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                               @"agentID": @"codex", @"workdirID": modelWorkdirID,
                                                                               @"modelID": @"no-such-model", @"text": @"坏模型"},
                                                                 &unknownModelStatus, nil);
            BOOL modelUnknown = unknownModelStatus == 400 &&
                [unknownModelJSON[@"error"] isEqualToString:@"unknown_model"];

            NSInteger orderStatus = 0;
            NSDictionary *orderJSON = CPBridgeTestRequest(@"POST", [modelBase stringByAppendingString:@"/api/commands"],
                                                          modelToken, @{@"opID": NSUUID.UUID.UUIDString, @"action": @"start",
                                                                        @"agentID": @"codex", @"workdirID": @"no-such-wd",
                                                                        @"modelID": @"no-such-model", @"text": @"先查项目"},
                                                          &orderStatus, nil);
            BOOL modelOrder = orderStatus == 400 && [orderJSON[@"error"] isEqualToString:@"unknown_workdir"];

            [modelDriver shutdown];
            [modelBridge stop];
            [modelBridge.pairing clearAllDevices];
            [modelDefaults removePersistentDomainForName:modelSuite];
            [[NSFileManager defaultManager] removeItemAtPath:modelWorkdir error:nil];

            BOOL modelCatalogOK = modelBridgeOK && modelParseHidden && modelSnapShape && modelListFail &&
                                  modelSnapEmpty && modelStartOK && modelNoKey && modelUnknown && modelOrder;
            printf("Activity stream self-test: fold-say=%s fold-think=%s fold-run=%s fold-edit=%s fold-plan=%s fold-usage=%s fold-note=%s drop-noise=%s coalesce=%s gate=%s timer-push=%s cap-entries=%s cap-streams=%s truncate=%s redact=%s redact-bridge=%s no-path=%s seq=%s sse-batch=%s unmanaged=%s snapshot=%s live-flip=%s\n",
                   actFoldSay ? "OK" : "FAIL",
                   actFoldThink ? "OK" : "FAIL",
                   actFoldRun ? "OK" : "FAIL",
                   actFoldEdit ? "OK" : "FAIL",
                   actFoldPlan ? "OK" : "FAIL",
                   actFoldUsage ? "OK" : "FAIL",
                   actFoldNote ? "OK" : "FAIL",
                   actDropsNoise ? "OK" : "FAIL",
                   actCoalesce ? "OK" : "FAIL",
                   actGated ? "OK" : "FAIL",
                   actTimerPush ? "OK" : "FAIL",
                   actCapEntries ? "OK" : "FAIL",
                   actCapStreams ? "OK" : "FAIL",
                   actTruncate ? "OK" : "FAIL",
                   actRedact ? "OK" : "FAIL",
                   actBridgeRedact ? "OK" : "FAIL",
                   actSSENoPath ? "OK" : "FAIL",
                   actSeqOK ? "OK" : "FAIL",
                   actSSEBatch ? "OK" : "FAIL",
                   actNoUnmanagedStream ? "OK" : "FAIL",
                   actSnapStream ? "OK" : "FAIL",
                   actLiveFlip ? "OK" : "FAIL");

            printf("Model catalog self-test: parse=%s list-fail=%s snap-shape=%s snap-empty=%s start-model=%s unknown-model=%s no-model-key=%s order=%s\n",
                   modelParseHidden ? "OK" : "FAIL",
                   modelListFail ? "OK" : "FAIL",
                   modelSnapShape ? "OK" : "FAIL",
                   modelSnapEmpty ? "OK" : "FAIL",
                   modelStartOK ? "OK" : "FAIL",
                   modelUnknown ? "OK" : "FAIL",
                   modelNoKey ? "OK" : "FAIL",
                   modelOrder ? "OK" : "FAIL");

            // taskCount 是环境事实而非断言:没装 Codex/Kimi 的机器(CI runner、纯贡献者)
            // 读到 0 个任务是正确结果,不该判失败。下面全部断言都跑 fixture,与本机数据无关。
            printf("Local agent data: %s (%ld tasks)\n",
                   taskCount > 0 ? "present" : "none — fixture assertions only",
                   (long)taskCount);

            BOOL controlSettingsOK = CPRunControlSettingsSelfTest();

            NSDate *quotaNow = [NSDate dateWithTimeIntervalSince1970:1];
            BOOL quotaTitleOK = [CPQuotaTitleForMinutes(300) isEqualToString:@"5小时"] &&
                                [CPQuotaTitleForMinutes(10080) isEqualToString:@"周"] &&
                                [CPQuotaTitleForMinutes(43200) isEqualToString:@"月"];
            BOOL quotaResetOK = [CPQuotaResetPhrase([NSDate dateWithTimeIntervalSince1970:1 + 25 * 60], quotaNow) isEqualToString:@"25分钟后重置"] &&
                                [CPQuotaResetPhrase([NSDate dateWithTimeIntervalSince1970:1 + 3 * 3600], quotaNow) isEqualToString:@"3小时后重置"] &&
                                [CPQuotaResetPhrase([NSDate dateWithTimeIntervalSince1970:1 + 3 * 86400], quotaNow) isEqualToString:@"3天后重置"];
            NSDictionary *codexCamel = @{
                @"rateLimits": @{
                    @"primary": @{ @"usedPercent": @57, @"windowDurationMins": @10080, @"resetsAt": @1787205275 },
                    @"secondary": [NSNull null]
                }
            };
            CPQuotaSnapshot *codexSnap = CPQuotaFromCodexRateLimits(codexCamel, @"codex", quotaNow);
            BOOL quotaCodexCamel = codexSnap.windows.count == 1 &&
                fabs(codexSnap.windows.firstObject.usedPercent - 57) < 0.01 &&
                [codexSnap.windows.firstObject.title isEqualToString:@"周"];
            NSDictionary *codexSnake = @{
                @"rate_limits": @{
                    @"primary": @{ @"used_percent": @12, @"window_minutes": @300, @"resets_at": @1000 },
                    @"secondary": @{ @"used_percent": @40, @"window_minutes": @10080, @"resets_at": @2000 }
                }
            };
            CPQuotaSnapshot *codexTwo = CPQuotaFromCodexRateLimits(codexSnake, @"codex", quotaNow);
            BOOL quotaCodexSnake = codexTwo.windows.count == 2 &&
                [codexTwo.windows[0].title isEqualToString:@"5小时"] &&
                [codexTwo.windows[1].title isEqualToString:@"周"];
            NSDictionary *kimiUsages = @{
                @"usages": @[
                    @{
                        @"scope": @"FEATURE_CODING",
                        @"detail": @{ @"limit": @"100", @"used": @"15", @"remaining": @"85",
                                      @"resetTime": @"2026-08-19T17:02:10.907253Z" },
                        @"limits": @[
                            @{ @"window": @{ @"duration": @300, @"timeUnit": @"TIME_UNIT_MINUTE" },
                               @"detail": @{ @"limit": @"100", @"remaining": @"100",
                                             @"resetTime": @"2026-08-17T12:02:10.907253Z" } }
                        ]
                    }
                ]
            };
            NSDictionary *kimiStats = @{
                @"ratelimitCode7d": @{ @"ratio": @0.1524, @"enabled": @YES,
                                       @"resetTime": @"2026-08-19T17:02:11.101527266Z" },
                @"subscriptionBalance": @{ @"amountUsedRatio": @0.7465,
                                           @"expireTime": @"2026-08-28T00:00:00Z" }
            };
            CPQuotaSnapshot *kimiSnap = CPQuotaFromKimiResponses(kimiUsages, kimiStats, @"kimi", quotaNow);
            CPQuotaWindow *kimiWeekly = nil;
            for (CPQuotaWindow *w in kimiSnap.windows) if ([w.windowID isEqualToString:@"weekly"]) kimiWeekly = w;
            BOOL quotaKimiRatio = kimiSnap.windows.count == 3 &&
                kimiWeekly && fabs(kimiWeekly.usedPercent - 15.24) < 0.05 &&
                [kimiSnap.windows.firstObject.title isEqualToString:@"5小时"];
            BOOL quotaMissing = CPQuotaFromCodexRateLimits(@{}, @"codex", quotaNow) == nil &&
                CPQuotaCompactLine(nil).length == 0 &&
                CPQuotaMenuTitle(@"Codex", nil) == nil;
            CPQuotaSnapshot *missingSnap = CPQuotaSnapshot.new;
            missingSnap.health = CPAgentHealthMissing;
            missingSnap.windows = NSMutableArray.array;
            BOOL quotaUnavailable = [CPQuotaMenuTitle(@"Codex", missingSnap) isEqualToString:@"Codex  额度不可用"];
            BOOL quotaOK = quotaTitleOK && quotaResetOK && quotaCodexCamel && quotaCodexSnake &&
                           quotaKimiRatio && quotaMissing && quotaUnavailable;
            printf("Quota self-test: title=%s reset=%s codex-camel=%s codex-snake=%s kimi-ratio=%s missing=%s unavailable=%s\n",
                   quotaTitleOK ? "OK" : "FAIL",
                   quotaResetOK ? "OK" : "FAIL",
                   quotaCodexCamel ? "OK" : "FAIL",
                   quotaCodexSnake ? "OK" : "FAIL",
                   quotaKimiRatio ? "OK" : "FAIL",
                   quotaMissing ? "OK" : "FAIL",
                   quotaUnavailable ? "OK" : "FAIL");

            return (internalThreadsFiltered && m2 && grandfatherIdempotent && taskRoutingOK && m6 && kimiOK && perfOK && todoSchemaOK && codexGlobOK && codexHealthMissingOK && bridgeOK && controlOK && workdirOK && codexDriverOK && activityOK && modelCatalogOK && controlSettingsOK && quotaOK) ? 0 : 2;
}


int CPRunKimiProbe(void) {
            // 只读真实验证:Kimi App conversations.sqlite + 客户端状态是否被识别。
            // 仅打印计数和状态,不打印会话标题、prompt 或记录正文。
            unsetenv("CP_KIMI_CLI_ROOT");
            unsetenv("CP_KIMI_DESKTOP_ROOT");
            unsetenv("CP_KIMI_CLIENT_DB");
            unsetenv("CP_KIMI_CLIENT_STATUS");
            CPKimiSource *probeSource = [[CPKimiSource alloc] initWithCache:CPStateCache.new];
            CPAgent *probeKimi = [probeSource readAgent];
            NSInteger workingCount = 0, completedCount = 0, waitingCount = 0, failedCount = 0;
            for (CPTask *t in probeKimi.tasks) {
                if (![t.sourceKind isEqualToString:@"kimi-client"]) continue;
                if (t.status == CPStatusWorking) workingCount++;
                else if (t.status == CPStatusCompleted) completedCount++;
                else if (t.status == CPStatusWaiting) waitingCount++;
                else if (t.status == CPStatusFailed) failedCount++;
            }
            NSMutableString *probeReport = [NSMutableString stringWithFormat:
                @"Kimi client probe: indexed=%ld shown=%lu working=%ld completed=%ld waiting=%ld failed=%ld\n",
                (long)probeSource.lastClientCount, (unsigned long)probeKimi.tasks.count,
                (long)workingCount, (long)completedCount, (long)waitingCount, (long)failedCount];
            fputs(probeReport.UTF8String, stdout);
            [probeReport writeToFile:@"/tmp/kimi-probe.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return probeSource.lastClientCount > 0 ? 0 : 4;
}

