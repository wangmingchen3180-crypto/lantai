#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <sqlite3.h>

#pragma mark - Constants

// 高对比通道调整：亮通道更亮、暗通道更暗，提高对比度。
static CGFloat CPContrastAdjustChannel(CGFloat v) {
    return v >= 0.5 ? MIN(1.0, v + 0.12) : MAX(0.0, v * 0.72);
}

// 动态颜色：按 effectiveAppearance 区分浅色/深色，并在高对比模式下提高对比。
static NSColor *CPDyn(CGFloat lr, CGFloat lg, CGFloat lb, CGFloat dr, CGFloat dg, CGFloat db) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        BOOL dark = [match isEqualToString:NSAppearanceNameDarkAqua];
        CGFloat r = dark ? dr : lr, g = dark ? dg : lg, b = dark ? db : lb;
        if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast) {
            r = CPContrastAdjustChannel(r);
            g = CPContrastAdjustChannel(g);
            b = CPContrastAdjustChannel(b);
        }
        return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    }];
}

// 主基调为深石墨/深海军蓝：工作台、HUD、Dock 三处窗口始终深色，不随系统浅色外观变白。
// CPDyn 的 light 槽即深色主基调（CGColor 快照与浅色外观下也保持深色），dark 槽为 DarkAqua 下的微调。
static NSColor *CPAccent(void) { return CPDyn(0.320, 0.500, 1.000, 0.400, 0.560, 1.000); }
static NSColor *CPBg(void) { return CPDyn(0.093, 0.102, 0.133, 0.075, 0.082, 0.110); }
static NSColor *CPSurface(void) { return CPDyn(0.145, 0.155, 0.196, 0.125, 0.133, 0.172); }
static NSColor *CPBorder(void) { return CPDyn(0.300, 0.315, 0.375, 0.335, 0.350, 0.410); }
static NSColor *CPFg(void) { return CPDyn(0.930, 0.930, 0.945, 0.950, 0.950, 0.960); }
static NSColor *CPFg2(void) { return CPDyn(0.740, 0.745, 0.775, 0.780, 0.780, 0.810); }
static NSColor *CPMuted(void) { return CPDyn(0.580, 0.585, 0.620, 0.620, 0.625, 0.660); }
// 状态色：饱和度调高，在深石墨/深海军蓝底上清晰可见。
static NSColor *CPBlue(void) { return CPDyn(0.420, 0.590, 1.000, 0.480, 0.640, 1.000); }
static NSColor *CPOrange(void) { return CPDyn(1.000, 0.620, 0.240, 1.000, 0.660, 0.300); }
static NSColor *CPRed(void) { return CPDyn(1.000, 0.420, 0.430, 1.000, 0.470, 0.480); }
static NSColor *CPGreen(void) { return CPDyn(0.330, 0.860, 0.450, 0.380, 0.890, 0.500); }

#pragma mark - Status

typedef NS_ENUM(NSInteger, CPStatus) {
    CPStatusWorking, CPStatusWaiting, CPStatusAttention, CPStatusCompleted, CPStatusFailed, CPStatusIdle
};

static NSString *CPStatusTitle(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return @"工作中";
        case CPStatusWaiting: return @"等待中";
        case CPStatusAttention: return @"需关注";
        case CPStatusCompleted: return @"已完成";
        case CPStatusFailed: return @"失败";
        case CPStatusIdle: return @"空闲";
    }
}

static NSString *CPStatusSymbol(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return @"sparkles";
        case CPStatusWaiting: return @"pause.fill";
        case CPStatusAttention: return @"exclamationmark.bubble.fill";
        case CPStatusCompleted: return @"checkmark.circle.fill";
        case CPStatusFailed: return @"xmark.octagon.fill";
        case CPStatusIdle: return @"moon.zzz.fill";
    }
}

static NSColor *CPStatusColor(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return CPBlue();
        case CPStatusWaiting: return CPOrange();
        case CPStatusAttention: return CPDyn(1.000, 0.560, 0.220, 1.000, 0.600, 0.270);
        case CPStatusCompleted: return CPGreen();
        case CPStatusFailed: return CPRed();
        case CPStatusIdle: return CPMuted();
    }
}

static NSImage *CPDotImage(CGFloat size, NSColor *color) {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [img lockFocus];
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, size, size)] fill];
    [img unlockFocus];
    return img;
}

static NSImage *CPStatusDot(CGFloat size, CPStatus status) { return CPDotImage(size, CPStatusColor(status)); }

static NSDate *CPDateFromMillis(sqlite3_int64 v) { return v <= 0 ? NSDate.date : [NSDate dateWithTimeIntervalSince1970:v / 1000.0]; }
static NSDate *CPDateFromSeconds(sqlite3_int64 v) { return v <= 0 ? nil : [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)v]; }

static NSString *CPCleanTitle(const unsigned char *text) {
    if (!text) return @"未命名任务";
    NSString *value = [NSString stringWithUTF8String:(const char *)text] ?: @"未命名任务";

    // 1) 移除成对的 XML 块(如 <in-app-browser-context>…</in-app-browser-context>),含跨行内容。
    NSRegularExpression *blockRe = [NSRegularExpression regularExpressionWithPattern:@"<([A-Za-z][\\w-]*)[^>]*>.*?</\\1>"
                                                                           options:NSRegularExpressionDotMatchesLineSeparators
                                                                             error:nil];
    value = [blockRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@" "];
    // 2) 移除不成对的残留标签。
    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"</?[A-Za-z][^>]*>" options:0 error:nil];
    value = [tagRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@" "];
    // 3) 逐行挑选首个简洁非空行;去掉 "[11] user:" 之类前缀,跳过 TRANSCRIPT 包装与审查样板文本。
    NSRegularExpression *anywherePrefixRe = [NSRegularExpression regularExpressionWithPattern:@"\\[\\d+\\]\\s*(user|assistant|system)\\s*:\\s*"
                                                                                      options:NSRegularExpressionCaseInsensitive
                                                                                        error:nil];
    NSRegularExpression *headPrefixRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(user|assistant|system)\\s*:\\s*"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
    NSString *picked = nil;
    for (NSString *rawLine in [value componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [anywherePrefixRe stringByReplacingMatchesInString:rawLine options:0 range:NSMakeRange(0, rawLine.length) withTemplate:@" "];
        line = [headPrefixRe stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        // 去掉行首行尾的 ">" 与空白后判断 transcript 标记(大小写不敏感):
        // "TRANSCRIPT", ">>> TRANSCRIPT START", "transcript end >" 等都跳过。
        NSString *marker = [line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"> \t"]].lowercaseString;
        if ([marker isEqualToString:@"transcript"] ||
            [marker isEqualToString:@"transcript start"] ||
            [marker isEqualToString:@"transcript end"]) continue;
        NSString *lower = line.lowercaseString;
        if ([lower hasPrefix:@"the following is"]) continue; // "The following is the Codex agent history…" 样板
        picked = line;
        break;
    }
    value = picked.length ? picked : @"未命名任务";
    // 4) 清洗完成后再做最终截断。
    return value.length > 58 ? [[value substringToIndex:58] stringByAppendingString:@"…"] : value;
}

#pragma mark - Models

@interface CPTask : NSObject
@property NSString *taskID;
@property NSString *title;
@property NSString *projectPath;
@property NSString *projectName;
@property NSString *activity;
@property NSDate *createdAt;
@property NSDate *updatedAt;
@property NSInteger tokensUsed;
@property CPStatus status;
@end
@implementation CPTask @end

@interface CPAgent : NSObject
@property NSString *agentID;
@property NSString *name;
@property NSString *iconName;
@property NSColor *color;
@property BOOL placeholder;
@property CPStatus status;
@property NSMutableArray<CPTask *> *tasks;
@end
@implementation CPAgent @end

#pragma mark - Display Status & Review Store

typedef NS_ENUM(NSInteger, CPDisplayStatus) {
    CPDisplayStatusIdle,
    CPDisplayStatusWorking,
    CPDisplayStatusCompletedPendingReview,
    CPDisplayStatusWaiting,
    CPDisplayStatusFailed
};

@interface CPReviewStore : NSObject
@property NSUserDefaults *defaults;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSString *)signatureForTask:(CPTask *)task;
- (BOOL)isTaskReviewed:(CPTask *)task agentID:(NSString *)agentID;
- (void)markTaskReviewed:(CPTask *)task agentID:(NSString *)agentID;
@end

@implementation CPReviewStore

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;
    self.defaults = defaults;
    return self;
}

- (NSString *)signatureForTask:(CPTask *)task {
    return [NSString stringWithFormat:@"%.3f", task.updatedAt.timeIntervalSince1970];
}

- (NSString *)keyForTask:(CPTask *)task agentID:(NSString *)agentID {
    return [NSString stringWithFormat:@"reviewed.%@.%@", agentID, task.taskID];
}

- (BOOL)isTaskReviewed:(CPTask *)task agentID:(NSString *)agentID {
    NSString *stored = [self.defaults stringForKey:[self keyForTask:task agentID:agentID]];
    return stored && [stored isEqualToString:[self signatureForTask:task]];
}

- (void)markTaskReviewed:(CPTask *)task agentID:(NSString *)agentID {
    [self.defaults setObject:[self signatureForTask:task] forKey:[self keyForTask:task agentID:agentID]];
}

@end

// Strict priority: failed > attention/waiting > completed-unreviewed > working > idle.
static CPDisplayStatus CPDisplayStatusForTasks(NSArray<CPTask *> *tasks, NSString *agentID, CPReviewStore *reviewStore) {
    BOOL anyFailed = NO, anyWaiting = NO, anyPendingReview = NO, anyWorking = NO;
    for (CPTask *t in tasks) {
        switch (t.status) {
            case CPStatusFailed: anyFailed = YES; break;
            case CPStatusAttention:
            case CPStatusWaiting: anyWaiting = YES; break;
            case CPStatusCompleted:
                if (![reviewStore isTaskReviewed:t agentID:agentID]) anyPendingReview = YES;
                break;
            case CPStatusWorking: anyWorking = YES; break;
            case CPStatusIdle: break;
        }
    }
    if (anyFailed) return CPDisplayStatusFailed;
    if (anyWaiting) return CPDisplayStatusWaiting;
    if (anyPendingReview) return CPDisplayStatusCompletedPendingReview;
    if (anyWorking) return CPDisplayStatusWorking;
    return CPDisplayStatusIdle;
}

#pragma mark - Helpers

static NSTextField *CPLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.maximumNumberOfLines = 2;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

// 通用 hover/pressed 反馈按钮：圆角背景 + 边框，hover 高亮，pressed 下沉变色。
@interface CPHoverButton : NSButton
@property (nonatomic, strong) NSColor *cpBaseBackground;
@end

@implementation CPHoverButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;
    // 静止态不显示描边;hover/pressed 时才出现轻微描边与底色。
    self.layer.borderWidth = 0.0;
    self.layer.borderColor = CPBorder().CGColor;
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        if (area.owner == self) [self removeTrackingArea:area];
    }
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                          owner:self
                                                       userInfo:nil];
    [self addTrackingArea:area];
}

- (void)cpApplyBackground {
    if (self.isHighlighted) {
        self.layer.borderWidth = 1.0;
        self.layer.backgroundColor = [CPMuted() colorWithAlphaComponent:0.30].CGColor;
    } else {
        NSPoint p = [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        BOOL hovered = self.window && NSPointInRect(p, self.bounds);
        self.layer.borderWidth = hovered ? 1.0 : 0.0;
        self.layer.backgroundColor = (hovered ? [CPMuted() colorWithAlphaComponent:0.16] : (self.cpBaseBackground ?: NSColor.clearColor)).CGColor;
    }
}

- (void)mouseEntered:(NSEvent *)event { [super mouseEntered:event]; [self cpApplyBackground]; }
- (void)mouseExited:(NSEvent *)event { [super mouseExited:event]; [self cpApplyBackground]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self cpApplyBackground]; }
- (void)setCpBaseBackground:(NSColor *)color { _cpBaseBackground = color; [self cpApplyBackground]; }

@end

static NSButton *CPIconButton(NSString *symbol, id target, SEL action, NSString *tooltip) {
    NSButton *b = [CPHoverButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@""] target:target action:action];
    b.bordered = NO;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.contentTintColor = CPMuted();
    b.toolTip = tooltip;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

static NSImage *CPSymbol(NSString *name, CGFloat pointSize, NSColor *color) {
    NSImage *img = [NSImage imageWithSystemSymbolName:name accessibilityDescription:@""];
    img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:pointSize weight:NSFontWeightMedium]];
    if (color) img = [img imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:color]];
    return img;
}

#pragma mark - Agent Status Button

static NSString *CPDisplayStatusTitle(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return @"失败";
        case CPDisplayStatusWaiting: return @"需关注";
        case CPDisplayStatusCompletedPendingReview: return @"待查验";
        case CPDisplayStatusWorking: return @"工作中";
        case CPDisplayStatusIdle: return @"空闲";
    }
}

static NSColor *CPDisplayStatusColor(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return CPRed();
        case CPDisplayStatusWaiting: return CPOrange();
        case CPDisplayStatusCompletedPendingReview: return CPBlue();
        case CPDisplayStatusWorking: return CPGreen();
        case CPDisplayStatusIdle: return CPDyn(0.300, 0.850, 0.900, 0.350, 0.900, 0.950);
    }
}

static CGFloat CPDisplayStatusRippleDuration(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return 0.9;                 // 红色快速涟漪
        case CPDisplayStatusWaiting: return 1.4;                // 橙色较快涟漪
        case CPDisplayStatusCompletedPendingReview: return 1.8; // 蓝色双层涟漪
        case CPDisplayStatusWorking: return 2.0;                // 绿色涟漪
        case CPDisplayStatusIdle: return 3.2;                   // 青色慢涟漪
    }
}

@interface CPAgentStatusButton : NSButton
@property NSString *agentID;
@property (nonatomic) BOOL reduceMotion;
@property CPDisplayStatus displayStatus;
@property BOOL statusSelected;
@property CAShapeLayer *ringLayer;
@property CAShapeLayer *innerRingLayer;
@property CAShapeLayer *rippleLayerA;
@property CAShapeLayer *rippleLayerB;
@property NSView *statusDot;
@property NSImageView *iconView;
- (void)updateWithAgent:(CPAgent *)agent displayStatus:(CPDisplayStatus)status selected:(BOOL)selected;
@end

