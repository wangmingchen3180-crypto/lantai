#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <sqlite3.h>

typedef NS_ENUM(NSInteger, CPStatus) {
    CPStatusWorking,
    CPStatusWaiting,
    CPStatusAttention,
    CPStatusCompleted,
    CPStatusFailed,
    CPStatusIdle,
};

@interface CPTask : NSObject
@property NSString *taskID;
@property NSString *title;
@property NSString *projectPath;
@property NSString *projectName;
@property NSDate *createdAt;
@property NSDate *updatedAt;
@property NSInteger tokensUsed;
@property CPStatus status;
@property NSString *activity;
@end
@implementation CPTask @end

static NSString *CPStatusTitle(CPStatus status) {
    switch (status) {
        case CPStatusWorking: return @"正在工作";
        case CPStatusWaiting: return @"等待下一步";
        case CPStatusAttention: return @"需要你处理";
        case CPStatusCompleted: return @"刚刚完成";
        case CPStatusFailed: return @"出现错误";
        case CPStatusIdle: return @"空闲";
    }
}

static NSString *CPStatusSymbol(CPStatus status) {
    switch (status) {
        case CPStatusWorking: return @"sparkles";
        case CPStatusWaiting: return @"pause.fill";
        case CPStatusAttention: return @"exclamationmark.bubble.fill";
        case CPStatusCompleted: return @"checkmark.circle.fill";
        case CPStatusFailed: return @"xmark.octagon.fill";
        case CPStatusIdle: return @"moon.zzz.fill";
    }
}

static NSColor *CPStatusColor(CPStatus status) {
    switch (status) {
        case CPStatusWorking: return NSColor.systemBlueColor;
        case CPStatusWaiting: return NSColor.systemOrangeColor;
        case CPStatusAttention: return NSColor.systemPurpleColor;
        case CPStatusCompleted: return NSColor.systemGreenColor;
        case CPStatusFailed: return NSColor.systemRedColor;
        case CPStatusIdle: return NSColor.secondaryLabelColor;
    }
}

static NSDate *CPDateFromMillis(sqlite3_int64 value) {
    if (value <= 0) return NSDate.date;
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)value / 1000.0];
}

static NSDate *CPDateFromSeconds(sqlite3_int64 value) {
    if (value <= 0) return nil;
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)value];
}

