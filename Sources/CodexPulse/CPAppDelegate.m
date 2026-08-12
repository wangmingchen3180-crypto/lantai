#import "CPAppDelegate.h"
#import "CPStatusEngine.h"
#import "CPScreenPolicy.h"
#import "CPReviewStore.h"
#import "CPControls.h"

#pragma mark - App Delegate


@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.reader = CPStateReader.new;
    self.refreshQueue = dispatch_queue_create("com.codexpulse.refresh", DISPATCH_QUEUE_SERIAL);
    self.refreshGate = CPRefreshGate.new;
    // 首帧不在主线程做昂贵读取:先以空数据建 UI,启动后立即由 refresh 走后台队列填充。
    self.agents = @[];
    self.lastAppliedSignature = CPAgentsSignature(self.agents);

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"Codex Pulse"];
    self.statusItem.menu = [self statusMenu];

    __weak typeof(self) weakSelf = self;
    self.dock = CPDockWindowController.new;
    self.dock.onPillClicked = ^{ [weakSelf showCard]; };
    [self.dock show];

    self.card = CPWorkbenchCardController.new;
    [self.card renderAgents:self.agents];
    [self.dock renderWithAgents:self.agents selectedAgent:self.card.selectedAgent];

    self.hud = CPHUDWindowController.new;
    self.hud.onClicked = ^{ [weakSelf showCard]; };
    [self.hud updateWithAgents:self.agents selectedAgent:self.card.selectedAgent];
    [self.hud show];
    if (self.hudVisualTest) { // --visual-test-hud: 强制展开并保持
        self.hud.stickyExpanded = YES;
        [self.hud expand];
    }
    if (self.detailVisualTest) { // --visual-test-detail: 打开工作台并展示一条真实任务详情
        // 截图模式需要同步拿到真实数据,一次性同步读取(非主路径,不进入常态刷新)。
        [self applyAgents:[self.reader readAgents] signature:nil];
        [self showCard];
        CPAgent *a = self.card.selectedAgent;
        if (a.tasks.count) {
            CPWorkbenchTaskRowButton *fake = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            fake.agentID = a.agentID;
            fake.taskID = a.tasks.firstObject.taskID;
            [self.card taskClicked:fake];
        }
    }
    if (self.kimiVisualTest) { // --visual-test-kimi: 打开工作台,选中 Kimi 并展示一条真实 Kimi 任务详情
        [self applyAgents:[self.reader readAgents] signature:nil];
        [self showCard];
        NSInteger kimiIdx = NSNotFound;
        for (NSInteger i = 0; i < (NSInteger)self.agents.count; i++) {
            if ([self.agents[(NSUInteger)i].agentID isEqualToString:@"kimi"]) { kimiIdx = i; break; }
        }
        if (kimiIdx != NSNotFound) {
            NSButton *fakeAgent = NSButton.new;
            fakeAgent.tag = kimiIdx;
            [self.card agentClicked:fakeAgent];
            // CP_VISUAL_TEST_KIMI_LIST=1 时只停在选择 Kimi 后的任务列表(列表截图),不打开详情抽屉。
            BOOL listOnly = NSProcessInfo.processInfo.environment[@"CP_VISUAL_TEST_KIMI_LIST"] != nil;
            if (!listOnly && self.card.selectedAgent.tasks.count) {
                CPWorkbenchTaskRowButton *fakeTask = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
                fakeTask.agentID = self.card.selectedAgent.agentID;
                fakeTask.taskID = self.card.selectedAgent.tasks.firstObject.taskID;
                [self.card taskClicked:fakeTask];
            }
        }
    }

    [self updateStatusBar];

    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(openWorkbench:)
                                               name:@"CPOpenWorkbench"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(selectAgent:)
                                               name:@"CPSelectAgent"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(dockModeChanged:)
                                               name:@"CPDockModeChanged"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(taskReviewed:)
                                               name:@"CPTaskReviewed"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(agentSourcesChanged:)
                                               name:CPAgentSourcesChangedNotification
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(screenParametersChanged:)
                                               name:NSApplicationDidChangeScreenParametersNotification
                                             object:nil];

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode == 53 && weakSelf.card.isVisible) {
            [weakSelf.card handleEscape];
            return nil;
        }
        return event;
    }];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
    [self refresh:nil]; // 首帧数据后台读取填充(闸门+串行队列),启动主线程不被 SQLite/rollout 阻塞
}

- (NSMenu *)statusMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Codex Pulse"];
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"打开工作台" action:@selector(openWorkbenchFromMenu:) keyEquivalent:@""];
    openItem.target = self;
    [menu addItem:openItem];
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出 Codex Pulse" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [menu addItem:quitItem];
    return menu;
}

- (void)openWorkbenchFromMenu:(id)sender {
    (void)sender;
    [self showCard];
}

- (void)openWorkbench:(NSNotification *)note {
    (void)note;
    [self showCard];
}

- (void)showCard {
    NSRect dockRect = self.dock.dockRect;
    [self.card showNearDockRect:dockRect edge:self.dock.dockEdge];
}