@implementation CPAgentStatusButton

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.bordered = NO;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8.0;

    self.ringLayer = [CAShapeLayer layer];
    self.ringLayer.fillColor = NSColor.clearColor.CGColor;
    self.ringLayer.lineWidth = 2.0;
    [self.layer addSublayer:self.ringLayer];

    // Second ring used only by the blue completed-pending-review double layer.
    self.innerRingLayer = [CAShapeLayer layer];
    self.innerRingLayer.fillColor = NSColor.clearColor.CGColor;
    self.innerRingLayer.lineWidth = 1.5;
    [self.layer addSublayer:self.innerRingLayer];

    // Ripple layers: 由内向外扩散并淡出的错峰波纹。
    self.rippleLayerA = [CAShapeLayer layer];
    self.rippleLayerA.fillColor = NSColor.clearColor.CGColor;
    self.rippleLayerA.lineWidth = 1.5;
    self.rippleLayerA.hidden = YES;
    [self.layer addSublayer:self.rippleLayerA];

    self.rippleLayerB = [CAShapeLayer layer];
    self.rippleLayerB.fillColor = NSColor.clearColor.CGColor;
    self.rippleLayerB.lineWidth = 1.5;
    self.rippleLayerB.hidden = YES;
    [self.layer addSublayer:self.rippleLayerB];

    self.iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    [self addSubview:self.iconView];

    self.statusDot = [[NSView alloc] initWithFrame:NSZeroRect];
    self.statusDot.wantsLayer = YES;
    self.statusDot.layer.cornerRadius = 5.0;
    self.statusDot.layer.borderWidth = 1.5;
    self.statusDot.layer.borderColor = NSColor.whiteColor.CGColor;
    [self addSubview:self.statusDot];
    return self;
}

- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    CGFloat outerR = side / 2.0 - 2.0;
    self.ringLayer.frame = b;
    self.ringLayer.path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - outerR, c.y - outerR, outerR * 2, outerR * 2)].CGPath;
    CGFloat innerR = MAX(outerR - 4.0, 1.0);
    self.innerRingLayer.frame = b;
    self.innerRingLayer.path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - innerR, c.y - innerR, innerR * 2, innerR * 2)].CGPath;
    // 波纹与外圈同路径，动画里从 0.55 倍放大到 1.0（由内向外扩散）。
    self.rippleLayerA.frame = b;
    self.rippleLayerA.path = self.ringLayer.path;
    self.rippleLayerB.frame = b;
    self.rippleLayerB.path = self.ringLayer.path;
    self.iconView.frame = NSMakeRect(c.x - 10, c.y - 10, 20, 20);
    self.statusDot.frame = NSMakeRect(b.size.width - 12, 1, 10, 10);
}

- (void)setReduceMotion:(BOOL)reduceMotion {
    _reduceMotion = reduceMotion;
    [self applyAnimations];
}

- (void)updateWithAgent:(CPAgent *)agent displayStatus:(CPDisplayStatus)status selected:(BOOL)selected {
    self.agentID = agent.agentID;
    self.displayStatus = status;
    self.statusSelected = selected;
    NSColor *color = CPDisplayStatusColor(status);

    self.image = nil;
    self.iconView.image = CPSymbol(agent.iconName ?: @"sparkles", 16, selected ? CPAccent() : CPFg2());
    self.iconView.contentTintColor = selected ? CPAccent() : CPFg2();
    self.layer.backgroundColor = (selected ? CPDyn(0.24, 0.32, 0.50, 0.20, 0.28, 0.45) : NSColor.clearColor).CGColor;

    self.ringLayer.strokeColor = color.CGColor;
    self.ringLayer.opacity = 1.0;
    BOOL doubleRing = status == CPDisplayStatusCompletedPendingReview;
    self.innerRingLayer.hidden = !doubleRing;
    self.innerRingLayer.strokeColor = color.CGColor;
    self.innerRingLayer.opacity = 1.0;
    self.rippleLayerA.strokeColor = color.CGColor;
    self.rippleLayerB.strokeColor = color.CGColor;
    self.statusDot.layer.backgroundColor = color.CGColor;

    self.toolTip = [NSString stringWithFormat:@"%@ · %@", agent.name, CPDisplayStatusTitle(status)];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", agent.name, CPDisplayStatusTitle(status)];

    [self setNeedsLayout:YES];
    [self layout];
    [self applyAnimations];
}

- (CAAnimationGroup *)rippleAnimationWithDuration:(CGFloat)duration timeOffset:(CGFloat)timeOffset {
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @0.55;
    scale.toValue = @1.0;

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.85;
    fade.toValue = @0.0;

    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale, fade];
    group.duration = duration;
    group.timeOffset = timeOffset; // 错峰：两条波纹错开半个周期
    group.repeatCount = HUGE_VALF;
    group.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    group.removedOnCompletion = NO;
    return group;
}

- (void)applyAnimations {
    [self.ringLayer removeAllAnimations];
    [self.innerRingLayer removeAllAnimations];
    [self.rippleLayerA removeAllAnimations];
    [self.rippleLayerB removeAllAnimations];
    self.ringLayer.opacity = 1.0;
    self.innerRingLayer.opacity = 1.0;
    if (self.reduceMotion) {
        // 减少动态效果：不加任何动画，保留静态外圈与状态点。
        self.rippleLayerA.hidden = YES;
        self.rippleLayerB.hidden = YES;
        self.rippleLayerA.opacity = 1.0;
        self.rippleLayerB.opacity = 1.0;
        return;
    }

    CGFloat duration = CPDisplayStatusRippleDuration(self.displayStatus);
    self.rippleLayerA.hidden = NO;
    self.rippleLayerB.hidden = NO;
    // 静态终值设为 0，动画从 timeOffset 相位接管，避免闪烁。
    self.rippleLayerA.opacity = 0.0;
    self.rippleLayerB.opacity = 0.0;
    [self.rippleLayerA addAnimation:[self rippleAnimationWithDuration:duration timeOffset:0.0] forKey:@"rippleA"];
    [self.rippleLayerB addAnimation:[self rippleAnimationWithDuration:duration timeOffset:duration / 2.0] forKey:@"rippleB"];

    if (!self.innerRingLayer.hidden) {
        // 待查验：内圈保留一条蓝色涟漪，形成双层蓝色波纹。
        [self.innerRingLayer addAnimation:[self rippleAnimationWithDuration:duration timeOffset:duration / 4.0] forKey:@"rippleInner"];
    }
}

@end

#pragma mark - State Reader

@interface CPStateReader : NSObject
- (NSArray<CPAgent *> *)readAgents;
@end

@implementation CPStateReader

- (NSArray<CPAgent *> *)readAgents {
    CPAgent *codex = [self readCodexAgent];
    CPAgent *kimi = [self kimiPlaceholderAgent];
    return @[codex, kimi];
}

- (CPAgent *)readCodexAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"codex";
    agent.name = @"Codex";
    agent.iconName = @"terminal.fill";
    agent.color = CPAccent();
    agent.placeholder = NO;
    agent.tasks = NSMutableArray.array;

    NSString *home = NSHomeDirectory();
    NSString *statePath = [home stringByAppendingPathComponent:@".codex/state_5.sqlite"];
    sqlite3 *stateDB = NULL;
    if (sqlite3_open_v2(statePath.UTF8String, &stateDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (stateDB) sqlite3_close(stateDB);
        agent.status = CPStatusIdle;
        return agent;
    }
    sqlite3_busy_timeout(stateDB, 150);

    NSString *logsPath = [home stringByAppendingPathComponent:@".codex/logs_2.sqlite"];
    sqlite3 *logsDB = NULL;
    if (sqlite3_open_v2(logsPath.UTF8String, &logsDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(logsDB, 150);
    }

    const char *sql =
        "SELECT id, COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), '未命名任务'), "
        "cwd, created_at_ms, updated_at_ms, tokens_used FROM threads "
        "WHERE archived=0 AND preview<>'' ORDER BY recency_at_ms DESC, updated_at_ms DESC LIMIT 10";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(stateDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)] ?: @"";
            task.title = CPCleanTitle(sqlite3_column_text(stmt, 1));
            task.projectPath = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 2)] ?: @"";
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Codex";
            task.createdAt = CPDateFromMillis(sqlite3_column_int64(stmt, 3));
            task.updatedAt = CPDateFromMillis(sqlite3_column_int64(stmt, 4));
            task.tokensUsed = (NSInteger)sqlite3_column_int64(stmt, 5);
            [self enrichTask:task logsDB:logsDB];
            [agent.tasks addObject:task];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(stateDB);
    if (logsDB) sqlite3_close(logsDB);

    agent.status = [self overallStatusForTasks:agent.tasks];
    return agent;
}

- (CPAgent *)kimiPlaceholderAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"kimi";
    agent.name = @"Kimi";
    agent.iconName = @"moon";
    agent.color = CPMuted();
    agent.placeholder = YES;
    agent.status = CPStatusWorking;
    agent.tasks = [NSMutableArray arrayWithArray:@[
        [self sampleTask:@"k1" title:@"整理本周会议纪要（示例）" project:@"team-sync" path:@"~/Notes/team-sync" status:CPStatusWorking activity:@"正在从本地日志提取待办事项（数据源待接入）。"],
        [self sampleTask:@"k2" title:@"润色产品发布文案（示例）" project:@"launch-copy" path:@"~/Notes/launch-copy" status:CPStatusWaiting activity:@"等待用户提供品牌语气参考。"],
        [self sampleTask:@"k3" title:@"分析上季度数据报告（示例）" project:@"q3-review" path:@"~/Notes/q3-review" status:CPStatusCompleted activity:@"已生成摘要，保存为 q3-summary.md。"]
    ]];
    return agent;
}

- (CPTask *)sampleTask:(NSString *)taskID title:(NSString *)title project:(NSString *)project path:(NSString *)path status:(CPStatus)status activity:(NSString *)activity {
    CPTask *task = CPTask.new;
    task.taskID = taskID;
    task.title = title;
    task.projectName = project;
    task.projectPath = path;
    task.status = status;
    task.activity = activity;
    task.createdAt = NSDate.date;
    task.updatedAt = NSDate.date;
    task.tokensUsed = 0;
    return task;
}

- (void)enrichTask:(CPTask *)task logsDB:(sqlite3 *)logsDB {
    if (!logsDB) {
        task.status = -task.updatedAt.timeIntervalSinceNow < 1800 ? CPStatusWaiting : CPStatusIdle;
        task.activity = @"正在整理任务状态";
        return;
    }
    const char *sql =
        "SELECT MAX(ts), "
        "MAX(CASE WHEN feedback_log_body LIKE '%turn/completed%' OR feedback_log_body LIKE '%turn_completed%' THEN ts ELSE 0 END), "
        "MAX(CASE WHEN feedback_log_body LIKE '%approval%' OR feedback_log_body LIKE '%request_user_input%' THEN ts ELSE 0 END), "
        "MAX(CASE WHEN level='ERROR' THEN ts ELSE 0 END) FROM logs WHERE thread_id=?";
    sqlite3_stmt *stmt = NULL;
    NSDate *lastLog = nil, *lastComplete = nil, *lastAttention = nil, *lastError = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, task.taskID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            lastLog = CPDateFromSeconds(sqlite3_column_int64(stmt, 0));
            lastComplete = CPDateFromSeconds(sqlite3_column_int64(stmt, 1));
            lastAttention = CPDateFromSeconds(sqlite3_column_int64(stmt, 2));
            lastError = CPDateFromSeconds(sqlite3_column_int64(stmt, 3));
        }
    }
    if (stmt) sqlite3_finalize(stmt);

    NSTimeInterval errorAge = lastError ? -lastError.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval attentionAge = lastAttention ? -lastAttention.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval logAge = lastLog ? -lastLog.timeIntervalSinceNow : DBL_MAX;
    NSTimeInterval completeAge = lastComplete ? -lastComplete.timeIntervalSinceNow : DBL_MAX;

    if (errorAge < 180 && (!lastComplete || [lastError compare:lastComplete] == NSOrderedDescending)) task.status = CPStatusFailed;
    else if (attentionAge < 900 && (!lastComplete || [lastAttention compare:lastComplete] == NSOrderedDescending)) task.status = CPStatusAttention;
    else if (logAge < 12) task.status = CPStatusWorking;
    else if (completeAge < 180) task.status = CPStatusCompleted;
    else if (-task.updatedAt.timeIntervalSinceNow < 1800) task.status = CPStatusWaiting;
    else task.status = CPStatusIdle;

    task.activity = [self activityForTask:task logsDB:logsDB];
}

- (NSString *)activityForTask:(CPTask *)task logsDB:(sqlite3 *)logsDB {
    const char *sql = "SELECT target FROM logs WHERE thread_id=? ORDER BY ts DESC, ts_nanos DESC LIMIT 1";
    sqlite3_stmt *stmt = NULL;
    NSString *target = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, task.taskID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_text(stmt, 0))
            target = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)];
    }
    if (stmt) sqlite3_finalize(stmt);
    if ([target containsString:@"tools::parallel"]) return @"正在调用工具";
    if ([target containsString:@"stream_events"]) return @"正在处理模型输出";
    if ([target containsString:@"http_client"] || [target containsString:@"responses"]) return @"正在请求模型";
    if ([target containsString:@"shell"] || [target containsString:@"exec"]) return @"正在运行命令";
    if ([target containsString:@"app_server"]) return @"正在同步 Codex";
    if ([target containsString:@"goal"]) return @"正在推进长期目标";
    return task.status == CPStatusCompleted ? @"任务已完成" : @"Codex 正在活动";
}

- (CPStatus)overallStatusForTasks:(NSArray<CPTask *> *)tasks {
    for (CPTask *t in tasks) if (t.status == CPStatusFailed) return CPStatusFailed;
    for (CPTask *t in tasks) if (t.status == CPStatusAttention) return CPStatusAttention;
    for (CPTask *t in tasks) if (t.status == CPStatusWorking) return CPStatusWorking;
    return tasks.count ? CPStatusWaiting : CPStatusIdle;
}

@end

#pragma mark - Workbench Card

@interface CPDraggableHeaderView : NSView
@property BOOL draggingWindow;
@property NSPoint dragStartMouse;
@property NSPoint dragStartOrigin;
@end

@implementation CPDraggableHeaderView
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return [hit isKindOfClass:NSButton.class] ? hit : self;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event {
    self.draggingWindow = YES;
    self.dragStartMouse = NSEvent.mouseLocation;
    self.dragStartOrigin = self.window.frame.origin;
}
- (void)mouseDragged:(NSEvent *)event {
    if (!self.draggingWindow || !self.window) return;
    NSPoint mouse = NSEvent.mouseLocation;
    NSPoint origin = NSMakePoint(self.dragStartOrigin.x + mouse.x - self.dragStartMouse.x,
                                 self.dragStartOrigin.y + mouse.y - self.dragStartMouse.y);
    [self.window setFrameOrigin:origin];
}
- (void)mouseUp:(NSEvent *)event {
    self.draggingWindow = NO;
}
@end

