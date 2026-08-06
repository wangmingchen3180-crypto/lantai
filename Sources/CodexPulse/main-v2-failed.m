#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <sqlite3.h>

#pragma mark - Types

typedef NS_ENUM(NSInteger, CPAgentID) {
    CPAgentIDCodex,
    CPAgentIDKimi,
    CPAgentIDCustom,
};

typedef NS_ENUM(NSInteger, CPStatus) {
    CPStatusWorking,
    CPStatusWaiting,
    CPStatusAttention,
    CPStatusCompleted,
    CPStatusFailed,
    CPStatusIdle,
};

#pragma mark - Models

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

@interface CPAgent : NSObject
@property CPAgentID agentID;
@property NSString *name;
@property NSString *identifier;
@property NSString *iconName;
@property NSColor *accentColor;
@property BOOL isPlaceholder;
@property NSMutableArray<CPTask *> *tasks;
+ (instancetype)agentWithID:(CPAgentID)agentID name:(NSString *)name identifier:(NSString *)identifier iconName:(NSString *)iconName accentColor:(NSColor *)accentColor placeholder:(BOOL)placeholder;
@end
@implementation CPAgent
+ (instancetype)agentWithID:(CPAgentID)agentID name:(NSString *)name identifier:(NSString *)identifier iconName:(NSString *)iconName accentColor:(NSColor *)accentColor placeholder:(BOOL)placeholder {
    CPAgent *a = [CPAgent new];
    a.agentID = agentID;
    a.name = name;
    a.identifier = identifier;
    a.iconName = iconName;
    a.accentColor = accentColor;
    a.isPlaceholder = placeholder;
    a.tasks = [NSMutableArray array];
    return a;
}
@end

#pragma mark - Strings

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

static NSImage *CPStatusSymbolImage(CPStatus status, CGFloat size) {
    return CPStatusDotImage(size, CPStatusColor(status));
}

static NSColor *CPStatusColor(CPStatus status) {
    switch (status) {
        case CPStatusWorking: return [NSColor colorWithSRGBRed:0.145 green:0.388 blue:0.922 alpha:1.0]; // #2563eb
        case CPStatusWaiting: return [NSColor colorWithSRGBRed:0.851 green:0.467 blue:0.024 alpha:1.0]; // #d97706
        case CPStatusAttention: return [NSColor colorWithSRGBRed:0.918 green:0.345 blue:0.047 alpha:1.0]; // #ea580c
        case CPStatusCompleted: return [NSColor colorWithSRGBRed:0.086 green:0.639 blue:0.290 alpha:1.0]; // #16a34a
        case CPStatusFailed: return [NSColor colorWithSRGBRed:0.863 green:0.149 blue:0.149 alpha:1.0]; // #dc2626
        case CPStatusIdle: return [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0]; // #6e6e73
    }
}

#pragma mark - Colors (HTML tokens)

static NSColor *CPColorBackground(void) { return [NSColor colorWithSRGBRed:0.961 green:0.961 blue:0.949 alpha:1.0]; } // #f5f5f2
static NSColor *CPColorSurface(void) { return NSColor.whiteColor; }
static NSColor *CPColorSurface2(void) { return [NSColor colorWithSRGBRed:0.941 green:0.941 blue:0.925 alpha:1.0]; } // #f0f0ec
static NSColor *CPColorForeground(void) { return [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:1.0]; } // #141416
static NSColor *CPColorForeground2(void) { return [NSColor colorWithSRGBRed:0.290 green:0.290 blue:0.310 alpha:1.0]; } // #4a4a4f
static NSColor *CPColorMuted(void) { return [NSColor colorWithSRGBRed:0.431 green:0.431 blue:0.451 alpha:1.0]; } // #6e6e73
static NSColor *CPColorBorder(void) { return [NSColor colorWithSRGBRed:0.886 green:0.886 blue:0.871 alpha:1.0]; } // #e2e2de
static NSColor *CPColorBorderSoft(void) { return [NSColor colorWithSRGBRed:0.929 green:0.929 blue:0.918 alpha:1.0]; } // #ededea
static NSColor *CPColorAccent(void) { return [NSColor colorWithSRGBRed:0.118 green:0.353 blue:0.961 alpha:1.0]; } // #1e5af5
static NSColor *CPColorAccentHover(void) { return [NSColor colorWithSRGBRed:0.094 green:0.278 blue:0.765 alpha:1.0]; }
static NSColor *CPColorAccentActive(void) { return [NSColor colorWithSRGBRed:0.078 green:0.231 blue:0.627 alpha:1.0]; }

#pragma mark - Helpers

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

static NSFont *CPFontDisplay(CGFloat size, NSFontWeight weight) {
    NSFont *font = [NSFont fontWithName:@"Georgia" size:size];
    if (!font) font = [NSFont fontWithName:@"Times New Roman" size:size];
    if (!font) return [NSFont systemFontOfSize:size weight:weight];
    return [[NSFontManager sharedFontManager] convertFont:font toHaveTrait:(weight >= NSFontWeightSemibold ? NSBoldFontMask : 0)];
}

static NSFont *CPFontBody(CGFloat size, NSFontWeight weight) {
    return [NSFont systemFontOfSize:size weight:weight];
}