static NSString *CPCleanTitle(const unsigned char *text) {
    if (!text) return @"未命名任务";
    NSString *value = [NSString stringWithUTF8String:(const char *)text] ?: @"未命名任务";
    value = [[value stringByReplacingOccurrencesOfString:@"\n" withString:@" "]
             stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (value.length > 58) return [[value substringToIndex:58] stringByAppendingString:@"…"];
    return value;
}

@interface CPStateReader : NSObject
- (NSArray<CPTask *> *)readTasks;
@end

@implementation CPStateReader
- (NSArray<CPTask *> *)readTasks {
    NSString *home = NSHomeDirectory();
    NSString *statePath = [home stringByAppendingPathComponent:@".codex/state_5.sqlite"];
    sqlite3 *stateDB = NULL;
    if (sqlite3_open_v2(statePath.UTF8String, &stateDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (stateDB) sqlite3_close(stateDB);
        return @[];
    }
    sqlite3_busy_timeout(stateDB, 150);

    NSString *logsPath = [home stringByAppendingPathComponent:@".codex/logs_2.sqlite"];
    sqlite3 *logsDB = NULL;
    if (sqlite3_open_v2(logsPath.UTF8String, &logsDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (logsDB) sqlite3_close(logsDB);
        logsDB = NULL;
    } else {
        sqlite3_busy_timeout(logsDB, 150);
    }

    const char *sql =
        "SELECT id, COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), '未命名任务'), "
        "cwd, created_at_ms, updated_at_ms, tokens_used FROM threads "
        "WHERE archived=0 AND preview<>'' ORDER BY recency_at_ms DESC, updated_at_ms DESC LIMIT 10";
    sqlite3_stmt *statement = NULL;
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    if (sqlite3_prepare_v2(stateDB, sql, -1, &statement, NULL) == SQLITE_OK) {
        while (sqlite3_step(statement) == SQLITE_ROW) {
            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(statement, 0)] ?: @"";
            task.title = CPCleanTitle(sqlite3_column_text(statement, 1));
            task.projectPath = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(statement, 2)] ?: @"";
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Codex";
            task.createdAt = CPDateFromMillis(sqlite3_column_int64(statement, 3));
            task.updatedAt = CPDateFromMillis(sqlite3_column_int64(statement, 4));
            task.tokensUsed = (NSInteger)sqlite3_column_int64(statement, 5);
            [self enrichTask:task logsDB:logsDB];
            [tasks addObject:task];
        }
    }
    if (statement) sqlite3_finalize(statement);
    sqlite3_close(stateDB);
    if (logsDB) sqlite3_close(logsDB);
    return tasks;
}

- (void)enrichTask:(CPTask *)task logsDB:(sqlite3 *)logsDB {
    if (!logsDB) {
        task.status = -[task.updatedAt timeIntervalSinceNow] < 1800 ? CPStatusWaiting : CPStatusIdle;
        task.activity = @"正在整理任务状态";
        return;
    }
    const char *sql =
        "SELECT MAX(ts), "
        "MAX(CASE WHEN feedback_log_body LIKE '%turn/completed%' OR feedback_log_body LIKE '%turn_completed%' THEN ts ELSE 0 END), "
        "MAX(CASE WHEN feedback_log_body LIKE '%approval%' OR feedback_log_body LIKE '%request_user_input%' THEN ts ELSE 0 END), "
        "MAX(CASE WHEN level='ERROR' THEN ts ELSE 0 END) FROM logs WHERE thread_id=?";
    sqlite3_stmt *statement = NULL;
    NSDate *lastLog = nil, *lastComplete = nil, *lastAttention = nil, *lastError = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, task.taskID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_ROW) {
            lastLog = CPDateFromSeconds(sqlite3_column_int64(statement, 0));
            lastComplete = CPDateFromSeconds(sqlite3_column_int64(statement, 1));
            lastAttention = CPDateFromSeconds(sqlite3_column_int64(statement, 2));
            lastError = CPDateFromSeconds(sqlite3_column_int64(statement, 3));
        }
    }
    if (statement) sqlite3_finalize(statement);

    NSTimeInterval logAge = lastLog ? -lastLog.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval completeAge = lastComplete ? -lastComplete.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval attentionAge = lastAttention ? -lastAttention.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval errorAge = lastError ? -lastError.timeIntervalSinceNow : DBL_MAX;
    if (errorAge < 180 && (!lastComplete || [lastError compare:lastComplete] == NSOrderedDescending)) task.status = CPStatusFailed;
    else if (attentionAge < 900 && (!lastComplete || [lastAttention compare:lastComplete] == NSOrderedDescending)) task.status = CPStatusAttention;
    else if (logAge < 12) task.status = CPStatusWorking;
    else if (completeAge < 180) task.status = CPStatusCompleted;
    else if (-task.updatedAt.timeIntervalSinceNow < 1800) task.status = CPStatusWaiting;
    else task.status = CPStatusIdle;

    task.activity = [self latestActivityForThread:task.taskID logsDB:logsDB status:task.status];
}

- (NSString *)latestActivityForThread:(NSString *)threadID logsDB:(sqlite3 *)logsDB status:(CPStatus)status {
    const char *sql = "SELECT target FROM logs WHERE thread_id=? ORDER BY ts DESC, ts_nanos DESC LIMIT 1";
    sqlite3_stmt *statement = NULL;
    NSString *target = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, threadID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_ROW && sqlite3_column_text(statement, 0))
            target = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(statement, 0)];
    }
    if (statement) sqlite3_finalize(statement);
    if ([target containsString:@"tools::parallel"]) return @"正在调用工具";
    if ([target containsString:@"stream_events"]) return @"正在处理模型输出";
    if ([target containsString:@"http_client"] || [target containsString:@"responses"]) return @"正在请求模型";
    if ([target containsString:@"shell"] || [target containsString:@"exec"]) return @"正在运行命令";
    if ([target containsString:@"app_server"]) return @"正在同步 Codex";
    if ([target containsString:@"goal"]) return @"正在推进长期目标";
    return status == CPStatusCompleted ? @"任务已完成" : @"Codex 正在活动";
}
@end