@interface CPWorkbenchCardController : NSObject
@property NSPanel *window;
@property NSView *shadowCarrier;
@property NSView *card;
@property NSView *leftColumn;
@property NSView *middleColumn;
@property NSView *rightColumn;
@property NSStackView *agentStack;
@property NSStackView *taskStack;
@property NSStackView *detailStack;
@property NSButton *pinButton;
@property NSButton *modeButton;
@property NSTextField *cardMetaLabel;
@property NSTextField *centerTitle;
@property NSTextField *centerMeta;
@property NSArray<CPAgent *> *agents;
@property CPAgent *selectedAgent;
@property CPTask *selectedTask;
@property CPReviewStore *reviewStore;
@property BOOL pinned;
@property NSInteger dockMode;
@property id clickMonitor;
@property NSRect lastDockRect;
- (NSRect)targetFrameNearDockRect:(NSRect)rect edge:(NSRectEdge)edge;
- (NSRect)targetFrameInVisibleRect:(NSRect)visible;
- (void)showNearDockRect:(NSRect)rect edge:(NSRectEdge)edge;
- (void)close;
- (BOOL)isVisible;
- (void)renderAgents:(NSArray<CPAgent *> *)agents;
@end

@implementation CPWorkbenchCardController

static const CGFloat CPCardWidth = 520.0;
static const CGFloat CPCardHeight = 360.0;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.pinned = YES;
    self.dockMode = 0;
    self.reviewStore = [[CPReviewStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    [self buildWindow];
    return self;
}

static const CGFloat CPWorkbenchInset = 20.0;

// Pure geometry helpers: depend only on a visibleFrame rect and a target size,
// so headless self-tests can drive the exact same code paths with synthetic rects.
static NSRect CPCenteredRectInVisibleFrame(NSRect visible, NSSize size) {
    CGFloat x = NSMidX(visible) - size.width / 2.0;
    CGFloat y = NSMidY(visible) - size.height / 2.0;
    x = MAX(NSMinX(visible) + CPWorkbenchInset, MIN(x, NSMaxX(visible) - size.width - CPWorkbenchInset));
    y = MAX(NSMinY(visible) + CPWorkbenchInset, MIN(y, NSMaxY(visible) - size.height - CPWorkbenchInset));
    return NSIntegralRect(NSMakeRect(x, y, size.width, size.height));
}

static NSRect CPRectAtTopRightOfVisibleFrame(NSRect visible, NSSize size) {
    return NSMakeRect(NSMaxX(visible) - size.width, NSMaxY(visible) - size.height, size.width, size.height);
}

- (void)buildWindow {
    CGFloat windowW = CPCardWidth + CPWorkbenchInset * 2.0;
    CGFloat windowH = CPCardHeight + CPWorkbenchInset * 2.0;
    self.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, windowW, windowH)
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; // 工作台始终深色
    self.window.level = NSFloatingWindowLevel;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = NO;
    self.window.hidesOnDeactivate = NO;
    self.window.movable = YES;
    self.window.movableByWindowBackground = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary;

    self.shadowCarrier = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, windowW, windowH)];
    self.shadowCarrier.wantsLayer = YES;
    self.shadowCarrier.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.shadowCarrier.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.12].CGColor;
    self.shadowCarrier.layer.shadowOffset = CGSizeMake(0, -8);
    self.shadowCarrier.layer.shadowRadius = 30.0;
    self.shadowCarrier.layer.shadowOpacity = 1.0;
    self.shadowCarrier.layer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(CPWorkbenchInset, CPWorkbenchInset, CPCardWidth, CPCardHeight) xRadius:18 yRadius:18].CGPath;
    self.window.contentView = self.shadowCarrier;

    self.card = [[NSView alloc] initWithFrame:NSMakeRect(CPWorkbenchInset, CPWorkbenchInset, CPCardWidth, CPCardHeight)];
    self.card.wantsLayer = YES;
    self.card.layer.backgroundColor = CPSurface().CGColor;
    self.card.layer.cornerRadius = 18.0;
    self.card.layer.borderWidth = 1.0;
    self.card.layer.borderColor = CPBorder().CGColor;
    self.card.layer.masksToBounds = YES;
    self.card.autoresizingMask = NSViewNotSizable;
    [self.shadowCarrier addSubview:self.card];

    [self buildHeader];
    [self buildBody];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dockModeChanged:)
                                                 name:@"CPDockModeChanged"
                                               object:nil];
}

- (void)buildHeader {
    CPDraggableHeaderView *header = [[CPDraggableHeaderView alloc] initWithFrame:NSMakeRect(0, CPCardHeight - 48, CPCardWidth, 48)];
    header.toolTip = @"拖动以移动工作台";
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.card addSubview:header];
    [NSLayoutConstraint activateConstraints:@[
        [header.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor],
        [header.topAnchor constraintEqualToAnchor:self.card.topAnchor],
        [header.heightAnchor constraintEqualToConstant:48]
    ]];

    NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
    logo.image = CPSymbol(@"waveform.path.ecg", 16, CPAccent());
    logo.contentTintColor = CPAccent();
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:20].active = YES;
    [logo.heightAnchor constraintEqualToConstant:20].active = YES;

    NSTextField *title = CPLabel(@"Codex Pulse", 14, NSFontWeightSemibold, CPFg());
    self.cardMetaLabel = CPLabel(@"2 个 Agent", 11, NSFontWeightRegular, CPMuted());

    NSStackView *text = [NSStackView stackViewWithViews:@[title, self.cardMetaLabel]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 0;

    NSStackView *left = [NSStackView stackViewWithViews:@[logo, text]];
    left.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    left.alignment = NSLayoutAttributeCenterY;
    left.spacing = 8;
    left.translatesAutoresizingMaskIntoConstraints = NO;

    self.modeButton = CPIconButton(@"rectangle.2.swap", self, @selector(toggleDockMode:), @"切换为底部快捷栏");
    self.pinButton = CPIconButton(@"pin.fill", self, @selector(togglePin:), @"固定");
    NSButton *closeButton = CPIconButton(@"xmark", self, @selector(close), @"关闭");

    NSStackView *right = [NSStackView stackViewWithViews:@[self.modeButton, self.pinButton, closeButton]];
    right.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    right.spacing = 4;
    right.translatesAutoresizingMaskIntoConstraints = NO;

    [header addSubview:left];
    [header addSubview:right];
    [NSLayoutConstraint activateConstraints:@[
        [left.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:16],
        [left.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [right.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-12],
        [right.centerYAnchor constraintEqualToAnchor:header.centerYAnchor]
    ]];

    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, CPCardWidth, 1)];
    sep.boxType = NSBoxSeparator;
    sep.translatesAutoresizingMaskIntoConstraints = NO;
    [self.card addSubview:sep];
    [NSLayoutConstraint activateConstraints:@[
        [sep.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor],
        [sep.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor],
        [sep.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [sep.heightAnchor constraintEqualToConstant:1]
    ]];
}

- (void)buildBody {
    NSView *body = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPCardWidth, CPCardHeight - 49)];
    body.translatesAutoresizingMaskIntoConstraints = NO;
    [self.card addSubview:body];
    [NSLayoutConstraint activateConstraints:@[
        [body.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor],
        [body.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor],
        [body.topAnchor constraintEqualToAnchor:self.card.topAnchor constant:49],
        [body.bottomAnchor constraintEqualToAnchor:self.card.bottomAnchor]
    ]];

    self.leftColumn = [self columnWithBackground:CPBg()];
    self.middleColumn = [self columnWithBackground:CPSurface()];
    self.rightColumn = [self columnWithBackground:CPDyn(0.110, 0.120, 0.160, 0.095, 0.105, 0.140)];

    [self.leftColumn setContentHuggingPriority:NSLayoutPriorityDefaultHigh forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.middleColumn setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    // 常驻两栏:左侧 Agent 固定宽度,右侧任务区填满剩余宽度。
    NSStackView *columns = [NSStackView stackViewWithViews:@[self.leftColumn, self.middleColumn]];
    columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columns.spacing = 0;
    columns.distribution = NSStackViewDistributionFill;
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    [body addSubview:columns];
    [NSLayoutConstraint activateConstraints:@[
        [columns.leadingAnchor constraintEqualToAnchor:body.leadingAnchor],
        [columns.trailingAnchor constraintEqualToAnchor:body.trailingAnchor],
        [columns.topAnchor constraintEqualToAnchor:body.topAnchor],
        [columns.bottomAnchor constraintEqualToAnchor:body.bottomAnchor]
    ]];

    [self.leftColumn.widthAnchor constraintEqualToConstant:126].active = YES;

    // 详情抽屉:middleColumn 上方的隐藏 overlay,不占水平宽度,层级在任务列表之上。
    self.rightColumn.hidden = YES;
    self.rightColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [self.middleColumn addSubview:self.rightColumn positioned:NSWindowAbove relativeTo:nil];
    [NSLayoutConstraint activateConstraints:@[
        [self.rightColumn.leadingAnchor constraintEqualToAnchor:self.middleColumn.leadingAnchor],
        [self.rightColumn.trailingAnchor constraintEqualToAnchor:self.middleColumn.trailingAnchor],
        [self.rightColumn.topAnchor constraintEqualToAnchor:self.middleColumn.topAnchor],
        [self.rightColumn.bottomAnchor constraintEqualToAnchor:self.middleColumn.bottomAnchor]
    ]];

    [self buildLeftColumn];
    [self buildMiddleColumn];
    [self buildRightColumn];
}

- (NSView *)columnWithBackground:(NSColor *)color {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    v.wantsLayer = YES;
    v.layer.backgroundColor = color.CGColor;
    return v;
}

