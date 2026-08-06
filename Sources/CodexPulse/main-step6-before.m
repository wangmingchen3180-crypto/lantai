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

static NSImage *CPStatusDotImage(CGFloat size, NSColor *color) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [image lockFocus];
    [color setFill];
    NSBezierPath *path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, size, size)];
    [path fill];
    [image unlockFocus];
    image.template = NO;
    return image;
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

#pragma mark - Dock Capsule

@interface CPWorkbenchCardController : NSObject
@property NSPanel *window;
@property NSView *leftColumn;
@property NSView *middleColumn;
@property NSView *rightColumn;
@property NSStackView *taskStack;
@property NSStackView *rightStack;
@property NSArray<CPTask *> *tasks;
@property CPTask *selectedTask;
@property NSLayoutConstraint *leftWidthConstraint;
@property NSLayoutConstraint *rightWidthConstraint;
@property BOOL leftCollapsed;
@property BOOL rightCollapsed;
- (void)show;
- (void)close;
- (BOOL)isVisible;
- (void)renderTasks:(NSArray<CPTask *> *)tasks;
- (void)taskRowClicked:(NSButton *)sender;
- (void)toggleLeftColumn:(id)sender;
- (void)toggleRightColumn:(id)sender;
@end

@implementation CPWorkbenchCardController

static const CGFloat CPCardWidth = 720.0;
static const CGFloat CPCardHeight = 520.0;
static const CGFloat CPCardRightMargin = 70.0;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, CPCardWidth, CPCardHeight)
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.level = NSFloatingWindowLevel;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = YES;
    self.window.hidesOnDeactivate = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary;

    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPCardWidth, CPCardHeight)];
    card.wantsLayer = YES;
    card.layer.backgroundColor = NSColor.whiteColor.CGColor;
    card.layer.cornerRadius = 18.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = [NSColor colorWithSRGBRed:0.886 green:0.886 blue:0.878 alpha:1.0].CGColor; // #e2e2de
    card.shadow = [[NSShadow alloc] init];
    card.shadow.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.12];
    card.shadow.shadowOffset = NSMakeSize(0, -8);
    card.shadow.shadowBlurRadius = 30.0;
    self.window.contentView = card;

    NSStackView *columns = [NSStackView stackViewWithViews:@[]];
    columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columns.spacing = 0;
    columns.distribution = NSStackViewDistributionFill;
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:columns];
    [NSLayoutConstraint activateConstraints:@[
        [columns.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [columns.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [columns.topAnchor constraintEqualToAnchor:card.topAnchor],
        [columns.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
    ]];

    self.leftColumn = [self columnWithColor:[NSColor colorWithSRGBRed:0.961 green:0.961 blue:0.957 alpha:1.0] width:150];
    self.middleColumn = [self columnWithColor:NSColor.whiteColor width:0];
    self.rightColumn = [self columnWithColor:[NSColor colorWithSRGBRed:0.980 green:0.980 blue:0.976 alpha:1.0] width:240];

    [columns addArrangedSubview:self.leftColumn];
    [columns addArrangedSubview:self.middleColumn];
    [columns addArrangedSubview:self.rightColumn];

    self.leftWidthConstraint = [self.leftColumn.widthAnchor constraintEqualToConstant:150];
    self.rightWidthConstraint = [self.rightColumn.widthAnchor constraintEqualToConstant:240];
    self.leftWidthConstraint.active = YES;
    self.rightWidthConstraint.active = YES;

    [self buildAgentListIn:self.leftColumn];
    [self buildTaskListIn:self.middleColumn];
    [self buildDetailIn:self.rightColumn];

    return self;
}

- (NSView *)columnWithColor:(NSColor *)color width:(CGFloat)width {
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, CPCardHeight)];
    view.wantsLayer = YES;
    view.layer.backgroundColor = color.CGColor;
    return view;
}

- (NSStackView *)stackContainerIn:(NSView *)column spacing:(CGFloat)spacing {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = spacing;
    stack.edgeInsets = NSEdgeInsetsMake(16, 12, 16, 12);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:column.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:column.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:column.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:column.bottomAnchor],
    ]];
    return stack;
}