@interface CPViewController : NSViewController
@property NSTextField *statusLabel;
@property NSTextField *connectionLabel;
@property NSImageView *statusImage;
@property NSTextField *titleLabel;
@property NSTextField *activityLabel;
@property NSTextField *metaLabel;
@property NSStackView *stageStack;
@property NSStackView *recentStack;
@property NSTextField *sourceLabel;
@property NSArray<CPTask *> *tasks;
- (void)renderTasks:(NSArray<CPTask *> *)tasks codexRunning:(BOOL)running;
@end

static NSTextField *CPLabel(CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.maximumNumberOfLines = 2;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSBox *CPSeparator(void) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 328, 1)];
    box.boxType = NSBoxSeparator;
    [box.widthAnchor constraintEqualToConstant:328].active = YES;
    return box;
}

@implementation CPViewController
- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 360, 470)];
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.view = root;

    NSStackView *content = [NSStackView stackViewWithViews:@[]];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 11;
    content.edgeInsets = NSEdgeInsetsMake(16, 16, 14, 16);
    content.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:content];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [content.topAnchor constraintEqualToAnchor:root.topAnchor],
        [content.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor],
    ]];

    NSStackView *header = [NSStackView stackViewWithViews:@[]];
    header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    header.alignment = NSLayoutAttributeCenterY;
    header.spacing = 10;
    self.statusImage = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 30, 30)];
    [self.statusImage.widthAnchor constraintEqualToConstant:30].active = YES;
    [self.statusImage.heightAnchor constraintEqualToConstant:30].active = YES;
    NSStackView *headerText = [NSStackView stackViewWithViews:@[]];
    headerText.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerText.alignment = NSLayoutAttributeLeading;
    headerText.spacing = 2;
    self.statusLabel = CPLabel(15, NSFontWeightSemibold, NSColor.labelColor);
    self.connectionLabel = CPLabel(11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    [headerText addArrangedSubview:self.statusLabel];
    [headerText addArrangedSubview:self.connectionLabel];
    [header addArrangedSubview:self.statusImage];
    [header addArrangedSubview:headerText];
    [content addArrangedSubview:header];

    [content addArrangedSubview:CPSeparator()];
    NSTextField *section = [NSTextField labelWithString:@"当前任务"];
    section.font = [NSFont systemFontOfSize:11];
    section.textColor = NSColor.secondaryLabelColor;
    [content addArrangedSubview:section];
    self.titleLabel = CPLabel(14, NSFontWeightSemibold, NSColor.labelColor);
    self.titleLabel.preferredMaxLayoutWidth = 320;
    [content addArrangedSubview:self.titleLabel];
    self.activityLabel = CPLabel(12, NSFontWeightMedium, NSColor.systemBlueColor);
    [content addArrangedSubview:self.activityLabel];
    self.stageStack = [NSStackView stackViewWithViews:@[]];
    self.stageStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.stageStack.spacing = 5;
    self.stageStack.distribution = NSStackViewDistributionFillEqually;
    [self.stageStack.widthAnchor constraintEqualToConstant:328].active = YES;
    for (NSInteger index = 0; index < 4; index++) {
        NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 75, 4)];
        box.boxType = NSBoxCustom;
        box.cornerRadius = 2;
        box.fillColor = [NSColor separatorColor];
        box.borderWidth = 0;
        [box.heightAnchor constraintEqualToConstant:4].active = YES;
        [self.stageStack addArrangedSubview:box];
    }
    [content addArrangedSubview:self.stageStack];
    self.metaLabel = CPLabel(11, NSFontWeightRegular, NSColor.secondaryLabelColor);
    [content addArrangedSubview:self.metaLabel];

    [content addArrangedSubview:CPSeparator()];
    NSTextField *recent = [NSTextField labelWithString:@"最近任务"];
    recent.font = [NSFont systemFontOfSize:11];
    recent.textColor = NSColor.secondaryLabelColor;
    [content addArrangedSubview:recent];
    self.recentStack = [NSStackView stackViewWithViews:@[]];
    self.recentStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.recentStack.alignment = NSLayoutAttributeLeading;
    self.recentStack.spacing = 7;
    [content addArrangedSubview:self.recentStack];
    [content addArrangedSubview:CPSeparator()];

    NSStackView *footer = [NSStackView stackViewWithViews:@[]];
    footer.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    footer.alignment = NSLayoutAttributeCenterY;
    self.sourceLabel = CPLabel(10, NSFontWeightRegular, NSColor.tertiaryLabelColor);
    self.sourceLabel.stringValue = @"Codex Desktop · 本地只读";
    NSButton *openButton = [NSButton buttonWithTitle:@"打开 Codex" target:self action:@selector(openCodex:)];
    openButton.bezelStyle = NSBezelStyleRounded;
    [footer addArrangedSubview:self.sourceLabel];
    [footer addArrangedSubview:openButton];
    footer.distribution = NSStackViewDistributionEqualSpacing;
    [footer.widthAnchor constraintEqualToConstant:328].active = YES;
    [content addArrangedSubview:footer];
}

