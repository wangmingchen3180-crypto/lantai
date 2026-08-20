#import "CPAppDelegate.h"
#import "CPStatusEngine.h"
#import "CPScreenPolicy.h"
#import "CPReviewStore.h"
#import "CPControls.h"
#import "CPDemoSource.h"
#import "CPScreenshots.h"
#import "CPBridgeServer.h"
#import "CPAgentControl.h"
#import "CPCodexDriver.h"
#import "CPQuota.h"

#pragma mark - App Delegate

@interface AppDelegate () <NSMenuDelegate>
@property CPBridgeServer *bridge;
@property CPAgentControlRegistry *controlRegistry;
@property CPCodexDriver *codexDriver;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.reader = CPStateReader.new;
    if (self.demoMode) self.reader.sources = CPDemoAgentSources();
    self.refreshQueue = dispatch_queue_create("com.codexpulse.refresh", DISPATCH_QUEUE_SERIAL);
    self.refreshGate = CPRefreshGate.new;
    // 首帧不在主线程做昂贵读取:先以空数据建 UI,启动后立即由 refresh 走后台队列填充。
    self.agents = @[];
    self.quotas = NSMutableDictionary.dictionary;
    self.lastAppliedSignature = CPAgentsSignature(self.agents);

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"澜台"];
    [self refreshStatusMenu];

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

    self.bridge = CPBridgeServer.new;
    self.bridge.reader = self.reader;
    self.bridge.todoStore = self.card.todoStore;
    self.bridge.reviewStore = self.card.reviewStore;
    self.controlRegistry = CPAgentControlRegistry.new;
    self.codexDriver = CPCodexDriver.new; // 二进制查找很快；app-server 握手在后台，不挡菜单栏
    // 实时活动流的接线只在这里发生：Agents 层不认识 Bridge，Bridge 也不认识 driver 的私有协议。
    // driver 被 registry 持有，registry 又挂在 bridge 上，捕获强引用会成环。
    __weak CPBridgeServer *weakBridge = self.bridge;
    self.codexDriver.onActivityEntry = ^(CPActivityEntry *entry) {
        [weakBridge ingestActivityEntry:entry];
    };
    self.codexDriver.onActivityFlush = ^(NSString *agentID, NSString *taskID) {
        [weakBridge flushActivityForAgentID:agentID taskID:taskID];
    };
    self.codexDriver.onActivityLive = ^(NSString *agentID, BOOL live) {
        [weakBridge setActivityLive:live forAgentID:agentID];
    };
    [self.controlRegistry registerDriver:self.codexDriver];
    self.bridge.controlRegistry = self.controlRegistry;
    // 默认不监听:Bridge 一起就在局域网上开明文端口,必须由用户主动打开。
    // driver 不受此开关影响——菜单栏的 Codex 额度也走它,且它只起本机子进程,不监听网络。
    if (CPBridgeIsEnabled()) [self.bridge start];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(bridgeTodosDidChange:)
                                               name:CPTodosDidChangeNotification
                                             object:nil];
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

    if (self.shotOutputDir.length) CPCaptureScreenshots(self, self.shotOutputDir);

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
                                           selector:@selector(connectPhoneFromMenu:)
                                               name:@"CPConnectPhone"
                                             object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(devicePaired:)
                                               name:CPBridgeDevicePairedNotification
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
    if (!self.demoMode && !CPRunningSelfTests) {
        self.quotaTimer = [NSTimer scheduledTimerWithTimeInterval:120.0 target:self selector:@selector(refreshQuotas:) userInfo:nil repeats:YES];
        [self refreshQuotas:nil];
    }
}

- (void)refreshStatusMenu {
    NSMenu *menu = [self statusMenu];
    menu.delegate = self;
    self.statusItem.menu = menu;
}

// 每次点开菜单栏图标前重建,避免旧进程或旧 NSMenu 实例长期缓存过时条目。
- (void)menuNeedsUpdate:(NSMenu *)menu {
    if (menu != self.statusItem.menu) return;
    if (self.lastQuotaRefresh && [NSDate.date timeIntervalSinceDate:self.lastQuotaRefresh] > 30) {
        [self refreshQuotas:nil];
    }
    [self refreshStatusMenu];
}