- (NSView *)agentRowWithName:(NSString *)name icon:(NSString *)iconName color:(NSColor *)color badge:(NSString *)badge selected:(BOOL)selected {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 126, 36)];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 8.0;
    if (selected) {
        row.layer.backgroundColor = NSColor.whiteColor.CGColor;
        row.layer.borderWidth = 1.0;
        row.layer.borderColor = [NSColor colorWithSRGBRed:0.886 green:0.886 blue:0.878 alpha:1.0].CGColor;
    }
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:36].active = YES;

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
    NSImage *img = [NSImage imageWithSystemSymbolName:iconName accessibilityDescription:name];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    iconView.image = img;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant:20].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:20].active = YES;

    NSTextField *label = [NSTextField labelWithString:name];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor colorWithSRGBRed:0.200 green:0.200 blue:0.220 alpha:1.0];

    NSTextField *badgeLabel = nil;
    if (badge.length) {
        badgeLabel = [NSTextField labelWithString:badge];
        badgeLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        badgeLabel.textColor = NSColor.whiteColor;
        badgeLabel.alignment = NSTextAlignmentCenter;
        badgeLabel.wantsLayer = YES;
        badgeLabel.layer.backgroundColor = [NSColor colorWithSRGBRed:0.918 green:0.345 blue:0.047 alpha:1.0].CGColor;
        badgeLabel.layer.cornerRadius = 8.0;
        badgeLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [badgeLabel.widthAnchor constraintGreaterThanOrEqualToConstant:16].active = YES;
        [badgeLabel.heightAnchor constraintEqualToConstant:16].active = YES;
    }

    NSStackView *stack = [NSStackView stackViewWithViews:@[iconView, label]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    if (badgeLabel) stack = [NSStackView stackViewWithViews:@[iconView, label, badgeLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:8],
        [stack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-8],
        [stack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    return row;
}

- (void)buildAgentListIn:(NSView *)column {
    NSStackView *stack = [self stackContainerIn:column spacing:4];

    NSTextField *header = [NSTextField labelWithString:@"AGENTS"];
    header.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    header.textColor = [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0];
    [header setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];

    NSView *codexRow = [self agentRowWithName:@"Codex" icon:@"terminal.fill" color:[NSColor colorWithSRGBRed:0.118 green:0.353 blue:0.961 alpha:1.0] badge:@"2" selected:YES];
    NSView *kimiRow = [self agentRowWithName:@"Kimi" icon:@"moon" color:[NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0] badge:nil selected:NO];

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 126, 1)];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.heightAnchor constraintEqualToConstant:1].active = YES;

    NSView *addRow = [self agentRowWithName:@"添加 Agent" icon:@"plus" color:[NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0] badge:nil selected:NO];

    [stack addArrangedSubview:header];
    [stack addArrangedSubview:codexRow];
    [stack addArrangedSubview:kimiRow];
    [stack addArrangedSubview:sep];
    [stack addArrangedSubview:addRow];
}

- (void)buildTaskListIn:(NSView *)column {
    NSStackView *stack = [self stackContainerIn:column spacing:8];
    self.taskStack = stack;

    NSStackView *headerRow = [NSStackView stackViewWithViews:@[]];
    headerRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headerRow.alignment = NSLayoutAttributeCenterY;
    headerRow.distribution = NSStackViewDistributionEqualSpacing;
    headerRow.spacing = 8;

    NSTextField *header = [NSTextField labelWithString:@"活动流"];
    header.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    header.textColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:1.0];

    NSButton *leftToggle = [self iconButton:@"sidebar.leading" action:@selector(toggleLeftColumn:)];
    NSButton *rightToggle = [self iconButton:@"sidebar.trailing" action:@selector(toggleRightColumn:)];

    NSStackView *buttons = [NSStackView stackViewWithViews:@[leftToggle, rightToggle]];
    buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttons.spacing = 4;

    [headerRow addArrangedSubview:header];
    [headerRow addArrangedSubview:buttons];
    [stack addArrangedSubview:headerRow];

    [self renderTasks:@[]];
}

- (NSButton *)iconButton:(NSString *)iconName action:(SEL)action {
    NSButton *button = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:iconName accessibilityDescription:@""]
                                          target:self
                                          action:action];
    button.bordered = NO;
    button.imageScaling = NSImageScaleProportionallyDown;
    button.contentTintColor = [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0];
    [button.widthAnchor constraintEqualToConstant:24].active = YES;
    [button.heightAnchor constraintEqualToConstant:24].active = YES;
    return button;
}

- (void)toggleLeftColumn:(id)sender {
    self.leftCollapsed = !self.leftCollapsed;
    self.leftWidthConstraint.constant = self.leftCollapsed ? 0 : 150;
    self.leftColumn.hidden = self.leftCollapsed;
}

- (void)toggleRightColumn:(id)sender {
    self.rightCollapsed = !self.rightCollapsed;
    self.rightWidthConstraint.constant = self.rightCollapsed ? 0 : 240;
    self.rightColumn.hidden = self.rightCollapsed;
}