- (CPTask *)primaryTask {
    for (CPTask *task in self.tasks) if (task.status == CPStatusWorking || task.status == CPStatusAttention) return task;
    return self.tasks.firstObject;
}

- (CPStatus)overallStatus {
    for (CPTask *task in self.tasks) if (task.status == CPStatusFailed) return CPStatusFailed;
    for (CPTask *task in self.tasks) if (task.status == CPStatusAttention) return CPStatusAttention;
    for (CPTask *task in self.tasks) if (task.status == CPStatusWorking) return CPStatusWorking;
    return self.primaryTask ? self.primaryTask.status : CPStatusIdle;
}

- (void)renderTasks:(NSArray<CPTask *> *)tasks codexRunning:(BOOL)running {
    self.tasks = tasks;
    CPStatus overall = self.overallStatus;
    self.statusLabel.stringValue = CPStatusTitle(overall);
    self.connectionLabel.stringValue = running ? @"Codex Mac 已连接" : @"Codex Mac 未运行";
    NSImage *symbol = [NSImage imageWithSystemSymbolName:CPStatusSymbol(overall) accessibilityDescription:CPStatusTitle(overall)];
    symbol = [symbol imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:CPStatusColor(overall)]];
    self.statusImage.image = symbol;

    CPTask *task = self.primaryTask;
    if (task) {
        self.titleLabel.stringValue = task.title;
        self.activityLabel.stringValue = [@"⌁  " stringByAppendingString:task.activity];
        self.activityLabel.textColor = CPStatusColor(task.status);
        NSTimeInterval elapsed = MAX(0, -task.createdAt.timeIntervalSinceNow);
        NSString *duration = elapsed < 3600 ? [NSString stringWithFormat:@"%ld 分钟", (long)(elapsed / 60)] : [NSString stringWithFormat:@"%ld 小时 %ld 分", (long)(elapsed / 3600), (long)((NSInteger)elapsed % 3600 / 60)];
        self.metaLabel.stringValue = [NSString stringWithFormat:@"%@   ·   %@   ·   %ld tokens", task.projectName, duration, (long)task.tokensUsed];
        NSInteger step = task.status == CPStatusCompleted ? 3 : (task.status == CPStatusWorking ? 1 : 2);
        NSInteger index = 0;
        for (NSBox *box in self.stageStack.arrangedSubviews) box.fillColor = index++ <= step ? CPStatusColor(task.status) : NSColor.separatorColor;
    } else {
        self.titleLabel.stringValue = @"还没有可显示的 Codex 任务";
        self.activityLabel.stringValue = @"启动 Codex 后，小窗会自动刷新";
        self.metaLabel.stringValue = @"";
    }

    for (NSView *view in self.recentStack.arrangedSubviews.copy) [self.recentStack removeArrangedSubview:view], [view removeFromSuperview];
    for (CPTask *item in [tasks subarrayWithRange:NSMakeRange(0, MIN((NSUInteger)4, tasks.count))]) {
        NSStackView *row = [NSStackView stackViewWithViews:@[]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.spacing = 7;
        NSTextField *dot = [NSTextField labelWithString:@"●"];
        dot.textColor = CPStatusColor(item.status);
        dot.font = [NSFont systemFontOfSize:8];
        NSTextField *label = CPLabel(11.5, NSFontWeightRegular, NSColor.labelColor);
        label.stringValue = [NSString stringWithFormat:@"%@  ·  %@", item.title, item.projectName];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label.widthAnchor constraintLessThanOrEqualToConstant:305].active = YES;
        [row addArrangedSubview:dot];
        [row addArrangedSubview:label];
        [self.recentStack addArrangedSubview:row];
    }
    self.sourceLabel.stringValue = [NSString stringWithFormat:@"本地只读 · %@", [NSDateFormatter localizedStringFromDate:NSDate.date dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]];
}