- (NSStackView *)stackIn:(NSView *)view spacing:(CGFloat)spacing {
    NSStackView *s = [NSStackView stackViewWithViews:@[]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = spacing;
    s.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
    s.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:s];
    [NSLayoutConstraint activateConstraints:@[
        [s.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [s.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [s.topAnchor constraintEqualToAnchor:view.topAnchor],
        [s.bottomAnchor constraintLessThanOrEqualToAnchor:view.bottomAnchor]
    ]];
    return s;
}

- (void)buildLeftColumn {
    NSStackView *stack = [self stackIn:self.leftColumn spacing:4];
    self.agentStack = stack;

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [head.heightAnchor constraintEqualToConstant:36].active = YES;

    NSImageView *logo = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
    logo.image = CPSymbol(@"waveform.path.ecg", 14, CPAccent());
    logo.contentTintColor = CPAccent();
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:20].active = YES;
    [logo.heightAnchor constraintEqualToConstant:20].active = YES;

    NSTextField *title = CPLabel(@"Agent", 13, NSFontWeightSemibold, CPFg());
    NSStackView *h = [NSStackView stackViewWithViews:@[logo, title]];
    h.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    h.spacing = 6;
    h.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:h];
    [NSLayoutConstraint activateConstraints:@[
        [h.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [h.centerYAnchor constraintEqualToAnchor:head.centerYAnchor]
    ]];

    [stack addArrangedSubview:head];
}

- (void)buildMiddleColumn {
    NSStackView *stack = [self stackIn:self.middleColumn spacing:8];
    self.taskStack = stack;

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [head.heightAnchor constraintEqualToConstant:36].active = YES;

    self.centerTitle = CPLabel(@"Codex", 22, NSFontWeightSemibold, CPFg());
    self.centerTitle.font = [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold];
    self.centerMeta = CPLabel(@"0 个活动", 11, NSFontWeightRegular, CPMuted());
    NSStackView *text = [NSStackView stackViewWithViews:@[self.centerTitle, self.centerMeta]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.spacing = 1;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    [head addSubview:text];
    [NSLayoutConstraint activateConstraints:@[
        [text.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [text.centerYAnchor constraintEqualToAnchor:head.centerYAnchor]
    ]];

    [stack addArrangedSubview:head];
}

- (void)buildRightColumn {
    NSStackView *stack = [self stackIn:self.rightColumn spacing:10];
    self.detailStack = stack;

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [head.heightAnchor constraintEqualToConstant:36].active = YES;
    NSTextField *title = CPLabel(@"任务详情", 12, NSFontWeightSemibold, CPFg());
    title.translatesAutoresizingMaskIntoConstraints = NO;
    NSButton *closeButton = CPIconButton(@"xmark", self, @selector(closeDetailDrawer), @"关闭详情");
    [head addSubview:title];
    [head addSubview:closeButton];
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [closeButton.trailingAnchor constraintEqualToAnchor:head.trailingAnchor],
        [closeButton.centerYAnchor constraintEqualToAnchor:head.centerYAnchor]
    ]];
    [stack addArrangedSubview:head];
}

- (void)showDetailDrawer {
    // 提到任务列表之上再显示。
    [self.middleColumn addSubview:self.rightColumn positioned:NSWindowAbove relativeTo:nil];
    self.rightColumn.hidden = NO;
}

- (void)closeDetailDrawer {
    self.rightColumn.hidden = YES;
}

- (void)handleEscape {
    if (!self.rightColumn.hidden) {
        [self closeDetailDrawer];
    } else {
        [self close];
    }
}

- (NSButton *)agentRow:(CPAgent *)agent selected:(BOOL)selected {
    NSButton *row = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(agentClicked:)];
    row.bordered = NO;
    [row setButtonType:NSButtonTypeMomentaryChange];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 8.0;
    row.layer.borderWidth = 0.0;
    ((CPHoverButton *)row).cpBaseBackground = selected ? CPDyn(0.24, 0.32, 0.50, 0.20, 0.28, 0.45) : NSColor.clearColor;
    row.tag = [self.agents indexOfObject:agent];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:36].active = YES;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 20, 20)];
    icon.image = CPSymbol(agent.iconName, 12, selected ? agent.color : CPFg2());
    icon.contentTintColor = selected ? agent.color : CPFg2();
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    [icon.heightAnchor constraintEqualToConstant:20].active = YES;

    NSTextField *name = CPLabel(agent.name, 12, NSFontWeightMedium, CPFg());
    name.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *status = CPLabel(CPStatusTitle(agent.status), 10, NSFontWeightRegular, CPMuted());

    NSStackView *text = [NSStackView stackViewWithViews:@[name, status]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 0;

    NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 6, 6)];
    dot.image = CPStatusDot(6, agent.status);
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    [dot.widthAnchor constraintEqualToConstant:6].active = YES;
    [dot.heightAnchor constraintEqualToConstant:6].active = YES;

    NSStackView *h = [NSStackView stackViewWithViews:@[icon, text, dot]];
    h.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    h.alignment = NSLayoutAttributeCenterY;
    h.spacing = 8;
    h.distribution = NSStackViewDistributionEqualSpacing;
    h.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:h];
    [NSLayoutConstraint activateConstraints:@[
        [h.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:8],
        [h.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-8],
        [h.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    return row;
}

- (NSButton *)taskRow:(CPTask *)task index:(NSInteger)index {
    NSButton *row = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(taskClicked:)];
    row.bordered = NO;
    [row setButtonType:NSButtonTypeMomentaryChange];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 10.0;
    row.layer.borderWidth = 0.0;
    ((CPHoverButton *)row).cpBaseBackground = NSColor.clearColor;
    row.tag = index;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:56].active = YES;

    NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 7, 7)];
    dot.image = CPStatusDot(7, task.status);
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    [dot.widthAnchor constraintEqualToConstant:7].active = YES;
    [dot.heightAnchor constraintEqualToConstant:7].active = YES;

    NSTextField *title = CPLabel(task.title, 12, NSFontWeightMedium, CPFg());
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *meta = CPLabel([NSString stringWithFormat:@"%@ · %@", task.projectName, CPStatusTitle(task.status)], 11, NSFontWeightRegular, CPMuted());

    NSStackView *text = [NSStackView stackViewWithViews:@[title, meta]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 1;

    NSStackView *h = [NSStackView stackViewWithViews:@[dot, text]];
    h.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    h.alignment = NSLayoutAttributeCenterY;
    h.spacing = 10;
    h.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:h];
    [NSLayoutConstraint activateConstraints:@[
        [h.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:12],
        [h.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-12],
        [h.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    return row;
}

- (NSView *)detailPair:(NSString *)label value:(NSString *)value {
    NSStackView *s = [NSStackView stackViewWithViews:@[]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.spacing = 1;
    [s addArrangedSubview:CPLabel(label, 10, NSFontWeightSemibold, CPMuted())];
    [s addArrangedSubview:CPLabel(value.length ? value : @"—", 12, NSFontWeightRegular, CPFg2())];
    return s;
}

- (void)renderAgents:(NSArray<CPAgent *> *)agents {
    // 刷新时先按 agentID 映射到新实例;找不到才回退 firstObject,并清 selectedTask/关闭抽屉。
    NSString *selectedID = self.selectedAgent.agentID;
    CPAgent *match = nil;
    for (CPAgent *a in agents) {
        if (selectedID && [a.agentID isEqualToString:selectedID]) {
            match = a;
            break;
        }
    }
    if (match) {
        self.selectedAgent = match;
    } else {
        self.selectedAgent = agents.count ? agents.firstObject : nil;
        self.selectedTask = nil;
        [self closeDetailDrawer];
    }
    self.agents = agents;

    // Rebuild agent list
    while (self.agentStack.arrangedSubviews.count > 1) {
        NSView *v = self.agentStack.arrangedSubviews.lastObject;
        [self.agentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    for (CPAgent *agent in agents) {
        [self.agentStack addArrangedSubview:[self agentRow:agent selected:agent == self.selectedAgent]];
    }

    // Add Agent placeholder
    NSButton *add = [CPHoverButton buttonWithTitle:@"+ 添加 Agent" target:self action:@selector(addAgent:)];
    add.bordered = NO;
    add.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    add.contentTintColor = CPMuted();
    add.alignment = NSTextAlignmentCenter;
    add.translatesAutoresizingMaskIntoConstraints = NO;
    [add.heightAnchor constraintEqualToConstant:32].active = YES;
    [self.agentStack addArrangedSubview:add];

    [self renderStream];
}

- (void)renderStream {
    if (!self.selectedAgent) return;
    CPAgent *agent = self.selectedAgent;
    NSArray<CPTask *> *tasks = agent.tasks;

    while (self.taskStack.arrangedSubviews.count > 1) {
        NSView *v = self.taskStack.arrangedSubviews.lastObject;
        [self.taskStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    self.centerTitle.stringValue = agent.name;
    NSInteger attention = 0;
    for (CPTask *t in tasks) if (t.status == CPStatusAttention || t.status == CPStatusFailed) attention++;
    self.centerMeta.stringValue = [NSString stringWithFormat:@"%lu 个活动 · %ld 个需关注", (unsigned long)tasks.count, (long)attention];

    if (!tasks.count) {
        [self.taskStack addArrangedSubview:CPLabel(@"暂无活动任务", 12, NSFontWeightRegular, CPMuted())];
        self.selectedTask = nil;
        [self closeDetailDrawer];
    } else {
        NSInteger idx = 0;
        for (CPTask *task in tasks) {
            [self.taskStack addArrangedSubview:[self taskRow:task index:idx++]];
        }
        // 刷新时按 taskID 映射保留 selectedTask 与抽屉开关;任务不存在才关闭抽屉。
        if (self.selectedTask) {
            CPTask *match = nil;
            for (CPTask *t in tasks) {
                if ([t.taskID isEqualToString:self.selectedTask.taskID]) {
                    match = t;
                    break;
                }
            }
            if (match) {
                self.selectedTask = match;
            } else {
                self.selectedTask = nil;
                [self closeDetailDrawer];
            }
        }
    }
    [self renderDetail];
    [self updateMeta];
}

- (void)renderDetail {
    while (self.detailStack.arrangedSubviews.count > 1) {
        NSView *v = self.detailStack.arrangedSubviews.lastObject;
        [self.detailStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (!self.selectedTask) {
        [self.detailStack addArrangedSubview:CPLabel(@"选择一项任务查看详情", 12, NSFontWeightRegular, CPMuted())];
        return;
    }

    CPTask *task = self.selectedTask;
    CPAgent *agent = self.selectedAgent;

    if (agent.placeholder) {
        NSTextField *notice = CPLabel([NSString stringWithFormat:@"%@ 目前为占位接入。后续将替换为真实本地数据源。", agent.name], 11, NSFontWeightRegular, CPFg2());
        notice.maximumNumberOfLines = 3;
        [self.detailStack addArrangedSubview:notice];
    }

    NSTextField *title = CPLabel(task.title, 14, NSFontWeightSemibold, CPFg());
    title.maximumNumberOfLines = 3;
    [self.detailStack addArrangedSubview:title];
    [self.detailStack addArrangedSubview:CPLabel(CPStatusTitle(task.status), 12, NSFontWeightMedium, CPStatusColor(task.status))];
    [self.detailStack addArrangedSubview:[self detailPair:@"Agent" value:agent.name]];
    [self.detailStack addArrangedSubview:[self detailPair:@"项目" value:task.projectName]];
    [self.detailStack addArrangedSubview:[self detailPair:@"Tokens" value:[NSString stringWithFormat:@"%ld", (long)task.tokensUsed]]];
    [self.detailStack addArrangedSubview:[self detailPair:@"最近活动" value:task.activity]];

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    [self.detailStack addArrangedSubview:[self detailPair:@"更新于" value:[fmt stringFromDate:task.updatedAt]]];
}

- (void)updateMeta {
    NSInteger attention = 0, active = 0;
    for (CPAgent *a in self.agents) {
        if (a.status == CPStatusWorking || a.status == CPStatusAttention) active++;
        for (CPTask *t in a.tasks) if (t.status == CPStatusAttention || t.status == CPStatusFailed) attention++;
    }
    self.cardMetaLabel.stringValue = attention
        ? [NSString stringWithFormat:@"%lu 个 Agent · %ld 个需关注", (unsigned long)self.agents.count, (long)attention]
        : [NSString stringWithFormat:@"%lu 个 Agent · %ld 个活动中", (unsigned long)self.agents.count, (long)active];
}

- (void)agentClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= 0 && idx < (NSInteger)self.agents.count) {
        self.selectedAgent = self.agents[(NSUInteger)idx];
        self.selectedTask = nil;
        [self closeDetailDrawer];
        [self renderAgents:self.agents];
    }
}

- (void)taskClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= 0 && idx < (NSInteger)self.selectedAgent.tasks.count) {
        self.selectedTask = self.selectedAgent.tasks[(NSUInteger)idx];
        [self renderDetail];
        [self showDetailDrawer];
        // 只有真正打开任务详情才写入查验；render/选择Agent/刷新均不写defaults。
        if (self.selectedTask.status == CPStatusCompleted) {
            [self.reviewStore markTaskReviewed:self.selectedTask agentID:self.selectedAgent.agentID];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CPTaskReviewed" object:nil];
        }
    }
}

- (void)addAgent:(id)sender {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"添加新 Agent";
    alert.informativeText = @"未来将支持读取本地配置文件添加更多 Agent。";
    [alert addButtonWithTitle:@"好"];
    [alert runModal];
}

- (void)togglePin:(id)sender {
    self.pinned = !self.pinned;
    self.pinButton.contentTintColor = self.pinned ? CPAccent() : CPMuted();
}

- (void)toggleDockMode:(id)sender {
    NSInteger newMode = self.dockMode == 0 ? 1 : 0;
    self.dockMode = newMode;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CPDockModeChanged" object:@(newMode)];
}

- (void)dockModeChanged:(NSNotification *)note {
    NSInteger mode = [note.object integerValue];
    self.dockMode = mode;
    self.modeButton.toolTip = mode == 0 ? @"切换为底部快捷栏" : @"切换为侧边胶囊";
}

- (NSRect)targetFrameInVisibleRect:(NSRect)visible {
    NSSize size = NSMakeSize(CPCardWidth + CPWorkbenchInset * 2.0, CPCardHeight + CPWorkbenchInset * 2.0);
    return CPCenteredRectInVisibleFrame(visible, size);
}

- (NSRect)targetFrameNearDockRect:(NSRect)rect edge:(NSRectEdge)edge {
    (void)rect;
    (void)edge;
    NSScreen *screen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
    return [self targetFrameInVisibleRect:screen.visibleFrame];
}

- (void)showNearDockRect:(NSRect)rect edge:(NSRectEdge)edge {
    self.lastDockRect = rect;
    NSRect target = [self targetFrameNearDockRect:rect edge:edge];
    if (!self.window.isVisible) {
        [self.window setFrame:target display:NO];
        [self.window orderFrontRegardless];
        [self.window setFrame:target display:YES animate:YES];
    } else {
        [self.window setFrame:target display:YES animate:YES];
    }
    [self installClickMonitor];
}

- (void)close {
    [self.window orderOut:nil];
    [self removeClickMonitor];
}

- (BOOL)isVisible {
    return self.window.isVisible;
}

- (void)installClickMonitor {
    [self removeClickMonitor];
    if (self.pinned) return;
    __weak typeof(self) weakSelf = self;
    self.clickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *event) {
        [weakSelf handleGlobalClick:event];
    }];
}

- (void)removeClickMonitor {
    if (self.clickMonitor) {
        [NSEvent removeMonitor:self.clickMonitor];
        self.clickMonitor = nil;
    }
}

- (void)handleGlobalClick:(NSEvent *)event {
    NSPoint loc = [NSEvent mouseLocation];
    if (!NSPointInRect(loc, self.window.frame) && !NSPointInRect(loc, self.lastDockRect)) {
        [self close];
    }
}

@end

#pragma mark - Dock Capsule

@interface CPDockPillView : NSView
@property (weak) id controller;
@end

@interface CPDockWindowController : NSObject
@property NSPanel *window;
@property CPDockPillView *pill;
@property NSView *floatingPill;
@property NSView *stripView;
@property NSView *stripLine;
@property NSImageView *iconView;
@property NSTrackingArea *trackingArea;
@property BOOL docked;
@property NSRectEdge dockEdge;
@property CGFloat freeX;
@property CGFloat freeY;
@property BOOL dragging;
@property BOOL didMove;
@property NSPoint dragStartMouse;
@property NSPoint dragStartOrigin;
@property void (^onPillClicked)(void);
@property NSView *badgeView;
@property NSTextField *badgeLabel;
@property (nonatomic) NSInteger mode; // 0 = orb, 1 = bar
@property NSTimer *unpeekTimer;
@property NSView *barView;
@property NSStackView *barAgentStack;
@property NSButton *barLogoButton;
@property NSArray<CPAgent *> *agents;
@property CPAgent *selectedAgent;
- (void)show;
- (void)renderWithAgents:(NSArray<CPAgent *> *)agents selectedAgent:(CPAgent *)agent;
- (NSRect)dockRect;
- (void)setMode:(NSInteger)mode;
- (void)pillMouseDown:(NSEvent *)event;
- (void)pillMouseDragged:(NSEvent *)event;
- (void)pillMouseUp:(NSEvent *)event;
- (void)mouseEntered:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
@end

@implementation CPDockWindowController

static const CGFloat CPOrbSize = 56.0;
static const CGFloat CPStripWidth = 6.0;
static const CGFloat CPHotZone = 28.0;
static const CGFloat CPMargin = 18.0;
static const CGFloat CPSnapThreshold = 60.0;
static const CGFloat CPBarHeight = 48.0;
static const CGFloat CPBarItem = 34.0;
static const CGFloat CPBarWorkbenchWidth = 82.0;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.docked = NO;
    self.dockEdge = NSRectEdgeMaxX;
    self.mode = 0;
    [self buildWindow];
    return self;
}

- (void)buildWindow {
    self.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, CPOrbSize, CPOrbSize)
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; // Dock 始终深色
    self.window.level = NSStatusWindowLevel + 1;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = NO;
    self.window.hidesOnDeactivate = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary;
    self.window.ignoresMouseEvents = NO;

    CPDockPillView *pill = [[CPDockPillView alloc] initWithFrame:NSMakeRect(0, 0, CPOrbSize, CPOrbSize)];
    pill.controller = self;
    pill.wantsLayer = YES;
    self.pill = pill;
    self.window.contentView = pill;

    // Orb floating pill
    NSView *floatingPill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPOrbSize, CPOrbSize)];
    floatingPill.wantsLayer = YES;
    floatingPill.layer.backgroundColor = CPSurface().CGColor;
    floatingPill.layer.cornerRadius = CPOrbSize / 2.0;
    floatingPill.layer.borderWidth = 1.5;
    floatingPill.layer.borderColor = CPBorder().CGColor;
    floatingPill.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.18].CGColor;
    floatingPill.layer.shadowOffset = CGSizeMake(0, 8);
    floatingPill.layer.shadowRadius = 26.0;
    floatingPill.layer.shadowOpacity = 1.0;
    floatingPill.layer.shadowPath = [NSBezierPath bezierPathWithOvalInRect:floatingPill.bounds].CGPath;
    self.floatingPill = floatingPill;
    [pill addSubview:floatingPill];

    // Idle shadow pulse
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    pulse.fromValue = @0.72;
    pulse.toValue = @1.0;
    pulse.duration = 2.4;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [floatingPill.layer addAnimation:pulse forKey:@"idlePulse"];

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(15, 15, 26, 26)];
    iconView.image = CPSymbol(@"waveform.path.ecg", 22, CPAccent());
    iconView.contentTintColor = CPAccent();
    [floatingPill addSubview:iconView];
    self.iconView = iconView;

    // Badge: dynamic width pill, positioned at top-right
    NSView *badgeView = [[NSView alloc] initWithFrame:NSMakeRect(38, 38, 18, 16)];
    badgeView.wantsLayer = YES;
    badgeView.layer.backgroundColor = CPAccent().CGColor;
    badgeView.layer.cornerRadius = 8.0;
    badgeView.layer.shadowColor = [NSColor colorWithSRGBRed:0.0 green:0.0 blue:0.0 alpha:0.16].CGColor;
    badgeView.layer.shadowOffset = CGSizeMake(0, 2);
    badgeView.layer.shadowRadius = 4.0;
    badgeView.layer.shadowOpacity = 1.0;
    badgeView.hidden = YES;
    [floatingPill addSubview:badgeView];
    self.badgeView = badgeView;

    NSTextField *badgeLabel = [[NSTextField alloc] initWithFrame:badgeView.bounds];
    badgeLabel.stringValue = @"";
    badgeLabel.font = [NSFont systemFontOfSize:9 weight:NSFontWeightBold];
    badgeLabel.textColor = NSColor.whiteColor;
    badgeLabel.alignment = NSTextAlignmentCenter;
    badgeLabel.bordered = NO;
    badgeLabel.backgroundColor = NSColor.clearColor;
    badgeLabel.translatesAutoresizingMaskIntoConstraints = YES;
    [badgeView addSubview:badgeLabel];
    self.badgeLabel = badgeLabel;

    // Docked strip (orb mode only)
    NSView *stripView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPHotZone, CPOrbSize)];
    stripView.wantsLayer = YES;
    stripView.hidden = YES;
    self.stripView = stripView;
    [pill addSubview:stripView];

    NSView *stripLine = [[NSView alloc] initWithFrame:NSMakeRect(0, 8, CPStripWidth, CPOrbSize - 16)];
    stripLine.wantsLayer = YES;
    stripLine.layer.backgroundColor = CPAccent().CGColor;
    stripLine.layer.cornerRadius = CPStripWidth / 2.0;
    [stripView addSubview:stripLine];
    self.stripLine = stripLine;

    // Bar mode view
    [self buildBarView];

    [self updateTracking];
}