static void CPButtonSetObject(NSButton *button, id object) {
    objc_setAssociatedObject(button, "cp_object", object, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id CPButtonGetObject(NSButton *button) {
    return objc_getAssociatedObject(button, "cp_object");
}

static NSImage *CPSymbol(NSString *name, CGFloat size, NSColor *color) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
    if (!img) return nil;
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium];
    if (color) config = [config configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    return [img imageWithSymbolConfiguration:config];
}

static NSImage *CPAgentIcon(CPAgentID agentID, CGFloat size, NSColor *color) {
    NSImage *img = nil;
    switch (agentID) {
        case CPAgentIDCodex: img = [NSImage imageWithSystemSymbolName:@"list.bullet.clipboard" accessibilityDescription:@"Codex"]; break;
        case CPAgentIDKimi: img = [NSImage imageWithSystemSymbolName:@"moon.stars" accessibilityDescription:@"Kimi"]; break;
        case CPAgentIDCustom: img = [NSImage imageWithSystemSymbolName:@"square.grid.2x2" accessibilityDescription:@"Custom"]; break;
    }
    if (!img) return nil;
    NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium];
    if (color) config = [config configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    return [img imageWithSymbolConfiguration:config];
}

static NSString *CPFormatDuration(NSTimeInterval seconds) {
    if (seconds < 60) return @"刚刚";
    if (seconds < 3600) return [NSString stringWithFormat:@"%ld 分钟", (long)(seconds / 60)];
    return [NSString stringWithFormat:@"%ld 小时 %ld 分", (long)(seconds / 3600), (long)((NSInteger)seconds % 3600 / 60)];
}

#pragma mark - Builders

static NSTextField *CPLabel(NSString *string, NSFont *font, NSColor *color) {
    NSTextField *label = [NSTextField labelWithString:string ?: @""];
    label.font = font;
    label.textColor = color;
    label.maximumNumberOfLines = 1;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    return label;
}

static NSTextField *CPLabelMultiline(NSString *string, NSFont *font, NSColor *color, CGFloat maxWidth) {
    NSTextField *label = [NSTextField labelWithString:string ?: @""];
    label.font = font;
    label.textColor = color;
    label.maximumNumberOfLines = 0;
    label.preferredMaxLayoutWidth = maxWidth;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

static NSView *CPSeparator(BOOL vertical) {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.boxType = NSBoxSeparator;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    if (vertical) {
        [box.widthAnchor constraintEqualToConstant:1].active = YES;
    } else {
        [box.heightAnchor constraintEqualToConstant:1].active = YES;
    }
    return box;
}

static NSButton *CPGhostButton(NSString *title, id target, SEL action) {
    NSButton *btn = [NSButton buttonWithTitle:title target:target action:action];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.font = CPFontBody(12, NSFontWeightMedium);
    return btn;
}

static NSButton *CPPrimaryButton(NSString *title, id target, SEL action) {
    NSButton *btn = [NSButton buttonWithTitle:title target:target action:action];
    btn.bezelStyle = NSBezelStyleRounded;
    btn.font = CPFontBody(12, NSFontWeightSemibold);
    return btn;
}

static NSButton *CPIconButton(NSString *symbol, id target, SEL action) {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
    btn.bezelStyle = NSBezelStyleRegularSquare;
    btn.image = CPSymbol(symbol, 14, CPColorForeground2());
    btn.imagePosition = NSImageOnly;
    btn.target = target;
    btn.action = action;
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn.widthAnchor constraintEqualToConstant:28].active = YES;
    [btn.heightAnchor constraintEqualToConstant:28].active = YES;
    return btn;
}

#pragma mark - Codex Reader

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

#pragma mark - Agent Manager

@interface CPAgentManager : NSObject
@property NSMutableArray<CPAgent *> *agents;
@property CPAgent *selectedAgent;
- (void)reload;
- (CPStatus)overallStatus;
- (NSInteger)attentionCount;
@end

@implementation CPAgentManager
- (instancetype)init {
    self = [super init];
    if (self) {
        self.agents = [NSMutableArray array];
        [self.agents addObject:[CPAgent agentWithID:CPAgentIDCodex name:@"Codex" identifier:@"com.openai.codex" iconName:@"list.bullet.clipboard" accentColor:CPColorAccent() placeholder:NO]];
        [self.agents addObject:[CPAgent agentWithID:CPAgentIDKimi name:@"Kimi" identifier:@"com.moonshot.kimi" iconName:@"moon.stars" accentColor:CPColorAccent() placeholder:YES]];
        [self.agents addObject:[CPAgent agentWithID:CPAgentIDCustom name:@"添加 Agent" identifier:@"custom" iconName:@"plus" accentColor:CPColorMuted() placeholder:YES]];
        self.selectedAgent = self.agents.firstObject;
    }
    return self;
}

- (void)reload {
    CPAgent *codex = self.agents[0];
    [codex.tasks removeAllObjects];
    [codex.tasks addObjectsFromArray:[CPStateReader.new readTasks]];

    CPAgent *kimi = self.agents[1];
    if (kimi.isPlaceholder) {
        [kimi.tasks removeAllObjects];
        CPTask *t1 = CPTask.new;
        t1.taskID = @"kimi-sample-1";
        t1.title = @"总结今日未读推文";
        t1.projectName = @"Kimi";
        t1.status = CPStatusWaiting;
        t1.activity = @"等待网络请求";
        t1.updatedAt = [NSDate dateWithTimeIntervalSinceNow:-120];
        [kimi.tasks addObject:t1];

        CPTask *t2 = CPTask.new;
        t2.taskID = @"kimi-sample-2";
        t2.title = @"翻译技术文档";
        t2.projectName = @"Kimi";
        t2.status = CPStatusCompleted;
        t2.activity = @"翻译完成";
        t2.updatedAt = [NSDate dateWithTimeIntervalSinceNow:-600];
        [kimi.tasks addObject:t2];
    }
}

- (CPStatus)overallStatus {
    for (CPAgent *agent in self.agents) {
        if (agent.isPlaceholder) continue;
        for (CPTask *task in agent.tasks) {
            if (task.status == CPStatusFailed) return CPStatusFailed;
            if (task.status == CPStatusAttention) return CPStatusAttention;
            if (task.status == CPStatusWorking) return CPStatusWorking;
        }
    }
    return CPStatusIdle;
}

- (NSInteger)attentionCount {
    NSInteger count = 0;
    for (CPAgent *agent in self.agents) {
        if (agent.isPlaceholder) continue;
        for (CPTask *task in agent.tasks) {
            if (task.status == CPStatusAttention || task.status == CPStatusFailed) count++;
        }
    }
    return count;
}
@end

#pragma mark - Workbench View Controller

@protocol CPWorkbenchDelegate <NSObject>
- (void)workbenchDidTogglePin;
- (void)workbenchDidClose;
@end

@interface CPWorkbenchViewController : NSViewController
@property CPAgentManager *agentManager;
@property CPTask *selectedTask;
@property NSView *leftRail;
@property NSView *centerColumn;
@property NSView *rightRail;
@property NSView *leftTrigger;
@property NSView *rightTrigger;
@property NSButton *pinButton;
@property NSButton *closeButton;
@property NSStackView *agentListStack;
@property NSTextField *centerTitle;
@property NSStackView *taskListStack;
@property NSView *detailContainer;
@property NSLayoutConstraint *leftRailWidthConstraint;
@property NSLayoutConstraint *centerColumnWidthConstraint;
@property NSLayoutConstraint *rightRailWidthConstraint;
@property id<CPWorkbenchDelegate> delegate;
- (void)render;
@end

@implementation CPWorkbenchViewController

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 720, 600)];
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    root.state = NSVisualEffectStateActive;
    root.wantsLayer = YES;
    root.layer.cornerRadius = 18;
    root.layer.masksToBounds = YES;
    self.view = root;

    // Border
    root.layer.borderWidth = 1;
    root.layer.borderColor = CPColorBorder().CGColor;

    // Header
    NSView *header = [self buildHeader];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:header];
    [header.leadingAnchor constraintEqualToAnchor:root.leadingAnchor].active = YES;
    [header.trailingAnchor constraintEqualToAnchor:root.trailingAnchor].active = YES;
    [header.topAnchor constraintEqualToAnchor:root.topAnchor].active = YES;
    [header.heightAnchor constraintEqualToConstant:48].active = YES;

    // Body
    NSView *body = [self buildBody];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:body];
    [body.leadingAnchor constraintEqualToAnchor:root.leadingAnchor].active = YES;
    [body.trailingAnchor constraintEqualToAnchor:root.trailingAnchor].active = YES;
    [body.topAnchor constraintEqualToAnchor:header.bottomAnchor].active = YES;
    [body.bottomAnchor constraintEqualToAnchor:root.bottomAnchor].active = YES;

    [self render];
}