- (NSButton *)taskRowWithTask:(CPTask *)task index:(NSInteger)index {
    NSButton *row = [NSButton buttonWithTitle:@"" target:self action:@selector(taskRowClicked:)];
    row.bordered = NO;
    [row setButtonType:NSButtonTypeMomentaryChange];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 10.0;
    row.layer.backgroundColor = NSColor.whiteColor.CGColor;
    row.tag = index;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:56].active = YES;

    NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
    dot.image = CPStatusDotImage(8, CPStatusColor(task.status));
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    [dot.widthAnchor constraintEqualToConstant:8].active = YES;
    [dot.heightAnchor constraintEqualToConstant:8].active = YES;

    NSTextField *title = [NSTextField labelWithString:task.title];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    title.textColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:1.0];
    title.lineBreakMode = NSLineBreakByTruncatingTail;

    NSTextField *meta = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ · %@", task.projectName, CPStatusTitle(task.status)]];
    meta.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    meta.textColor = [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0];

    NSStackView *textStack = [NSStackView stackViewWithViews:@[title, meta]];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 2;

    NSStackView *rowStack = [NSStackView stackViewWithViews:@[dot, textStack]];
    rowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    rowStack.alignment = NSLayoutAttributeCenterY;
    rowStack.spacing = 10;
    rowStack.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:rowStack];
    [NSLayoutConstraint activateConstraints:@[
        [rowStack.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [rowStack.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [rowStack.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];

    return row;
}

- (void)renderTasks:(NSArray<CPTask *> *)tasks {
    self.tasks = tasks;
    if (!self.taskStack) return;
    while (self.taskStack.arrangedSubviews.count > 1) {
        NSView *view = self.taskStack.arrangedSubviews.lastObject;
        [self.taskStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    if (tasks.count == 0) {
        NSTextField *empty = [NSTextField labelWithString:@"暂无活动任务"];
        empty.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        empty.textColor = [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0];
        [self.taskStack addArrangedSubview:empty];
        self.selectedTask = nil;
        [self renderDetail];
        return;
    }
    NSInteger index = 0;
    for (CPTask *task in tasks) {
        [self.taskStack addArrangedSubview:[self taskRowWithTask:task index:index++]];
    }
    self.selectedTask = tasks.firstObject;
    [self renderDetail];
}

- (void)taskRowClicked:(NSButton *)sender {
    NSInteger index = sender.tag;
    if (index >= 0 && index < (NSInteger)self.tasks.count) {
        self.selectedTask = self.tasks[(NSUInteger)index];
        [self renderDetail];
    }
}

- (void)buildDetailIn:(NSView *)column {
    NSStackView *stack = [self stackContainerIn:column spacing:10];
    self.rightStack = stack;
    [self renderDetail];
}

- (void)renderDetail {
    if (!self.rightStack) return;
    for (NSView *view in self.rightStack.arrangedSubviews.copy) {
        [self.rightStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    NSTextField *header = [NSTextField labelWithString:@"任务详情"];
    header.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    header.textColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:1.0];
    [header setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationVertical];
    [self.rightStack addArrangedSubview:header];

    CPTask *task = self.selectedTask;
    if (!task) {
        NSTextField *empty = [NSTextField labelWithString:@"选择一个任务查看详情"];
        empty.font = [NSFont systemFontOfSize:13 weight:NSFontWeightRegular];
        empty.textColor = [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0];
        [self.rightStack addArrangedSubview:empty];
        return;
    }

    NSTextField *title = [NSTextField labelWithString:task.title];
    title.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    title.textColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:1.0];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.maximumNumberOfLines = 3;
    [self.rightStack addArrangedSubview:title];

    NSStackView *statusRow = [NSStackView stackViewWithViews:@[
        [self smallLabel:CPStatusTitle(task.status) color:CPStatusColor(task.status)],
    ]];
    statusRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    statusRow.spacing = 6;
    [self.rightStack addArrangedSubview:statusRow];

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 216, 1)];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.heightAnchor constraintEqualToConstant:1].active = YES;
    [self.rightStack addArrangedSubview:sep];

    [self.rightStack addArrangedSubview:[self detailPairWithLabel:@"项目" value:task.projectName]];
    [self.rightStack addArrangedSubview:[self detailPairWithLabel:@"Tokens" value:[NSString stringWithFormat:@"%ld", (long)task.tokensUsed]]];
    [self.rightStack addArrangedSubview:[self detailPairWithLabel:@"活动" value:task.activity]];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    [self.rightStack addArrangedSubview:[self detailPairWithLabel:@"更新于" value:[fmt stringFromDate:task.updatedAt]]];
}

- (NSTextField *)smallLabel:(NSString *)text color:(NSColor *)color {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    label.textColor = color;
    return label;
}

- (NSView *)detailPairWithLabel:(NSString *)labelText value:(NSString *)valueText {
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 2;

    NSTextField *label = [NSTextField labelWithString:labelText];
    label.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    label.textColor = [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0];

    NSTextField *value = [NSTextField labelWithString:valueText.length ? valueText : @"—"];
    value.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    value.textColor = [NSColor colorWithSRGBRed:0.200 green:0.200 blue:0.220 alpha:1.0];
    value.lineBreakMode = NSLineBreakByTruncatingTail;
    value.maximumNumberOfLines = 2;

    [stack addArrangedSubview:label];
    [stack addArrangedSubview:value];
    return stack;
}

- (void)addPlaceholderTo:(NSView *)column title:(NSString *)title {
    NSTextField *label = [NSTextField labelWithString:title];
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    label.textColor = [NSColor colorWithSRGBRed:0.290 green:0.290 blue:0.310 alpha:1.0];
    label.alignment = NSTextAlignmentCenter;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [column addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerXAnchor constraintEqualToAnchor:column.centerXAnchor],
        [label.centerYAnchor constraintEqualToAnchor:column.centerYAnchor],
    ]];
}