- (void)buildBarView {
    NSView *barView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 180, CPBarHeight)];
    barView.wantsLayer = YES;
    barView.layer.backgroundColor = CPSurface().CGColor;
    barView.layer.cornerRadius = CPBarHeight / 2.0;
    barView.layer.borderWidth = 1.0;
    barView.layer.borderColor = CPBorder().CGColor;
    barView.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.10].CGColor;
    barView.layer.shadowOffset = CGSizeMake(0, 4);
    barView.layer.shadowRadius = 18.0;
    barView.layer.shadowOpacity = 1.0;
    barView.toolTip = @"Codex Pulse 快捷栏：打开工作台或查看 Agent 状态";
    barView.hidden = YES;
    self.barView = barView;
    [self.pill addSubview:barView];

    NSButton *logo = [CPHoverButton buttonWithTitle:@"工作台" target:self action:@selector(barLogoClicked:)];
    logo.bordered = NO;
    logo.layer.cornerRadius = 16.0;
    logo.image = CPSymbol(@"waveform.path.ecg", 17, CPAccent());
    logo.imagePosition = NSImageLeading;
    logo.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    logo.contentTintColor = CPFg2();
    logo.toolTip = @"打开 Codex Pulse 工作台";
    logo.accessibilityLabel = @"打开工作台";
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    [logo.widthAnchor constraintEqualToConstant:CPBarWorkbenchWidth].active = YES;
    [logo.heightAnchor constraintEqualToConstant:32].active = YES;
    [barView addSubview:logo];
    self.barLogoButton = logo;

    NSView *divider = [[NSView alloc] initWithFrame:NSZeroRect];
    divider.wantsLayer = YES;
    divider.layer.backgroundColor = CPBorder().CGColor;
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    [barView addSubview:divider];

    NSStackView *agents = [NSStackView stackViewWithViews:@[]];
    agents.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    agents.spacing = 2;
    agents.alignment = NSLayoutAttributeCenterY;
    agents.translatesAutoresizingMaskIntoConstraints = NO;
    self.barAgentStack = agents;
    [barView addSubview:agents];

    [NSLayoutConstraint activateConstraints:@[
        [logo.leadingAnchor constraintEqualToAnchor:barView.leadingAnchor constant:8],
        [logo.centerYAnchor constraintEqualToAnchor:barView.centerYAnchor],
        [divider.leadingAnchor constraintEqualToAnchor:logo.trailingAnchor constant:2],
        [divider.centerYAnchor constraintEqualToAnchor:barView.centerYAnchor],
        [divider.widthAnchor constraintEqualToConstant:1],
        [divider.heightAnchor constraintEqualToConstant:22],
        [agents.leadingAnchor constraintEqualToAnchor:divider.trailingAnchor constant:6],
        [agents.trailingAnchor constraintEqualToAnchor:barView.trailingAnchor constant:-8],
        [agents.centerYAnchor constraintEqualToAnchor:barView.centerYAnchor],
        [agents.heightAnchor constraintEqualToConstant:CPBarItem]
    ]];
}

- (void)barLogoClicked:(id)sender {
    if (self.onPillClicked) self.onPillClicked();
}

- (void)barAgentClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx >= 0 && idx < (NSInteger)self.agents.count) {
        self.selectedAgent = self.agents[(NSUInteger)idx];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CPSelectAgent" object:self.selectedAgent];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CPOpenWorkbench" object:nil];
        [self renderDockAgents];
    }
}

- (void)renderDockAgents {
    while (self.barAgentStack.arrangedSubviews.count > 0) {
        NSView *v = self.barAgentStack.arrangedSubviews.lastObject;
        [self.barAgentStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    CGFloat agentWidths = 0;
    NSInteger visibleAgentCount = 0;
    for (CPAgent *agent in self.agents) {
        if (agent.placeholder) continue;
        NSString *buttonTitle = [NSString stringWithFormat:@"%@ · %@", agent.name, CPStatusTitle(agent.status)];
        NSButton *btn = [CPHoverButton buttonWithTitle:buttonTitle target:self action:@selector(barAgentClicked:)];
        btn.bordered = NO;
        btn.layer.borderWidth = 0.0;
        btn.image = CPSymbol(agent.iconName, 14, agent == self.selectedAgent ? CPAccent() : CPFg2());
        btn.imagePosition = NSImageLeading;
        btn.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        btn.contentTintColor = agent == self.selectedAgent ? CPAccent() : CPFg2();
        btn.tag = [self.agents indexOfObject:agent];
        btn.toolTip = [NSString stringWithFormat:@"查看 %@ · %@", agent.name, CPStatusTitle(agent.status)];
        btn.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", agent.name, CPStatusTitle(agent.status)];
        btn.wantsLayer = YES;
        btn.layer.cornerRadius = CPBarItem / 2.0;
        ((CPHoverButton *)btn).cpBaseBackground = agent == self.selectedAgent ? CPDyn(0.24, 0.32, 0.50, 0.20, 0.28, 0.45) : NSColor.clearColor;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        CGFloat labelWidth = [buttonTitle sizeWithAttributes:@{NSFontAttributeName: btn.font}].width;
        CGFloat itemWidth = MAX(68.0, labelWidth + 36.0);
        [btn.widthAnchor constraintEqualToConstant:itemWidth].active = YES;
        [btn.heightAnchor constraintEqualToConstant:CPBarItem].active = YES;
        [self.barAgentStack addArrangedSubview:btn];
        agentWidths += itemWidth;
        visibleAgentCount++;
    }
    CGFloat agentSpacing = visibleAgentCount > 1 ? (visibleAgentCount - 1) * 2.0 : 0;
    CGFloat width = 8 + CPBarWorkbenchWidth + 2 + 1 + 6 + agentWidths + agentSpacing + 8;
    self.barView.frame = NSMakeRect(0, 0, width, CPBarHeight);
    [self applyFrame];
}

- (void)updateTracking {
    if (self.trackingArea) [self.pill removeTrackingArea:self.trackingArea];
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.pill.bounds
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil];
    [self.pill addTrackingArea:self.trackingArea];
}

- (NSScreen *)targetScreen {
    return NSScreen.mainScreen ?: NSScreen.screens.firstObject;
}

- (NSRect)initialFrame {
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat x = NSMaxX(visible) - CPOrbSize - CPMargin;
    CGFloat y = NSMidY(visible) - CPOrbSize / 2.0;
    return NSMakeRect(x, y, CPOrbSize, CPOrbSize);
}

- (void)show {
    if (self.freeX == 0 && self.freeY == 0) {
        NSRect r = [self initialFrame];
        self.freeX = r.origin.x;
        self.freeY = r.origin.y;
    }
    [self applyFrame];
    [self.window orderFrontRegardless];
}

- (void)setMode:(NSInteger)mode {
    _mode = mode;
    self.docked = NO;
    [self cancelUnpeek];
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    if (mode == 0) {
        self.freeX = NSMaxX(visible) - CPOrbSize - CPMargin;
        self.freeY = NSMidY(visible) - CPOrbSize / 2.0;
    } else {
        NSRect r = [self barInitialFrame];
        self.freeX = r.origin.x;
        self.freeY = r.origin.y;
    }
    [self renderDockAgents];
    [self applyFrame];
}

- (NSRect)barInitialFrame {
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    NSRect rf = self.barView.frame;
    CGFloat x = NSMidX(visible) - rf.size.width / 2.0;
    CGFloat y = NSMinY(visible) + 24;
    return NSMakeRect(x, y, rf.size.width, rf.size.height);
}

- (CGFloat)currentWidth {
    return self.mode == 0 ? CPOrbSize : self.barView.frame.size.width;
}

- (CGFloat)currentHeight {
    return self.mode == 0 ? CPOrbSize : CPBarHeight;
}

- (void)applyFrame {
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat x, y, w, h;
    if (self.docked && self.mode == 0) {
        y = self.freeY;
        h = CPOrbSize;
        w = CPHotZone;
        if (self.dockEdge == NSRectEdgeMaxX) {
            x = NSMaxX(visible) - CPHotZone;
        } else {
            x = NSMinX(visible);
        }
        self.floatingPill.hidden = YES;
        self.barView.hidden = YES;
        self.stripView.hidden = NO;
        if (self.dockEdge == NSRectEdgeMaxX) {
            self.stripView.frame = NSMakeRect(CPHotZone - CPStripWidth, 0, CPStripWidth, CPOrbSize);
        } else {
            self.stripView.frame = NSMakeRect(0, 0, CPStripWidth, CPOrbSize);
        }
        self.stripLine.frame = NSMakeRect(0, 8, CPStripWidth, CPOrbSize - 16);
    } else {
        x = self.freeX;
        y = self.freeY;
        if (self.mode == 0) {
            w = CPOrbSize;
            h = CPOrbSize;
            self.floatingPill.hidden = NO;
            self.barView.hidden = YES;
            self.stripView.hidden = YES;
        } else {
            w = self.barView.frame.size.width;
            h = CPBarHeight;
            self.floatingPill.hidden = YES;
            self.barView.hidden = NO;
            self.stripView.hidden = YES;
        }
    }
    [self.window setFrame:NSMakeRect(x, y, w, h) display:YES];
    self.pill.frame = NSMakeRect(0, 0, w, h);
    [self updateTracking];
}

- (void)peek:(BOOL)show {
    if (!self.docked || self.mode != 0) return;
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat y = self.freeY;
    CGFloat h = CPOrbSize;
    CGFloat w = CPOrbSize;
    CGFloat x;
    if (self.dockEdge == NSRectEdgeMaxX) {
        x = NSMaxX(visible) - CPOrbSize;
    } else {
        x = NSMinX(visible);
    }
    [self.window setFrame:NSMakeRect(x, y, w, h) display:YES];
    self.pill.frame = NSMakeRect(0, 0, w, h);
    self.floatingPill.hidden = NO;
    self.barView.hidden = YES;
    self.stripView.hidden = YES;
    [self updateTracking];
}

- (void)unpeek {
    if (!self.docked || self.mode != 0) return;
    [self applyFrame];
    [self updateTracking];
}

- (void)scheduleUnpeek {
    [self cancelUnpeek];
    __weak typeof(self) weakSelf = self;
    self.unpeekTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:NO block:^(NSTimer *timer) {
        [weakSelf unpeek];
    }];
}

- (void)cancelUnpeek {
    [self.unpeekTimer invalidate];
    self.unpeekTimer = nil;
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.dragging) return;
    if (self.docked && self.mode == 0) {
        [self cancelUnpeek];
        [self peek:YES];
        [self updateTracking];
    } else if (!self.docked && self.mode == 0) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.floatingPill.animator.layer.transform = CATransform3DMakeScale(1.18, 1.18, 1.0);
            self.floatingPill.animator.layer.shadowRadius = 36.0;
            self.floatingPill.animator.layer.shadowColor = [CPAccent() colorWithAlphaComponent:0.28].CGColor;
            self.floatingPill.animator.layer.borderColor = CPAccent().CGColor;
            self.iconView.animator.frame = NSMakeRect(12, 12, 32, 32);
        }];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (self.dragging) return;
    if (self.docked && self.mode == 0) {
        [self scheduleUnpeek];
    } else if (!self.docked && self.mode == 0) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.22;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.floatingPill.animator.layer.transform = CATransform3DIdentity;
            self.floatingPill.animator.layer.shadowRadius = 26.0;
            self.floatingPill.animator.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.18].CGColor;
            self.floatingPill.animator.layer.borderColor = CPBorder().CGColor;
            self.iconView.animator.frame = NSMakeRect(15, 15, 26, 26);
        }];
    }
}

- (void)startPulseAnimation {
    if (self.mode != 0 || self.docked) return;
    [self.floatingPill.layer removeAnimationForKey:@"idlePulse"];
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    pulse.fromValue = @0.8;
    pulse.toValue = @1.0;
    pulse.duration = 2.2;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    pulse.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [self.floatingPill.layer addAnimation:pulse forKey:@"idlePulse"];
}

- (void)pillMouseDown:(NSEvent *)event {
    [self cancelUnpeek];
    self.dragging = YES;
    self.didMove = NO;
    self.dragStartMouse = [NSEvent mouseLocation];
    self.dragStartOrigin = self.window.frame.origin;
    if (self.docked) {
        self.docked = NO;
        NSPoint loc = self.dragStartMouse;
        self.freeX = loc.x - [self currentWidth] / 2.0;
        self.freeY = loc.y - [self currentHeight] / 2.0;
        [self applyFrame];
        self.dragStartOrigin = self.window.frame.origin;
    }
    if (self.mode == 0) {
        self.floatingPill.layer.transform = CATransform3DMakeScale(0.86, 0.86, 1.0);
        self.floatingPill.layer.shadowRadius = 18.0;
        self.floatingPill.layer.shadowColor = [CPAccent() colorWithAlphaComponent:0.35].CGColor;
    } else {
        self.barView.layer.transform = CATransform3DMakeScale(0.97, 0.97, 1.0);
    }
}