- (NSMenu *)statusMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"澜台"];
    NSMenuItem *openItem = [[NSMenuItem alloc] initWithTitle:@"打开工作台" action:@selector(openWorkbenchFromMenu:) keyEquivalent:@""];
    openItem.target = self;
    [menu addItem:openItem];
    // 开关放在配对入口之前:先让用户看见「这会开一个局域网端口」,再谈配对。
    NSMenuItem *bridgeItem = [[NSMenuItem alloc] initWithTitle:@"手机连接（局域网）"
                                                        action:@selector(toggleBridgeFromMenu:)
                                                 keyEquivalent:@""];
    bridgeItem.target = self;
    bridgeItem.state = self.bridge.running ? NSControlStateValueOn : NSControlStateValueOff;
    if (self.bridge.running && self.bridge.port > 0) {
        bridgeItem.toolTip = [NSString stringWithFormat:@"正在监听 %@:%ld（明文 HTTP，仅限局域网）",
                              [self.bridge preferredLANAddress] ?: @"本机", (long)self.bridge.port];
    } else {
        bridgeItem.toolTip = @"关闭时澜台不监听任何端口，手机无法连接";
    }
    [menu addItem:bridgeItem];

    // 配对是一次性动作(手机存下 token 后直接连),所以入口放菜单,不占工作台标题栏。
    NSMenuItem *phoneItem = [[NSMenuItem alloc] initWithTitle:@"连接手机…" action:@selector(connectPhoneFromMenu:) keyEquivalent:@""];
    phoneItem.target = self;
    [menu addItem:phoneItem];
    NSMenuItem *controlItem = [[NSMenuItem alloc] initWithTitle:@"手机指挥设置…" action:@selector(openControlSettingsFromMenu:) keyEquivalent:@""];
    controlItem.target = self;
    [menu addItem:controlItem];
    [menu addItem:[NSMenuItem separatorItem]];
    BOOL drewQuota = NO;
    for (CPAgent *agent in self.agents) {
        if (agent.placeholder) continue;
        NSString *title = CPQuotaMenuTitle(agent.name, agent.quota ?: self.quotas[agent.agentID]);
        if (!title.length) continue;
        NSMenuItem *quotaItem = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        quotaItem.enabled = NO;
        [menu addItem:quotaItem];
        drewQuota = YES;
    }
    if (drewQuota) [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"退出澜台" action:@selector(terminate:) keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [menu addItem:quitItem];
    return menu;
}

- (void)openWorkbenchFromMenu:(id)sender {
    (void)sender;
    [self showCard];
}

- (void)toggleBridgeFromMenu:(id)sender {
    (void)sender;
    if (self.bridge.running) {
        [self.bridge stop];
        CPBridgeSetEnabled(NO);
        // 关掉监听不撤销已配对设备:它们重新打开时自然连不上,重开开关即恢复。
        if (self.pairingSheet.isVisible) [self.pairingSheet close];
    } else {
        CPBridgeSetEnabled(YES);
        if (![self.bridge start]) CPBridgeSetEnabled(NO); // 端口全被占用等,别把开关留在骗人的开态
    }
    self.statusItem.menu = [self statusMenu];
}

- (void)connectPhoneFromMenu:(id)sender {
    (void)sender;
    // 点「连接手机」本身就是明确同意开放端口,不再多一层确认。
    if (!self.bridge.running) [self toggleBridgeFromMenu:nil];
    if (!self.bridge.running) {
        NSAlert *alert = NSAlert.new;
        alert.messageText = @"无法启动手机连接";
        alert.informativeText = @"8787–8797 端口都被占用了。关掉占用端口的程序后再试。";
        [alert runModal];
        return;
    }
    if (!self.pairingSheet) {
        self.pairingSheet = CPPairingSheetController.new;
        __weak typeof(self) weakSelf = self;
        // 配对卡不持有配对逻辑,只在打开/重新生成时向 Bridge 取码;码不落盘、不写日志。
        self.pairingSheet.codeProvider = ^NSString *(BOOL regenerate) {
            CPBridgeServer *bridge = weakSelf.bridge;
            if (!bridge.running) return nil;
            if (regenerate) return [bridge.pairing issuePairingCode];
            return [bridge.pairing currentPairingCode] ?: [bridge.pairing issuePairingCode];
        };
        self.pairingSheet.baseURLProvider = ^NSString *{
            CPBridgeServer *bridge = weakSelf.bridge;
            if (!bridge.running) return nil;
            NSString *host = [bridge preferredLANAddress];
            if (!host.length) return nil;
            return [NSString stringWithFormat:@"http://%@:%ld", host, (long)bridge.port];
        };
        self.pairingSheet.codeTTL = self.bridge.pairing.pairingCodeTTL;
    }
    [self.pairingSheet show];
}