- (NSRect)targetFrame {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMaxX(visible) - CPCardWidth - CPCardRightMargin;
    CGFloat y = NSMidY(visible) - CPCardHeight / 2.0;
    return NSMakeRect(x, y, CPCardWidth, CPCardHeight);
}

- (void)show {
    [self.window setFrame:[self targetFrame] display:YES];
    [self.window orderFrontRegardless];
}

- (void)close {
    [self.window orderOut:nil];
}

- (BOOL)isVisible {
    return self.window.isVisible;
}

@end

@interface CPDockWindowController : NSObject
@property NSPanel *window;
@property NSButton *pillButton;
@property CPWorkbenchCardController *cardController;
- (void)show;
- (void)toggleCard:(id)sender;
- (void)renderTasks:(NSArray<CPTask *> *)tasks;
@end

@implementation CPDockWindowController

static const CGFloat CPDockSize = 52.0;
static const CGFloat CPDockMargin = 12.0;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;

    self.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, CPDockSize, CPDockSize)
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.level = NSFloatingWindowLevel;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = YES;
    self.window.hidesOnDeactivate = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary;

    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPDockSize, CPDockSize)];
    content.wantsLayer = YES;
    content.layer.backgroundColor = [NSColor colorWithSRGBRed:0.118 green:0.353 blue:0.961 alpha:1.0].CGColor; // #1e5af5
    content.layer.cornerRadius = CPDockSize / 2.0;
    content.layer.borderWidth = 0.5;
    content.layer.borderColor = [NSColor colorWithWhite:1.0 alpha:0.25].CGColor;
    self.window.contentView = content;

    self.pillButton = [[NSButton alloc] initWithFrame:content.bounds];
    self.pillButton.bordered = NO;
    self.pillButton.imagePosition = NSImageOnly;
    self.pillButton.target = self;
    self.pillButton.action = @selector(toggleCard:);
    self.pillButton.toolTip = @"打开 Codex Pulse";
    [content addSubview:self.pillButton];

    NSImage *icon = [NSImage imageWithSystemSymbolName:@"wave.3.forward" accessibilityDescription:@"Pulse"];
    icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:22 weight:NSFontWeightMedium]];
    icon = [icon imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.whiteColor]];
    self.pillButton.image = icon;

    self.cardController = CPWorkbenchCardController.new;

    [NSNotificationCenter.defaultCenter addObserver:self
                                            selector:@selector(screenChanged:)
                                                name:NSApplicationDidChangeScreenParametersNotification
                                              object:nil];
    return self;
}

- (NSScreen *)targetScreen {
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

- (NSRect)targetFrame {
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMaxX(visible) - CPDockSize - CPDockMargin;
    CGFloat y = NSMidY(visible) - CPDockSize / 2.0;
    return NSMakeRect(x, y, CPDockSize, CPDockSize);
}

- (void)show {
    [self.window setFrame:[self targetFrame] display:YES];
    [self.window orderFrontRegardless];
}

- (void)screenChanged:(NSNotification *)note {
    [self.window setFrame:[self targetFrame] display:YES animate:YES];
}

- (void)toggleCard:(id)sender {
    if (self.cardController.isVisible) [self.cardController close];
    else [self.cardController show];
}

- (void)renderTasks:(NSArray<CPTask *> *)tasks {
    [self.cardController renderTasks:tasks];
}

@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSPopover *popover;
@property CPViewController *viewController;
@property CPStateReader *reader;
@property NSTimer *timer;
@property CPDockWindowController *dockController;
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
    self.dockController = CPDockWindowController.new;
    [self.dockController show];
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
    [self.dockController renderTasks:tasks];
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