- (void)pillMouseDragged:(NSEvent *)event {
    if (!self.dragging) return;
    NSPoint loc = [NSEvent mouseLocation];
    CGFloat dx = loc.x - self.dragStartMouse.x;
    CGFloat dy = loc.y - self.dragStartMouse.y;
    if (fabs(dx) > 2 || fabs(dy) > 2) self.didMove = YES;
    self.freeX = self.dragStartOrigin.x + dx;
    self.freeY = self.dragStartOrigin.y + dy;
    [self applyFrame];
}

- (void)pillMouseUp:(NSEvent *)event {
    if (!self.dragging) return;
    self.dragging = NO;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        self.floatingPill.animator.layer.transform = CATransform3DIdentity;
        self.floatingPill.animator.layer.shadowRadius = 26.0;
        self.floatingPill.animator.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.18].CGColor;
        self.barView.animator.layer.transform = CATransform3DIdentity;
    }];
    if (self.didMove) {
        [self snapToEdge];
    } else if (self.onPillClicked) {
        self.onPillClicked();
    }
}

- (void)snapToEdge {
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat w = [self currentWidth];
    CGFloat h = [self currentHeight];
    CGFloat rightEdge = NSMaxX(visible) - w;
    if (self.mode == 0) {
        if (self.freeX <= NSMinX(visible) + CPSnapThreshold) {
            self.docked = YES;
            self.dockEdge = NSRectEdgeMinX;
            self.freeX = NSMinX(visible);
        } else if (self.freeX >= rightEdge - CPSnapThreshold) {
            self.docked = YES;
            self.dockEdge = NSRectEdgeMaxX;
            self.freeX = rightEdge;
        } else {
            self.docked = NO;
        }
    } else {
        self.docked = NO;
    }
    CGFloat maxY = NSMaxY(visible) - h - 8;
    CGFloat minY = NSMinY(visible) + 8;
    self.freeY = MAX(minY, MIN(self.freeY, maxY));
    [self applyFrame];
}

- (void)renderWithAgents:(NSArray<CPAgent *> *)agents selectedAgent:(CPAgent *)agent {
    self.agents = agents;
    self.selectedAgent = agent;
    NSInteger attention = 0;
    for (CPAgent *a in agents) for (CPTask *t in a.tasks) if (t.status == CPStatusAttention || t.status == CPStatusFailed) attention++;

    NSString *badgeText = [NSString stringWithFormat:@"%ld", (long)attention];
    CGFloat badgeW = 18.0;
    if (attention >= 10) badgeW = 22.0;
    if (attention >= 100) badgeW = 26.0;
    CGFloat badgeH = 16.0;
    CGFloat badgeX = CPOrbSize - badgeW - 3.0;
    CGFloat badgeY = CPOrbSize - badgeH - 3.0;

    self.badgeView.frame = NSMakeRect(badgeX, badgeY, badgeW, badgeH);
    self.badgeLabel.frame = self.badgeView.bounds;
    self.badgeLabel.stringValue = badgeText;
    self.badgeView.hidden = attention == 0;
    self.badgeLabel.hidden = attention == 0;
    [self renderDockAgents];
}

- (NSRect)dockRect {
    return self.window.frame;
}

@end

@implementation CPDockPillView
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return [hit isKindOfClass:NSButton.class] ? hit : self;
}
- (void)mouseDown:(NSEvent *)event { [self.controller pillMouseDown:event]; }
- (void)mouseDragged:(NSEvent *)event { [self.controller pillMouseDragged:event]; }
- (void)mouseUp:(NSEvent *)event { [self.controller pillMouseUp:event]; }
- (void)mouseEntered:(NSEvent *)event { [self.controller mouseEntered:event]; }
- (void)mouseExited:(NSEvent *)event { [self.controller mouseExited:event]; }
@end

#pragma mark - Status HUD

@interface CPProgressBarView : NSView
@property NSView *fillView;
@property (nonatomic) CGFloat progress; // 0.0 - 100.0
@end

@implementation CPProgressBarView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.backgroundColor = [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.12].CGColor;
    self.layer.cornerRadius = 2.0;

    NSView *fill = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 0, frame.size.height)];
    fill.wantsLayer = YES;
    fill.layer.backgroundColor = CPAccent().CGColor;
    fill.layer.cornerRadius = 2.0;
    [self addSubview:fill];
    self.fillView = fill;
    self.progress = 0.0;
    return self;
}

- (void)setProgress:(CGFloat)progress {
    _progress = MAX(0.0, MIN(100.0, progress));
    CGFloat width = self.bounds.size.width * (_progress / 100.0);
    self.fillView.frame = NSMakeRect(0, 0, width, self.bounds.size.height);
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self setProgress:self.progress];
}

@end

static const CGFloat CPHUDContentWidth = 320.0;
static const CGFloat CPHUDContentHeight = 200.0;
static const CGFloat CPHUDInset = 12.0;
static const CGFloat CPHUDCollapsedWidth = 6.0;
static const CGFloat CPHUDCollapsedHeight = 72.0;

@interface CPHUDBackgroundView : NSView
@property (weak) id target;
@property SEL action;
@end

@implementation CPHUDBackgroundView
- (void)mouseDown:(NSEvent *)event {
    if (self.target && self.action && [self.target respondsToSelector:self.action]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [self.target performSelector:self.action withObject:self];
#pragma clang diagnostic pop
    }
}
@end

@interface CPHUDWindowController : NSObject
@property NSPanel *window;
@property NSView *shadowCarrier;
@property NSVisualEffectView *visualView;
@property NSView *container;
@property NSView *handleView;
@property NSView *backgroundClickView;
@property NSTrackingArea *trackingArea;
@property NSTimer *hoverTimer;
@property BOOL expanded;
@property BOOL pendingCollapse;
@property NSArray<CPAgent *> *agents;
@property CPAgent *selectedAgent;
@property CPReviewStore *reviewStore;
@property NSStackView *agentList;
@property NSStackView *taskList;
@property NSTextField *agentNameLabel;
@property NSTextField *agentStatusLabel;
@property void (^onClicked)(void);
- (void)show;
- (void)updateWithAgents:(NSArray<CPAgent *> *)agents selectedAgent:(CPAgent *)agent;
- (NSRect)expandedFrameInVisibleRect:(NSRect)visible;
- (NSRect)collapsedFrameInVisibleRect:(NSRect)visible;
@end

@implementation CPHUDWindowController

static const CGFloat CPHUDAgentColumn = 84.0;

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.reviewStore = [[CPReviewStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(taskReviewed:)
                                                 name:@"CPTaskReviewed"
                                               object:nil];
    [self buildWindow];
    return self;
}

- (void)buildWindow {
    NSScreen *screen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    NSRect collapsedFrame = [self collapsedFrameInVisibleRect:visible];

    self.window = [[NSPanel alloc] initWithContentRect:collapsedFrame
                                             styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; // HUD 始终深色
    self.window.level = NSStatusWindowLevel + 2;
    self.window.opaque = NO;
    self.window.backgroundColor = NSColor.clearColor;
    self.window.hasShadow = NO;
    self.window.hidesOnDeactivate = NO;
    self.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                     NSWindowCollectionBehaviorFullScreenAuxiliary |
                                     NSWindowCollectionBehaviorStationary;
    self.window.ignoresMouseEvents = NO;

    self.shadowCarrier = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPHUDCollapsedWidth, CPHUDCollapsedHeight)];
    self.shadowCarrier.wantsLayer = YES;
    self.shadowCarrier.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.shadowCarrier.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.window.contentView = self.shadowCarrier;

    self.handleView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, CPHUDCollapsedWidth, CPHUDCollapsedHeight)];
    self.handleView.wantsLayer = YES;
    self.handleView.layer.backgroundColor = CPAccent().CGColor;
    self.handleView.layer.cornerRadius = CPHUDCollapsedWidth / 2.0;
    self.handleView.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.shadowCarrier addSubview:self.handleView];

    NSVisualEffectView *visualView = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(CPHUDInset, CPHUDInset, CPHUDContentWidth, CPHUDContentHeight)];
    visualView.material = NSVisualEffectMaterialHUDWindow;
    visualView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    visualView.state = NSVisualEffectStateActive;
    visualView.wantsLayer = YES;
    visualView.layer.cornerRadius = 18.0;
    visualView.layer.borderWidth = 1.0;
    visualView.layer.borderColor = [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.22].CGColor;
    visualView.layer.masksToBounds = YES;
    visualView.autoresizingMask = NSViewNotSizable;
    visualView.hidden = YES;
    self.visualView = visualView;
    [self.shadowCarrier addSubview:visualView];

    NSView *container = [[NSView alloc] initWithFrame:visualView.bounds];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [visualView addSubview:container];
    self.container = container;

    // Background click view behind all content so Agent buttons hit first.
    self.backgroundClickView = [[CPHUDBackgroundView alloc] initWithFrame:container.bounds];
    ((CPHUDBackgroundView *)self.backgroundClickView).target = self;
    ((CPHUDBackgroundView *)self.backgroundClickView).action = @selector(hudClicked:);
    self.backgroundClickView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:self.backgroundClickView positioned:NSWindowBelow relativeTo:nil];

    // Header
    NSTextField *title = [NSTextField labelWithString:@"Pulse"];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    title.textColor = CPFg();
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:title];

    NSTextField *time = [NSTextField labelWithString:[self currentTimeString]];
    time.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    time.textColor = CPMuted();
    time.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:time];

    // Agent column
    NSView *agentColumn = [[NSView alloc] initWithFrame:NSZeroRect];
    agentColumn.wantsLayer = YES;
    agentColumn.layer.backgroundColor = [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:0.06].CGColor;
    agentColumn.layer.cornerRadius = 12.0;
    agentColumn.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:agentColumn];

    NSTextField *agentHeader = [NSTextField labelWithString:@"AGENTS"];
    agentHeader.font = [NSFont systemFontOfSize:9 weight:NSFontWeightSemibold];
    agentHeader.textColor = CPMuted();
    agentHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [agentColumn addSubview:agentHeader];

    self.agentList = [NSStackView stackViewWithViews:@[]];
    self.agentList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.agentList.spacing = 2;
    self.agentList.alignment = NSLayoutAttributeCenterX;
    self.agentList.translatesAutoresizingMaskIntoConstraints = NO;
    [agentColumn addSubview:self.agentList];

    // Detail column
    NSTextField *agentName = [NSTextField labelWithString:@"Codex"];
    agentName.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
    agentName.textColor = CPFg();
    agentName.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:agentName];
    self.agentNameLabel = agentName;

    NSTextField *agentStatus = [NSTextField labelWithString:@"空闲"];
    agentStatus.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    agentStatus.textColor = CPMuted();
    agentStatus.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:agentStatus];
    self.agentStatusLabel = agentStatus;

    NSTextField *taskHeader = [NSTextField labelWithString:@"任务"];
    taskHeader.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    taskHeader.textColor = CPFg2();
    taskHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:taskHeader];

    self.taskList = [NSStackView stackViewWithViews:@[]];
    self.taskList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.taskList.spacing = 6;
    self.taskList.alignment = NSLayoutAttributeLeading;
    self.taskList.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.taskList];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:16],
        [title.topAnchor constraintEqualToAnchor:container.topAnchor constant:14],
        [time.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [time.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [agentColumn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:12],
        [agentColumn.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12],
        [agentColumn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12],
        [agentColumn.widthAnchor constraintEqualToConstant:CPHUDAgentColumn],

        [agentHeader.topAnchor constraintEqualToAnchor:agentColumn.topAnchor constant:10],
        [agentHeader.centerXAnchor constraintEqualToAnchor:agentColumn.centerXAnchor],

        [self.agentList.topAnchor constraintEqualToAnchor:agentHeader.bottomAnchor constant:8],
        [self.agentList.leadingAnchor constraintEqualToAnchor:agentColumn.leadingAnchor constant:6],
        [self.agentList.trailingAnchor constraintEqualToAnchor:agentColumn.trailingAnchor constant:-6],
        [self.agentList.bottomAnchor constraintLessThanOrEqualToAnchor:agentColumn.bottomAnchor constant:-8],

        [agentName.leadingAnchor constraintEqualToAnchor:agentColumn.trailingAnchor constant:14],
        [agentName.topAnchor constraintEqualToAnchor:agentColumn.topAnchor constant:10],
        [agentName.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-16],

        [agentStatus.leadingAnchor constraintEqualToAnchor:agentName.leadingAnchor],
        [agentStatus.topAnchor constraintEqualToAnchor:agentName.bottomAnchor constant:2],

        [taskHeader.leadingAnchor constraintEqualToAnchor:agentName.leadingAnchor],
        [taskHeader.topAnchor constraintEqualToAnchor:agentStatus.bottomAnchor constant:14],
        [taskHeader.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-16],

        [self.taskList.leadingAnchor constraintEqualToAnchor:taskHeader.leadingAnchor],
        [self.taskList.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-16],
        [self.taskList.topAnchor constraintEqualToAnchor:taskHeader.bottomAnchor constant:8],
        [self.taskList.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor constant:-12]
    ]];

    [self updateTimeLabel:time];
    [self updateTracking];
}

- (NSString *)currentTimeString {
    NSDateFormatter *f = NSDateFormatter.new;
    f.dateFormat = @"HH:mm";
    return [f stringFromDate:NSDate.date];
}

- (void)updateTimeLabel:(NSTextField *)label {
    label.stringValue = [self currentTimeString];
    __weak NSTextField *weakLabel = label;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self updateTimeLabel:weakLabel];
    });
}

- (void)hudClicked:(id)sender {
    if (self.onClicked) self.onClicked();
}

- (void)show {
    [self.window orderFrontRegardless];
    [self updateTracking];
}

- (void)updateTracking {
    if (self.trackingArea) [self.shadowCarrier removeTrackingArea:self.trackingArea];
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.shadowCarrier.bounds
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil];
    [self.shadowCarrier addTrackingArea:self.trackingArea];
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.expanded) return;
    [self cancelHoverTimer];
    __weak typeof(self) weakSelf = self;
    self.hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *timer) {
        [weakSelf expand];
    }];
}