// 每 3s tick:昂贵的 state/logs SQLite 查询与 rollout 尾部解析全部在串行后台队列执行,
// 主线程只做合入与渲染。闸门保证最多一个在途读取,过期代际结果被丢弃。
- (void)refresh:(id)sender {
    (void)sender;
    if (!self.refreshGate) { // 自测中手工构造的 AppDelegate 无队列,退化为同步路径
        [self applyAgents:[self.reader readAgents] signature:nil];
        return;
    }
    if (![self.refreshGate beginRefresh]) return; // 合并:已有读取在途
    NSUInteger generation = ++self.refreshGeneration;
    CPStateReader *reader = self.reader;
    dispatch_queue_t queue = self.refreshQueue;
    __weak typeof(self) weakSelf = self;
    dispatch_async(queue, ^{
        NSArray<CPAgent *> *agents = [reader readAgents]; // 后台:IO + JSON 解析
        NSString *signature = CPAgentsSignature(agents);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate *strongSelf = weakSelf;
            if (!strongSelf) return; // 生命周期安全:app 退出后不再触达 UI
            BOOL runAgain = [strongSelf.refreshGate endRefreshAndShouldRunAgain];
            if (generation == strongSelf.refreshGeneration) { // 过期结果不覆盖
                [strongSelf applyAgents:agents signature:signature];
            }
            if (runAgain) [strongSelf refresh:nil];
        });
    });
}

// 数据无可见变化(签名一致)时跳过工作台/Dock/HUD/菜单栏全部重建,
// 不再每 3s 反复拆建视图与动画;签名变化才走完整渲染。UI 更新恒在主线程(调用方保证)。
- (void)applyAgents:(NSArray<CPAgent *> *)agents signature:(NSString *)signature {
    NSString *sig = signature ?: CPAgentsSignature(agents);
    if (self.lastAppliedSignature && [sig isEqualToString:self.lastAppliedSignature]) return;
    self.lastAppliedSignature = sig;
    self.appliedRefreshCount += 1;
    self.agents = agents;
    // 首次成功合入真实数据时豁免历史 Completed 的未读徽标(仅一次)。
    if (self.card.reviewStore) {
        CPGrandfatherCompletedReviewsIfNeeded(self.card.reviewStore.defaults, self.card.reviewStore, agents);
    }
    [self.card renderAgents:agents];
    [self.dock renderWithAgents:agents selectedAgent:self.card.selectedAgent];
    [self.hud updateWithAgents:agents selectedAgent:self.card.selectedAgent];
    [self updateStatusBar];
}

- (void)selectAgent:(NSNotification *)note {
    CPAgent *agent = note.object;
    if ([agent isKindOfClass:CPAgent.class]) {
        self.card.selectedAgent = agent;
        [self.card renderAgents:self.agents];
        [self.hud updateWithAgents:self.agents selectedAgent:agent];
    }
}

- (void)taskReviewed:(NSNotification *)note {
    (void)note;
    // HUD 自身已监听此通知；这里只同步悬浮球角标和菜单栏提示。
    [self.dock renderWithAgents:self.agents selectedAgent:self.card.selectedAgent];
    [self updateStatusBar];
}

- (void)agentSourcesChanged:(NSNotification *)note {
    (void)note;
    // 注册表变更后重建 reader;在途旧读取依靠 generation 自动丢弃,
    // pending 轮会用新配置立即同步,无需重启应用。
    self.reader = CPStateReader.new;
    self.lastAppliedSignature = nil;
    self.refreshGeneration += 1;
    [self refresh:nil];
}

- (void)screenParametersChanged:(NSNotification *)note {
    (void)note;
    // 拔显示器 / 改分辨率后把各窗口拉回主屏可见区；screens 为空时直接跳过。
    if (!CPTargetScreen()) return;
    [self.dock reclampToVisibleScreen];
    [self.hud reclampCollapsedIfNeeded];
    [self.card ensureFrameIntersectsVisibleScreen];
}

- (void)dockModeChanged:(NSNotification *)note {
    NSInteger mode = [note.object integerValue];
    [self.dock setMode:mode];
}

- (void)updateStatusBar {
    CPStatus overall = CPStatusIdle;
    for (CPAgent *a in self.agents) {
        if (a.status == CPStatusFailed) { overall = CPStatusFailed; break; }
        if (a.status == CPStatusAttention) overall = CPStatusAttention;
        else if (a.status == CPStatusWorking && overall != CPStatusAttention) overall = CPStatusWorking;
    }
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:CPStatusSymbol(overall) accessibilityDescription:CPStatusTitle(overall)];
    self.statusItem.button.contentTintColor = CPStatusColor(overall);

    NSInteger attention = CPBadgeCountForAgents(self.agents, self.card.reviewStore);
    self.statusItem.button.toolTip = attention
        ? [NSString stringWithFormat:@"Codex Pulse · %ld 个任务需关注", (long)attention]
        : [NSString stringWithFormat:@"Codex Pulse · %@", CPStatusTitle(overall)];
}

@end