- (void)openCodex:(id)sender {
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if ([app.bundleIdentifier isEqualToString:@"com.openai.codex"] || [app.localizedName isEqualToString:@"Codex"]) {
            [app activateWithOptions:0];
            return;
        }
    }
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:@"/Applications/Codex.app"]];
}
@end

@interface CPEdgePanelController : NSObject
@property NSPanel *panel;
@property CPViewController *dashboard;
@property NSButton *handleButton;
@property BOOL expanded;
- (void)show;
- (void)toggle;
- (void)renderTasks:(NSArray<CPTask *> *)tasks codexRunning:(BOOL)running;
@end

@implementation CPEdgePanelController
static const CGFloat CPEdgeHandleWidth = 30.0;
static const CGFloat CPEdgeDashboardWidth = 360.0;
static const CGFloat CPEdgePanelHeight = 470.0;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.expanded = ![NSUserDefaults.standardUserDefaults boolForKey:@"CodexPulseEdgeCollapsed"];
    self.dashboard = CPViewController.new;
    (void)self.dashboard.view;

    CGFloat totalWidth = CPEdgeHandleWidth + CPEdgeDashboardWidth;
    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, totalWidth, CPEdgePanelHeight)
                                            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.level = NSFloatingWindowLevel;
    self.panel.opaque = NO;
    self.panel.backgroundColor = NSColor.clearColor;
    self.panel.hasShadow = YES;
    self.panel.hidesOnDeactivate = NO;
    self.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                    NSWindowCollectionBehaviorFullScreenAuxiliary |
                                    NSWindowCollectionBehaviorStationary;

    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, totalWidth, CPEdgePanelHeight)];
    container.wantsLayer = YES;
    self.panel.contentView = container;

    NSVisualEffectView *handle = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 158, CPEdgeHandleWidth, 154)];
    handle.material = NSVisualEffectMaterialHUDWindow;
    handle.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    handle.state = NSVisualEffectStateActive;
    handle.wantsLayer = YES;
    handle.layer.cornerRadius = 12;
    handle.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner;
    handle.layer.borderWidth = 0.5;
    handle.layer.borderColor = NSColor.separatorColor.CGColor;
    [container addSubview:handle];

    self.handleButton = [[NSButton alloc] initWithFrame:handle.bounds];
    self.handleButton.bordered = NO;
    self.handleButton.imagePosition = NSImageOnly;
    self.handleButton.target = self;
    self.handleButton.action = @selector(toggleFromButton:);
    self.handleButton.toolTip = @"展开或收起 Codex Pulse";
    [handle addSubview:self.handleButton];

    NSView *dashboardView = self.dashboard.view;
    dashboardView.frame = NSMakeRect(CPEdgeHandleWidth, 0, CPEdgeDashboardWidth, CPEdgePanelHeight);
    dashboardView.wantsLayer = YES;
    dashboardView.layer.cornerRadius = 14;
    dashboardView.layer.masksToBounds = YES;
    [container addSubview:dashboardView];

    NSPanGestureRecognizer *pan = [[NSPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [container addGestureRecognizer:pan];
    [self updateHandleImage];

    [NSNotificationCenter.defaultCenter addObserver:self
                                            selector:@selector(screenChanged:)
                                                name:NSApplicationDidChangeScreenParametersNotification
                                              object:nil];
    return self;
}

- (NSScreen *)targetScreen {
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

- (NSRect)targetFrameExpanded:(BOOL)expanded {
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat totalWidth = CPEdgeHandleWidth + CPEdgeDashboardWidth;
    CGFloat visibleWidth = expanded ? totalWidth : CPEdgeHandleWidth;
    CGFloat x = NSMaxX(visible) - visibleWidth;
    CGFloat y = NSMidY(visible) - CPEdgePanelHeight / 2.0;
    y = MAX(NSMinY(visible) + 16, MIN(y, NSMaxY(visible) - CPEdgePanelHeight - 16));
    return NSMakeRect(x, y, totalWidth, CPEdgePanelHeight);
}

- (void)show {
    [self.panel setFrame:[self targetFrameExpanded:self.expanded] display:YES];
    [self.panel orderFrontRegardless];
}

- (void)toggle { [self setExpanded:!self.expanded animated:YES]; }

- (void)toggleFromButton:(id)sender { [self toggle]; }

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    _expanded = expanded;
    [NSUserDefaults.standardUserDefaults setBool:!expanded forKey:@"CodexPulseEdgeCollapsed"];
    [self updateHandleImage];
    NSRect frame = [self targetFrameExpanded:expanded];
    if (!animated) {
        [self.panel setFrame:frame display:YES];
        return;
    }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.24;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.panel.animator setFrame:frame display:YES];
    } completionHandler:nil];
}