- (void)mouseExited:(NSEvent *)event {
    [self cancelHoverTimer];
    if (!self.expanded) return;
    self.pendingCollapse = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        CPHUDWindowController *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pendingCollapse = NO;
        if (!NSPointInRect(NSEvent.mouseLocation, strongSelf.window.frame)) {
            [strongSelf collapse];
        }
    });
}

- (void)cancelHoverTimer {
    [self.hoverTimer invalidate];
    self.hoverTimer = nil;
}

- (NSScreen *)targetScreen {
    return NSScreen.screens.firstObject ?: NSScreen.mainScreen;
}

- (NSRect)expandedFrameInVisibleRect:(NSRect)visible {
    NSSize size = NSMakeSize(CPHUDContentWidth + CPHUDInset * 2.0, CPHUDContentHeight + CPHUDInset * 2.0);
    return CPRectAtTopRightOfVisibleFrame(visible, size);
}

- (NSRect)collapsedFrameInVisibleRect:(NSRect)visible {
    return CPRectAtTopRightOfVisibleFrame(visible, NSMakeSize(CPHUDCollapsedWidth, CPHUDCollapsedHeight));
}

- (NSRect)expandedFrame {
    return [self expandedFrameInVisibleRect:self.targetScreen.visibleFrame];
}

- (NSRect)collapsedFrame {
    return [self collapsedFrameInVisibleRect:self.targetScreen.visibleFrame];
}

- (void)layoutHandleToTopRightOfCarrier {
    NSSize sz = self.shadowCarrier.bounds.size;
    self.handleView.frame = NSMakeRect(MAX(0, sz.width - CPHUDCollapsedWidth),
                                       MAX(0, sz.height - CPHUDCollapsedHeight),
                                       CPHUDCollapsedWidth,
                                       CPHUDCollapsedHeight);
}

- (void)expand {
    if (self.expanded) return;
    self.expanded = YES;
    [self layoutHandleToTopRightOfCarrier];
    self.handleView.hidden = YES;
    self.visualView.hidden = NO;
    NSRect frame = [self expandedFrame];
    [self.window setFrame:frame display:YES animate:YES];
    self.shadowCarrier.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.18].CGColor;
    self.shadowCarrier.layer.shadowOffset = CGSizeMake(0, 8);
    self.shadowCarrier.layer.shadowRadius = 24.0;
    self.shadowCarrier.layer.shadowOpacity = 1.0;
    self.shadowCarrier.layer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(CPHUDInset, CPHUDInset, CPHUDContentWidth, CPHUDContentHeight) xRadius:18 yRadius:18].CGPath;
    [self updateTracking];
}

- (void)collapse {
    if (!self.expanded) return;
    self.expanded = NO;
    self.visualView.hidden = YES;
    [self layoutHandleToTopRightOfCarrier];
    self.handleView.hidden = NO;
    self.shadowCarrier.layer.shadowOpacity = 0.0;
    NSRect frame = [self collapsedFrame];
    [self.window setFrame:frame display:YES animate:YES];
    [self updateTracking];
}

- (void)agentButtonClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || idx >= (NSInteger)self.agents.count) return;
    self.selectedAgent = self.agents[(NSUInteger)idx];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CPSelectAgent" object:self.selectedAgent];
    [self render];
}

- (void)updateWithAgents:(NSArray<CPAgent *> *)agents selectedAgent:(CPAgent *)agent {
    // 按 agentID 映射保留选择，避免用旧对象指针导致状态错位；找不到才回退 firstObject。
    NSString *selectedID = agent.agentID ?: self.selectedAgent.agentID;
    CPAgent *match = nil;
    for (CPAgent *a in agents) {
        if (selectedID && [a.agentID isEqualToString:selectedID]) {
            match = a;
            break;
        }
    }
    self.agents = agents;
    self.selectedAgent = match ?: agents.firstObject;
    [self render];
}

- (void)taskReviewed:(NSNotification *)note {
    [self render];
}

- (void)render {
    CPAgent *agent = self.selectedAgent ?: self.agents.firstObject;
    if (!agent) return;

    self.agentNameLabel.stringValue = agent.name;
    CPDisplayStatus displayStatus = CPDisplayStatusForTasks(agent.tasks, agent.agentID, self.reviewStore);
    self.agentStatusLabel.stringValue = CPDisplayStatusTitle(displayStatus);
    self.agentStatusLabel.textColor = CPDisplayStatusColor(displayStatus);

    // Agent list
    while (self.agentList.arrangedSubviews.count > 0) {
        NSView *v = self.agentList.arrangedSubviews.lastObject;
        [self.agentList removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    for (NSUInteger i = 0; i < self.agents.count; i++) {
        CPAgent *a = self.agents[i];
        CPDisplayStatus ds = CPDisplayStatusForTasks(a.tasks, a.agentID, self.reviewStore);
        CPAgentStatusButton *btn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
        btn.reduceMotion = reduceMotion;
        btn.target = self;
        btn.action = @selector(agentButtonClicked:);
        btn.tag = (NSInteger)i;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn updateWithAgent:a displayStatus:ds selected:(a == agent)];
        [btn.widthAnchor constraintEqualToConstant:38].active = YES;
        [btn.heightAnchor constraintEqualToConstant:38].active = YES;
        [self.agentList addArrangedSubview:btn];
    }

    // Task list
    while (self.taskList.arrangedSubviews.count > 0) {
        NSView *v = self.taskList.arrangedSubviews.lastObject;
        [self.taskList removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // 右侧只渲染当前选中 Agent 的真实任务，不混入其他 Agent。
    NSArray<CPTask *> *displayTasks = agent.tasks;
    if (displayTasks.count == 0) {
        NSTextField *empty = [NSTextField labelWithString:@"当前没有任务"];
        empty.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        empty.textColor = CPMuted();
        [self.taskList addArrangedSubview:empty];
    } else {
        for (NSUInteger i = 0; i < displayTasks.count && i < 3; i++) {
            CPTask *t = displayTasks[i];
            NSStackView *row = [NSStackView stackViewWithViews:@[
                [self taskDot:t.status],
                [self taskLabel:t]
            ]];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.spacing = 8;
            row.alignment = NSLayoutAttributeTop;
            [self.taskList addArrangedSubview:row];
        }
    }
}

- (NSImageView *)taskDot:(CPStatus)status {
    NSImageView *v = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 7, 7)];
    v.image = CPStatusDot(7, status);
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.widthAnchor constraintEqualToConstant:7].active = YES;
    [v.heightAnchor constraintEqualToConstant:7].active = YES;
    return v;
}

- (NSStackView *)taskLabel:(CPTask *)task {
    NSTextField *title = [NSTextField labelWithString:task.title];
    title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    title.textColor = CPFg();
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.maximumNumberOfLines = 1;

    NSString *path = task.projectPath.length ? task.projectPath : @"—";
    NSTextField *meta = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ · %@", task.projectName, path]];
    meta.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    meta.textColor = CPMuted();
    meta.lineBreakMode = NSLineBreakByTruncatingMiddle;
    meta.maximumNumberOfLines = 1;

    NSTextField *activity = [NSTextField labelWithString:task.activity.length ? task.activity : @"—"];
    activity.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    activity.textColor = CPFg2();
    activity.lineBreakMode = NSLineBreakByTruncatingTail;
    activity.maximumNumberOfLines = 1;

    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateStyle = NSDateFormatterShortStyle;
    fmt.timeStyle = NSDateFormatterShortStyle;
    NSTextField *updated = [NSTextField labelWithString:[NSString stringWithFormat:@"更新于 %@", [fmt stringFromDate:task.updatedAt]]];
    updated.font = [NSFont systemFontOfSize:9 weight:NSFontWeightRegular];
    updated.textColor = CPMuted();

    NSStackView *s = [NSStackView stackViewWithViews:@[title, meta, activity, updated]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 1;
    return s;
}

@end

#pragma mark - Menu Popover

@interface CPMenuPopoverController : NSViewController
@property (nonatomic) NSArray<CPAgent *> *agents;
@end

@implementation CPMenuPopoverController

- (void)loadView {
    NSVisualEffectView *root = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 300, 320)];
    root.material = NSVisualEffectMaterialPopover;
    root.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.view = root;

    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(16, 16, 16, 16);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:root.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor]
    ]];

    NSTextField *title = CPLabel(@"Codex Pulse", 18, NSFontWeightSemibold, CPFg());
    title.font = [NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    [stack addArrangedSubview:title];
}

- (void)setAgents:(NSArray<CPAgent *> *)agents {
    _agents = agents;
    [self render];
}

- (void)render {
    NSStackView *stack = (NSStackView *)self.view.subviews.firstObject;
    while (stack.arrangedSubviews.count > 1) {
        NSView *v = stack.arrangedSubviews.lastObject;
        [stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    NSMutableArray<CPTask *> *attentionTasks = NSMutableArray.array;
    for (CPAgent *a in self.agents) {
        for (CPTask *t in a.tasks) {
            if (t.status == CPStatusAttention || t.status == CPStatusFailed) {
                [attentionTasks addObject:t];
            }
        }
    }

    NSTextField *section = CPLabel(@"需要关注", 10, NSFontWeightSemibold, CPMuted());
    [stack addArrangedSubview:section];

    if (!attentionTasks.count) {
        [stack addArrangedSubview:CPLabel(@"当前没有需要关注的任务。", 12, NSFontWeightRegular, CPMuted())];
    } else {
        for (CPTask *t in attentionTasks) {
            NSStackView *row = [NSStackView stackViewWithViews:@[
                [self dotView:t.status],
                [self taskText:t]
            ]];
            row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
            row.alignment = NSLayoutAttributeTop;
            row.spacing = 8;
            [stack addArrangedSubview:row];
        }
    }

    NSButton *open = [NSButton buttonWithTitle:@"打开工作台" target:self action:@selector(openWorkbench:)];
    open.bezelStyle = NSBezelStyleRounded;
    open.keyEquivalent = @"\r";
    [stack addArrangedSubview:open];
}

- (NSImageView *)dotView:(CPStatus)status {
    NSImageView *v = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 7, 7)];
    v.image = CPStatusDot(7, status);
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [v.widthAnchor constraintEqualToConstant:7].active = YES;
    [v.heightAnchor constraintEqualToConstant:7].active = YES;
    return v;
}

- (NSStackView *)taskText:(CPTask *)task {
    NSTextField *title = CPLabel(task.title, 12, NSFontWeightMedium, CPFg());
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    NSTextField *meta = CPLabel([NSString stringWithFormat:@"%@ · %@", task.projectName, CPStatusTitle(task.status)], 11, NSFontWeightRegular, CPMuted());
    NSStackView *s = [NSStackView stackViewWithViews:@[title, meta]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.spacing = 1;
    return s;
}

- (void)openWorkbench:(id)sender {
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CPOpenWorkbench" object:nil];
}

@end

#pragma mark - App Delegate

@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate>
@property NSStatusItem *statusItem;
@property NSPopover *popover;
@property CPMenuPopoverController *popoverController;
@property CPStateReader *reader;
@property NSTimer *timer;
@property CPDockWindowController *dock;
@property CPWorkbenchCardController *card;
@property CPHUDWindowController *hud;
@property NSArray<CPAgent *> *agents;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];

    self.reader = CPStateReader.new;
    self.agents = [self.reader readAgents];

    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"Codex Pulse"];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(togglePopover:);
    self.statusItem.menu = [self statusMenu];

    self.popoverController = CPMenuPopoverController.new;
    self.popoverController.agents = self.agents;

    self.popover = NSPopover.new;
    self.popover.behavior = NSPopoverBehaviorTransient;
    self.popover.contentSize = NSMakeSize(300, 320);
    self.popover.contentViewController = self.popoverController;
    self.popover.delegate = self;

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

    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode == 53 && weakSelf.card.isVisible) {
            [weakSelf.card handleEscape];
            return nil;
        }
        return event;
    }];

    self.timer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(refresh:) userInfo:nil repeats:YES];
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
    [self.popover close];
    [self showCard];
}