- (NSView *)buildHeader {
    NSView *header = [[NSView alloc] initWithFrame:NSZeroRect];

    NSImageView *logo = [[NSImageView alloc] initWithFrame:NSZeroRect];
    logo.image = CPSymbol(@"list.bullet.clipboard", 18, CPColorAccent());
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:20].active = YES;
    [logo.heightAnchor constraintEqualToConstant:20].active = YES;

    NSTextField *title = CPLabel(@"Pulse", CPFontDisplay(15, NSFontWeightSemibold), CPColorForeground());
    NSTextField *meta = CPLabel(@"多 Agent 工作台", CPFontBody(11, NSFontWeightRegular), CPColorMuted());

    NSStackView *textStack = [NSStackView stackViewWithViews:@[title, meta]];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 0;

    NSStackView *left = [NSStackView stackViewWithViews:@[logo, textStack]];
    left.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    left.alignment = NSLayoutAttributeCenterY;
    left.spacing = 8;
    left.translatesAutoresizingMaskIntoConstraints = NO;

    self.pinButton = CPIconButton(@"pin", self, @selector(togglePin:));
    self.closeButton = CPIconButton(@"xmark", self, @selector(close:));

    NSStackView *right = [NSStackView stackViewWithViews:@[self.pinButton, self.closeButton]];
    right.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    right.alignment = NSLayoutAttributeCenterY;
    right.spacing = 2;
    right.translatesAutoresizingMaskIntoConstraints = NO;

    [header addSubview:left];
    [header addSubview:right];
    [header addSubview:CPSeparator(NO)];

    [left.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16].active = YES;
    [left.centerYAnchor constraintEqualToAnchor:header.centerYAnchor].active = YES;
    [right.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12].active = YES;
    [right.centerYAnchor constraintEqualToAnchor:header.centerYAnchor].active = YES;

    NSView *sep = header.subviews.lastObject;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [sep.leadingAnchor constraintEqualToAnchor:header.leadingAnchor].active = YES;
    [sep.trailingAnchor constraintEqualToAnchor:header.trailingAnchor].active = YES;
    [sep.bottomAnchor constraintEqualToAnchor:header.bottomAnchor].active = YES;

    return header;
}