- (void)updateHandleImage {
    NSString *name = self.expanded ? @"chevron.right" : @"chevron.left";
    self.handleButton.image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:self.expanded ? @"收起" : @"展开"];
}

- (void)handlePan:(NSPanGestureRecognizer *)gesture {
    NSPoint velocity = [gesture velocityInView:gesture.view];
    if (gesture.state != NSGestureRecognizerStateEnded) return;
    if (velocity.x > 120) [self setExpanded:NO animated:YES];
    else if (velocity.x < -120) [self setExpanded:YES animated:YES];
}

- (void)screenChanged:(NSNotification *)note {
    [self.panel setFrame:[self targetFrameExpanded:self.expanded] display:YES animate:YES];
}

- (void)renderTasks:(NSArray<CPTask *> *)tasks codexRunning:(BOOL)running {
    [self.dashboard renderTasks:tasks codexRunning:running];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSPopover *popover;
@property CPViewController *viewController;
@property CPStateReader *reader;
@property NSTimer *timer;
@property CPEdgePanelController *edgeController;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.reader = CPStateReader.new;
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"Codex Pulse"];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    self.viewController = CPViewController.new;
    self.popover = NSPopover.new;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentSize = NSMakeSize(360, 470);
    self.popover.contentViewController = self.viewController;
    self.edgeController = CPEdgePanelController.new;
    [self.edgeController show];
    [self refresh:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) [self.popover close];
    else [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
}

- (void)refresh:(id)sender {
    NSArray<CPTask *> *tasks = [self.reader readTasks];
    BOOL running = NO;
    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications)
        if ([app.bundleIdentifier isEqualToString:@"com.openai.codex"] || [app.localizedName isEqualToString:@"Codex"]) running = YES;
    [self.viewController renderTasks:tasks codexRunning:running];
    [self.edgeController renderTasks:tasks codexRunning:running];
    CPStatus status = self.viewController.overallStatus;
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:CPStatusSymbol(status) accessibilityDescription:CPStatusTitle(status)];
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"Codex · %@", CPStatusTitle(status)];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            NSArray<CPTask *> *tasks = [CPStateReader.new readTasks];
            printf("Codex Pulse self-test: %lu tasks, local read OK\n", (unsigned long)tasks.count);
            return tasks.count > 0 ? 0 : 2;
        }
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