- (void)togglePopover:(id)sender {
    if (self.popover.shown) [self.popover close];
    else [self.popover showRelativeToRect:self.statusItem.button.bounds ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
}

- (void)openWorkbench:(NSNotification *)note {
    [self.popover close];
    [self showCard];
}

- (void)showCard {
    NSRect dockRect = self.dock.dockRect;
    [self.card showNearDockRect:dockRect edge:self.dock.dockEdge];
}

- (void)refresh:(id)sender {
    self.agents = [self.reader readAgents];
    self.popoverController.agents = self.agents;
    [self.card renderAgents:self.agents];
    [self.dock renderWithAgents:self.agents selectedAgent:self.card.selectedAgent];
    [self.hud updateWithAgents:self.agents selectedAgent:self.card.selectedAgent];
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

    NSInteger attention = 0;
    for (CPAgent *a in self.agents) for (CPTask *t in a.tasks) if (t.status == CPStatusAttention || t.status == CPStatusFailed) attention++;
    self.statusItem.button.toolTip = attention
        ? [NSString stringWithFormat:@"Codex Pulse · %ld 个任务需关注", (long)attention]
        : [NSString stringWithFormat:@"Codex Pulse · %@", CPStatusTitle(overall)];
}

- (void)popoverWillShow:(NSNotification *)notification {
    self.popoverController.agents = self.agents;
}

@end

#pragma mark - Main

static CPTask *CPTestTask(NSString *taskID, CPStatus status, NSTimeInterval updatedAt) {
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

static CPAgent *CPTestAgent(NSString *agentID, NSArray<CPTask *> *tasks) {
    CPAgent *a = CPAgent.new;
    a.agentID = agentID;
    a.name = agentID;
    a.iconName = @"sparkles";
    a.tasks = [NSMutableArray arrayWithArray:tasks];
    return a;
}

static BOOL CPAnotherInstanceIsRunning(void) {
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--ui-self-test") == 0) {
            [NSApplication sharedApplication];

            CPWorkbenchCardController *card = CPWorkbenchCardController.new;
            NSScreen *screen = NSScreen.screens.firstObject ?: NSScreen.mainScreen;
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
                                           fabs(card.window.frame.size.height - (CPCardHeight + CPWorkbenchInset * 2.0)) <= 0.5;
            BOOL fixedCardSize = fabs(card.card.frame.size.width - 520.0) <= 0.5 &&
                                 fabs(card.card.frame.size.height - 360.0) <= 0.5;
            NSStackView *columnsStack = (NSStackView *)card.leftColumn.superview;
            BOOL twoColumn = [columnsStack isKindOfClass:NSStackView.class] &&
                             columnsStack.arrangedSubviews.count == 2 &&
                             card.middleColumn.superview == columnsStack;
            BOOL rightOverlayHidden = card.rightColumn.hidden &&
                                      card.rightColumn.superview == card.middleColumn;

            NSArray<CPAgent *> *agents = [CPStateReader.new readAgents];
            CPDockWindowController *dock = CPDockWindowController.new;
            [dock renderWithAgents:agents selectedAgent:agents.firstObject];
            [dock setMode:1];
            [dock.barView layoutSubtreeIfNeeded];
            [dock.pill layoutSubtreeIfNeeded];

            BOOL labeledWorkbench = [dock.barLogoButton.title isEqualToString:@"工作台"] &&
                                    [dock.barLogoButton.toolTip containsString:@"工作台"];
            BOOL onlyRealAgents = dock.barAgentStack.arrangedSubviews.count == 1;
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
            BOOL hudExpanded344x224 = fabs(expandedSize.width - (CPHUDContentWidth + CPHUDInset * 2.0)) <= 0.5 &&
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
            NSRect carrierBounds = hud.shadowCarrier.bounds;
            NSRect handleFrame = hud.handleView.frame;
            BOOL hudVisualFrameExact = fabs(visualFrame.origin.x - CPHUDInset) <= 0.5 &&
                                       fabs(visualFrame.origin.y - CPHUDInset) <= 0.5 &&
                                       fabs(visualFrame.size.width - CPHUDContentWidth) <= 0.5 &&
                                       fabs(visualFrame.size.height - CPHUDContentHeight) <= 0.5;
            BOOL hudHandleTopRight = fabs(handleFrame.origin.x - (carrierBounds.size.width - CPHUDCollapsedWidth)) <= 0.5 &&
                                     fabs(handleFrame.origin.y - (carrierBounds.size.height - CPHUDCollapsedHeight)) <= 0.5 &&
                                     fabs(handleFrame.size.width - CPHUDCollapsedWidth) <= 0.5 &&
                                     fabs(handleFrame.size.height - CPHUDCollapsedHeight) <= 0.5;

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
                if (b.ringLayer.animationKeys.count != 0 || b.innerRingLayer.animationKeys.count != 0 ||
                    b.rippleLayerA.animationKeys.count != 0 || b.rippleLayerB.animationKeys.count != 0 ||
                    !b.rippleLayerA.hidden || !b.rippleLayerB.hidden) reduceMotionOK = NO;
            }
            CPAgentStatusButton *motionBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
            motionBtn.reduceMotion = NO;
            [motionBtn updateWithAgent:CPTestAgent(@"motion-test", @[]) displayStatus:CPDisplayStatusWorking selected:NO];
            CAAnimation *rippleA = [motionBtn.rippleLayerA animationForKey:@"rippleA"];
            CAAnimation *rippleB = [motionBtn.rippleLayerB animationForKey:@"rippleB"];
            BOOL motionAnimOK = rippleA != nil && rippleB != nil &&
                                rippleA.timeOffset != rippleB.timeOffset &&
                                rippleA.repeatCount > 1000.0f && rippleB.repeatCount > 1000.0f;
            CPAgentStatusButton *blueBtn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 38, 38)];
            blueBtn.reduceMotion = NO;
            [blueBtn updateWithAgent:CPTestAgent(@"blue-test", @[]) displayStatus:CPDisplayStatusCompletedPendingReview selected:NO];
            BOOL blueAnimOK = [blueBtn.rippleLayerA.animationKeys containsObject:@"rippleA"] &&
                              [blueBtn.rippleLayerB.animationKeys containsObject:@"rippleB"] &&
                              [blueBtn.innerRingLayer.animationKeys containsObject:@"rippleInner"] &&
                              CGColorEqualToColor(blueBtn.rippleLayerA.strokeColor, CPBlue().CGColor) &&
                              CGColorEqualToColor(blueBtn.rippleLayerB.strokeColor, CPBlue().CGColor) &&
                              CGColorEqualToColor(blueBtn.innerRingLayer.strokeColor, CPBlue().CGColor);

            CPHUDWindowController *hud2 = CPHUDWindowController.new;
            hud2.reviewStore = uiStore;
            CPAgent *agentA = CPTestAgent(@"agent-a", @[CPTestTask(@"a1", CPStatusWorking, 1),
                                                        CPTestTask(@"a2", CPStatusWaiting, 2)]);
            CPAgent *agentB = CPTestAgent(@"agent-b", @[CPTestTask(@"b1", CPStatusWorking, 1)]);
            [hud2 updateWithAgents:@[agentA, agentB] selectedAgent:agentB];
            BOOL hudAgentScope = [hud2.selectedAgent.agentID isEqualToString:@"agent-b"] &&
                                 hud2.taskList.arrangedSubviews.count == 1;
            if (hudAgentScope) {
                NSStackView *row = (NSStackView *)hud2.taskList.arrangedSubviews.firstObject;
                NSStackView *labelStack = row.arrangedSubviews.count > 1 ? (NSStackView *)row.arrangedSubviews[1] : nil;
                NSTextField *titleLabel = labelStack.arrangedSubviews.count ? (NSTextField *)labelStack.arrangedSubviews.firstObject : nil;
                hudAgentScope = [titleLabel isKindOfClass:NSTextField.class] &&
                                [titleLabel.stringValue isEqualToString:@"b1"];
            }
            CPAgent *agentANew = CPTestAgent(@"agent-a", @[CPTestTask(@"a9", CPStatusWorking, 9)]);
            CPAgent *agentBNew = CPTestAgent(@"agent-b", @[CPTestTask(@"b9", CPStatusWorking, 9)]);
            [hud2 updateWithAgents:@[agentANew, agentBNew] selectedAgent:agentB]; // stale pointer, same agentID
            BOOL hudSelectByID = hud2.selectedAgent == agentBNew;
            [uiDefaults removePersistentDomainForName:uiSuite];
            [uiDefaults synchronize];

            BOOL m2ui = ringColorsOK && blueDoubleOK && reduceMotionOK && motionAnimOK && blueAnimOK &&
                        hudAgentScope && hudSelectByID;

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

            NSButton *fakeRow = NSButton.new;
            fakeRow.tag = 1; // completed task w2
            [card2 taskClicked:fakeRow];
            BOOL drawerShownOnClick = !card2.rightColumn.hidden &&
                                      card2.rightColumn.superview == card2.middleColumn;
            BOOL reviewMarkedOnOpen = [card2.reviewStore isTaskReviewed:workAgent.tasks[1] agentID:@"w-agent"];

            [card2.window orderFrontRegardless];
            [card2 handleEscape];
            BOOL firstEscDrawerOnly = card2.rightColumn.hidden && card2.window.isVisible;
            [card2 handleEscape];
            BOOL secondEscClosesWorkbench = !card2.window.isVisible;
            [m3Defaults removePersistentDomainForName:m3Suite];
            [m3Defaults synchronize];

            BOOL m3ui = drawerInitiallyHidden && renderDoesNotMark && drawerShownOnClick &&
                        reviewMarkedOnOpen && firstEscDrawerOnly && secondEscClosesWorkbench;

            // M3 entries: every entry shows-and-fronts, never toggles closed
            CPWorkbenchCardController *card3 = CPWorkbenchCardController.new;
            NSRect fakeDockRect = NSMakeRect(NSMaxX(testVisible) - 56, NSMidY(testVisible), 56, 56);
            [card3 showNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            [card3 showNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            [card3 showNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            NSRect expectedTarget = [card3 targetFrameNearDockRect:fakeDockRect edge:NSRectEdgeMaxX];
            BOOL reshowVisible = card3.window.isVisible;
            BOOL reshowCentered = NSEqualRects(card3.window.frame, expectedTarget);
            BOOL reshowFixedSize = fabs(card3.window.frame.size.width - (CPCardWidth + CPWorkbenchInset * 2.0)) <= 0.5 &&
                                   fabs(card3.window.frame.size.height - (CPCardHeight + CPWorkbenchInset * 2.0)) <= 0.5;
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
            NSButton *m4Row = NSButton.new;
            m4Row.tag = 1;
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
            NSButton *m4Row0 = NSButton.new;
            m4Row0.tag = 0;
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
            for (NSInteger i = 0; i < 3; i++) {
                [hBtn updateWithAgent:hAgent displayStatus:CPDisplayStatusWorking selected:YES];
            }
            BOOL singleRippleKeys = [hBtn.rippleLayerA.animationKeys isEqualToArray:@[@"rippleA"]] &&
                                    [hBtn.rippleLayerB.animationKeys isEqualToArray:@[@"rippleB"]] &&
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
            BOOL taskCapOK = hud5.taskList.arrangedSubviews.count == 3; // HUD 最多 3 张任务卡
            BOOL titleTruncates = cleanTruncates;
            if (taskCapOK) {
                NSStackView *row = (NSStackView *)hud5.taskList.arrangedSubviews.firstObject;
                NSStackView *labelStack = row.arrangedSubviews.count > 1 ? (NSStackView *)row.arrangedSubviews[1] : nil;
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

            BOOL passed = centered && draggableHeader && labeledWorkbench && onlyRealAgents && labeledAgent && buttonReceivesClick &&
                          cardMasksToBounds && shadowCarrierNoMasks && cardIsChildOfShadowCarrier && windowHasWorkbenchInset &&
                          fixedCardSize && twoColumn && rightOverlayHidden &&
                          hudCollapsed6x72 && hudCollapsedOnMainScreen && hudExpanded344x224 && hudExpandedOnMainScreen &&
                          shadowCarrierScales && handleAnchoredTopRight && contentNotSizable && hudClickViewIsBackgroundView &&
                          hudVisualFrameExact && hudHandleTopRight && m2ui && m3ui && m3entries && m4ui && m5ui;
            NSMutableString *result = [NSMutableString stringWithFormat:
                @"Codex Pulse UI self-test: center=%@ drag=%@ workbench-label=%@ real-agents=%@ agent-label=%@ button-hit=%@ "
                @"card-mask=%@ carrier-mask=%@ card-child=%@ win-inset=%@ card-520x360=%@ two-column=%@ right-overlay=%@ "
                @"hud-6x72=%@ hud-collapsed-pos=%@ hud-344x224=%@ hud-expanded-pos=%@ "
                @"hud-carrier-scale=%@ hud-handle-tr=%@ hud-content-fixed=%@ hud-bg-click=%@ "
                @"hud-visual-frame=%@ hud-handle-pos=%@\n",
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
                hudExpanded344x224 ? @"OK" : @"FAIL",
                hudExpandedOnMainScreen ? @"OK" : @"FAIL",
                shadowCarrierScales ? @"OK" : @"FAIL",
                handleAnchoredTopRight ? @"OK" : @"FAIL",
                contentNotSizable ? @"OK" : @"FAIL",
                hudClickViewIsBackgroundView ? @"OK" : @"FAIL",
                hudVisualFrameExact ? @"OK" : @"FAIL",
                hudHandleTopRight ? @"OK" : @"FAIL"];
            [result appendFormat:@"M2 UI self-test: ring-colors=%@ blue-double=%@ reduce-motion=%@ ripple-anim=%@ ripple-blue=%@ hud-agent-scope=%@ hud-select-by-id=%@\n",
                ringColorsOK ? @"OK" : @"FAIL",
                blueDoubleOK ? @"OK" : @"FAIL",
                reduceMotionOK ? @"OK" : @"FAIL",
                motionAnimOK ? @"OK" : @"FAIL",
                blueAnimOK ? @"OK" : @"FAIL",
                hudAgentScope ? @"OK" : @"FAIL",
                hudSelectByID ? @"OK" : @"FAIL"];
            [result appendFormat:@"M3 UI self-test: drawer-init-hidden=%@ render-no-mark=%@ drawer-on-click=%@ review-on-open=%@ esc-drawer=%@ esc-workbench=%@\n",
                drawerInitiallyHidden ? @"OK" : @"FAIL",
                renderDoesNotMark ? @"OK" : @"FAIL",
                drawerShownOnClick ? @"OK" : @"FAIL",
                reviewMarkedOnOpen ? @"OK" : @"FAIL",
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
            if (!centered) {
                [result appendFormat:@"  diagnostic: testVisible=%@ cardFrame=%@ hasScreen=%@\n",
                 NSStringFromRect(testVisible), NSStringFromRect(cardFrame), hasScreen ? @"YES" : @"NO"];
            }
            fputs(result.UTF8String, stdout);
            fflush(stdout);
            if (argc > 2) {
                NSString *outputPath = [NSString stringWithUTF8String:argv[2]];
                [result writeToFile:outputPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            return passed ? 0 : 3;
        }
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            NSArray<CPAgent *> *agents = [CPStateReader.new readAgents];
            NSInteger taskCount = 0;
            for (CPAgent *a in agents) taskCount += a.tasks.count;
            printf("Codex Pulse self-test: %lu agents, %ld tasks, local read OK\n", (unsigned long)agents.count, (long)taskCount);

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

            [testDefaults removePersistentDomainForName:suite];
            [testDefaults synchronize];

            BOOL m2 = reviewUnseenFirst && reviewMarked && reviewResetOnNewSignature && reviewAgentIsolated &&
                      prFailed && prWaiting && prAttention && prBlue && prWorking && prIdle;
            NSString *m2line = [NSString stringWithFormat:
                @"M2 self-test: review-unseen=%@ review-marked=%@ review-resign=%@ review-agent-isolated=%@ "
                @"prio-failed=%@ prio-waiting=%@ prio-attention=%@ prio-blue=%@ prio-working=%@ prio-idle=%@\n",
                reviewUnseenFirst ? @"OK" : @"FAIL", reviewMarked ? @"OK" : @"FAIL",
                reviewResetOnNewSignature ? @"OK" : @"FAIL", reviewAgentIsolated ? @"OK" : @"FAIL",
                prFailed ? @"OK" : @"FAIL", prWaiting ? @"OK" : @"FAIL", prAttention ? @"OK" : @"FAIL",
                prBlue ? @"OK" : @"FAIL", prWorking ? @"OK" : @"FAIL", prIdle ? @"OK" : @"FAIL"];
            fputs(m2line.UTF8String, stdout);

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
            BOOL m6 = ctDirty && ctLooseTag && ctTranscript && ctPlain && ctNil && ctTrunc;
            NSString *m6line = [NSString stringWithFormat:
                @"M6 self-test: clean-dirty=%@ clean-loose-tag=%@ clean-transcript=%@ clean-plain=%@ clean-nil=%@ clean-truncate=%@\n",
                ctDirty ? @"OK" : @"FAIL", ctLooseTag ? @"OK" : @"FAIL", ctTranscript ? @"OK" : @"FAIL",
                ctPlain ? @"OK" : @"FAIL", ctNil ? @"OK" : @"FAIL", ctTrunc ? @"OK" : @"FAIL"];
            fputs(m6line.UTF8String, stdout);
            return (taskCount > 0 && m2 && m6) ? 0 : 2;
        }
        if (CPAnotherInstanceIsRunning()) return 0;
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