- (NSView *)buildBody {
    NSView *body = [[NSView alloc] initWithFrame:NSZeroRect];

    // Left trigger
    self.leftTrigger = [self edgeTrigger];
    [body addSubview:self.leftTrigger];
    self.leftTrigger.translatesAutoresizingMaskIntoConstraints = NO;
    [self.leftTrigger.leadingAnchor constraintEqualToAnchor:body.leadingAnchor].active = YES;
    [self.leftTrigger.topAnchor constraintEqualToAnchor:body.topAnchor].active = YES;
    [self.leftTrigger.bottomAnchor constraintEqualToAnchor:body.bottomAnchor].active = YES;
    [self.leftTrigger.widthAnchor constraintEqualToConstant:6].active = YES;

    // Left rail
    self.leftRail = [self buildLeftRail];
    [body addSubview:self.leftRail];
    self.leftRail.translatesAutoresizingMaskIntoConstraints = NO;
    [self.leftRail.leadingAnchor constraintEqualToAnchor:self.leftTrigger.trailingAnchor].active = YES;
    [self.leftRail.topAnchor constraintEqualToAnchor:body.topAnchor].active = YES;
    [self.leftRail.bottomAnchor constraintEqualToAnchor:body.bottomAnchor].active = YES;
    self.leftRailWidthConstraint = [self.leftRail.widthAnchor constraintEqualToConstant:150];
    self.leftRailWidthConstraint.active = YES;

    // Center column
    self.centerColumn = [self buildCenterColumn];
    [body addSubview:self.centerColumn];
    self.centerColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.centerColumn.leadingAnchor constraintEqualToAnchor:self.leftRail.trailingAnchor].active = YES;
    [self.centerColumn.topAnchor constraintEqualToAnchor:body.topAnchor].active = YES;
    [self.centerColumn.bottomAnchor constraintEqualToAnchor:body.bottomAnchor].active = YES;
    self.centerColumnWidthConstraint = [self.centerColumn.widthAnchor constraintEqualToConstant:320];
    self.centerColumnWidthConstraint.active = YES;

    // Right rail
    self.rightRail = [self buildRightRail];
    [body addSubview:self.rightRail];
    self.rightRail.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightRail.leadingAnchor constraintEqualToAnchor:self.centerColumn.trailingAnchor].active = YES;
    [self.rightRail.topAnchor constraintEqualToAnchor:body.topAnchor].active = YES;
    [self.rightRail.bottomAnchor constraintEqualToAnchor:body.bottomAnchor].active = YES;
    self.rightRailWidthConstraint = [self.rightRail.widthAnchor constraintEqualToConstant:240];
    self.rightRailWidthConstraint.active = YES;

    // Right trigger
    self.rightTrigger = [self edgeTrigger];
    [body addSubview:self.rightTrigger];
    self.rightTrigger.translatesAutoresizingMaskIntoConstraints = NO;
    [self.rightTrigger.leadingAnchor constraintEqualToAnchor:self.rightRail.trailingAnchor].active = YES;
    [self.rightTrigger.topAnchor constraintEqualToAnchor:body.topAnchor].active = YES;
    [self.rightTrigger.bottomAnchor constraintEqualToAnchor:body.bottomAnchor].active = YES;
    [self.rightTrigger.trailingAnchor constraintEqualToAnchor:body.trailingAnchor].active = YES;
    [self.rightTrigger.widthAnchor constraintEqualToConstant:6].active = YES;

    return body;
}

- (NSView *)edgeTrigger {
    NSView *trigger = [[NSView alloc] initWithFrame:NSZeroRect];
    trigger.wantsLayer = YES;

    NSBox *line = [[NSBox alloc] initWithFrame:NSZeroRect];
    line.boxType = NSBoxCustom;
    line.fillColor = CPColorAccent();
    line.borderWidth = 0;
    line.cornerRadius = 1;
    line.alphaValue = 0;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [trigger addSubview:line];
    [line.widthAnchor constraintEqualToConstant:2].active = YES;
    [line.heightAnchor constraintEqualToConstant:40].active = YES;
    [line.centerXAnchor constraintEqualToAnchor:trigger.centerXAnchor].active = YES;
    [line.centerYAnchor constraintEqualToAnchor:trigger.centerYAnchor].active = YES;

    [trigger addTrackingArea:[[NSTrackingArea alloc] initWithRect:trigger.bounds
                                                              options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                                owner:trigger
                                                             userInfo:nil]];

    // Store line reference for hover effects
    objc_setAssociatedObject(trigger, "line", line, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return trigger;
}

- (NSView *)buildLeftRail {
    NSView *rail = [[NSView alloc] initWithFrame:NSZeroRect];

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    NSTextField *headTitle = CPLabel(@"Agents", CPFontBody(11, NSFontWeightSemibold), CPColorMuted());
    headTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:headTitle];
    [headTitle.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:12].active = YES;
    [headTitle.centerYAnchor constraintEqualToAnchor:head.centerYAnchor].active = YES;
    [head.heightAnchor constraintEqualToConstant:40].active = YES;

    NSStackView *list = [NSStackView stackViewWithViews:@[]];
    list.orientation = NSUserInterfaceLayoutOrientationVertical;
    list.alignment = NSLayoutAttributeLeading;
    list.spacing = 4;
    list.translatesAutoresizingMaskIntoConstraints = NO;
    self.agentListStack = list;

    NSStackView *stack = [NSStackView stackViewWithViews:@[head, list]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:stack];
    [stack.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor].active = YES;
    [stack.topAnchor constraintEqualToAnchor:rail.topAnchor].active = YES;
    [stack.bottomAnchor constraintLessThanOrEqualToAnchor:rail.bottomAnchor].active = YES;

    // Separator
    NSView *sep = CPSeparator(YES);
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:sep];
    [sep.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor].active = YES;
    [sep.topAnchor constraintEqualToAnchor:rail.topAnchor].active = YES;
    [sep.bottomAnchor constraintEqualToAnchor:rail.bottomAnchor].active = YES;
    [sep.widthAnchor constraintEqualToConstant:1].active = YES;

    return rail;
}