- (void)openControlSettingsFromMenu:(id)sender {
    (void)sender;
    if (!self.controlSettings) {
        self.controlSettings = CPControlSettingsController.new;
        __weak typeof(self) weakSelf = self;
        self.controlSettings.devicesProvider = ^NSArray<NSDictionary *> *{
            NSMutableArray *rows = NSMutableArray.array;
            for (CPBridgeDevice *device in weakSelf.bridge.pairing.pairedDevices) {
                [rows addObject:@{
                    @"deviceId": device.deviceId ?: @"",
                    @"deviceName": device.deviceName ?: @"",
                    @"createdAt": @(device.createdAt),
                    @"canControl": device.canControl ? @YES : @NO,
                }];
            }
            return rows;
        };
        self.controlSettings.setControlHandler = ^BOOL(NSString *deviceId, BOOL canControl) {
            return [weakSelf.bridge.pairing setDevice:deviceId canControl:canControl];
        };
        self.controlSettings.revokeHandler = ^BOOL(NSString *deviceId) {
            return [weakSelf.bridge.pairing revokeDevice:deviceId];
        };
        self.controlSettings.settingsDidChange = ^{
            [weakSelf.bridge publishSnapshotNow];
        };
    }
    [self.controlSettings show];
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
    for (CPAgent *agent in agents) {
        if (!agent.quota) agent.quota = self.quotas[agent.agentID];
        else self.quotas[agent.agentID] = agent.quota;
    }
    self.agents = agents;
    self.bridge.latestAgents = agents;
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
    if (self.demoMode) self.reader.sources = CPDemoAgentSources();
    self.bridge.reader = self.reader;
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

- (void)refreshQuotas:(id)sender {
    (void)sender;
    if (self.demoMode || CPRunningSelfTests) return;
    if (self.quotaRefreshInFlight) return;
    self.quotaRefreshInFlight = YES;
    self.lastQuotaRefresh = NSDate.date;
    NSMutableSet<NSString *> *ids = NSMutableSet.set;
    for (CPAgent *agent in self.agents) {
        if (agent.agentID.length) [ids addObject:agent.agentID];
    }
    if (!ids.count) {
        for (NSString *providerID in CPEnabledAgentProviderIDs()) [ids addObject:providerID];
    }

    NSSet<NSString *> *wanted = [ids copy];
    dispatch_group_t group = dispatch_group_create();
    NSMutableDictionary<NSString *, CPQuotaSnapshot *> *fresh = NSMutableDictionary.dictionary;
    NSObject *lock = NSObject.new;

    if ([wanted containsObject:@"codex"]) {
        dispatch_group_enter(group);
        [self.codexDriver readRateLimitsWithCompletion:^(NSDictionary *result, NSString *errorMessage) {
            (void)errorMessage;
            CPQuotaSnapshot *snap = CPQuotaFromCodexRateLimits(result, @"codex", NSDate.date);
            if (!snap) {
                snap = CPQuotaSnapshot.new;
                snap.agentID = @"codex";
                snap.health = CPAgentHealthMissing;
                snap.windows = NSMutableArray.array;
                snap.updatedAt = NSDate.date;
            }
            @synchronized (lock) { fresh[@"codex"] = snap; }
            dispatch_group_leave(group);
        }];
    }
    if ([wanted containsObject:@"kimi"] || [wanted containsObject:@"kimi-cli"]) {
        dispatch_group_enter(group);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            CPQuotaSnapshot *snap = CPKimiFetchQuotaSnapshot();
            @synchronized (lock) {
                fresh[@"kimi"] = snap;
                if ([wanted containsObject:@"kimi-cli"]) fresh[@"kimi-cli"] = snap;
            }
            dispatch_group_leave(group);
        });
    }

    __weak typeof(self) weakSelf = self;
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        AppDelegate *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.quotaRefreshInFlight = NO;
        [strongSelf.quotas addEntriesFromDictionary:fresh];
        if (!strongSelf.agents.count) return;
        NSMutableArray<CPAgent *> *updated = [strongSelf.agents mutableCopy];
        for (CPAgent *agent in updated) {
            CPQuotaSnapshot *snap = fresh[agent.agentID];
            if (snap) agent.quota = snap;
        }
        strongSelf.lastAppliedSignature = nil;
        [strongSelf applyAgents:updated signature:CPAgentsSignature(updated)];
        [strongSelf refreshStatusMenu];
    });
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
        ? [NSString stringWithFormat:@"澜台 · %ld 个任务需关注", (long)attention]
        : [NSString stringWithFormat:@"澜台 · %@", CPStatusTitle(overall)];
}

- (void)devicePaired:(NSNotification *)note {
    [self.pairingSheet showPairedWithDeviceName:note.userInfo[@"deviceName"]];
}

- (void)bridgeTodosDidChange:(NSNotification *)note {
    (void)note;
    [self.card renderTodos];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self.codexDriver shutdown];
    [self.bridge stop];
}

@end