- (NSView *)buildCenterColumn {
    NSView *col = [[NSView alloc] initWithFrame:NSZeroRect];

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    self.centerTitle = CPLabel(@"", CPFontDisplay(18, NSFontWeightSemibold), CPColorForeground());
    self.centerTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:self.centerTitle];
    [self.centerTitle.leadingAnchor constraintEqualToAnchor:head.leadingAnchor constant:14].active = YES;
    [self.centerTitle.centerYAnchor constraintEqualToAnchor:head.centerYAnchor].active = YES;
    [head.heightAnchor constraintEqualToConstant:48].active = YES;

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    self.taskListStack = [NSStackView stackViewWithViews:@[]];
    self.taskListStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.taskListStack.alignment = NSLayoutAttributeLeading;
    self.taskListStack.spacing = 0;
    self.taskListStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *clip = [[NSView alloc] initWithFrame:NSZeroRect];
    [clip addSubview:self.taskListStack];
    [self.taskListStack.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor].active = YES;
    [self.taskListStack.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor].active = YES;
    [self.taskListStack.topAnchor constraintEqualToAnchor:clip.topAnchor].active = YES;
    [self.taskListStack.bottomAnchor constraintLessThanOrEqualToAnchor:clip.bottomAnchor].active = YES;

    scroll.documentView = clip;
    [clip.widthAnchor constraintEqualToAnchor:scroll.widthAnchor].active = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[head, scroll]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [col addSubview:stack];
    [stack.leadingAnchor constraintEqualToAnchor:col.leadingAnchor].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:col.trailingAnchor].active = YES;
    [stack.topAnchor constraintEqualToAnchor:col.topAnchor].active = YES;
    [stack.bottomAnchor constraintEqualToAnchor:col.bottomAnchor].active = YES;

    return col;
}

- (NSView *)buildRightRail {
    NSView *rail = [[NSView alloc] initWithFrame:NSZeroRect];

    NSView *sep = CPSeparator(YES);
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:sep];
    [sep.leadingAnchor constraintEqualToAnchor:rail.leadingAnchor].active = YES;
    [sep.topAnchor constraintEqualToAnchor:rail.topAnchor].active = YES;
    [sep.bottomAnchor constraintEqualToAnchor:rail.bottomAnchor].active = YES;
    [sep.widthAnchor constraintEqualToConstant:1].active = YES;

    self.detailContainer = [[NSView alloc] initWithFrame:NSZeroRect];
    self.detailContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:self.detailContainer];
    [self.detailContainer.leadingAnchor constraintEqualToAnchor:sep.trailingAnchor].active = YES;
    [self.detailContainer.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor].active = YES;
    [self.detailContainer.topAnchor constraintEqualToAnchor:rail.topAnchor].active = YES;
    [self.detailContainer.bottomAnchor constraintEqualToAnchor:rail.bottomAnchor].active = YES;

    return rail;
}

- (void)render {
    [self renderAgentList];
    [self renderTaskList];
    [self renderDetail];
}

- (void)renderAgentList {
    for (NSView *view in self.agentListStack.arrangedSubviews.copy) {
        [self.agentListStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    for (CPAgent *agent in self.agentManager.agents) {
        NSButton *btn = [self agentButton:agent];
        [self.agentListStack addArrangedSubview:btn];
    }
}

- (NSButton *)agentButton:(CPAgent *)agent {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
    btn.bezelStyle = NSBezelStyleRegularSquare;
    btn.bordered = NO;
    btn.target = self;
    btn.action = @selector(selectAgent:);
    CPButtonSetObject(btn, agent);
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn.heightAnchor constraintEqualToConstant:36].active = YES;
    [btn.widthAnchor constraintEqualToConstant:138].active = YES;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.image = CPAgentIcon(agent.agentID, 16, agent.isPlaceholder ? CPColorMuted() : (agent == self.agentManager.selectedAgent ? CPColorAccent() : CPColorForeground2()));
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:18].active = YES;
    [icon.heightAnchor constraintEqualToConstant:18].active = YES;

    NSTextField *label = CPLabel(agent.name, CPFontBody(13, agent == self.agentManager.selectedAgent ? NSFontWeightSemibold : NSFontWeightRegular), agent == self.agentManager.selectedAgent ? CPColorForeground() : CPColorForeground2());
    label.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[icon, label]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [btn addSubview:stack];
    [stack.leadingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:10].active = YES;
    [stack.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor].active = YES;

    NSView *bg = [[NSView alloc] initWithFrame:btn.bounds];
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 8;
    bg.layer.backgroundColor = (agent == self.agentManager.selectedAgent) ? [NSColor colorWithSRGBRed:0.118 green:0.353 blue:0.961 alpha:0.08].CGColor : [NSColor clearColor].CGColor;
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [btn addSubview:bg positioned:NSWindowBelow relativeTo:stack];

    return btn;
}

- (void)renderTaskList {
    CPAgent *agent = self.agentManager.selectedAgent;
    self.centerTitle.stringValue = agent.name;

    for (NSView *view in self.taskListStack.arrangedSubviews.copy) {
        [self.taskListStack removeArrangedSubview:view];
        [view removeFromSuperview];
    }

    if (agent.isPlaceholder) {
        NSView *empty = [self placeholderView:@"该 Agent 尚未接入真实数据源" sub:@"可在此处显示示例任务或接入本地日志"];
        [self.taskListStack addArrangedSubview:empty];
        return;
    }

    if (agent.tasks.count == 0) {
        NSView *empty = [self placeholderView:@"暂无活动任务" sub:@"启动 Codex 后，任务会自动出现在这里"];
        [self.taskListStack addArrangedSubview:empty];
        return;
    }

    for (CPTask *task in agent.tasks) {
        NSView *row = [self taskRow:task];
        [self.taskListStack addArrangedSubview:row];
    }
}

- (NSView *)taskRow:(CPTask *)task {
    NSButton *btn = [[NSButton alloc] initWithFrame:NSZeroRect];
    btn.bezelStyle = NSBezelStyleRegularSquare;
    btn.bordered = NO;
    btn.target = self;
    btn.action = @selector(selectTask:);
    CPButtonSetObject(btn, task);
    btn.translatesAutoresizingMaskIntoConstraints = NO;
    [btn.heightAnchor constraintEqualToConstant:64].active = YES;

    BOOL selected = (self.selectedTask == task);

    NSImageView *statusIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    statusIcon.image = CPStatusSymbolImage(task.status, 7);
    statusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [statusIcon.widthAnchor constraintEqualToConstant:7].active = YES;
    [statusIcon.heightAnchor constraintEqualToConstant:7].active = YES;

    NSTextField *title = CPLabel(task.title, CPFontBody(13, NSFontWeightMedium), selected ? CPColorAccent() : CPColorForeground());
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *meta = CPLabel([NSString stringWithFormat:@"%@ · %@", task.projectName, CPFormatDuration(-task.updatedAt.timeIntervalSinceNow)], CPFontBody(11, NSFontWeightRegular), CPColorMuted());
    meta.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *text = [NSStackView stackViewWithViews:@[title, meta]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;
    text.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *stack = [NSStackView stackViewWithViews:@[statusIcon, text]];
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [btn addSubview:stack];
    [stack.leadingAnchor constraintEqualToAnchor:btn.leadingAnchor constant:14].active = YES;
    [stack.trailingAnchor constraintLessThanOrEqualToAnchor:btn.trailingAnchor constant:-14].active = YES;
    [stack.centerYAnchor constraintEqualToAnchor:btn.centerYAnchor].active = YES;

    NSView *bg = [[NSView alloc] initWithFrame:btn.bounds];
    bg.wantsLayer = YES;
    bg.layer.cornerRadius = 8;
    bg.layer.backgroundColor = selected ? [NSColor colorWithSRGBRed:0.118 green:0.353 blue:0.961 alpha:0.06].CGColor : [NSColor clearColor].CGColor;
    bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [btn addSubview:bg positioned:NSWindowBelow relativeTo:stack];

    return btn;
}

- (NSView *)placeholderView:(NSString *)title sub:(NSString *)sub {
    NSView *box = [[NSView alloc] initWithFrame:NSZeroRect];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    [box.heightAnchor constraintEqualToConstant:160].active = YES;

    NSTextField *t = CPLabel(title, CPFontBody(13, NSFontWeightMedium), CPColorForeground2());
    NSTextField *s = CPLabelMultiline(sub, CPFontBody(11, NSFontWeightRegular), CPColorMuted(), 260);
    s.alignment = NSTextAlignmentCenter;

    NSStackView *stack = [NSStackView stackViewWithViews:@[t, s]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 6;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:stack];
    [stack.centerXAnchor constraintEqualToAnchor:box.centerXAnchor].active = YES;
    [stack.centerYAnchor constraintEqualToAnchor:box.centerYAnchor].active = YES;

    return box;
}

- (void)renderDetail {
    for (NSView *view in self.detailContainer.subviews.copy) [view removeFromSuperview];

    if (!self.selectedTask) {
        NSView *empty = [self placeholderView:@"选择任务查看详情" sub:@"点击左侧任意任务，可在此处查看状态、活动与项目路径"];
        [self.detailContainer addSubview:empty];
        empty.translatesAutoresizingMaskIntoConstraints = NO;
        [empty.leadingAnchor constraintEqualToAnchor:self.detailContainer.leadingAnchor constant:14].active = YES;
        [empty.trailingAnchor constraintEqualToAnchor:self.detailContainer.trailingAnchor constant:-14].active = YES;
        [empty.centerYAnchor constraintEqualToAnchor:self.detailContainer.centerYAnchor].active = YES;
        return;
    }

    CPTask *task = self.selectedTask;

    NSTextField *status = CPLabel(CPStatusTitle(task.status), CPFontBody(11, NSFontWeightSemibold), CPStatusColor(task.status));
    status.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = CPLabelMultiline(task.title, CPFontDisplay(18, NSFontWeightSemibold), CPColorForeground(), 210);
    title.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *activity = CPLabel([NSString stringWithFormat:@"当前活动：%@", task.activity], CPFontBody(12, NSFontWeightRegular), CPColorForeground2());
    activity.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *meta = CPLabel([NSString stringWithFormat:@"项目：%@\n持续：%@\nTokens：%ld", task.projectName, CPFormatDuration(-task.createdAt.timeIntervalSinceNow), (long)task.tokensUsed], CPFontBody(11, NSFontWeightRegular), CPColorMuted());
    meta.maximumNumberOfLines = 0;
    meta.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *openBtn = CPPrimaryButton(@"打开 Codex", self, @selector(openSelected:));
    openBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [openBtn.widthAnchor constraintEqualToConstant:180].active = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[status, title, activity, CPSeparator(NO), meta, openBtn]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailContainer addSubview:stack];
    [stack.leadingAnchor constraintEqualToAnchor:self.detailContainer.leadingAnchor constant:14].active = YES;
    [stack.trailingAnchor constraintEqualToAnchor:self.detailContainer.trailingAnchor constant:-14].active = YES;
    [stack.topAnchor constraintEqualToAnchor:self.detailContainer.topAnchor constant:16].active = YES;
}

#pragma mark - Actions

- (void)selectAgent:(NSButton *)sender {
    CPAgent *agent = CPButtonGetObject(sender);
    if (agent.agentID == CPAgentIDCustom) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"添加 Agent";
        alert.informativeText = @"后续可在此接入 Kimi、Claude 等本地日志或 API。";
        [alert addButtonWithTitle:@"好"];
        [alert runModal];
        return;
    }
    self.agentManager.selectedAgent = agent;
    self.selectedTask = nil;
    [self render];
}

- (void)selectTask:(NSButton *)sender {
    self.selectedTask = CPButtonGetObject(sender);
    [self render];
}

- (void)openSelected:(id)sender {
    [self openCodex:sender];
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

- (void)togglePin:(id)sender {
    [self.delegate workbenchDidTogglePin];
}

- (void)close:(id)sender {
    [self.delegate workbenchDidClose];
}

@end
#pragma mark - Floating Orb Controller

@interface CPFloatingOrbController : NSObject
@property NSPanel *window;
@property NSButton *clickButton;
@property NSImageView *logoView;
@property NSTextField *countLabel;
@property BOOL pinned;
- (void)show;
- (void)setAttentionCount:(NSInteger)count;
- (void)setTarget:(id)target action:(SEL)action;
@end

@implementation CPFloatingOrbController

- (instancetype)init {
    self = [super init];
    if (self) {
        NSSize size = NSMakeSize(52, 52);
        self.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
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

        NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, size.width, size.height)];
        content.wantsLayer = YES;
        content.layer.cornerRadius = size.width / 2.0;
        content.layer.masksToBounds = YES;
        content.layer.backgroundColor = CPColorSurface().CGColor;
        content.layer.borderWidth = 1;
        content.layer.borderColor = CPColorBorder().CGColor;
        content.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.10].CGColor;
        content.layer.shadowOffset = CGSizeMake(0, 8);
        content.layer.shadowRadius = 14;
        content.layer.shadowOpacity = 1;
        self.window.contentView = content;

        self.logoView = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 14, 24, 24)];
        self.logoView.image = CPSymbol(@"list.bullet.clipboard", 18, CPColorAccent());
        [content addSubview:self.logoView];

        self.countLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(30, 30, 18, 18)];
        self.countLabel.font = CPFontBody(10, NSFontWeightSemibold);
        self.countLabel.textColor = CPColorSurface();
        self.countLabel.backgroundColor = CPColorAccent();
        self.countLabel.alignment = NSTextAlignmentCenter;
        self.countLabel.editable = NO;
        self.countLabel.bordered = NO;
        self.countLabel.wantsLayer = YES;
        self.countLabel.layer.cornerRadius = 9;
        self.countLabel.layer.masksToBounds = YES;
        self.countLabel.hidden = YES;
        [content addSubview:self.countLabel];

        self.clickButton = [[NSButton alloc] initWithFrame:content.bounds];
        self.clickButton.bezelStyle = NSBezelStyleRegularSquare;
        self.clickButton.bordered = NO;
        self.clickButton.title = @"";
        self.clickButton.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        [content addSubview:self.clickButton];
    }
    return self;
}

- (void)setTarget:(id)target action:(SEL)action {
    self.clickButton.target = target;
    self.clickButton.action = action;
}

- (void)show {
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMaxX(visible) - 52 - 12;
    CGFloat y = NSMidY(visible);
    [self.window setFrame:NSMakeRect(x, y, 52, 52) display:YES];
    [self.window orderFrontRegardless];
}

- (void)setAttentionCount:(NSInteger)count {
    if (count > 0) {
        self.countLabel.stringValue = [NSString stringWithFormat:@"%ld", (long)MIN(count, 99)];
        self.countLabel.hidden = NO;
    } else {
        self.countLabel.hidden = YES;
    }
}

@end

#pragma mark - Workbench Panel Controller

@interface CPWorkbenchPanelController : NSObject <CPWorkbenchDelegate>
@property NSPanel *panel;
@property CPWorkbenchViewController *workbench;
@property BOOL pinned;
@property CPFloatingOrbController *orbController;
- (void)showRelativeToOrb;
- (void)close;
- (void)render;
@end

@implementation CPWorkbenchPanelController

- (instancetype)initWithOrbController:(CPFloatingOrbController *)orbController {
    self = [super init];
    if (self) {
        self.orbController = orbController;
        self.workbench = [CPWorkbenchViewController new];
        self.workbench.agentManager = [CPAgentManager new];
        [self.workbench.agentManager reload];
        self.workbench.delegate = self;

        NSView *content = self.workbench.view;
        NSSize size = content.frame.size;

        self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, size.width, size.height)
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
        self.panel.contentView = content;
    }
    return self;
}

- (void)showRelativeToOrb {
    NSRect orbFrame = self.orbController.window.frame;
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect visible = screen.visibleFrame;

    CGFloat cardWidth = 720;
    CGFloat cardHeight = 600;
    CGFloat x = NSMinX(orbFrame) - cardWidth - 12;
    CGFloat y = NSMidY(visible) - cardHeight / 2.0;
    y = MAX(NSMinY(visible) + 12, MIN(y, NSMaxY(visible) - cardHeight - 12));

    [self.panel setFrame:NSMakeRect(x, y, cardWidth, cardHeight) display:YES];
    [self.panel orderFrontRegardless];
    [self.workbench render];
}

- (void)close {
    [self.panel orderOut:nil];
}

- (void)render {
    [self.workbench.agentManager reload];
    [self.workbench render];
}

- (void)workbenchDidTogglePin {
    self.pinned = !self.pinned;
    self.panel.hidesOnDeactivate = !self.pinned;
    self.orbController.pinned = self.pinned;
    NSButtonCell *cell = self.workbench.pinButton.cell;
    if (self.pinned) {
        self.workbench.pinButton.image = CPSymbol(@"pin.fill", 14, CPColorAccent());
    } else {
        self.workbench.pinButton.image = CPSymbol(@"pin", 14, CPColorForeground2());
    }
    (void)cell;
}

- (void)workbenchDidClose {
    [self close];
}

@end

#pragma mark - App Delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property CPAgentManager *agentManager;
@property CPFloatingOrbController *orbController;
@property CPWorkbenchPanelController *panelController;
@property NSTimer *timer;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.agentManager = [CPAgentManager new];
    [self.agentManager reload];

    self.orbController = [CPFloatingOrbController new];
    [self.orbController show];

    self.panelController = [[CPWorkbenchPanelController alloc] initWithOrbController:self.orbController];

    // Menu bar
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = CPSymbol(@"list.bullet.clipboard", 16, CPColorAccent());
    self.statusItem.button.toolTip = @"Codex Pulse";
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePanel:);

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Pulse"];
    [menu addItemWithTitle:@"打开工作台" action:@selector(openPanel:) keyEquivalent:@"b"].target = self;
    [menu addItemWithTitle:@"退出 Codex Pulse" action:@selector(terminate:) keyEquivalent:@"q"].target = NSApp;
    self.statusItem.button.menu = menu;

    // Orb click
    [self.orbController setTarget:self action:@selector(togglePanel:)];

    [self refresh:nil];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
}

- (void)togglePanel:(id)sender {
    if (self.panelController.panel.isVisible) {
        [self.panelController close];
    } else {
        [self.panelController showRelativeToOrb];
    }
}

- (void)openPanel:(id)sender {
    [self.panelController showRelativeToOrb];
}

- (void)refresh:(id)sender {
    [self.agentManager reload];
    [self.panelController render];

    CPStatus status = [self.agentManager overallStatus];
    self.statusItem.button.image = CPSymbol(CPStatusSymbol(status), 16, CPStatusColor(status));
    self.statusItem.button.toolTip = [NSString stringWithFormat:@"Pulse · %@", CPStatusTitle(status)];
    [self.orbController setAttentionCount:[self.agentManager attentionCount]];

    NSImageView *logo = self.orbController.logoView;
    logo.image = CPSymbol(@"list.bullet.clipboard", 18, CPStatusColor(status));
}

@end

#pragma mark - Main

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            CPAgentManager *manager = [CPAgentManager new];
            [manager reload];
            printf("Codex Pulse self-test: codex=%lu tasks, attention=%ld\n",
                   (unsigned long)manager.agents[0].tasks.count, (long)[manager attentionCount]);
            return manager.agents[0].tasks.count > 0 ? 0 : 2;
        }
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
