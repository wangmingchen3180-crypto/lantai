#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <sqlite3.h>
#import <string.h>

#pragma mark - Constants

static BOOL CPRunningSelfTests = NO;
static BOOL CPTodoUseIsolatedStore = NO; // 仅 --ui-self-test:Todo 用临时库,不读写用户真实待办

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
// 8% 白色 hairline(对齐原型 --hairline: rgba(255,255,255,.08)):B 版待办卡片、输入框等
// 嵌入式描边专用,比 CPBorder 柔和一档。不改全局 CPBorder,控件描边语义保持不变。
static NSColor *CPHairline(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        BOOL dark = [match isEqualToString:NSAppearanceNameDarkAqua];
        return [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:dark ? 0.08 : 0.10];
    }];
}

#pragma mark - Status

typedef NS_ENUM(NSInteger, CPStatus) {
    CPStatusWorking, CPStatusWaiting, CPStatusAttention, CPStatusCompleted, CPStatusFailed, CPStatusIdle
};

static NSString *CPStatusTitle(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return @"工作中";
        case CPStatusWaiting: return @"等待中";
        case CPStatusAttention: return @"需关注";
        case CPStatusCompleted: return @"已就绪";
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
static NSDate *CPDateFromSeconds(NSTimeInterval v) { return v <= 0 ? nil : [NSDate dateWithTimeIntervalSince1970:v]; }

// 用 Codex rollout 的真实生命周期判断，而不是在调试日志正文里做关键词搜索。
// task_complete 持续为已完成，直到下一次 task_started；黄色只来自尚未返回的审批/输入调用。
static CPStatus CPInferTaskStatus(NSDate *lastLog, NSDate *lastStarted, NSDate *lastComplete,
                                  BOOL attentionPending, NSDate *lastError, NSDate *now) {
    if (attentionPending) return CPStatusAttention;
    BOOL activeTurn = lastStarted && (!lastComplete || [lastStarted compare:lastComplete] == NSOrderedDescending);
    if (activeTurn) {
        BOOL unresolvedError = lastError && [lastError compare:lastStarted] != NSOrderedAscending &&
                               (!lastLog || [lastError compare:lastLog] != NSOrderedAscending);
        if (unresolvedError) return CPStatusFailed;
        return CPStatusWorking;
    }
    if (lastComplete && (!lastStarted || [lastComplete compare:lastStarted] != NSOrderedAscending)) return CPStatusCompleted;
    if (lastLog && [now timeIntervalSinceDate:lastLog] < 12) return CPStatusWorking;
    return CPStatusIdle;
}

static NSInteger CPStatusTiePriority(CPStatus status) {
    switch (status) {
        case CPStatusFailed: return 5;
        case CPStatusAttention: return 4;
        case CPStatusWaiting: return 3;
        case CPStatusCompleted: return 2;
        case CPStatusWorking: return 1;
        case CPStatusIdle: return 0;
    }
}

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
    // 2.5) Markdown 链接 [label](url) / [label](url "title") 只保留可读 label;裸 chatgpt-conversation:// URI 直接移除。
    NSRegularExpression *mdLinkRe = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]*)\\]\\([^)\\s]+(?:\\s+\"[^\"]*\")?\\)" options:0 error:nil];
    value = [mdLinkRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@"$1"];
    NSRegularExpression *uriRe = [NSRegularExpression regularExpressionWithPattern:@"chatgpt-conversation://\\S+" options:0 error:nil];
    value = [uriRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
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

// Tokens 紧凑格式(全 app 统一):2.63M / 12.4k。
static NSString *CPFormatTokens(NSInteger tokens) {
    if (tokens >= 1000000) return [NSString stringWithFormat:@"%.2fM", tokens / 1000000.0];
    if (tokens >= 1000) return [NSString stringWithFormat:@"%.1fk", tokens / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)tokens];
}

// 中文本地时间格式(全 app 统一):7月8日 15:14。
static NSString *CPFormatDateCN(NSDate *date) {
    if (!date) return @"—";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"M月d日 HH:mm";
    return [fmt stringFromDate:date];
}

#pragma mark - Models

@interface CPTask : NSObject
@property NSString *taskID;
@property NSString *title;
@property NSString *projectPath;
@property NSString *projectName;
@property NSString *rolloutPath;
@property NSString *sourceKind; // 任务来源:"codex" / "kimi-client" / "kimi-cli"(未来 "claude" 等),路由按它分流
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

static CPDisplayStatus CPDisplayStatusForTask(CPTask *task, NSString *agentID, CPReviewStore *reviewStore) {
    (void)agentID;
    (void)reviewStore;
    switch (task.status) {
        case CPStatusFailed: return CPDisplayStatusFailed;
        case CPStatusAttention:
        case CPStatusWaiting: return CPDisplayStatusWaiting;
        case CPStatusCompleted: return CPDisplayStatusCompletedPendingReview;
        case CPStatusWorking: return CPDisplayStatusWorking;
        case CPStatusIdle: return CPDisplayStatusIdle;
    }
}

// Agent 灯代表最近更新的任务；仅在更新时间完全相同时才用严重度打破平局。
// 这样历史等待项不会长期压住一个已经重新运行的任务，也能真实呈现五种灯色。
static CPDisplayStatus CPDisplayStatusForTasks(NSArray<CPTask *> *tasks, NSString *agentID, CPReviewStore *reviewStore) {
    CPTask *latestTask = nil;
    CPDisplayStatus latestStatus = CPDisplayStatusIdle;
    for (CPTask *t in tasks) {
        CPDisplayStatus status = CPDisplayStatusForTask(t, agentID, reviewStore);
        NSComparisonResult order = latestTask ? [t.updatedAt compare:latestTask.updatedAt] : NSOrderedDescending;
        if (!latestTask || order == NSOrderedDescending || (order == NSOrderedSame && status > latestStatus)) {
            latestTask = t;
            latestStatus = status;
        }
    }
    return latestStatus;
}

#pragma mark - Unified Ripple Component (CPRippleView)

// 前向声明:涟漪组件需要在其实际定义(见下文 Agent Status Button 段)之前取状态色/标题。
static NSString *CPDisplayStatusTitle(CPDisplayStatus s);
static NSColor *CPDisplayStatusColor(CPDisplayStatus s);

// 定稿涟漪参数(ripple-selection-preview.html 逐轮确认):
// 8 层同心涟漪,每层明暗成对(一圈半透明白峰 + 一圈半透明黑谷紧邻,两层描边 CALayer 成对扩散);
// 基准周期 12s,层间错峰 1/8 周期(1.5s),缓入缓出(出发极平缓、中后程荡到外围);
// scale 1.0→1.55,线宽 2.0→0.5(能量摊薄),透明度长尾巴衰减(场上同时保持四五层)。
// 状态差异只调周期:失败最快、待机最慢;层数、曲线、错峰比例统一。
static CGFloat CPRippleDurationForStatus(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return 8.0;                 // 失败,最快
        case CPDisplayStatusWaiting: return 9.6;                // 等待处理
        case CPDisplayStatusCompletedPendingReview: return 10.8;// 完成待查验
        case CPDisplayStatusWorking: return 12.0;               // 运行中,基准周期
        case CPDisplayStatusIdle: return 14.0;                  // 待机,最慢
    }
}

// 水波时间曲线:缓入缓出,等价 CSS cubic-bezier(0.45, 0.08, 0.35, 1)——波刚出发几乎不推进,中后程荡到外围。
static CAMediaTimingFunction *CPRippleTimingFunction(void) {
    return [CAMediaTimingFunction functionWithControlPoints:0.45 :0.08 :0.35 :1.0];
}

// 8 层错峰涟漪公共参数:scale 1.0→1.55,lineWidth 2.0→0.5,层间错峰 = duration/8。
static const CGFloat CPRippleScaleTo = 1.55;
static const CGFloat CPRippleLineWidthFrom = 2.0;
static const CGFloat CPRippleLineWidthTo = 0.5;
static const NSInteger CPRippleLayerCount = 8;

// 明暗对的整体强度(HUD 深色底):白峰峰值 alpha ~0.22,黑谷 ~0.18;悬浮球(底更亮)略高。
static const CGFloat CPRippleCrestAlpha = 0.22;
static const CGFloat CPRippleTroughAlpha = 0.18;

// 单个涟漪动画组:扩散 + 透明度时间轴 + 线宽渐细,同一缓入缓出曲线,无限重复。
// 透明度时间轴(相对值乘 peakAlpha):0%→0,26%→峰值,45%→0.647,70%→0.329,88%→~0.06,100%→0。
static CAAnimationGroup *CPRippleAnimationGroup(CGFloat duration, CGFloat timeOffset, CGFloat peakAlpha) {
    CABasicAnimation *scale = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    scale.fromValue = @1.0;
    scale.toValue = @(CPRippleScaleTo);
    CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    fade.keyTimes = @[@0.0, @0.26, @0.45, @0.70, @0.88, @1.0];
    fade.values = @[@0.0,
                    @(peakAlpha),
                    @(peakAlpha * 0.55 / 0.85),
                    @(peakAlpha * 0.28 / 0.85),
                    @(peakAlpha * 0.05 / 0.85),
                    @0.0];
    CABasicAnimation *thin = [CABasicAnimation animationWithKeyPath:@"lineWidth"];
    thin.fromValue = @(CPRippleLineWidthFrom);
    thin.toValue = @(CPRippleLineWidthTo);
    CAAnimationGroup *group = [CAAnimationGroup animation];
    group.animations = @[scale, fade, thin];
    group.duration = duration;
    group.timeOffset = timeOffset;
    group.repeatCount = HUGE_VALF;
    group.timingFunction = CPRippleTimingFunction();
    group.removedOnCompletion = NO;
    return group;
}

// 明暗成对扩散:白峰(crest)与黑谷(trough)同相位、同周期,只 alpha 不同,层间错峰 duration/8。
static void CPRippleApplyPairAnimations(CAShapeLayer *crest, CAShapeLayer *trough, NSInteger index,
                                        CGFloat duration, CGFloat crestAlpha, CGFloat troughAlpha) {
    CGFloat offset = duration * (CGFloat)index / (CGFloat)CPRippleLayerCount;
    crest.hidden = NO;
    crest.opacity = 0.0; // 静态终值 0,动画从 timeOffset 相位接管,避免闪烁
    [crest addAnimation:CPRippleAnimationGroup(duration, offset, crestAlpha)
                 forKey:[NSString stringWithFormat:@"ripple%ld", (long)index]];
    trough.hidden = NO;
    trough.opacity = 0.0;
    [trough addAnimation:CPRippleAnimationGroup(duration, offset, troughAlpha)
                  forKey:[NSString stringWithFormat:@"trough%ld", (long)index]];
}

// 汇聚全部 agent 的最高优先状态(CPDisplayStatus 枚举值随严重度递增:idle < working < pending-review < waiting < failed)。
static CPDisplayStatus CPDisplayStatusForAgents(NSArray<CPAgent *> *agents, CPReviewStore *reviewStore) {
    CPDisplayStatus overall = CPDisplayStatusIdle;
    for (CPAgent *a in agents) {
        if (a.placeholder) continue;
        CPDisplayStatus s = CPDisplayStatusForTasks(a.tasks, a.agentID, reviewStore);
        if (s > overall) overall = s;
    }
    return overall;
}

// CPRippleView:统一水波组件(定稿规范)。
// - 固定中心:自身只承载描边圆环 layer,中心图标由宿主提供且永不缩放;
// - 固定基础环 baseRingLayer:固定半径、固定线宽,始终静止显示状态色;
// - 8 层明暗成对涟漪 rippleLayers(白峰)/rippleTroughLayers(黑谷):scale 1.0 → 1.55,
//   透明度 0→峰值→长尾巴衰减→0,lineWidth 2.0 → 0.5,缓入缓出(0.45,0.08,0.35,1),
//   repeat forever,层间 timeOffset = duration/8(基准 12s 即 1.5s)错拍;
// - 波层在组件内先于基础环加入,宿主把组件放在图标之下,波从图标边缘水面露出;
// - reduce motion:停止所有 CAAnimation,只留固定状态环(实色),不缩放不闪烁;
// - 组件按 1.55 倍扩散预留自身 frame,不改变父视图尺寸,也不改变宿主按钮 frame。
@interface CPRippleView : NSView
@property (nonatomic) CPDisplayStatus displayStatus; // 决定颜色与扩散速度
@property (nonatomic) BOOL reduceMotion;             // 停止动画,只留固定状态环(实色)
@property (nonatomic) BOOL rippleSuppressed;         // hover/drag 时暂时隐藏动效
@property (nonatomic) CGFloat ripplePeakOpacity;     // 白峰峰值 alpha(默认 0.22,悬浮球用 0.28 更明显)
@property (nonatomic, readonly) CAShapeLayer *baseRingLayer;
@property (nonatomic, readonly) NSArray<CAShapeLayer *> *rippleLayers;       // 8 层白峰
@property (nonatomic, readonly) NSArray<CAShapeLayer *> *rippleTroughLayers; // 8 层黑谷
- (instancetype)initWithRingDiameter:(CGFloat)diameter lineWidth:(CGFloat)lineWidth;
- (void)updateRipples;
- (void)invalidateRippleCache; // 宿主绕过 updateRipples 直接改层(如隐藏时移除动画)后,强制下次全量重应用
@end

@implementation CPRippleView {
    CGFloat _ringLineWidth; // 基础环静态线宽
    NSString *_appliedKey;  // 上次实际应用的参数签名:未变化时不再 remove/re-add 无限动画(防相位重启与合成抖动)
}

- (instancetype)initWithRingDiameter:(CGFloat)diameter lineWidth:(CGFloat)lineWidth {
    // frame 预留 1.55 倍扩散空间,放大后不会超出自身 bounds。
    CGFloat side = ceil(diameter * CPRippleScaleTo + 3.0);
    self = [super initWithFrame:NSMakeRect(0, 0, side, side)];
    if (!self) return nil;
    _displayStatus = CPDisplayStatusIdle;
    _ripplePeakOpacity = CPRippleCrestAlpha;
    _ringLineWidth = lineWidth;
    self.wantsLayer = YES;

    CGPoint center = CGPointMake(side / 2.0, side / 2.0);
    CAShapeLayer * (^makeRing)(CGFloat ringDiameter, NSColor *stroke) = ^CAShapeLayer *(CGFloat ringDiameter, NSColor *stroke) {
        CAShapeLayer *ring = [CAShapeLayer layer];
        // layer 必须有明确 bounds/position/anchorPoint,path 画在 layer-local bounds 内,
        // 否则 transform.scale 围绕默认零点缩放,弧线会漂移而不是绕中心同心扩散。
        ring.bounds = NSMakeRect(0, 0, side, side);
        ring.anchorPoint = CGPointMake(0.5, 0.5);
        ring.position = center;
        ring.fillColor = NSColor.clearColor.CGColor;
        ring.lineWidth = lineWidth;
        ring.path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(center.x - ringDiameter / 2.0,
                                                                      center.y - ringDiameter / 2.0,
                                                                      ringDiameter, ringDiameter)].CGPath;
        ring.strokeColor = stroke.CGColor;
        ring.hidden = YES;
        return ring;
    };
    // 波层沉在最底:先加 8 对涟漪(黑谷略靠外 1.2pt,与白峰紧邻成对),基础环在最上。
    NSMutableArray<CAShapeLayer *> *crests = [NSMutableArray arrayWithCapacity:CPRippleLayerCount];
    NSMutableArray<CAShapeLayer *> *troughs = [NSMutableArray arrayWithCapacity:CPRippleLayerCount];
    for (NSInteger i = 0; i < CPRippleLayerCount; i++) {
        CAShapeLayer *trough = makeRing(diameter + 2.4, NSColor.blackColor);
        CAShapeLayer *crest = makeRing(diameter, NSColor.whiteColor);
        [self.layer addSublayer:trough];
        [self.layer addSublayer:crest];
        [troughs addObject:trough];
        [crests addObject:crest];
    }
    _rippleLayers = crests;
    _rippleTroughLayers = troughs;
    _baseRingLayer = makeRing(diameter, NSColor.clearColor);
    _baseRingLayer.hidden = NO;
    [self.layer addSublayer:_baseRingLayer];
    return self;
}

- (NSArray<CAShapeLayer *> *)cpAllRippleLayers {
    return [self.rippleTroughLayers arrayByAddingObjectsFromArray:self.rippleLayers];
}

- (void)updateRipples {
    NSString *key = [NSString stringWithFormat:@"%ld|%d|%d|%.3f", (long)self.displayStatus,
                                               (int)self.reduceMotion, (int)self.rippleSuppressed, self.ripplePeakOpacity];
    if (_appliedKey && [_appliedKey isEqualToString:key]) return; // 参数未变:保留正在运行的动画
    _appliedKey = key;
    for (CAShapeLayer *ring in [self cpAllRippleLayers]) [ring removeAllAnimations];
    NSColor *color = CPDisplayStatusColor(self.displayStatus);
    // 固定基础环:固定半径、固定线宽、固定状态色,永不动画;reduce motion 时提升为实色固定环。
    self.baseRingLayer.strokeColor = [color colorWithAlphaComponent:self.reduceMotion ? 1.0 : 0.5].CGColor;
    self.baseRingLayer.lineWidth = _ringLineWidth;
    self.baseRingLayer.opacity = 1.0;
    self.baseRingLayer.hidden = NO;
    if (self.reduceMotion) {
        // 停止所有动画:只留固定状态环(实色),不缩放不闪烁。
        for (CAShapeLayer *ring in [self cpAllRippleLayers]) {
            ring.hidden = YES;
            ring.opacity = 1.0;
        }
        return;
    }
    if (self.rippleSuppressed) {
        for (CAShapeLayer *ring in [self cpAllRippleLayers]) ring.hidden = YES;
        return;
    }
    CGFloat duration = CPRippleDurationForStatus(self.displayStatus);
    CGFloat troughAlpha = self.ripplePeakOpacity * (CPRippleTroughAlpha / CPRippleCrestAlpha);
    for (NSInteger i = 0; i < CPRippleLayerCount; i++) {
        CPRippleApplyPairAnimations(self.rippleLayers[(NSUInteger)i], self.rippleTroughLayers[(NSUInteger)i],
                                    i, duration, self.ripplePeakOpacity, troughAlpha);
    }
}

- (void)invalidateRippleCache {
    _appliedKey = nil;
}

@end

#pragma mark - Helpers

static NSTextField *CPLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.maximumNumberOfLines = 2;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

// Reduce Motion:动画全部退化为立即切换,不留过渡。
static BOOL CPHoverReduceMotion(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

// hover wash 唯一动画入口:只动 overlay 的 opacity,不碰布局、不碰 borderWidth。
// 进入 120ms ease-out,退出 150ms ease-in-out;始终从 presentation 当前值起跳,
// 快速打断/反向时画面连续不闪;model opacity 先置为终态,动画结束或被移除都不弹回。
static void CPAnimateWashOpacity(CALayer *overlay, CGFloat target) {
    if (!overlay) return;
    if (CPHoverReduceMotion()) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        [overlay removeAllAnimations];
        overlay.opacity = target;
        [CATransaction commit];
        return;
    }
    CALayer *pres = (CALayer *)overlay.presentationLayer ?: overlay;
    CGFloat from = pres.opacity;
    // model 赋值必须禁隐式动画,否则与显式动画叠加、keys 堆积、时序不可控。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [overlay removeAllAnimations];
    overlay.opacity = target; // model 立即为终态
    [CATransaction commit];
    if (fabs(from - target) < 0.001) return;
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"opacity"];
    anim.fromValue = @(from);
    anim.toValue = @(target);
    BOOL entering = target > from;
    anim.duration = entering ? 0.12 : 0.15;
    anim.timingFunction = [CAMediaTimingFunction functionWithName:entering ? kCAMediaTimingFunctionEaseOut
                                                                            : kCAMediaTimingFunctionEaseInEaseOut];
    [overlay addAnimation:anim forKey:@"cpHoverFade"];
}

// 通用 hover/pressed 反馈按钮：独立白色 wash overlay 层，hover/pressed 只调 overlay
// 的 opacity(对照原型 4%~7% 白),不再用 .16 muted 灰块,也不再在 hover 时新增描边。
@interface CPHoverButton : NSButton
@property (nonatomic, strong) NSColor *cpBaseBackground;
@property (nonatomic) BOOL cpAlwaysBorder; // 常驻 1px 描边(如详情关闭按钮)
// 可选的视觉层:设置后底色/描边/wash 都画在这层上,按钮自身 layer 保持透明。
// 用于"点击热区 > 可见图形"的场景(如详情返回钮:24pt 热区 + 与标题行高等大的小圆)。
@property (nonatomic, strong) CALayer *cpVisualLayer;
@property (nonatomic, readonly) CALayer *cpHoverOverlay; // 自测断言用
@property (nonatomic) CGFloat cpHoverWash;   // hover 白 wash 不透明度,默认 0.07(图标钮);行级 0.04~0.05
@property (nonatomic) CGFloat cpPressedWash; // pressed 白 wash 不透明度,默认 0.10
@end

@implementation CPHoverButton {
    BOOL _cpHovered; // 显式 hover 状态:mouseEntered/Exited 维护,hide/移出窗口时强制复位
    CALayer *_cpHoverOverlay;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 6.0;
    self.layer.borderWidth = 0.0;
    self.layer.borderColor = CPBorder().CGColor;
    _cpHoverWash = 0.07;
    _cpPressedWash = 0.10;
    _cpHoverOverlay = [CALayer layer];
    _cpHoverOverlay.name = @"cpHoverWash";
    _cpHoverOverlay.backgroundColor = NSColor.whiteColor.CGColor;
    _cpHoverOverlay.opacity = 0.0;
    [self.layer addSublayer:_cpHoverOverlay];
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

- (CALayer *)cpOverlayHost {
    return self.cpVisualLayer ?: self.layer;
}

// overlay 始终铺满宿主层并跟随圆角,保证 wash 完整覆盖可见区域(如 Todo 收起整条 34pt)。
- (void)cpSyncOverlay {
    CALayer *host = self.cpOverlayHost;
    if (_cpHoverOverlay.superlayer != host) {
        [_cpHoverOverlay removeFromSuperlayer];
        [host insertSublayer:_cpHoverOverlay atIndex:0];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _cpHoverOverlay.frame = host.bounds;
    _cpHoverOverlay.cornerRadius = host.cornerRadius;
    [CATransaction commit];
}

- (void)layout {
    [super layout];
    [self cpSyncOverlay];
}

- (void)cpApplyBackground {
    [self cpSyncOverlay];
    BOOL hovered = _cpHovered && self.window && !self.isHiddenOrHasHiddenAncestor;
    CGFloat wash = self.isHighlighted ? self.cpPressedWash : (hovered ? self.cpHoverWash : 0.0);
    CPAnimateWashOpacity(_cpHoverOverlay, wash);
    CALayer *target = self.cpVisualTarget;
    target.borderWidth = self.cpAlwaysBorder ? 1.0 : 0.0;
    target.backgroundColor = (self.cpBaseBackground ?: NSColor.clearColor).CGColor;
}

- (CALayer *)cpVisualTarget {
    // 有视觉层时按钮自身 layer 不承载任何可见绘制,热区之外完全透明。
    if (self.cpVisualLayer) {
        if (self.cpVisualLayer != self.layer) {
            self.layer.borderWidth = 0.0;
            self.layer.backgroundColor = NSColor.clearColor.CGColor;
        }
        return self.cpVisualLayer;
    }
    return self.layer;
}

// hover 残留修复:视图被隐藏/移出窗口/换窗口时收不到 mouseExited,蒙层会停留;
// 在这些生命周期点强制复位 hover 状态并重刷外观,保证 mouseExited 语义一定恢复。
- (void)cpClearHover {
    _cpHovered = NO;
    [self cpApplyBackground];
}

// 立即清理(滚动/失焦/关闭):移除动画、禁隐式动画把 model opacity 直接归 0,
// 连续滚动时不会每帧重启 150ms 退出动画造成拖影,终态也不会有残留动画弹回。
- (void)cpClearHoverImmediate {
    _cpHovered = NO;
    CALayer *target = self.cpVisualTarget;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_cpHoverOverlay removeAllAnimations];
    _cpHoverOverlay.opacity = 0.0;
    target.borderWidth = self.cpAlwaysBorder ? 1.0 : 0.0;
    target.backgroundColor = (self.cpBaseBackground ?: NSColor.clearColor).CGColor;
    [CATransaction commit];
}

// 指针真实位置重校验:窗口移动/缩放(如切换 dock 模式、面板展开收回)时,静止的鼠标
// 相对按钮已经移出,但 tracking area 不会补发 mouseExited —— 必须按真实位置清掉 hover。
- (void)cpRevalidateHover {
    if (_cpHovered) {
        NSWindow *w = self.window;
        if (!w || self.isHiddenOrHasHiddenAncestor) {
            _cpHovered = NO;
        } else {
            NSPoint p = [self convertPoint:w.mouseLocationOutsideOfEventStream fromView:nil];
            if (!NSPointInRect(p, self.bounds)) _cpHovered = NO;
        }
    }
    [self cpApplyBackground];
}

- (void)cpObserveWindow:(NSWindow *)window {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self name:NSWindowDidMoveNotification object:nil];
    [center removeObserver:self name:NSWindowDidResizeNotification object:nil];
    if (window) {
        [center addObserver:self selector:@selector(cpRevalidateHover) name:NSWindowDidMoveNotification object:window];
        [center addObserver:self selector:@selector(cpRevalidateHover) name:NSWindowDidResizeNotification object:window];
    }
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidHide { [super viewDidHide]; [self cpClearHover]; }
- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    [self cpObserveWindow:self.window];
    [self cpClearHover];
}
- (void)removeFromSuperview { [self cpClearHover]; [super removeFromSuperview]; }

- (void)cpSetHovered:(BOOL)hovered { // mouseEntered/Exited 与自测共用的置态入口
    _cpHovered = hovered;
    [self cpApplyBackground];
}
- (void)mouseEntered:(NSEvent *)event { [super mouseEntered:event]; [self cpSetHovered:YES]; }
- (void)mouseExited:(NSEvent *)event { [super mouseExited:event]; [self cpSetHovered:NO]; }
- (void)setHighlighted:(BOOL)highlighted { [super setHighlighted:highlighted]; [self cpApplyBackground]; }
- (void)setCpBaseBackground:(NSColor *)color { _cpBaseBackground = color; [self cpApplyBackground]; }
- (void)setCpAlwaysBorder:(BOOL)flag { _cpAlwaysBorder = flag; [self cpApplyBackground]; }
- (void)setCpVisualLayer:(CALayer *)layer { _cpVisualLayer = layer; [self cpApplyBackground]; }
- (void)setCpHoverWash:(CGFloat)wash { _cpHoverWash = wash; [self cpApplyBackground]; }
- (void)setCpPressedWash:(CGFloat)wash { _cpPressedWash = wash; [self cpApplyBackground]; }

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

// 把官方 app 图标裁成 side x side 的圆形,放进状态环内。
static NSImage *CPCircularIcon(NSImage *source, CGFloat side) {
    NSSize size = NSMakeSize(side, side);
    NSImage *result = [[NSImage alloc] initWithSize:size];
    [result lockFocus];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, side, side)] addClip];
    [source drawInRect:NSMakeRect(0, 0, side, side)
              fromRect:NSMakeRect(0, 0, source.size.width, source.size.height)
             operation:NSCompositingOperationSourceOver fraction:1.0];
    [result unlockFocus];
    return result;
}

static NSArray<NSString *> *CPBundleIDsForAgent(NSString *agentID) {
    static NSDictionary<NSString *, NSArray<NSString *> *> *bundleMap = nil;
    if (!bundleMap) {
        bundleMap = @{
            @"codex": @[@"com.openai.codex", @"com.openai.chat"],
            @"kimi": @[@"com.moonshot.kimi", @"com.moonshot.kimichat"],
            @"kimi-cli": @[@"com.moonshot.kimi", @"com.moonshot.kimichat"],
            @"claude": @[@"com.anthropic.claudefordesktop", @"com.anthropic.claude"],
            @"terminal": @[@"com.apple.Terminal"],
            @"vscode": @[@"com.microsoft.VSCode"],
            @"cursor": @[@"com.todesktop.230313mzl4w4u92"],
        };
    }
    return bundleMap[agentID.lowercaseString] ?: @[];
}

// 官方图标回退:系统里装了对应 app(如 Codex / Claude / Terminal / VS Code)就用 NSWorkspace
// 官方图标(圆形裁切);取不到返回 nil,调用方回退到现有 SF Symbol 自绘方案。
static NSImage *CPAppIconForAgent(NSString *agentID, CGFloat side) {
    for (NSString *bundleID in CPBundleIDsForAgent(agentID)) {
        NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
        if (!appURL) continue;
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:appURL.path];
        if (icon) return CPCircularIcon(icon, side);
    }
    return nil;
}

// 返回可精确定位任务的 Agent 深链。未知/占位 Agent 返回 nil，由调用方降级为仅唤起应用。
// Kimi App 客户端会话使用它自身注册的 kimi-work://chat/<conversation-id>;
// Kimi Code CLI 会话无安全精确的 resume 入口,明确返回 nil(降级唤起 Kimi 客户端,不伪造成功)。
static NSURL *CPDeepLinkForAgentTask(CPAgent *agent, CPTask *task) {
    if (!agent || !task || !task.taskID.length || agent.placeholder) return nil;
    NSString *agentID = agent.agentID.lowercaseString;
    if ([agentID isEqualToString:@"codex"]) {
        NSString *escapedID = [task.taskID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        if (!escapedID.length) return nil;
        return [NSURL URLWithString:[NSString stringWithFormat:@"codex://threads/%@", escapedID]];
    }
    if ([agentID isEqualToString:@"kimi"]) {
        if (![task.sourceKind isEqualToString:@"kimi-client"] &&
            ![task.sourceKind isEqualToString:@"kimi-desktop"]) return nil;
        NSString *rawID = task.taskID;
        for (NSString *prefix in @[@"kimi-client-", @"kimi-desktop-"]) {
            if ([rawID hasPrefix:prefix]) { rawID = [rawID substringFromIndex:prefix.length]; break; }
        }
        NSString *escapedID = [rawID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        if (!escapedID.length) return nil;
        NSURL *probe = [NSURL URLWithString:@"kimi-work://"];
        if (!probe || ![NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:probe]) return nil; // 未注册客户端协议不试深链
        return [NSURL URLWithString:[NSString stringWithFormat:@"kimi-work://chat/%@", escapedID]];
    }
    return nil;
}

// 优先用任务深链精确跳转；不支持深链时至少唤起任务所属 Agent 应用。
static BOOL CPOpenAgentTask(CPAgent *agent, CPTask *task) {
    NSURL *deepLink = CPDeepLinkForAgentTask(agent, task);
    if (deepLink && [NSWorkspace.sharedWorkspace openURL:deepLink]) return YES;

    for (NSString *bundleID in CPBundleIDsForAgent(agent.agentID)) {
        NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
        if (running.count) {
            [running.firstObject activateWithOptions:NSApplicationActivateAllWindows];
            return YES;
        }
        NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
        if (!appURL) continue;
        NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
        configuration.activates = YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:appURL
                                            configuration:configuration
                                        completionHandler:nil];
        return YES;
    }
    return NO;
}

#pragma mark - Agent Status Button

static NSString *CPDisplayStatusTitle(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return @"失败";
        case CPDisplayStatusWaiting: return @"需关注";
        case CPDisplayStatusCompletedPendingReview: return @"已就绪"; // 完成事件的底层语义不变，界面统一显示「已就绪」
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

// 角标计数:需要用户处理且尚未查看的条目。
// 打开详情会记录当前 updatedAt 签名；任务再次更新后会自动重新出现。
static NSInteger CPBadgeCountForAgents(NSArray<CPAgent *> *agents, CPReviewStore *reviewStore) {
    NSInteger count = 0;
    for (CPAgent *a in agents) {
        if (a.placeholder) continue;
        for (CPTask *t in a.tasks) {
            switch (t.status) {
                case CPStatusFailed:
                case CPStatusAttention:
                case CPStatusWaiting:
                    if (![reviewStore isTaskReviewed:t agentID:a.agentID]) count++;
                    break;
                case CPStatusCompleted:
                    if (![reviewStore isTaskReviewed:t agentID:a.agentID]) count++;
                    break;
                case CPStatusWorking:
                case CPStatusIdle:
                    break;
            }
        }
    }
    return count;
}

// CPAgentStatusButton:HUD rail 的 Agent 状态按钮(方向 A 选中态)。
// 选中信息完全由状态环与涟漪承载:未选中 = 状态色细环(1.5px,opacity ~0.28)+ 涟漪静止;
// 选中 = 环变实色(opacity 1,线宽 2px)+ 8 层明暗成对涟漪常开(按状态周期);
// hover 未选中项只把环透明度提到 ~0.55,不起涟漪、不加背景蒙层(背景永远透明)。
// 无描边、无左侧指示条、无背景蒙层。
@interface CPAgentStatusButton : NSButton
@property NSString *agentID;
@property (nonatomic) BOOL reduceMotion;
@property (nonatomic) BOOL animationsPaused; // HUD 收起/不可见时暂停 8 层无限涟漪(可见性驱动降载)
@property CPDisplayStatus displayStatus;
@property BOOL statusSelected;
@property CAShapeLayer *ringLayer;
@property CAShapeLayer *innerRingLayer;
@property NSArray<CAShapeLayer *> *rippleLayers;       // 8 层白峰(波层在图标之下)
@property NSArray<CAShapeLayer *> *rippleTroughLayers; // 8 层黑谷
@property NSImageView *iconView;
- (void)updateWithAgent:(CPAgent *)agent displayStatus:(CPDisplayStatus)status selected:(BOOL)selected;
@end

@implementation CPAgentStatusButton {
    BOOL _hovered; // 显式 hover 状态,hide/移出窗口时强制复位,防止状态残留
    NSString *_appliedAnimKey; // 上次实际应用的动画参数签名:未变化时保留运行中的动画,不重启相位
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.bordered = NO;
    // NSButton 用 initWithFrame: 创建时会保留本地化默认标题（中文系统下是“按钮”）。
    // 图标由 iconView 单独绘制，必须清空 cell 标题，否则会压在图标下面。
    self.title = @"";
    self.image = nil;
    self.imagePosition = NSNoImage;
    // 阻止 NSButtonCell 在按下/highlight 时叠加系统高亮蒙层(用户感知的"蓝灰色罩子"):
    // 按钮的所有视觉(环/涟漪/hover)全部由自有 layer 与 iconView 绘制。
    ((NSButtonCell *)self.cell).highlightsBy = NSNoCellMask;
    ((NSButtonCell *)self.cell).showsStateBy = NSNoCellMask;
    self.wantsLayer = YES;
    self.layer.cornerRadius = 7.0;

    // 8 层明暗成对涟漪:白峰 + 黑谷紧邻,沉在所有 layer 最底(图标 iconView 是 subview,天然在波层之上)。
    NSMutableArray<CAShapeLayer *> *crests = [NSMutableArray arrayWithCapacity:CPRippleLayerCount];
    NSMutableArray<CAShapeLayer *> *troughs = [NSMutableArray arrayWithCapacity:CPRippleLayerCount];
    for (NSInteger i = 0; i < CPRippleLayerCount; i++) {
        CAShapeLayer *trough = [CAShapeLayer layer];
        trough.fillColor = NSColor.clearColor.CGColor;
        trough.strokeColor = NSColor.blackColor.CGColor;
        trough.lineWidth = 0.75;
        trough.hidden = YES;
        [self.layer addSublayer:trough];
        [troughs addObject:trough];
        CAShapeLayer *crest = [CAShapeLayer layer];
        crest.fillColor = NSColor.clearColor.CGColor;
        crest.strokeColor = NSColor.whiteColor.CGColor;
        crest.lineWidth = 0.75;
        crest.hidden = YES;
        [self.layer addSublayer:crest];
        [crests addObject:crest];
    }
    self.rippleTroughLayers = troughs;
    self.rippleLayers = crests;

    self.ringLayer = [CAShapeLayer layer];
    self.ringLayer.fillColor = NSColor.clearColor.CGColor;
    self.ringLayer.lineWidth = 1.5;
    self.ringLayer.opacity = 0.28; // 未选中:低透明度细环
    [self.layer addSublayer:self.ringLayer];

    // Second ring used only by the blue completed-pending-review double layer.
    self.innerRingLayer = [CAShapeLayer layer];
    self.innerRingLayer.fillColor = NSColor.clearColor.CGColor;
    self.innerRingLayer.lineWidth = 1.5;
    [self.layer addSublayer:self.innerRingLayer];

    self.iconView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    [self addSubview:self.iconView];
    return self;
}

- (void)layout {
    [super layout];
    CGRect b = self.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    CGPoint c = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
    // 状态环比按钮收小一圈(各留 3pt),按钮整体缩到 30x30 后视觉更轻。
    CGFloat outerR = side / 2.0 - 3.0;
    self.ringLayer.frame = b;
    self.ringLayer.path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - outerR, c.y - outerR, outerR * 2, outerR * 2)].CGPath;
    CGFloat innerR = MAX(outerR - 4.0, 1.0);
    self.innerRingLayer.frame = b;
    self.innerRingLayer.path = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - innerR, c.y - innerR, innerR * 2, innerR * 2)].CGPath;
    // 波纹与外圈同路径(黑谷略靠外 1.2pt 与白峰成对),动画按定稿规范从 1.0 倍扩散到 1.55 倍(绕中心同心外扩)。
    CGPathRef troughPath = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - outerR - 1.2, c.y - outerR - 1.2,
                                                                             (outerR + 1.2) * 2, (outerR + 1.2) * 2)].CGPath;
    for (NSInteger i = 0; i < CPRippleLayerCount; i++) {
        CAShapeLayer *crest = self.rippleLayers[(NSUInteger)i];
        crest.frame = b;
        crest.path = self.ringLayer.path;
        CAShapeLayer *trough = self.rippleTroughLayers[(NSUInteger)i];
        trough.frame = b;
        trough.path = troughPath;
    }
    // 图标缩到 13x13(原 16x16),与缩小的按钮/状态环比例协调。
    self.iconView.frame = NSMakeRect(c.x - 6.5, c.y - 6.5, 13, 13);
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
    NSImage *officialIcon = CPAppIconForAgent(agent.agentID, 13.0);
    if (officialIcon) {
        self.iconView.image = officialIcon;
        self.iconView.contentTintColor = nil; // 官方彩色图标不做单色 tint
    } else {
        self.iconView.image = CPSymbol(agent.iconName ?: @"sparkles", 11, CPFg2());
        self.iconView.contentTintColor = CPFg2();
    }
    // 方向 A 选中态:选中信息完全由状态环与涟漪承载,按钮背景永远透明、无描边、无指示条。
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    self.layer.borderWidth = 0.0;

    self.ringLayer.strokeColor = color.CGColor;
    BOOL doubleRing = status == CPDisplayStatusCompletedPendingReview;
    self.innerRingLayer.hidden = !doubleRing;
    self.innerRingLayer.strokeColor = color.CGColor;

    self.toolTip = [NSString stringWithFormat:@"%@ · %@", agent.name, CPDisplayStatusTitle(status)];
    self.accessibilityLabel = [NSString stringWithFormat:@"%@，%@", agent.name, CPDisplayStatusTitle(status)];

    [self setNeedsLayout:YES];
    [self layout];
    [self cpApplyRingState];
    [self applyAnimations];
}

// 状态环三档:选中实色(opacity 1,线宽 2px);hover 未选中 ~0.55(不起涟漪);未选中 ~0.28 细环。
- (void)cpApplyRingState {
    CGFloat opacity = self.statusSelected ? 1.0 : (_hovered ? 0.55 : 0.28);
    self.ringLayer.opacity = opacity;
    self.ringLayer.lineWidth = self.statusSelected ? 2.0 : 1.5;
    self.innerRingLayer.opacity = opacity;
}

// hover 只提状态环透明度一档,背景永远透明(蒙层 alpha 0 ≤ 0.03);hide/移出窗口时强制复位防残留。
- (void)cpApplyHover {
    if (self.isHighlighted) return;
    self.layer.backgroundColor = NSColor.clearColor.CGColor;
    [self cpApplyRingState];
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
- (void)mouseEntered:(NSEvent *)event { [super mouseEntered:event]; _hovered = YES; [self cpApplyHover]; }
- (void)mouseExited:(NSEvent *)event { [super mouseExited:event]; _hovered = NO; [self cpApplyHover]; }
- (void)viewDidHide { [super viewDidHide]; _hovered = NO; [self cpApplyHover]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; _hovered = NO; [self cpApplyHover]; }
- (void)setStatusSelected:(BOOL)selected {
    _statusSelected = selected;
    [self cpApplyHover];
}

- (NSArray<CAShapeLayer *> *)cpAllRippleLayers {
    return [self.rippleTroughLayers arrayByAddingObjectsFromArray:self.rippleLayers];
}

- (void)setAnimationsPaused:(BOOL)animationsPaused {
    _animationsPaused = animationsPaused;
    [self applyAnimations];
}

- (void)applyAnimations {
    NSString *key = [NSString stringWithFormat:@"%d|%d|%ld|%d", (int)self.reduceMotion, (int)self.statusSelected,
                                               (long)self.displayStatus, (int)self.animationsPaused];
    if (_appliedAnimKey && [_appliedAnimKey isEqualToString:key]) return; // 参数未变:不重建动画
    _appliedAnimKey = key;
    for (CAShapeLayer *ring in [self cpAllRippleLayers]) [ring removeAllAnimations];
    [self.innerRingLayer removeAllAnimations];
    if (self.reduceMotion || self.animationsPaused) {
        // 减少动态效果/宿主不可见:停止所有 CAAnimation,只留固定状态环(实色/细环由 cpApplyRingState 决定),不缩放不闪烁。
        for (CAShapeLayer *ring in [self cpAllRippleLayers]) {
            ring.hidden = YES;
            ring.opacity = 1.0;
            ring.lineWidth = 0.75;
        }
        return;
    }
    if (!self.statusSelected) {
        // 未选中:涟漪静止(隐藏),选中时才常开。
        for (CAShapeLayer *ring in [self cpAllRippleLayers]) ring.hidden = YES;
        return;
    }

    CGFloat duration = CPRippleDurationForStatus(self.displayStatus); // 定稿周期表 8s~14s
    for (NSInteger i = 0; i < CPRippleLayerCount; i++) {
        CAShapeLayer *crest = self.rippleLayers[(NSUInteger)i];
        CAShapeLayer *trough = self.rippleTroughLayers[(NSUInteger)i];
        crest.lineWidth = 0.75; // 静态终值;动画期内由 lineWidth 动画接管
        trough.lineWidth = 0.75;
        CPRippleApplyPairAnimations(crest, trough, i, duration, CPRippleCrestAlpha, CPRippleTroughAlpha);
    }

    if (!self.innerRingLayer.hidden) {
        // 待查验:内圈保留一条涟漪,形成双层波纹(特色保留)。
        [self.innerRingLayer addAnimation:CPRippleAnimationGroup(duration, duration / 4.0, CPRippleCrestAlpha) forKey:@"rippleInner"];
    }
}

@end

#pragma mark - State Reader

static const char *CPCodexVisibleThreadsSQL =
    "SELECT id, COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), '未命名任务'), "
    "cwd, created_at_ms, updated_at_ms, tokens_used, rollout_path FROM threads "
    "WHERE archived=0 AND preview<>'' "
    "AND COALESCE(thread_source,'') <> 'subagent' AND COALESCE(source,'') NOT LIKE '%\"subagent\"%' "
    "ORDER BY recency_at_ms DESC, updated_at_ms DESC LIMIT 10";

@interface CPRolloutState : NSObject
@property NSDate *lastStarted;
@property NSDate *lastComplete;
@property BOOL attentionPending;
@end
@implementation CPRolloutState @end

static NSDate *CPDateFromISO8601(NSString *value) {
    if (!value.length) return nil;
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = NSISO8601DateFormatter.new;
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter dateFromString:value];
}

// 只读 rollout 尾部，避免加载整段长会话；完成/启动事件都位于每轮末端。
static CPRolloutState *CPReadRolloutState(NSString *path) {
    CPRolloutState *state = CPRolloutState.new;
    if (!path.length) return state;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return state;

    NSData *tail = nil;
    @try {
        unsigned long long length = [handle seekToEndOfFile];
        unsigned long long start = length > 262144 ? length - 262144 : 0;
        [handle seekToFileOffset:start];
        tail = [handle readDataToEndOfFile];
        [handle closeFile];
        if (start > 0 && tail.length) {
            const uint8_t *bytes = tail.bytes;
            NSUInteger firstNewline = NSNotFound;
            for (NSUInteger i = 0; i < tail.length; i++) {
                if (bytes[i] == '\n') { firstNewline = i; break; }
            }
            if (firstNewline == NSNotFound || firstNewline + 1 >= tail.length) return state;
            tail = [tail subdataWithRange:NSMakeRange(firstNewline + 1, tail.length - firstNewline - 1)];
        }
    } @catch (__unused NSException *exception) {
        return state;
    }

    NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
    if (!text.length) return state;
    NSMutableDictionary<NSString *, NSDate *> *pendingAttention = NSMutableDictionary.dictionary;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *payload = entry[@"payload"];
        if (![payload isKindOfClass:NSDictionary.class]) continue;
        NSString *entryType = entry[@"type"];
        NSString *payloadType = payload[@"type"];
        NSDate *timestamp = CPDateFromISO8601(entry[@"timestamp"]);

        if ([entryType isEqualToString:@"event_msg"] && [payloadType isEqualToString:@"task_started"]) {
            state.lastStarted = timestamp;
            [pendingAttention removeAllObjects];
            continue;
        }
        if ([entryType isEqualToString:@"event_msg"] && [payloadType isEqualToString:@"task_complete"]) {
            state.lastComplete = timestamp;
            [pendingAttention removeAllObjects];
            continue;
        }
        if (![entryType isEqualToString:@"response_item"]) continue;
        if ([payloadType isEqualToString:@"custom_tool_call"] || [payloadType isEqualToString:@"function_call"]) {
            NSString *name = [payload[@"name"] description].lowercaseString;
            NSString *input = [payload[@"input"] description];
            BOOL asksForInput = [name containsString:@"request_user_input"];
            BOOL asksForApproval = [input containsString:@"sandbox_permissions"] && [input containsString:@"require_escalated"];
            if (asksForInput || asksForApproval) {
                NSString *callID = [payload[@"call_id"] description];
                if (!callID.length) callID = [payload[@"id"] description];
                if (callID.length) pendingAttention[callID] = timestamp ?: NSDate.distantPast;
            }
        } else if ([payloadType isEqualToString:@"custom_tool_call_output"] || [payloadType isEqualToString:@"function_call_output"]) {
            NSString *callID = [payload[@"call_id"] description];
            if (!callID.length) callID = [payload[@"id"] description];
            if (callID.length) [pendingAttention removeObjectForKey:callID];
        }
    }
    state.attentionPending = pendingAttention.count > 0;
    return state;
}

#pragma mark - Agent Source 边界

// 通用解析缓存:按 path+mtime+size 复用解析结果,文件未变不重复读盘/解析。
// state.json 小文件与 wire/context 有界尾部都走这里。
// 容量必须有界 LRU(默认 1024):本机 CLI 会话 ~414(state+wire 候选 ~500 条目)+ desktop + Codex rollout,
// 512 会只剩个位数余量,新增会话即触发顺序淘汰;1024 留出约一倍增长空间,仍有界防无限增长。
// 命中路径 O(1):条目带单调 accessTick,命中只更新 tick;不用 recency 数组
// (removeObject+addObject 是 O(n),600 条连续扫描即 O(n²),刷新期 CPU 抖动)。
// 仅新增且超容量时才扫描一次选最小 tick 逐出——逐出很罕见,均摊成本可忽略。
@interface CPStateCache : NSObject
@property (nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *entries; // path → {mtime,size,value,tick}
@property (nonatomic) uint64_t tick;     // 单调访问序号
@property (nonatomic) NSUInteger capacity; // 默认 1024,测试可调小验证逐出
- (id)objectForPath:(NSString *)path parser:(id (^)(NSString *path))parser;
@end

@implementation CPStateCache

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.capacity = 1024;
    return self;
}

- (id)objectForPath:(NSString *)path parser:(id (^)(NSString *path))parser {
    if (!path.length || !parser) return nil;
    if (!self.entries) self.entries = NSMutableDictionary.dictionary;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate] ?: NSDate.distantPast;
    NSNumber *size = attrs[NSFileSize] ?: @0;
    NSDictionary *cached = self.entries[path];
    self.tick++;
    if (cached && [cached[@"mtime"] isEqual:mtime] && [cached[@"size"] isEqual:size]) {
        // O(1) 命中:只重写 accessTick,不搬动任何队列
        self.entries[path] = @{@"mtime": cached[@"mtime"], @"size": cached[@"size"],
                               @"value": cached[@"value"], @"tick": @(self.tick)};
        id value = cached[@"value"];
        return [value isKindOfClass:NSNull.class] ? nil : value;
    }
    id value = parser(path) ?: NSNull.null;
    if (!cached && self.entries.count >= MAX(self.capacity, (NSUInteger)1)) {
        // 超容量才扫描一次,逐出 accessTick 最小(最久未用)的条目;绝不清空全表
        NSString *victim = nil;
        uint64_t oldest = UINT64_MAX;
        for (NSString *key in self.entries) {
            uint64_t t = [self.entries[key][@"tick"] unsignedLongLongValue];
            if (t < oldest) { oldest = t; victim = key; }
        }
        if (victim) [self.entries removeObjectForKey:victim];
    }
    self.entries[path] = @{@"mtime": mtime, @"size": size, @"value": value, @"tick": @(self.tick)};
    return [value isKindOfClass:NSNull.class] ? nil : value;
}

@end

// 应用内 Agent 注册表:内置适配器与用户启用状态分离。开源用户只需在“添加 Agent”
// 里选择已安装的客户端;提供新 harness 时只需新增 CPAgentSource 并在此目录注册。
static NSString * const CPEnabledAgentProvidersKey = @"agents.enabledProviders.v1";
static NSString * const CPAgentSourcesChangedNotification = @"CPAgentSourcesChanged";

static NSArray<NSDictionary *> *CPAgentProviderCatalog(void) {
    static NSArray<NSDictionary *> *catalog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalog = @[
            @{ @"id": @"codex", @"name": @"Codex", @"detail": @"Codex Desktop 本地任务" },
            @{ @"id": @"kimi", @"name": @"Kimi", @"detail": @"Kimi App 客户端任务" },
            @{ @"id": @"kimi-cli", @"name": @"Kimi CLI", @"detail": @"Kimi Code 终端会话（可选）" },
        ];
    });
    return catalog;
}

static NSArray<NSString *> *CPEnabledAgentProviderIDs(void) {
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:CPEnabledAgentProvidersKey];
    if (![stored isKindOfClass:NSArray.class]) return @[@"codex", @"kimi"];
    NSMutableArray<NSString *> *valid = NSMutableArray.array;
    NSSet *known = [NSSet setWithArray:[CPAgentProviderCatalog() valueForKey:@"id"]];
    for (id item in stored) if ([item isKindOfClass:NSString.class] && [known containsObject:item]) [valid addObject:item];
    return valid;
}

static BOOL CPAgentProviderIsDetected(NSString *providerID) {
    NSString *home = NSHomeDirectory();
    if ([providerID isEqualToString:@"codex"]) {
        return [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@".codex/state_5.sqlite"]];
    }
    if ([providerID isEqualToString:@"kimi"]) {
        NSString *db = [home stringByAppendingPathComponent:@"Library/Application Support/kimi-desktop/daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite"];
        return [NSFileManager.defaultManager fileExistsAtPath:db] ||
               [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.moonshot.kimichat"] != nil;
    }
    if ([providerID isEqualToString:@"kimi-cli"]) {
        return [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@".kimi-code/sessions"]];
    }
    return NO;
}

static void CPEnableAgentProvider(NSString *providerID) {
    if (!providerID.length) return;
    NSMutableArray<NSString *> *enabled = [CPEnabledAgentProviderIDs() mutableCopy];
    if (![enabled containsObject:providerID]) [enabled addObject:providerID];
    [NSUserDefaults.standardUserDefaults setObject:enabled forKey:CPEnabledAgentProvidersKey];
    [NSNotificationCenter.defaultCenter postNotificationName:CPAgentSourcesChangedNotification object:providerID];
}

// Agent 数据源边界:每个 harness(Codex / Kimi / 未来 Claude)实现一个 source,
// 统一输出 CPAgent/CPTask;CPStateReader 只负责按注册数组聚合,不理解任何来源细节。
@protocol CPAgentSource <NSObject>
- (CPAgent *)readAgent;
@end

// Agent 总体状态:取最近更新任务的状态(同刻按严重度决胜)。供各 source 复用。
static CPStatus CPOverallStatusForTasks(NSArray<CPTask *> *tasks) {
    CPTask *latest = nil;
    for (CPTask *t in tasks) {
        NSComparisonResult order = latest ? [t.updatedAt compare:latest.updatedAt] : NSOrderedDescending;
        if (!latest || order == NSOrderedDescending ||
            (order == NSOrderedSame && CPStatusTiePriority(t.status) > CPStatusTiePriority(latest.status))) latest = t;
    }
    return latest ? latest.status : CPStatusIdle;
}

@interface CPStateReader : NSObject
@property (nonatomic) CPStateCache *cache;
@property (nonatomic) NSArray<id<CPAgentSource>> *sources;
- (NSArray<CPAgent *> *)readAgents;
// rollout 尾部解析按 (mtime,size) 缓存:文件未变直接复用上轮结果,不重复读 256KB/逐行 JSON。
- (CPRolloutState *)rolloutStateForPath:(NSString *)path;
@end

#pragma mark - Codex Source

@interface CPCodexSource : NSObject <CPAgentSource>
@property (nonatomic) CPStateCache *cache;
- (instancetype)initWithCache:(CPStateCache *)cache;
@end

@implementation CPCodexSource

- (instancetype)initWithCache:(CPStateCache *)cache {
    self = [super init];
    if (!self) return nil;
    self.cache = cache;
    return self;
}

- (CPRolloutState *)rolloutStateForPath:(NSString *)path {
    if (!path.length) return CPRolloutState.new;
    CPRolloutState *state = [self.cache objectForPath:path parser:^id(NSString *p) { return CPReadRolloutState(p); }];
    return state ?: CPRolloutState.new;
}

- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"codex";
    agent.name = @"Codex";
    // 品牌图标近似:官方 Codex logo 位图不可直接打包(不引入外部资源),用 SF Symbol terminal.fill
    // 表达 CLI 形态 + accent 品牌色代替。
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

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(stateDB, CPCodexVisibleThreadsSQL, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)] ?: @"";
            task.title = CPCleanTitle(sqlite3_column_text(stmt, 1));
            task.projectPath = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 2)] ?: @"";
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Codex";
            task.createdAt = CPDateFromMillis(sqlite3_column_int64(stmt, 3));
            task.updatedAt = CPDateFromMillis(sqlite3_column_int64(stmt, 4));
            task.tokensUsed = (NSInteger)sqlite3_column_int64(stmt, 5);
            task.rolloutPath = sqlite3_column_text(stmt, 6)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 6)] : @"";
            task.sourceKind = @"codex";
            [self enrichTask:task logsDB:logsDB];
            [agent.tasks addObject:task];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(stateDB);
    if (logsDB) sqlite3_close(logsDB);

    agent.status = CPOverallStatusForTasks(agent.tasks);
    return agent;
}

- (void)enrichTask:(CPTask *)task logsDB:(sqlite3 *)logsDB {
    CPRolloutState *rollout = [self rolloutStateForPath:task.rolloutPath];
    if (!logsDB) {
        task.status = CPInferTaskStatus(nil, rollout.lastStarted, rollout.lastComplete,
                                        rollout.attentionPending, nil, NSDate.date);
        task.activity = task.status == CPStatusCompleted ? @"任务已完成" : @"正在整理任务状态";
        return;
    }
    const char *sql =
        "SELECT MAX(ts + ts_nanos / 1000000000.0), "
        "MAX(CASE WHEN level='ERROR' THEN ts + ts_nanos / 1000000000.0 ELSE 0 END) FROM logs WHERE thread_id=?";
    sqlite3_stmt *stmt = NULL;
    NSDate *lastLog = nil, *lastError = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, task.taskID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            lastLog = CPDateFromSeconds(sqlite3_column_double(stmt, 0));
            lastError = CPDateFromSeconds(sqlite3_column_double(stmt, 1));
        }
    }
    if (stmt) sqlite3_finalize(stmt);

    task.status = CPInferTaskStatus(lastLog, rollout.lastStarted, rollout.lastComplete,
                                    rollout.attentionPending, lastError, NSDate.date);

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

@end

#pragma mark - Kimi Source

// Kimi 数据根:生产主源是 Kimi App 自己的 conversations.sqlite;
// CLI 是独立的可选 Agent,旧 daimon-share/sessions 仅保留为兼容解析与回归 fixture。
static NSString *CPKimiClientDatabasePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLIENT_DB"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/kimi-desktop/daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite"];
}

static NSString *CPKimiClientStatusPath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLIENT_STATUS"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/kimi-desktop/kimi-agent/conversation-statuses.json"];
}

static NSString *CPKimiCLIRoot(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLI_ROOT"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".kimi-code/sessions"];
}

static NSString *CPKimiDesktopRoot(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_DESKTOP_ROOT"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/kimi-desktop/daimon-share/sessions"];
}

// state.json 两版 schema:v2 是 epoch 毫秒(NSNumber/数字字符串,cwd/id/archived),
// v1 是 ISO8601 字符串(workDir)。两种都要能吃。
static NSDate *CPKimiDateFromValue(id value) {
    if ([value isKindOfClass:NSNumber.class]) return CPDateFromMillis([value longLongValue]);
    if ([value isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)value;
        if (!s.length) return nil;
        if ([s rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) {
            return CPDateFromMillis(s.longLongValue);
        }
        return CPDateFromISO8601(s);
    }
    return nil;
}

// 只读文件尾部(对齐到行边界),绝不全量读大 wire。
static NSString *CPReadFileTail(NSString *path, unsigned long long maxBytes) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSData *tail = nil;
    @try {
        unsigned long long length = [handle seekToEndOfFile];
        unsigned long long start = length > maxBytes ? length - maxBytes : 0;
        [handle seekToFileOffset:start];
        tail = [handle readDataToEndOfFile];
        [handle closeFile];
        if (start > 0 && tail.length) {
            const uint8_t *bytes = tail.bytes;
            for (NSUInteger i = 0; i < tail.length; i++) {
                if (bytes[i] == '\n') {
                    tail = i + 1 < tail.length ? [tail subdataWithRange:NSMakeRange(i + 1, tail.length - i - 1)] : NSData.data;
                    break;
                }
            }
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
}

// wire 尾部摘要:两种 wire 格式(CLI:顶层 type + time 毫秒;desktop:message.type + timestamp 秒)归一成同一结构。
@interface CPKimiWireState : NSObject
@property BOOL turnActive;            // 尾部最后一个 turn 未见结束
@property NSString *lastEndReason;    // 最近一次 turn 结束原因(completed/cancelled/error…)
@property BOOL attentionPending;      // 未解决的用户输入请求 / 中断待处理
@property NSString *firstUserInput;   // desktop TurnBegin payload.user_input(标题兜底)
@property NSDate *lastEventAt;
@end
@implementation CPKimiWireState @end

static CPKimiWireState *CPKimiParseWireTail(NSString *text, BOOL desktopFormat) {
    CPKimiWireState *state = CPKimiWireState.new;
    if (!text.length) return state;
    NSMutableSet<NSString *> *pendingCalls = NSMutableSet.set;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![entry isKindOfClass:NSDictionary.class]) continue; // 坏行跳过,不崩溃
        if (desktopFormat) {
            NSDictionary *message = entry[@"message"];
            if (![message isKindOfClass:NSDictionary.class]) continue;
            NSString *type = message[@"type"];
            if (![type isKindOfClass:NSString.class]) continue;
            NSDate *when = CPDateFromSeconds([entry[@"timestamp"] doubleValue]);
            if (when) state.lastEventAt = when;
            NSDictionary *payload = [message[@"payload"] isKindOfClass:NSDictionary.class] ? message[@"payload"] : nil;
            if ([type isEqualToString:@"TurnBegin"]) {
                state.turnActive = YES;
                state.attentionPending = NO;
                NSString *input = [payload[@"user_input"] isKindOfClass:NSString.class] ? payload[@"user_input"] : nil;
                if (input.length && !state.firstUserInput) state.firstUserInput = input;
            } else if ([type isEqualToString:@"TurnEnd"]) {
                state.turnActive = NO;
                state.attentionPending = NO;
                state.lastEndReason = @"completed";
            } else if ([type isEqualToString:@"StepInterrupted"]) {
                if (state.turnActive) state.attentionPending = YES; // 回合中断,等待用户处理
            }
            continue;
        }
        // CLI 格式:{"type": "...", "time": <毫秒>, ...}
        NSString *type = [entry[@"type"] isKindOfClass:NSString.class] ? entry[@"type"] : nil;
        if (!type) continue;
        NSNumber *timeMs = [entry[@"time"] isKindOfClass:NSNumber.class] ? entry[@"time"] : nil;
        if (timeMs) state.lastEventAt = CPDateFromMillis(timeMs.longLongValue);
        if ([type isEqualToString:@"turn.ended"]) {
            state.turnActive = NO;
            NSString *reason = [entry[@"reason"] isKindOfClass:NSString.class] ? entry[@"reason"] : nil;
            state.lastEndReason = reason.length ? reason : @"completed";
            [pendingCalls removeAllObjects];
            state.attentionPending = NO;
            continue;
        }
        if ([type isEqualToString:@"turn.begin"]) {
            state.turnActive = YES;
            state.attentionPending = NO;
            [pendingCalls removeAllObjects];
            continue;
        }
        if ([type isEqualToString:@"llm.request"]) {
            state.turnActive = YES; // turn.begin 在尾部窗口之外时,请求即活跃 turn 证据
            continue;
        }
        if (![type isEqualToString:@"context.append_loop_event"]) continue;
        NSDictionary *event = [entry[@"event"] isKindOfClass:NSDictionary.class] ? entry[@"event"] : nil;
        NSString *eventType = [event[@"type"] isKindOfClass:NSString.class] ? event[@"type"] : nil;
        if ([eventType isEqualToString:@"step.begin"]) {
            state.turnActive = YES;
        } else if ([eventType isEqualToString:@"tool.call"]) {
            NSString *name = [[event[@"name"] ?: event[@"toolName"] ?: event[@"tool"] description] lowercaseString];
            NSString *uuid = [event[@"uuid"] description];
            if ([name containsString:@"askuserquestion"] && uuid.length) [pendingCalls addObject:uuid];
        } else if ([eventType isEqualToString:@"tool.result"]) {
            NSString *uuid = [event[@"uuid"] description];
            if (uuid.length) [pendingCalls removeObject:uuid];
        }
    }
    if (pendingCalls.count) state.attentionPending = YES;
    return state;
}

// Kimi 状态映射(保守可解释):
// 未解决的用户输入/中断 → waiting;活跃 turn 证据 + 最近 15 分钟内有活动(state updatedAt 或 wire 事件)→ working;
// 活跃 turn 但活动已旧 → idle(旧会话不得仅因最近修改永远 working);
// 明确 completed → completed,error/failed → failed,cancelled/interrupted 与无证据 → idle。
static CPStatus CPKimiStatus(NSString *stateReason, CPKimiWireState *wire, NSDate *activityAt, NSDate *now) {
    if (wire.attentionPending) return CPStatusWaiting;
    BOOL fresh = activityAt && [now timeIntervalSinceDate:activityAt] < 15 * 60;
    if (wire.turnActive) return fresh ? CPStatusWorking : CPStatusIdle;
    NSString *reason = stateReason.length ? stateReason : wire.lastEndReason;
    if ([reason isEqualToString:@"completed"]) return CPStatusCompleted;
    if ([reason isEqualToString:@"error"] || [reason isEqualToString:@"failed"]) return CPStatusFailed;
    return CPStatusIdle; // cancelled / interrupted / 无证据
}

// 会话最近活动时刻:max(state updatedAt, wire 尾部 lastEventAt)。
// turn 进行中 state.json 不刷新,长回合(>15 分钟)靠 wire 尾部事件的 lastEventAt 保活,不会误判 idle;
// 不用 wire 文件 mtime——仅被外部触碰而内容未变的旧会话不得因此显得活跃。
static NSDate *CPKimiActivityAt(NSDate *updatedAt, CPKimiWireState *wire) {
    NSDate *latest = updatedAt;
    if (wire.lastEventAt && (!latest || [wire.lastEventAt compare:latest] == NSOrderedDescending)) latest = wire.lastEventAt;
    return latest;
}

static NSString *CPKimiActivity(NSString *sourceLabel, CPStatus status) {
    NSString *phase = @"会话空闲";
    switch (status) {
        case CPStatusWorking: phase = @"回合进行中"; break;
        case CPStatusWaiting: phase = @"等待用户输入"; break;
        case CPStatusCompleted: phase = @"回合已完成"; break;
        case CPStatusFailed: phase = @"回合出错"; break;
        default: break;
    }
    return [NSString stringWithFormat:@"%@ · %@", sourceLabel, phase];
}

static NSString *CPKimiCleanTitle(NSString *raw) {
    return CPCleanTitle((const unsigned char *)(raw.length ? raw.UTF8String : NULL));
}

@interface CPKimiSource : NSObject <CPAgentSource>
@property (nonatomic) CPStateCache *cache;
@property (nonatomic) NSInteger lastClientCount;  // Kimi App conversations.sqlite 会话数
@property (nonatomic) NSInteger lastCLICount;     // 最近一次读取到的非归档 CLI 会话数(probe 用)
@property (nonatomic) NSInteger lastDesktopCount; // 最近一次读取到的 desktop 会话数(probe 用)
- (instancetype)initWithCache:(CPStateCache *)cache;
- (NSArray<CPTask *> *)readCLITasksIntoRawIDs:(NSMutableSet<NSString *> *)rawIDs;
@end

@implementation CPKimiSource

- (instancetype)initWithCache:(CPStateCache *)cache {
    self = [super init];
    if (!self) return nil;
    self.cache = cache;
    return self;
}

- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"kimi";
    agent.name = @"Kimi";
    agent.iconName = @"moon";
    agent.color = CPMuted();
    agent.placeholder = NO; // 真实数据源:目录不存在/无会话就是真空态,不再用示例占位
    agent.tasks = NSMutableArray.array;

    // 回归 fixture 保留旧 CLI/desktop 混合路径;真实应用中 Kimi 只读客户端本地索引,
    // 不再把数百个 CLI session 冒充成用户的 Kimi App 对话。
    BOOL legacyFixture = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLIENT_DB"] == nil &&
        (NSProcessInfo.processInfo.environment[@"CP_KIMI_CLI_ROOT"] != nil ||
         NSProcessInfo.processInfo.environment[@"CP_KIMI_DESKTOP_ROOT"] != nil);
    if (legacyFixture) {
        NSMutableSet<NSString *> *cliRawIDs = NSMutableSet.set;
        [agent.tasks addObjectsFromArray:[self readCLITasksIntoRawIDs:cliRawIDs]];
        [agent.tasks addObjectsFromArray:[self readDesktopTasksExcludingRawIDs:cliRawIDs]];
    } else {
        [agent.tasks addObjectsFromArray:[self readClientTasks]];
    }
    [agent.tasks sortUsingComparator:^NSComparisonResult(CPTask *a, CPTask *b) {
        return [b.updatedAt compare:a.updatedAt]; // 非归档会话按 updatedAt 降序
    }];
    while (agent.tasks.count > 50) [agent.tasks removeLastObject]; // 上限 50

    agent.status = CPOverallStatusForTasks(agent.tasks);
    return agent;
}

// Kimi App 3.x 的权威本地索引:
// .../hosted-logical/conversations.sqlite 提供标题、conversation id、workspace、时间与 wire 路径;
// conversation-statuses.json 以 conversation_key 为 key 提供 running/completed。两者都只读。
- (NSArray<CPTask *> *)readClientTasks {
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    self.lastClientCount = 0;
    NSString *dbPath = CPKimiClientDatabasePath();
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return tasks;
    }
    sqlite3_busy_timeout(db, 150);

    NSDictionary *statusMap = [self.cache objectForPath:CPKimiClientStatusPath() parser:^id(NSString *statusPath) {
        NSData *data = [NSData dataWithContentsOfFile:statusPath];
        id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
    }] ?: @{};

    const char *sql =
        "SELECT conversation_key, conversation_id, title, COALESCE(workspace_path,''), "
        "created_at_ms, updated_at_ms, COALESCE(kernel_records_path,'') "
        "FROM conversations ORDER BY updated_at_ms DESC LIMIT 50";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *(^textAt)(int) = ^NSString *(int column) {
                const unsigned char *value = sqlite3_column_text(stmt, column);
                return value ? [NSString stringWithUTF8String:(const char *)value] : @"";
            };
            NSString *conversationKey = textAt(0);
            NSString *conversationID = textAt(1);
            if (!conversationID.length) continue;
            NSString *wirePath = textAt(6);
            CPKimiWireState *wire = wirePath.length ? [self.cache objectForPath:wirePath parser:^id(NSString *p) {
                return CPKimiParseWireTail(CPReadFileTail(p, 65536), NO);
            }] : nil;
            wire = wire ?: CPKimiWireState.new;

            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithFormat:@"kimi-client-%@", conversationID];
            task.sourceKind = @"kimi-client";
            task.title = CPKimiCleanTitle(textAt(2));
            task.projectPath = textAt(3);
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Kimi";
            task.rolloutPath = wirePath;
            task.createdAt = CPDateFromMillis(sqlite3_column_int64(stmt, 4)) ?: NSDate.date;
            task.updatedAt = CPDateFromMillis(sqlite3_column_int64(stmt, 5)) ?: task.createdAt;
            NSDate *activityAt = CPKimiActivityAt(task.updatedAt, wire);
            if (activityAt) task.updatedAt = activityAt;

            NSString *clientState = [statusMap[conversationKey] isKindOfClass:NSString.class]
                ? [statusMap[conversationKey] lowercaseString] : @"";
            if (wire.attentionPending || [clientState isEqualToString:@"waiting"] || [clientState isEqualToString:@"attention"]) {
                task.status = CPStatusWaiting;
            } else if ([clientState isEqualToString:@"running"]) {
                task.status = CPStatusWorking;
            } else if ([clientState isEqualToString:@"failed"] || [clientState isEqualToString:@"error"]) {
                task.status = CPStatusFailed;
            } else if ([clientState isEqualToString:@"completed"]) {
                task.status = CPStatusCompleted;
            } else {
                task.status = CPKimiStatus(nil, wire, activityAt, NSDate.date);
            }
            task.activity = CPKimiActivity(@"Kimi App", task.status);
            [tasks addObject:task];
            self.lastClientCount += 1;
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return tasks;
}

// wire 候选预筛上限:state.json 小文件全部解析(便宜且缓存),wire 尾部只读活跃度最高的前 N 个会话。
// 展示上限 50,留 30 余量;排名靠后的会话即使状态有偏差也会在 cap 50 时被裁掉,不影响 UI。
static const NSInteger CPKimiWireCandidateLimit = 80;

// A) Kimi Code CLI:~/.kimi-code/sessions/<workspace>/<session>/state.json(小文件全量解析,按 mtime+size 缓存)。
// 两遍式:第一遍只解析 state.json(归档过滤/计数/标题/时间);第二遍按 max(updatedAt, wire mtime) 元数据
// 预筛出活跃候选,只有候选才读 wire 尾部做状态映射——避免每轮刷新对几百个会话全量 stat+读 wire。
- (NSArray<CPTask *> *)readCLITasksIntoRawIDs:(NSMutableSet<NSString *> *)rawIDs {
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    NSMutableArray<NSString *> *wirePaths = NSMutableArray.array;   // 与 tasks 平行;无 wire 为 @""
    NSMutableArray<NSDate *> *activityHints = NSMutableArray.array; // max(updatedAt, wire mtime),预筛排序用
    NSMutableArray<NSString *> *reasons = NSMutableArray.array;
    self.lastCLICount = 0;
    NSString *root = CPKimiCLIRoot();
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *workspaceDir in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *workspacePath = [root stringByAppendingPathComponent:workspaceDir];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:workspacePath isDirectory:&isDir] || !isDir) continue;
        for (NSString *sessionDir in [fm contentsOfDirectoryAtPath:workspacePath error:nil]) {
            NSString *sessionPath = [workspacePath stringByAppendingPathComponent:sessionDir];
            NSString *statePath = [sessionPath stringByAppendingPathComponent:@"state.json"];
            if (![fm fileExistsAtPath:statePath]) continue;
            NSDictionary *state = [self.cache objectForPath:statePath parser:^id(NSString *p) {
                NSData *data = [NSData dataWithContentsOfFile:p];
                if (!data.length) return nil;
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil; // 坏 JSON 跳过该会话
            }];
            if (!state) continue;
            if ([state[@"archived"] boolValue]) continue; // 归档默认不展示

            NSString *sessionID = [state[@"id"] isKindOfClass:NSString.class] && [state[@"id"] length]
                                      ? state[@"id"] : sessionDir;
            self.lastCLICount++;
            NSString *rawID = [sessionID hasPrefix:@"session_"] ? [sessionID substringFromIndex:8] : sessionID;
            [rawIDs addObject:rawID];

            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithFormat:@"kimi-cli-%@", sessionID];
            task.sourceKind = @"kimi-cli";
            task.projectPath = [state[@"cwd"] isKindOfClass:NSString.class] && [state[@"cwd"] length]
                                   ? state[@"cwd"]
                                   : ([state[@"workDir"] isKindOfClass:NSString.class] ? state[@"workDir"] : @"");
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Kimi";
            task.createdAt = CPKimiDateFromValue(state[@"createdAt"]) ?: NSDate.date;
            task.updatedAt = CPKimiDateFromValue(state[@"updatedAt"]) ?: task.createdAt;

            NSString *title = [state[@"title"] isKindOfClass:NSString.class] ? state[@"title"] : nil;
            NSString *lastPrompt = [state[@"lastPrompt"] isKindOfClass:NSString.class] ? state[@"lastPrompt"] : nil;
            // isCustomTitle 为真才信 title;否则用 lastPrompt(可能超长,CPCleanTitle 清洗+截断,绝不铺进 UI)。
            NSString *seed = ([state[@"isCustomTitle"] boolValue] && title.length) ? title
                                                                                   : (lastPrompt.length ? lastPrompt : title);
            task.title = CPKimiCleanTitle(seed);

            NSString *wirePath = [sessionPath stringByAppendingPathComponent:@"agents/main/wire.jsonl"];
            BOOL hasWire = [fm fileExistsAtPath:wirePath];
            NSDate *hint = task.updatedAt;
            if (hasWire) {
                NSDate *wireMtime = [fm attributesOfItemAtPath:wirePath error:nil][NSFileModificationDate];
                if (wireMtime && [wireMtime compare:hint] == NSOrderedDescending) hint = wireMtime;
            }
            [tasks addObject:task];
            [wirePaths addObject:hasWire ? wirePath : @""];
            [activityHints addObject:hint];
            NSString *reason = [state[@"lastTurnReason"] isKindOfClass:NSString.class] ? state[@"lastTurnReason"] : @"";
            [reasons addObject:reason];
        }
    }

    // 第二遍:按活跃度 hint 降序,前 CPKimiWireCandidateLimit 个候选才读 wire 有界尾部(64KB,缓存)。
    NSMutableArray<NSNumber *> *order = NSMutableArray.array;
    for (NSInteger i = 0; i < (NSInteger)tasks.count; i++) [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [activityHints[b.unsignedIntegerValue] compare:activityHints[a.unsignedIntegerValue]];
    }];
    NSMutableIndexSet *candidates = NSMutableIndexSet.indexSet;
    for (NSInteger i = 0; i < (NSInteger)order.count && i < CPKimiWireCandidateLimit; i++) {
        [candidates addIndex:order[i].unsignedIntegerValue];
    }
    NSDate *now = NSDate.date;
    for (NSUInteger i = 0; i < tasks.count; i++) {
        CPTask *task = tasks[i];
        CPKimiWireState *wire = CPKimiWireState.new;
        if ([candidates containsIndex:i] && [wirePaths[i] length]) {
            wire = [self.cache objectForPath:wirePaths[i] parser:^id(NSString *p) {
                return CPKimiParseWireTail(CPReadFileTail(p, 65536), NO);
            }] ?: CPKimiWireState.new;
            // 活跃会话的展示时间用真实活动时刻:长回合 state.updatedAt 不刷新,按它排序会被埋到列表底部。
            NSDate *activityAt = CPKimiActivityAt(task.updatedAt, wire);
            if (activityAt) task.updatedAt = activityAt;
        }
        task.status = CPKimiStatus(reasons[i], wire, CPKimiActivityAt(task.updatedAt, wire), now);
        task.activity = CPKimiActivity(@"Kimi Code CLI", task.status);
    }
    return tasks;
}

// B) Kimi 桌面 daimon:…/daimon-share/sessions/<hash>/<uuid>/{context.jsonl,wire.jsonl}。
// 格式不完整/字段缺失直接跳过该会话;context 只读前 256KB,wire 只读尾部 64KB。
- (NSArray<CPTask *> *)readDesktopTasksExcludingRawIDs:(NSSet<NSString *> *)cliRawIDs {
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    self.lastDesktopCount = 0;
    NSString *root = CPKimiDesktopRoot();
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *hashDir in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *hashPath = [root stringByAppendingPathComponent:hashDir];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:hashPath isDirectory:&isDir] || !isDir) continue;
        for (NSString *uuidDir in [fm contentsOfDirectoryAtPath:hashPath error:nil]) {
            NSString *sessionPath = [hashPath stringByAppendingPathComponent:uuidDir];
            NSString *wirePath = [sessionPath stringByAppendingPathComponent:@"wire.jsonl"];
            NSString *contextPath = [sessionPath stringByAppendingPathComponent:@"context.jsonl"];
            if (![fm fileExistsAtPath:wirePath] || ![fm fileExistsAtPath:contextPath]) continue;
            if ([cliRawIDs containsObject:uuidDir]) continue; // 跨源去重:CLI 已收录同一 session
            self.lastDesktopCount++;

            CPKimiWireState *wire = [self.cache objectForPath:wirePath parser:^id(NSString *p) {
                return CPKimiParseWireTail(CPReadFileTail(p, 65536), YES);
            }] ?: CPKimiWireState.new;

            // context.jsonl 头部:取第一条 role=="user" 的消息做标题种子;坏行/缺字段跳过。
            // 与 state/wire 一样纳入 path+mtime+size 缓存,文件未变不重复读 256KB/逐行解析。
            NSString *firstUser = [self.cache objectForPath:contextPath parser:^id(NSString *p) {
                NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:p];
                NSData *headData = nil;
                @try {
                    headData = [handle readDataOfLength:262144];
                    [handle closeFile];
                } @catch (__unused NSException *exception) {}
                NSString *head = headData ? [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding] : nil;
                for (NSString *line in [head componentsSeparatedByString:@"\n"]) {
                    if (!line.length) continue;
                    NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    if (![entry isKindOfClass:NSDictionary.class]) continue;
                    if (![entry[@"role"] isEqualToString:@"user"]) continue;
                    if ([entry[@"content"] isKindOfClass:NSString.class] && [entry[@"content"] length]) {
                        return entry[@"content"];
                    }
                }
                return nil;
            }];

            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithFormat:@"kimi-desktop-%@", uuidDir];
            task.sourceKind = @"kimi-desktop";
            // 桌面源无可验证 cwd 元数据:按 session 目录名降级。
            task.projectPath = uuidDir;
            task.projectName = uuidDir;
            NSDictionary *attrs = [fm attributesOfItemAtPath:contextPath error:nil];
            task.createdAt = attrs[NSFileCreationDate] ?: NSDate.date;
            task.updatedAt = wire.lastEventAt ?: (attrs[NSFileModificationDate] ?: task.createdAt);
            task.title = CPKimiCleanTitle(firstUser.length ? firstUser : wire.firstUserInput);
            task.status = CPKimiStatus(nil, wire, CPKimiActivityAt(task.updatedAt, wire), NSDate.date);
            task.activity = CPKimiActivity(@"Kimi 桌面", task.status);
            [tasks addObject:task];
        }
    }
    return tasks;
}

@end

#pragma mark - Optional Kimi CLI Source

// CLI 与 Kimi App 是两个产品面:只有用户在“添加 Agent”中显式启用时才展示。
@interface CPKimiCLISource : NSObject <CPAgentSource>
@property (nonatomic) CPKimiSource *parser;
- (instancetype)initWithCache:(CPStateCache *)cache;
@end

@implementation CPKimiCLISource
- (instancetype)initWithCache:(CPStateCache *)cache {
    self = [super init];
    if (!self) return nil;
    self.parser = [[CPKimiSource alloc] initWithCache:cache];
    return self;
}
- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"kimi-cli";
    agent.name = @"Kimi CLI";
    agent.iconName = @"terminal";
    agent.color = CPMuted();
    agent.placeholder = NO;
    NSMutableSet<NSString *> *rawIDs = NSMutableSet.set;
    agent.tasks = [[self.parser readCLITasksIntoRawIDs:rawIDs] mutableCopy];
    [agent.tasks sortUsingComparator:^NSComparisonResult(CPTask *a, CPTask *b) { return [b.updatedAt compare:a.updatedAt]; }];
    while (agent.tasks.count > 50) [agent.tasks removeLastObject];
    agent.status = CPOverallStatusForTasks(agent.tasks);
    return agent;
}
@end

#pragma mark - State Reader 聚合

@implementation CPStateReader

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.cache = CPStateCache.new;
    // 注册表即扩展点:适配器内置,用户的启用选择由“添加 Agent”持久化。
    NSMutableArray<id<CPAgentSource>> *configured = NSMutableArray.array;
    for (NSString *providerID in CPEnabledAgentProviderIDs()) {
        if ([providerID isEqualToString:@"codex"]) {
            [configured addObject:[[CPCodexSource alloc] initWithCache:self.cache]];
        } else if ([providerID isEqualToString:@"kimi"]) {
            [configured addObject:[[CPKimiSource alloc] initWithCache:self.cache]];
        } else if ([providerID isEqualToString:@"kimi-cli"]) {
            [configured addObject:[[CPKimiCLISource alloc] initWithCache:self.cache]];
        }
    }
    self.sources = configured;
    return self;
}

- (NSArray<CPAgent *> *)readAgents {
    NSMutableArray<CPAgent *> *agents = [NSMutableArray arrayWithCapacity:self.sources.count];
    for (id<CPAgentSource> source in self.sources) {
        CPAgent *agent = [source readAgent];
        if (agent) [agents addObject:agent];
    }
    return agents;
}

- (CPRolloutState *)rolloutStateForPath:(NSString *)path {
    if (!path.length) return CPRolloutState.new;
    CPRolloutState *state = [self.cache objectForPath:path parser:^id(NSString *p) { return CPReadRolloutState(p); }];
    return state ?: CPRolloutState.new;
}

@end

#pragma mark - Todo Store

// 轻量个人待办:独立于 Agent,与只读的 Codex 状态库完全无关。
// agent_id/thread_id 为 nullable 预留字段,供未来可选的 Agent 联动;当前 UI 恒不写入(恒 NULL)。
// Todo 计数只显示在工作台 Todo 栏内,绝不进入 HUD/Dock badge/悬浮球角标/Agent 状态灯等提醒聚合。

@interface CPTodo : NSObject
@property NSInteger todoID;
@property NSString *title;
@property BOOL completed;
@property NSString *agentID;  // 预留,当前恒为 nil
@property NSString *threadID; // 预留,当前恒为 nil
@property NSDate *createdAt;
@property NSDate *updatedAt;
@end
@implementation CPTodo @end

@interface CPTodoStore : NSObject
@property NSString *path;
+ (NSString *)defaultPath;
- (instancetype)initWithPath:(NSString *)path;
- (NSArray<CPTodo *> *)allTodos; // 未完成在前(created_at 升序),已完成在后
- (NSInteger)pendingCount;
- (CPTodo *)addTodoWithTitle:(NSString *)title;
- (void)setTodo:(NSInteger)todoID completed:(BOOL)completed;
- (void)updateTodo:(NSInteger)todoID title:(NSString *)title;
- (void)deleteTodo:(NSInteger)todoID;
@end

@implementation CPTodoStore {
    sqlite3 *_db;
}

+ (NSString *)defaultPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Codex Pulse"];
    return [dir stringByAppendingPathComponent:@"todos.sqlite"];
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;
    self.path = path;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    if (sqlite3_open_v2(path.UTF8String, &_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (_db) { sqlite3_close(_db); _db = NULL; }
        return nil;
    }
    sqlite3_busy_timeout(_db, 150);
    const char *sql =
        "CREATE TABLE IF NOT EXISTS todos("
        "id INTEGER PRIMARY KEY AUTOINCREMENT, "
        "title TEXT NOT NULL, "
        "completed INTEGER NOT NULL DEFAULT 0, "
        "agent_id TEXT NULL, "
        "thread_id TEXT NULL, "
        "created_at REAL NOT NULL, "
        "updated_at REAL NOT NULL)";
    sqlite3_exec(_db, sql, NULL, NULL, NULL);
    return self;
}

- (void)dealloc {
    if (_db) sqlite3_close(_db);
}

- (NSArray<CPTodo *> *)allTodos {
    NSMutableArray<CPTodo *> *todos = NSMutableArray.array;
    if (!_db) return todos;
    const char *sql = "SELECT id, title, completed, agent_id, thread_id, created_at, updated_at "
                      "FROM todos ORDER BY completed ASC, created_at ASC, id ASC";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            CPTodo *todo = CPTodo.new;
            todo.todoID = (NSInteger)sqlite3_column_int64(stmt, 0);
            todo.title = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 1)] ?: @"";
            todo.completed = sqlite3_column_int(stmt, 2) != 0;
            todo.agentID = sqlite3_column_text(stmt, 3)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 3)] : nil;
            todo.threadID = sqlite3_column_text(stmt, 4)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 4)] : nil;
            todo.createdAt = CPDateFromSeconds(sqlite3_column_double(stmt, 5)) ?: NSDate.date;
            todo.updatedAt = CPDateFromSeconds(sqlite3_column_double(stmt, 6)) ?: NSDate.date;
            [todos addObject:todo];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    return todos;
}

- (NSInteger)pendingCount {
    if (!_db) return 0;
    NSInteger count = 0;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, "SELECT COUNT(*) FROM todos WHERE completed=0", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) count = (NSInteger)sqlite3_column_int64(stmt, 0);
    }
    if (stmt) sqlite3_finalize(stmt);
    return count;
}

- (BOOL)exec:(const char *)sql bind:(void (^)(sqlite3_stmt *stmt))bind {
    if (!_db) return NO;
    sqlite3_stmt *stmt = NULL;
    BOOL ok = NO;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        if (bind) bind(stmt);
        ok = sqlite3_step(stmt) == SQLITE_DONE;
    }
    if (stmt) sqlite3_finalize(stmt);
    return ok;
}

- (CPTodo *)addTodoWithTitle:(NSString *)title {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL ok = [self exec:"INSERT INTO todos(title, completed, created_at, updated_at) VALUES(?, 0, ?, ?)"
                    bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_text(stmt, 1, trimmed.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 2, now);
        sqlite3_bind_double(stmt, 3, now);
    }];
    if (!ok) return nil;
    CPTodo *todo = CPTodo.new;
    todo.todoID = (NSInteger)sqlite3_last_insert_rowid(_db);
    todo.title = trimmed;
    todo.completed = NO;
    todo.createdAt = [NSDate dateWithTimeIntervalSince1970:now];
    todo.updatedAt = todo.createdAt;
    return todo;
}

- (void)setTodo:(NSInteger)todoID completed:(BOOL)completed {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    [self exec:"UPDATE todos SET completed=?, updated_at=? WHERE id=?"
         bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_int(stmt, 1, completed ? 1 : 0);
        sqlite3_bind_double(stmt, 2, now);
        sqlite3_bind_int64(stmt, 3, todoID);
    }];
}

- (void)updateTodo:(NSInteger)todoID title:(NSString *)title {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    [self exec:"UPDATE todos SET title=?, updated_at=? WHERE id=?"
         bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_text(stmt, 1, trimmed.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 2, NSDate.date.timeIntervalSince1970);
        sqlite3_bind_int64(stmt, 3, todoID);
    }];
}

- (void)deleteTodo:(NSInteger)todoID {
    [self exec:"DELETE FROM todos WHERE id=?"
         bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_int64(stmt, 1, todoID);
    }];
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
// 允许成为 initialFirstResponder:把自动焦点挡在拖动头,Todo 输入框只有被点击才进入编辑。
- (BOOL)acceptsFirstResponder { return YES; }
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

// 滚动容器内使用的翻转 stack:首个任务在顶部。
@interface CPFlippedStackView : NSStackView
@end
@implementation CPFlippedStackView
- (BOOL)isFlipped { return YES; }
@end

// Todo 行(B 版):hover 时行底色经独立 wash overlay 淡入(对照原型 .row:hover 5% 白),
// 并同时放行尾编辑铅笔与删除垃圾桶;非 hover 两个动作钮完全透明,绝不常驻抢眼。
// 与按钮同一套可中断 opacity 动画;hide/移出窗口/移出父视图时强制复位,不留残留。
@interface CPTodoRowView : NSView
@property (nonatomic, weak) NSButton *cpDeleteButton;
@property (nonatomic, weak) NSButton *cpEditButton;
@property (nonatomic, readonly) CALayer *cpHoverOverlay; // 自测断言用
@end
@implementation CPTodoRowView {
    BOOL _cpRowHovered;
    CALayer *_cpHoverOverlay;
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
- (void)cpEnsureOverlay {
    if (_cpHoverOverlay || !self.layer) return;
    _cpHoverOverlay = [CALayer layer];
    _cpHoverOverlay.name = @"cpHoverWash";
    _cpHoverOverlay.backgroundColor = NSColor.whiteColor.CGColor;
    _cpHoverOverlay.opacity = 0.0;
    [self.layer insertSublayer:_cpHoverOverlay atIndex:0];
}
- (void)layout {
    [super layout];
    [self cpEnsureOverlay];
    if (_cpHoverOverlay) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _cpHoverOverlay.frame = self.layer.bounds;
        _cpHoverOverlay.cornerRadius = self.layer.cornerRadius;
        [CATransaction commit];
    }
}
- (void)cpSetRowHovered:(BOOL)hovered {
    _cpRowHovered = hovered;
    [self cpEnsureOverlay];
    [self layout];
    CPAnimateWashOpacity(_cpHoverOverlay, hovered ? 0.05 : 0.0);
    // 行尾动作钮同步淡入淡出(NSViewAnimator 天然可中断接续)。
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = CPHoverReduceMotion() ? 0.0 : (hovered ? 0.12 : 0.15);
        self.cpDeleteButton.animator.alphaValue = hovered ? 1.0 : 0.0;
        self.cpEditButton.animator.alphaValue = hovered ? 1.0 : 0.0;
    }];
}
// 立即清理(滚动/失焦/关闭):overlay 与行尾动作组直接归 0,不重启退出动画。
- (void)cpClearRowHoverImmediate {
    _cpRowHovered = NO;
    [self cpEnsureOverlay];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [_cpHoverOverlay removeAllAnimations];
    _cpHoverOverlay.opacity = 0.0;
    self.cpDeleteButton.alphaValue = 0.0;
    self.cpEditButton.alphaValue = 0.0;
    [CATransaction commit];
}
- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self cpSetRowHovered:YES];
}
- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [self cpSetRowHovered:NO];
}
// 生命周期兜底:收不到 mouseExited 的场景(hide/移出窗口/刷新重建移除)一律复位。
- (void)viewDidHide { [super viewDidHide]; [self cpSetRowHovered:NO]; }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; if (!self.window) [self cpSetRowHovered:NO]; }
- (void)removeFromSuperview { [self cpSetRowHovered:NO]; [super removeFromSuperview]; }
@end

// Todo 删除钮(B 版垃圾桶):平时透明(由行 hover 放行),hover 图标本身时变红(danger)。
@interface CPTodoDeleteButton : CPHoverButton
@end
@implementation CPTodoDeleteButton
- (void)cpSetHovered:(BOOL)hovered {
    [super cpSetHovered:hovered];
    NSColor *tint = hovered ? CPRed() : CPMuted();
    self.image = CPSymbol(@"trash", 11, tint);
    self.contentTintColor = tint;
}
@end

// Todo 编辑钮(B 版铅笔):平时透明(由行 hover 放行),hover 图标本身时提亮为 CPFg2。
@interface CPTodoEditButton : CPHoverButton
@end
@implementation CPTodoEditButton
- (void)cpSetHovered:(BOOL)hovered {
    [super cpSetHovered:hovered];
    NSColor *tint = hovered ? CPFg2() : CPMuted();
    self.image = CPSymbol(@"pencil", 11, tint);
    self.contentTintColor = tint;
}
@end

// 详情抽屉容器:显示时吞掉覆盖区内的全部命中与鼠标事件,点击不得穿透到下层任务列表。
@interface CPClickBarrierView : NSView
@end
@implementation CPClickBarrierView
- (NSView *)hitTest:(NSPoint)point {
    if (self.hidden || self.alphaValue <= 0.0) return nil;
    NSView *hit = [super hitTest:point];
    if (hit) return hit;
    // hitTest: 的 point 在父视图坐标系,必须先转换到本地坐标再判断 bounds,
    // 否则兜底判定失效,点击穿透到下层任务列表(L1 回归)。
    NSPoint local = [self convertPoint:point fromView:self.superview];
    return NSPointInRect(local, self.bounds) ? self : nil;
}
- (void)mouseDown:(NSEvent *)event { (void)event; /* 吞掉,不沿 responder chain 上抛 */ }
- (void)mouseUp:(NSEvent *)event { (void)event; }
- (void)scrollWheel:(NSEvent *)event { (void)event; /* 详情打开时滚动也不落到下层列表 */ }
@end

// 不拦截命中的排版 stack:子视图(图标/文字)只做视觉,hitTest 整体穿透,
// 保证父按钮(如详情返回胶囊)的点击/hover 命中判定不被自己的排版内容遮挡。
@interface CPHitPassthroughStackView : NSStackView
@end
@implementation CPHitPassthroughStackView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end

@interface CPWorkbenchCardController : NSObject <NSTextFieldDelegate>
@property NSPanel *window;
@property NSView *shadowCarrier;
@property NSView *card;
@property NSView *leftColumn;
@property NSView *middleColumn;
@property NSView *rightColumn;
@property NSStackView *agentStack;
@property NSStackView *taskStack;
@property NSScrollView *taskScrollView;
@property NSStackView *detailStack;
@property NSButton *pinButton;
@property NSButton *modeButton;
@property NSTextField *cardMetaLabel;
@property NSTextField *centerTitle;
@property NSTextField *centerMeta;
@property NSButton *detailBackButton;
@property NSButton *detailOpenAgentButton;
@property NSMapTable<NSView *, NSString *> *detailSavedRowTooltips; // 详情互斥期间暂存的 row tooltip
// 工作台底部全宽 Todo 栏:可收起/展开;计数只显示在栏内,不进入任何提醒聚合。
@property CPTodoStore *todoStore;
@property NSView *todoContainer;
@property NSLayoutConstraint *todoHeightConstraint;
@property NSView *todoExpandedContent;
@property NSView *todoInputWrap;
@property NSTextField *todoInput;
@property NSTextField *todoEditField;
@property NSInteger todoEditingID;
@property NSStackView *todoStack;
@property NSButton *todoStripButton;
@property NSScrollView *todoScrollView;
@property NSTextField *todoCountLabel;
@property NSView *todoCountPill;
@property NSImageView *todoChevron;
@property NSString *todoChevronSymbolName; // 当前 chevron 符号名(自测断言用)
@property NSInteger hoverRevalidateGeneration; // 滚动停止 revalidate 的去抖代际
@property BOOL todoExpanded;
@property NSArray<CPAgent *> *agents;
@property CPAgent *selectedAgent;
@property CPTask *selectedTask;
@property CPReviewStore *reviewStore;
@property BOOL pinned;
@property NSInteger dockMode;
@property BOOL lastShowMadeKey; // show 时是否已激活并 makeKey(自测断言用)
@property id clickMonitor;
@property NSRect lastDockRect;
- (NSRect)targetFrameNearDockRect:(NSRect)rect edge:(NSRectEdge)edge;
- (NSRect)targetFrameInVisibleRect:(NSRect)visible;
- (void)showNearDockRect:(NSRect)rect edge:(NSRectEdge)edge;
- (void)close;
- (BOOL)isVisible;
- (void)renderAgents:(NSArray<CPAgent *> *)agents;
@end

// 工作台面板:borderless 窗口默认 canBecomeKey=NO,加上 NonactivatingPanel 更是永远无法成为 key,
// 真实 Esc 等键盘事件进不来。工作台需要接收键盘(第一次 Esc 关详情、第二次关工作台),
// 因此用专用子类声明可以成为 key/main window;悬浮球与 HUD 仍用 NonactivatingPanel 不抢焦点。
@interface CPWorkbenchPanel : NSPanel
@end
@implementation CPWorkbenchPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@implementation CPWorkbenchCardController

static const CGFloat CPWorkbenchInset = 20.0;

static const CGFloat CPCardWidth = 520.0;
static const CGFloat CPCardHeight = 360.0; // 内容区高度(头部 + 三列);Todo 栏在此基础上向下加高卡片

// Todo 栏布局常量(方案 B 精致卡片型):Todo 区是 CPBg 工作台上的一张 CPSurface 卡片
// (hairline 描边 + 10px 圆角,四周 12pt 外部留白),收起态 shell 精确等于 34pt 卡片头横条
// (对照原型 .vB:12px 是 .todo 外部 padding,shell 收起只等于 strip,不含任何内部空尾);
// 展开时卡片/窗口整体向下加高 CPTodoExpandedExtra,任务区高度不变;展开内容自己的
// 底内边距留在 expanded content 内,不污染 collapsed shell。
// 尺寸对齐原型 B:strip padding 10px 12px;行 min-height 30;输入框 padding 7px 10px;
// 列表 5 行可见,超出滚动;展开内容底内边距 10。
static const CGFloat CPTodoStripHeight = 34.0;
static const CGFloat CPTodoCardMargin = 12.0; // Todo 卡片距工作台卡片左右/底部的外部留白
static const CGFloat CPTodoCollapsedHeight = CPTodoStripHeight; // 收起 = 34 横条,无内部空尾
static const CGFloat CPTodoRowHeight = 30.0; // B 版行 min-height 30
static const CGFloat CPTodoExpandedExtra = 210.0; // 2 上间距 + 32 输入行 + 8 间距 + 158 列表(5 行) + 10 下内边距

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.pinned = YES;
    self.dockMode = 0;
    self.reviewStore = [[CPReviewStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    // 自测用临时库,不污染用户真实待办数据;每次自测运行从空库开始,保证计数断言确定。
    NSString *todoPath = CPTodoUseIsolatedStore
        ? [NSTemporaryDirectory() stringByAppendingPathComponent:@"codexpulse-ui-test-todos.sqlite"]
        : CPTodoStore.defaultPath;
    if (CPTodoUseIsolatedStore) [[NSFileManager defaultManager] removeItemAtPath:todoPath error:nil];
    self.todoStore = [[CPTodoStore alloc] initWithPath:todoPath];
    self.todoExpanded = [NSUserDefaults.standardUserDefaults boolForKey:@"workbench.todoExpanded"];
    [self buildWindow];
    return self;
}

// 当前 Todo 栏高度(收起 34 / 展开 34+210)。
- (CGFloat)todoBarHeight {
    return CPTodoCollapsedHeight + (self.todoExpanded ? CPTodoExpandedExtra : 0.0);
}

// 卡片总高 = 内容区 + Todo 栏。
- (CGFloat)cardHeight {
    return CPCardHeight + self.todoBarHeight;
}

// 卡片几何唯一入口:frame 与阴影路径随时与展开状态一致(构建/展开收起/显示前都走这里)。
- (void)applyCardGeometry {
    self.card.frame = NSMakeRect(CPWorkbenchInset, CPWorkbenchInset, CPCardWidth, self.cardHeight);
    self.shadowCarrier.layer.shadowPath =
        [NSBezierPath bezierPathWithRoundedRect:self.card.frame xRadius:18 yRadius:18].CGPath;
}

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
    CGFloat windowH = self.cardHeight + CPWorkbenchInset * 2.0;
    self.window = [[CPWorkbenchPanel alloc] initWithContentRect:NSMakeRect(0, 0, windowW, windowH)
                                                      styleMask:NSWindowStyleMaskBorderless
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
    self.window.contentView = self.shadowCarrier;

    self.card = [[NSView alloc] initWithFrame:NSMakeRect(CPWorkbenchInset, CPWorkbenchInset, CPCardWidth, self.cardHeight)];
    self.card.wantsLayer = YES;
    // B 版层次:工作台整体是 CPBg 深色底,Todo 卡片才是 CPSurface(原型 window 底 vs todo-shell)。
    self.card.layer.backgroundColor = CPBg().CGColor;
    self.card.layer.cornerRadius = 18.0;
    self.card.layer.borderWidth = 1.0;
    self.card.layer.borderColor = CPBorder().CGColor;
    self.card.layer.masksToBounds = YES;
    self.card.autoresizingMask = NSViewNotSizable;
    [self.shadowCarrier addSubview:self.card];
    [self applyCardGeometry];

    [self buildHeader];
    [self buildTodoBar]; // Todo 栏先于 body 建立:body 底部约束到 Todo 栏顶部
    [self buildBody];
    [self cpInstallHoverGuards];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(dockModeChanged:)
                                                 name:@"CPDockModeChanged"
                                               object:nil];
}

- (void)buildHeader {
    CPDraggableHeaderView *header = [[CPDraggableHeaderView alloc] initWithFrame:NSMakeRect(0, CPCardHeight - 48, CPCardWidth, 48)];
    header.toolTip = @"拖动以移动工作台";
    header.translatesAutoresizingMaskIntoConstraints = NO;
    // 工作台成为 key 时焦点落在拖动头,而不是 Todo 输入框——避免开窗即进入编辑态、Esc 语义被抢走。
    self.window.initialFirstResponder = header;
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
        // Todo 栏常驻参与布局:body 底部钉在 Todo 栏顶部,任何状态下都不重叠。
        [body.bottomAnchor constraintEqualToAnchor:self.todoContainer.topAnchor]
    ]];

    self.leftColumn = [self columnWithBackground:CPBg()];
    self.middleColumn = [self columnWithBackground:CPBg()]; // B 版:主区与窗口同底,卡片层次只由 Todo 卡片承载
    // 详情列用命中拦截容器:盖住任务列表时,下层完全不可点击(修复穿透 bug)。
    self.rightColumn = [self barrierColumnWithBackground:CPDyn(0.110, 0.120, 0.160, 0.095, 0.105, 0.140)];

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

#pragma mark - Todo Bar (工作台底部常驻栏,参与布局,不 overlay)

// Todo 区(方案 B 精致卡片型)= CPBg 工作台上的一张 CPSurface 卡片:1px hairline(8% 白,
// CPHairline,不是亮一档的 CPBorder)描边 + 10px 圆角,四周 12pt 留白,不再像外挂插件。
// 卡片头 = 常驻 34pt 横条(「待办」标签 + 未完成计数 pill + chevron,整条可点);
// 展开内容(输入行 + 滚动列表)排在头部下方。展开时卡片/窗口整体向下加高,任务区高度不变。
- (void)buildTodoBar {
    NSView *container = [[NSView alloc] initWithFrame:NSZeroRect];
    container.wantsLayer = YES;
    container.layer.backgroundColor = CPSurface().CGColor;
    container.layer.cornerRadius = 10.0;
    container.layer.masksToBounds = YES;
    container.layer.borderWidth = 1.0;
    container.layer.borderColor = CPHairline().CGColor;
    container.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoContainer = container;
    [self.card addSubview:container];
    self.todoHeightConstraint = [container.heightAnchor constraintEqualToConstant:self.todoBarHeight];
    [NSLayoutConstraint activateConstraints:@[
        [container.leadingAnchor constraintEqualToAnchor:self.card.leadingAnchor constant:CPTodoCardMargin],
        [container.trailingAnchor constraintEqualToAnchor:self.card.trailingAnchor constant:-CPTodoCardMargin],
        [container.bottomAnchor constraintEqualToAnchor:self.card.bottomAnchor constant:-CPTodoCardMargin],
        self.todoHeightConstraint
    ]];

    // 卡片头(34pt,贴卡片顶部):整条是可点按钮,子视图只负责排版。
    // 对照原型 .vB .strip:hover = 4% 白 wash,无新增描边;pressed 约 7%。
    NSButton *strip = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(toggleTodoBar:)];
    strip.bordered = NO;
    [strip setButtonType:NSButtonTypeMomentaryChange];
    strip.layer.cornerRadius = 10.0; // hover/按压 wash 按卡片圆角裁切(容器 masksToBounds 兜底)
    ((CPHoverButton *)strip).cpHoverWash = 0.04;
    ((CPHoverButton *)strip).cpPressedWash = 0.07;
    strip.toolTip = @"展开/收起待办";
    strip.accessibilityLabel = @"待办，展开/收起";
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoStripButton = strip;
    [container addSubview:strip];
    [NSLayoutConstraint activateConstraints:@[
        [strip.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [strip.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [strip.topAnchor constraintEqualToAnchor:container.topAnchor],
        [strip.heightAnchor constraintEqualToConstant:CPTodoStripHeight]
    ]];

    NSTextField *title = CPLabel(@"待办", 12, NSFontWeightSemibold, CPFg());
    title.maximumNumberOfLines = 1;
    title.translatesAutoresizingMaskIntoConstraints = NO;

    // 未完成计数 pill(B 版):7% 白底小圆角胶囊,10.5pt muted;计数只出现在 Todo 区,不进任何提醒聚合。
    NSView *pill = [[NSView alloc] initWithFrame:NSZeroRect];
    pill.wantsLayer = YES;
    pill.layer.backgroundColor = [CPFg() colorWithAlphaComponent:0.07].CGColor;
    pill.layer.cornerRadius = 8.0; // 16pt 高胶囊的半高圆角
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoCountPill = pill;
    self.todoCountLabel = CPLabel(@"", 10.5, NSFontWeightRegular, CPMuted());
    self.todoCountLabel.maximumNumberOfLines = 1;
    self.todoCountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [pill addSubview:self.todoCountLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.todoCountLabel.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:7],
        [self.todoCountLabel.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-7],
        [self.todoCountLabel.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [pill.heightAnchor constraintEqualToConstant:16]
    ]];

    NSImageView *chevron = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 10, 10)];
    // 对照原型:收起=向下(可展开),展开=向上(可收起)。
    self.todoChevronSymbolName = self.todoExpanded ? @"chevron.up" : @"chevron.down";
    chevron.image = CPSymbol(self.todoChevronSymbolName, 10, CPMuted());
    chevron.contentTintColor = CPMuted();
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoChevron = chevron;

    [strip addSubview:title];
    [strip addSubview:pill];
    [strip addSubview:chevron];
    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:strip.leadingAnchor constant:12],
        [title.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor],
        [pill.leadingAnchor constraintEqualToAnchor:title.trailingAnchor constant:8],
        [pill.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor],
        [chevron.trailingAnchor constraintEqualToAnchor:strip.trailingAnchor constant:-12],
        [chevron.centerYAnchor constraintEqualToAnchor:strip.centerYAnchor]
    ]];

    // 展开内容:输入行 + 列表,从卡片头下方向下排;收起时整体隐藏。
    NSView *expanded = [[NSView alloc] initWithFrame:NSZeroRect];
    expanded.translatesAutoresizingMaskIntoConstraints = NO;
    expanded.hidden = !self.todoExpanded;
    self.todoExpandedContent = expanded;
    [container addSubview:expanded];
    [NSLayoutConstraint activateConstraints:@[
        [expanded.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [expanded.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [expanded.topAnchor constraintEqualToAnchor:strip.bottomAnchor],
        [expanded.heightAnchor constraintEqualToConstant:CPTodoExpandedExtra]
    ]];

    // 输入行(B 版):嵌入式圆角字段(22% 黑底 + hairline 描边),左侧常驻「＋」,
    // 聚焦时描边变 CPAccent 并带极淡 accent 光环(见 cpUpdateTodoInputFocus:);回车即新增,空串忽略。
    NSView *inputWrap = [[NSView alloc] initWithFrame:NSZeroRect];
    inputWrap.wantsLayer = YES;
    inputWrap.layer.backgroundColor = [NSColor colorWithSRGBRed:0.0 green:0.0 blue:0.0 alpha:0.22].CGColor;
    inputWrap.layer.cornerRadius = 8.0;
    inputWrap.layer.borderWidth = 1.0;
    inputWrap.layer.borderColor = CPHairline().CGColor;
    inputWrap.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoInputWrap = inputWrap;
    [expanded addSubview:inputWrap];

    NSTextField *plus = CPLabel(@"＋", 13, NSFontWeightRegular, CPMuted());
    plus.maximumNumberOfLines = 1;
    plus.translatesAutoresizingMaskIntoConstraints = NO;
    [inputWrap addSubview:plus];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSZeroRect];
    input.bordered = NO;
    input.bezeled = NO;
    input.drawsBackground = NO;
    input.focusRingType = NSFocusRingTypeNone;
    input.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
    input.textColor = CPFg();
    input.placeholderString = @"随手记下待办，回车保存";
    input.target = self;
    input.action = @selector(addTodoFromInput:);
    input.delegate = self;
    input.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoInput = input;
    [inputWrap addSubview:input];
    [NSLayoutConstraint activateConstraints:@[
        [inputWrap.leadingAnchor constraintEqualToAnchor:expanded.leadingAnchor constant:12],
        [inputWrap.trailingAnchor constraintEqualToAnchor:expanded.trailingAnchor constant:-12],
        [inputWrap.topAnchor constraintEqualToAnchor:expanded.topAnchor constant:2],
        [inputWrap.heightAnchor constraintEqualToConstant:32],
        [plus.leadingAnchor constraintEqualToAnchor:inputWrap.leadingAnchor constant:10],
        [plus.centerYAnchor constraintEqualToAnchor:inputWrap.centerYAnchor],
        [input.leadingAnchor constraintEqualToAnchor:plus.trailingAnchor constant:8],
        [input.trailingAnchor constraintEqualToAnchor:inputWrap.trailingAnchor constant:-10],
        [input.centerYAnchor constraintEqualToAnchor:inputWrap.centerYAnchor]
    ]];

    // 列表:纵向滚动、无横向、背景透明;固定 158pt(5 行 × 30 + 行距),超出滚动。
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    self.todoScrollView = scroll;
    [expanded addSubview:scroll];

    NSStackView *stack = [CPFlippedStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 2;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.todoStack = stack;
    scroll.documentView = stack;

    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:expanded.leadingAnchor constant:8],
        [scroll.trailingAnchor constraintEqualToAnchor:expanded.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:inputWrap.bottomAnchor constant:8],
        [scroll.heightAnchor constraintEqualToConstant:158],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];

    [self renderTodos];
}

// 展开/收起:Todo 栏高度 + 卡片/窗口整体高度一起变。
- (void)toggleTodoBar:(id)sender {
    (void)sender;
    self.todoExpanded = !self.todoExpanded;
    [NSUserDefaults.standardUserDefaults setBool:self.todoExpanded forKey:@"workbench.todoExpanded"];
    [self applyTodoExpandedState];
}

- (void)applyTodoExpandedState {
    self.todoHeightConstraint.constant = self.todoBarHeight;
    self.todoExpandedContent.hidden = !self.todoExpanded;
    self.todoChevronSymbolName = self.todoExpanded ? @"chevron.up" : @"chevron.down";
    self.todoChevron.image = CPSymbol(self.todoChevronSymbolName, 10, CPMuted());
    [self applyCardGeometry];
    // 窗口高度始终与展开状态一致。可见时按完整新尺寸重新居中，避免 Todo 向下展开后
    // 落到屏幕底部之外、迫使用户再手动把整个工作台拖上去；隐藏时只更新尺寸，
    // 下次 showNearDockRect: 会按同一套居中逻辑显示。
    CGFloat currentExtra = self.window.frame.size.height - (CPCardHeight + CPTodoCollapsedHeight + CPWorkbenchInset * 2.0);
    CGFloat wantedExtra = self.todoExpanded ? CPTodoExpandedExtra : 0.0;
    CGFloat delta = wantedExtra - currentExtra;
    if (fabs(delta) > 0.5) {
        NSRect frame = self.window.frame;
        frame.origin.y -= delta;
        frame.size.height += delta;
        BOOL visible = self.window.isVisible;
        NSScreen *screen = self.window.screen ?: NSScreen.screens.firstObject ?: NSScreen.mainScreen;
        if (visible && screen) {
            frame = CPCenteredRectInVisibleFrame(screen.visibleFrame, frame.size);
        }
        [self.window setFrame:frame display:YES animate:visible];
    }
}

- (CPTodo *)todoWithID:(NSInteger)todoID {
    for (CPTodo *todo in [self.todoStore allTodos]) {
        if (todo.todoID == todoID) return todo;
    }
    return nil;
}

- (void)renderTodos {
    while (self.todoStack.arrangedSubviews.count > 0) {
        NSView *v = self.todoStack.arrangedSubviews.lastObject;
        [self.todoStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    NSArray<CPTodo *> *todos = [self.todoStore allTodos];
    if (!todos.count) {
        // 空状态:一行 muted 居中小字(文案沿用既有)。
        NSTextField *empty = CPLabel(@"暂无待办，随手记一条", 11.5, NSFontWeightRegular, CPMuted());
        empty.alignment = NSTextAlignmentCenter;
        [self.todoStack addArrangedSubview:empty];
        [empty.widthAnchor constraintEqualToAnchor:self.todoStack.widthAnchor].active = YES;
    } else {
        for (CPTodo *todo in todos) {
            NSView *row = [self todoRow:todo];
            [self.todoStack addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.todoStack.widthAnchor].active = YES;
        }
    }
    NSInteger pending = [self.todoStore pendingCount];
    NSString *countText = !todos.count ? @""
        : (pending ? [NSString stringWithFormat:@"%ld 项待办", (long)pending] : @"全部完成");
    self.todoCountLabel.stringValue = countText;
    self.todoCountPill.hidden = countText.length == 0; // 空库时 pill 整体收起,不留空胶囊
}

- (NSView *)todoRow:(CPTodo *)todo {
    CPTodoRowView *row = [[CPTodoRowView alloc] initWithFrame:NSZeroRect];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 6.0;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [row.heightAnchor constraintEqualToConstant:CPTodoRowHeight].active = YES;

    // 完成/恢复勾选钮(B 版):15pt 圆形勾选框,未完成 muted 空心圆,勾中后绿色 CPGreen 填充。
    NSButton *check = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(toggleTodo:)];
    check.bordered = NO;
    [check setButtonType:NSButtonTypeMomentaryChange];
    check.tag = todo.todoID;
    check.image = CPSymbol(todo.completed ? @"checkmark.circle.fill" : @"circle", 15,
                           todo.completed ? CPGreen() : CPMuted());
    check.contentTintColor = todo.completed ? CPGreen() : CPMuted();
    check.toolTip = todo.completed ? @"恢复为待办" : @"标记完成";
    check.translatesAutoresizingMaskIntoConstraints = NO;
    [check.widthAnchor constraintEqualToConstant:22].active = YES;
    [check.heightAnchor constraintEqualToConstant:22].active = YES;
    [row addSubview:check];

    NSView *titleView;
    if (self.todoEditingID == todo.todoID) {
        // 行内编辑:回车保存,Esc 放弃(见 handleEscape);视觉上给极淡 accent 底标示编辑态。
        NSTextField *edit = [[NSTextField alloc] initWithFrame:NSZeroRect];
        edit.bordered = NO;
        edit.bezeled = NO;
        edit.drawsBackground = YES;
        edit.backgroundColor = [CPAccent() colorWithAlphaComponent:0.10];
        edit.wantsLayer = YES;
        edit.layer.cornerRadius = 4.0;
        edit.focusRingType = NSFocusRingTypeNone;
        edit.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
        edit.textColor = CPFg();
        edit.stringValue = todo.title;
        edit.target = self;
        edit.action = @selector(commitTodoEdit:);
        edit.tag = todo.todoID;
        edit.translatesAutoresizingMaskIntoConstraints = NO;
        self.todoEditField = edit;
        titleView = edit;
    } else {
        // 标题即按钮:点击进入行内编辑;B 版配色:未完成正文 CPFg2 次级前景,完成态 muted 灰。
        NSButton *titleButton = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(startTodoEdit:)];
        titleButton.bordered = NO;
        [titleButton setButtonType:NSButtonTypeMomentaryChange];
        titleButton.tag = todo.todoID;
        titleButton.toolTip = @"点击编辑";
        titleButton.translatesAutoresizingMaskIntoConstraints = NO;
        NSMutableDictionary<NSAttributedStringKey, id> *attrs = [NSMutableDictionary dictionary];
        attrs[NSFontAttributeName] = [NSFont systemFontOfSize:12.5 weight:NSFontWeightRegular];
        attrs[NSForegroundColorAttributeName] = todo.completed ? CPMuted() : CPFg2();
        titleButton.attributedTitle = [[NSAttributedString alloc] initWithString:todo.title attributes:attrs];
        titleButton.alignment = NSTextAlignmentLeft;
        titleButton.lineBreakMode = NSLineBreakByTruncatingTail;
        titleView = titleButton;
    }
    [row addSubview:titleView];

    // 行尾动作组(B 版):编辑铅笔 + 删除垃圾桶,平时透明,仅 hover 该行时同时出现。
    NSButton *editBtn = [CPTodoEditButton buttonWithTitle:@"" target:self action:@selector(startTodoEdit:)];
    editBtn.bordered = NO;
    [editBtn setButtonType:NSButtonTypeMomentaryChange];
    editBtn.tag = todo.todoID;
    editBtn.image = CPSymbol(@"pencil", 11, CPMuted());
    editBtn.contentTintColor = CPMuted();
    editBtn.alphaValue = 0.0;
    editBtn.toolTip = @"编辑";
    editBtn.translatesAutoresizingMaskIntoConstraints = NO;
    [editBtn.widthAnchor constraintEqualToConstant:24].active = YES;
    [editBtn.heightAnchor constraintEqualToConstant:24].active = YES;
    [row addSubview:editBtn];
    row.cpEditButton = editBtn;

    NSButton *delete = [CPTodoDeleteButton buttonWithTitle:@"" target:self action:@selector(deleteTodo:)];
    delete.bordered = NO;
    [delete setButtonType:NSButtonTypeMomentaryChange];
    delete.tag = todo.todoID;
    delete.image = CPSymbol(@"trash", 11, CPMuted());
    delete.contentTintColor = CPMuted();
    delete.alphaValue = 0.0;
    delete.toolTip = @"删除";
    delete.translatesAutoresizingMaskIntoConstraints = NO;
    [delete.widthAnchor constraintEqualToConstant:24].active = YES;
    [delete.heightAnchor constraintEqualToConstant:24].active = YES;
    [row addSubview:delete];
    row.cpDeleteButton = delete;

    [NSLayoutConstraint activateConstraints:@[
        [check.leadingAnchor constraintEqualToAnchor:row.leadingAnchor constant:8],
        [check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [titleView.leadingAnchor constraintEqualToAnchor:check.trailingAnchor constant:9],
        [titleView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [editBtn.leadingAnchor constraintEqualToAnchor:titleView.trailingAnchor constant:4],
        [delete.leadingAnchor constraintEqualToAnchor:editBtn.trailingAnchor constant:2],
        [delete.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-4],
        [editBtn.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [delete.centerYAnchor constraintEqualToAnchor:row.centerYAnchor]
    ]];
    return row;
}

// Todo 输入框聚焦态:描边变 CPAccent + 极淡 accent 光环;失焦恢复 8% 白 hairline。
- (void)cpUpdateTodoInputFocus:(BOOL)focused {
    self.todoInputWrap.layer.borderColor = (focused ? CPAccent() : CPHairline()).CGColor;
    self.todoInputWrap.layer.shadowColor = [CPAccent() colorWithAlphaComponent:0.16].CGColor;
    self.todoInputWrap.layer.shadowOpacity = focused ? 1.0 : 0.0;
    self.todoInputWrap.layer.shadowRadius = 3.0;
    self.todoInputWrap.layer.shadowOffset = NSZeroSize;
}

- (void)controlTextDidBeginEditing:(NSNotification *)note {
    if (note.object == self.todoInput) [self cpUpdateTodoInputFocus:YES];
}

- (void)controlTextDidEndEditing:(NSNotification *)note {
    if (note.object == self.todoInput) [self cpUpdateTodoInputFocus:NO];
}

- (void)addTodoFromInput:(id)sender {
    (void)sender;
    if ([self.todoStore addTodoWithTitle:self.todoInput.stringValue]) {
        self.todoInput.stringValue = @"";
        [self renderTodos];
    }
}

- (void)toggleTodo:(NSButton *)sender {
    CPTodo *todo = [self todoWithID:sender.tag];
    if (!todo) return;
    [self.todoStore setTodo:todo.todoID completed:!todo.completed];
    [self renderTodos];
}

- (void)startTodoEdit:(NSButton *)sender {
    self.todoEditingID = sender.tag;
    [self renderTodos];
    [self.window makeFirstResponder:self.todoEditField];
}

- (void)commitTodoEdit:(NSTextField *)sender {
    [self.todoStore updateTodo:sender.tag title:sender.stringValue];
    self.todoEditingID = 0;
    self.todoEditField = nil;
    [self renderTodos];
}

- (void)deleteTodo:(NSButton *)sender {
    [self.todoStore deleteTodo:sender.tag];
    [self renderTodos];
}

- (NSView *)columnWithBackground:(NSColor *)color {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    v.wantsLayer = YES;
    v.layer.backgroundColor = color.CGColor;
    return v;
}

- (NSView *)barrierColumnWithBackground:(NSColor *)color {
    NSView *v = [[CPClickBarrierView alloc] initWithFrame:NSZeroRect];
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
    // 顶部 header 固定不滚动
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
    [self.middleColumn addSubview:head];

    // 任务列表放入真正的 NSScrollView:纵向滚动、无横向、背景透明
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    self.taskScrollView = scroll;
    [self.middleColumn addSubview:scroll];

    NSStackView *stack = [CPFlippedStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    stack.edgeInsets = NSEdgeInsetsMake(0, 0, 12, 0); // 末行底部内边距,不被圆角裁切
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.taskStack = stack;
    scroll.documentView = stack;

    [NSLayoutConstraint activateConstraints:@[
        [head.leadingAnchor constraintEqualToAnchor:self.middleColumn.leadingAnchor constant:12],
        [head.trailingAnchor constraintEqualToAnchor:self.middleColumn.trailingAnchor constant:-12],
        [head.topAnchor constraintEqualToAnchor:self.middleColumn.topAnchor constant:12],

        [scroll.leadingAnchor constraintEqualToAnchor:self.middleColumn.leadingAnchor constant:12],
        [scroll.trailingAnchor constraintEqualToAnchor:self.middleColumn.trailingAnchor constant:-12],
        [scroll.topAnchor constraintEqualToAnchor:head.bottomAnchor constant:8],
        [scroll.bottomAnchor constraintEqualToAnchor:self.middleColumn.bottomAnchor constant:-12],

        // documentView 宽度跟随 clip view,任务行横向 fill 不溢出
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];
}

- (void)buildRightColumn {
    NSStackView *stack = [self stackIn:self.rightColumn spacing:10];
    self.detailStack = stack;

    NSView *head = [[NSView alloc] initWithFrame:NSZeroRect];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    [head.heightAnchor constraintEqualToConstant:30].active = YES;
    NSTextField *title = CPLabel(@"任务详情", 13, NSFontWeightSemibold, CPFg());
    title.translatesAutoresizingMaskIntoConstraints = NO;
    // 返回入口:56×28 胶囊(chevron.left + 「返回」),圆角 14,hairline 描边 + 极淡底色。
    // 与「任务详情」13pt 标题同行同中线。chevron 不作为 NSButton.image 设置——按钮的
    // 私有内部约束会撑坏热区几何(曾把热区纵向拉成椭圆);图标与文字改为子视图排版,
    // 几何完全自控。hover/按压 wash 经 CPHoverButton overlay 画满整个胶囊,
    // 点击热区与可视区域一致(56×28)。
    NSButton *backButton = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(closeDetailDrawer)];
    backButton.bordered = NO;
    backButton.toolTip = @"返回任务列表";
    backButton.accessibilityLabel = @"返回任务列表";
    backButton.layer.cornerRadius = 14.0; // 高度一半的胶囊圆角
    backButton.layer.borderColor = [CPFg2() colorWithAlphaComponent:0.55].CGColor; // 比 CPBorder 亮一档,小尺寸下更清晰
    ((CPHoverButton *)backButton).cpBaseBackground = CPBg(); // 极淡底色
    ((CPHoverButton *)backButton).cpAlwaysBorder = YES;
    ((CPHoverButton *)backButton).cpHoverWash = 0.04; // 行级约定:hover 4%
    ((CPHoverButton *)backButton).cpPressedWash = 0.08; // pressed 8%

    NSImageView *backChevron = [[NSImageView alloc] initWithFrame:NSZeroRect];
    backChevron.image = CPSymbol(@"chevron.left", 10, CPFg());
    backChevron.contentTintColor = CPFg();
    backChevron.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *backLabel = CPLabel(@"返回", 11, NSFontWeightMedium, CPFg());
    backLabel.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *pill = [CPHitPassthroughStackView stackViewWithViews:@[backChevron, backLabel]];
    pill.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pill.alignment = NSLayoutAttributeCenterY;
    pill.spacing = 3;
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    [backButton addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.centerXAnchor constraintEqualToAnchor:backButton.centerXAnchor],
        [pill.centerYAnchor constraintEqualToAnchor:backButton.centerYAnchor]
    ]];
    backButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailBackButton = backButton;
    [head addSubview:title];
    [head addSubview:backButton];
    [NSLayoutConstraint activateConstraints:@[
        [backButton.leadingAnchor constraintEqualToAnchor:head.leadingAnchor],
        [backButton.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [backButton.widthAnchor constraintEqualToConstant:56],
        [backButton.heightAnchor constraintEqualToConstant:28],
        [title.leadingAnchor constraintEqualToAnchor:backButton.trailingAnchor constant:8],
        [title.centerYAnchor constraintEqualToAnchor:head.centerYAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:head.trailingAnchor]
    ]];
    [stack addArrangedSubview:head];
    // header 横向填满,不按 intrinsic 收缩
    [head.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-24].active = YES;
}

- (void)showDetailDrawer {
    // 提到任务列表之上再显示。
    [self.middleColumn addSubview:self.rightColumn positioned:NSWindowAbove relativeTo:nil];
    self.rightColumn.hidden = NO;
    [self cpSetTaskListInteractive:NO];
}

- (void)closeDetailDrawer {
    self.rightColumn.hidden = YES;
    [self cpSetTaskListInteractive:YES];
}

// 详情打开期间任务列表真正互斥,不只靠 CPClickBarrierView 挡板:
// 1) taskScrollView 整体 hidden —— hitTest/滚动/绘制全部不落到下层;
// 2) 立即清空残留 hover 蒙层(复用滚动/失焦同一条清理路径);
// 3) 遍历列表子树,nil 掉 row tooltip(先暂存,关闭时还原)并移除自有 tracking area,
//    任何残余事件路径都不会再触发"查看任务详情…"tooltip 或 hover。
// 关闭详情时完整恢复:显示、还原 tooltip、CPHoverButton 重装 tracking area。
- (void)cpSetTaskListInteractive:(BOOL)interactive {
    self.taskScrollView.hidden = !interactive;
    [self cpInvalidateHoverImmediately];
    if (!self.detailSavedRowTooltips) {
        self.detailSavedRowTooltips = [NSMapTable weakToStrongObjectsMapTable];
    }
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithObject:self.taskScrollView];
    while (queue.count) {
        NSView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        [queue addObjectsFromArray:v.subviews];
        if (!interactive) {
            if (v.toolTip.length) {
                [self.detailSavedRowTooltips setObject:v.toolTip forKey:v];
                v.toolTip = nil;
            }
            for (NSTrackingArea *area in [NSArray arrayWithArray:v.trackingAreas]) {
                if (area.owner == v) [v removeTrackingArea:area];
            }
        } else {
            NSString *saved = [self.detailSavedRowTooltips objectForKey:v];
            if (saved) {
                v.toolTip = saved;
                [self.detailSavedRowTooltips removeObjectForKey:v];
            }
            if ([v isKindOfClass:CPHoverButton.class]) [v updateTrackingAreas];
        }
    }
    if (interactive) self.detailSavedRowTooltips = nil;
}

- (void)handleEscape {
    // 正在 Todo 栏输入/编辑时,Esc 只放弃当前编辑(不改数据),不关详情或工作台。
    NSResponder *firstResponder = self.window.firstResponder;
    if ([firstResponder isKindOfClass:NSTextView.class]) {
        NSTextField *field = (NSTextField *)[(NSTextView *)firstResponder delegate];
        if (field == self.todoInput || field == self.todoEditField) {
            [self.window makeFirstResponder:nil];
            if (field == self.todoEditField) {
                self.todoEditingID = 0;
                self.todoEditField = nil;
                [self renderTodos];
            }
            return;
        }
    }
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
    ((CPHoverButton *)row).cpHoverWash = 0.05; // 对照原型 .agent:hover;selected 底色独立,wash 只叠 5% 不抢层级
    ((CPHoverButton *)row).cpPressedWash = 0.08;
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
    CPDisplayStatus displayStatus = CPDisplayStatusForTasks(agent.tasks, agent.agentID, self.reviewStore);
    NSTextField *status = CPLabel(CPDisplayStatusTitle(displayStatus), 10, NSFontWeightRegular, CPMuted());

    NSStackView *text = [NSStackView stackViewWithViews:@[name, status]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 0;
    text.translatesAutoresizingMaskIntoConstraints = NO;
    // 固定文字列宽度，状态灯不再随 Agent 名称长度横向漂移。
    [text.widthAnchor constraintEqualToConstant:44].active = YES;

    NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 6, 6)];
    dot.image = CPDotImage(6, CPDisplayStatusColor(displayStatus));
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
    ((CPHoverButton *)row).cpHoverWash = 0.04; // 对照原型 .task:hover
    ((CPHoverButton *)row).cpPressedWash = 0.07;
    row.tag = index;
    row.toolTip = [NSString stringWithFormat:@"查看任务详情：%@", task.title];
    row.accessibilityLabel = [NSString stringWithFormat:@"%@，查看任务详情", task.title];
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

// metadata grid 单元格:11pt 标签 + 12pt 值,横向填满所在列。
- (NSView *)detailPair:(NSString *)label value:(NSString *)value {
    NSTextField *k = CPLabel(label, 11, NSFontWeightSemibold, CPMuted());
    NSTextField *v = CPLabel(value.length ? value : @"—", 12, NSFontWeightRegular, CPFg2());
    v.maximumNumberOfLines = 1;
    v.lineBreakMode = NSLineBreakByTruncatingTail;
    NSStackView *s = [NSStackView stackViewWithViews:@[k, v]];
    s.orientation = NSUserInterfaceLayoutOrientationVertical;
    s.alignment = NSLayoutAttributeLeading;
    s.spacing = 2;
    return s;
}

- (void)addDetailView:(NSView *)v {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [self.detailStack addArrangedSubview:v];
    // 所有内容横向 fill(扣除 stack edgeInsets 12+12),不缩成窄列
    [v.widthAnchor constraintEqualToAnchor:self.detailStack.widthAnchor constant:-24].active = YES;
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
    ((CPHoverButton *)add).cpHoverWash = 0.05; // 对照原型 .add-agent:hover
    ((CPHoverButton *)add).cpPressedWash = 0.08;
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

    while (self.taskStack.arrangedSubviews.count > 0) {
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
            NSButton *taskRowBtn = [self taskRow:task index:idx++];
            [self.taskStack addArrangedSubview:taskRowBtn];
            [taskRowBtn.widthAnchor constraintEqualToAnchor:self.taskStack.widthAnchor].active = YES;
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
    // 抽屉打开期间任务列表保持互斥:行重建会带回 tooltip/tracking area,重新停用。
    if (!self.rightColumn.hidden) [self cpSetTaskListInteractive:NO];
}

- (void)renderDetail {
    self.detailOpenAgentButton = nil;
    while (self.detailStack.arrangedSubviews.count > 1) {
        NSView *v = self.detailStack.arrangedSubviews.lastObject;
        [self.detailStack removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    if (!self.selectedTask) {
        [self addDetailView:CPLabel(@"选择一项任务查看详情", 12, NSFontWeightRegular, CPMuted())];
        return;
    }

    CPTask *task = self.selectedTask;
    CPAgent *agent = self.selectedAgent;

    if (agent.placeholder) {
        NSTextField *notice = CPLabel([NSString stringWithFormat:@"%@ 目前为占位接入。后续将替换为真实本地数据源。", agent.name], 11, NSFontWeightRegular, CPFg2());
        notice.maximumNumberOfLines = 3;
        [self addDetailView:notice];
    }

    // 标题:14pt semibold,最多 2 行尾部截断
    NSTextField *title = CPLabel(task.title, 14, NSFontWeightSemibold, CPFg());
    title.maximumNumberOfLines = 2;
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addDetailView:title];

    // 状态 · Agent 一行(状态用状态色,Agent 用次要色)
    NSMutableAttributedString *statusLine = [[NSMutableAttributedString alloc]
        initWithString:CPStatusTitle(task.status)
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: CPStatusColor(task.status)}];
    [statusLine appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@" · %@", agent.name]
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightRegular],
                         NSForegroundColorAttributeName: CPMuted()}]];
    NSTextField *statusLabel = [NSTextField labelWithString:@""];
    statusLabel.attributedStringValue = statusLine;
    [self addDetailView:statusLabel];

    // 两列 metadata grid:项目 / Agent;Tokens / 最近更新
    NSStackView *col1 = [NSStackView stackViewWithViews:@[
        [self detailPair:@"项目" value:task.projectName],
        [self detailPair:@"Tokens" value:CPFormatTokens(task.tokensUsed)]
    ]];
    col1.orientation = NSUserInterfaceLayoutOrientationVertical;
    col1.alignment = NSLayoutAttributeLeading;
    col1.spacing = 8;
    NSStackView *col2 = [NSStackView stackViewWithViews:@[
        [self detailPair:@"Agent" value:agent.name],
        [self detailPair:@"最近更新" value:CPFormatDateCN(task.updatedAt)]
    ]];
    col2.orientation = NSUserInterfaceLayoutOrientationVertical;
    col2.alignment = NSLayoutAttributeLeading;
    col2.spacing = 8;
    NSStackView *grid = [NSStackView stackViewWithViews:@[col1, col2]];
    grid.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    grid.distribution = NSStackViewDistributionFillEqually;
    grid.spacing = 10;
    [self addDetailView:grid];

    // 最近活动:全宽深色子卡片,multiline 限行截断
    NSView *activityCard = [[NSView alloc] initWithFrame:NSZeroRect];
    activityCard.wantsLayer = YES;
    activityCard.layer.backgroundColor = CPBg().CGColor;
    activityCard.layer.cornerRadius = 10.0;
    activityCard.layer.borderWidth = 1.0;
    activityCard.layer.borderColor = CPBorder().CGColor;
    activityCard.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *activityHead = CPLabel(@"最近活动", 11, NSFontWeightSemibold, CPMuted());
    activityHead.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *activityBody = CPLabel(task.activity.length ? task.activity : @"—", 11, NSFontWeightRegular, CPFg2());
    activityBody.maximumNumberOfLines = 4;
    activityBody.lineBreakMode = NSLineBreakByTruncatingTail;
    activityBody.translatesAutoresizingMaskIntoConstraints = NO;
    [activityCard addSubview:activityHead];
    [activityCard addSubview:activityBody];
    [NSLayoutConstraint activateConstraints:@[
        [activityHead.leadingAnchor constraintEqualToAnchor:activityCard.leadingAnchor constant:10],
        [activityHead.trailingAnchor constraintEqualToAnchor:activityCard.trailingAnchor constant:-10],
        [activityHead.topAnchor constraintEqualToAnchor:activityCard.topAnchor constant:8],
        [activityBody.leadingAnchor constraintEqualToAnchor:activityHead.leadingAnchor],
        [activityBody.trailingAnchor constraintEqualToAnchor:activityHead.trailingAnchor],
        [activityBody.topAnchor constraintEqualToAnchor:activityHead.bottomAnchor constant:4],
        [activityBody.bottomAnchor constraintEqualToAnchor:activityCard.bottomAnchor constant:-8]
    ]];
    [self addDetailView:activityCard];

    // 一级点击只进入详情；从详情页明确执行第二次点击才跳转到对应 Agent 的任务。
    // 直达入口做成 macOS 设置式"跳转行":与最近活动卡片同底色/同描边/同 10px
    // 圆角,左图标 + 左对齐文案 + 尾部 disclosure chevron。按钮本身是全行透明
    // 覆盖层,承接点击/hover/按压;视觉由行内子视图排版,不是网页 CTA。
    NSView *actionRow = [[NSView alloc] initWithFrame:NSZeroRect];
    actionRow.wantsLayer = YES;
    actionRow.layer.backgroundColor = CPBg().CGColor;
    actionRow.layer.cornerRadius = 10.0;
    actionRow.layer.borderWidth = 1.0;
    actionRow.layer.borderColor = CPBorder().CGColor;
    actionRow.translatesAutoresizingMaskIntoConstraints = NO;
    [actionRow.heightAnchor constraintEqualToConstant:36].active = YES;

    NSImageView *openIcon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    // 图标语言对齐:优先用 Agent 官方 app 图标的圆形裁切(与状态环/HUD 同源),
    // 语义本身就是"在 <Agent> 中打开";取不到时回退为无方框的 arrow.up.right,
    // 方框符号(arrow.up.right.square)与全产品的圆形语言冲突,不再使用。
    NSImage *agentIcon = CPAppIconForAgent(agent.agentID, 15.0);
    if (agentIcon) {
        openIcon.image = agentIcon;
        openIcon.contentTintColor = nil; // 官方彩色图标不做单色 tint
    } else {
        openIcon.image = CPSymbol(@"arrow.up.right", 11, CPAccent());
        openIcon.contentTintColor = CPAccent();
    }
    openIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [openIcon.widthAnchor constraintEqualToConstant:16].active = YES;
    [openIcon.heightAnchor constraintEqualToConstant:16].active = YES;

    NSString *openTitle = [NSString stringWithFormat:@"在 %@ 中打开", agent.name];
    NSTextField *openLabel = CPLabel(openTitle, 12, NSFontWeightMedium, CPFg());
    openLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    openLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *openChevron = [[NSImageView alloc] initWithFrame:NSZeroRect];
    openChevron.image = CPSymbol(@"chevron.right", 10, CPMuted());
    openChevron.contentTintColor = CPMuted();
    openChevron.translatesAutoresizingMaskIntoConstraints = NO;

    CPHoverButton *openButton = (CPHoverButton *)[CPHoverButton buttonWithTitle:openTitle
                                                                        target:self
                                                                        action:@selector(openSelectedTaskInAgent:)];
    openButton.bordered = NO;
    // 标题只作语义/自测载体,不重复绘制 —— 行内文字由 openLabel 排版。
    openButton.attributedTitle = [[NSAttributedString alloc]
        initWithString:openTitle
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: NSColor.clearColor}];
    openButton.layer.cornerRadius = 10.0; // hover/按压 wash 按卡片圆角裁切
    openButton.toolTip = [NSString stringWithFormat:@"直达 %@ 中的这个任务", agent.name];
    openButton.accessibilityLabel = openButton.toolTip;
    openButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.detailOpenAgentButton = openButton;

    [actionRow addSubview:openIcon];
    [actionRow addSubview:openLabel];
    [actionRow addSubview:openChevron];
    [actionRow addSubview:openButton]; // 覆盖层置顶,整行可点
    [NSLayoutConstraint activateConstraints:@[
        [openIcon.leadingAnchor constraintEqualToAnchor:actionRow.leadingAnchor constant:12],
        [openIcon.centerYAnchor constraintEqualToAnchor:actionRow.centerYAnchor],
        [openLabel.leadingAnchor constraintEqualToAnchor:openIcon.trailingAnchor constant:8],
        [openLabel.centerYAnchor constraintEqualToAnchor:actionRow.centerYAnchor],
        [openChevron.trailingAnchor constraintEqualToAnchor:actionRow.trailingAnchor constant:-12],
        [openChevron.centerYAnchor constraintEqualToAnchor:actionRow.centerYAnchor],
        [openLabel.trailingAnchor constraintLessThanOrEqualToAnchor:openChevron.leadingAnchor constant:-8],
        [openButton.leadingAnchor constraintEqualToAnchor:actionRow.leadingAnchor],
        [openButton.trailingAnchor constraintEqualToAnchor:actionRow.trailingAnchor],
        [openButton.topAnchor constraintEqualToAnchor:actionRow.topAnchor],
        [openButton.bottomAnchor constraintEqualToAnchor:actionRow.bottomAnchor]
    ]];
    [self addDetailView:actionRow];
}

- (void)openSelectedTaskInAgent:(id)sender {
    (void)sender;
    if (!self.selectedAgent || !self.selectedTask || CPRunningSelfTests) return;
    CPOpenAgentTask(self.selectedAgent, self.selectedTask);
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
        // 只有真正打开任务详情才记录已查看；render/选择 Agent/刷新均不写 defaults。
        if (self.selectedTask.status == CPStatusCompleted ||
            self.selectedTask.status == CPStatusAttention ||
            self.selectedTask.status == CPStatusFailed ||
            self.selectedTask.status == CPStatusWaiting) {
            [self.reviewStore markTaskReviewed:self.selectedTask agentID:self.selectedAgent.agentID];
            [[NSNotificationCenter defaultCenter] postNotificationName:@"CPTaskReviewed" object:nil];
            // 立即刷新工作台 Agent 灯；任务对象按 taskID 保留，详情抽屉不会关闭。
            [self renderAgents:self.agents];
        }
    }
}

- (void)addAgent:(id)sender {
    (void)sender;
    NSSet<NSString *> *enabled = [NSSet setWithArray:CPEnabledAgentProviderIDs()];
    NSMutableArray<NSDictionary *> *available = NSMutableArray.array;
    for (NSDictionary *provider in CPAgentProviderCatalog()) {
        if (![enabled containsObject:provider[@"id"]]) [available addObject:provider];
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"添加 Agent";
    alert.informativeText = available.count
        ? @"选择一个本机 Agent 数据源。Codex Pulse 只读取任务索引和运行状态。"
        : @"所有内置 Agent 均已添加。";
    if (!available.count) {
        [alert addButtonWithTitle:@"好"];
        alert.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        [alert runModal];
        return;
    }

    NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 30) pullsDown:NO];
    [picker removeAllItems];
    for (NSDictionary *provider in available) {
        BOOL detected = CPAgentProviderIsDetected(provider[@"id"]);
        NSString *title = [NSString stringWithFormat:@"%@  ·  %@", provider[@"name"], detected ? @"已检测" : @"未检测"];
        [picker addItemWithTitle:title];
        picker.lastItem.representedObject = provider[@"id"];
    }
    NSTextField *hint = CPLabel(@"添加后会立即出现在工作台；未检测到数据时保持空态。", 11, NSFontWeightRegular, CPMuted());
    hint.maximumNumberOfLines = 2;
    hint.preferredMaxLayoutWidth = 320;
    NSStackView *accessory = [NSStackView stackViewWithViews:@[picker, hint]];
    accessory.orientation = NSUserInterfaceLayoutOrientationVertical;
    accessory.alignment = NSLayoutAttributeLeading;
    accessory.spacing = 8;
    accessory.frame = NSMakeRect(0, 0, 320, 58);
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:@"添加"];
    [alert addButtonWithTitle:@"取消"];
    alert.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString *providerID = picker.selectedItem.representedObject;
        CPEnableAgentProvider(providerID);
    }
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
    NSSize size = NSMakeSize(CPCardWidth + CPWorkbenchInset * 2.0, self.cardHeight + CPWorkbenchInset * 2.0);
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
    [self applyCardGeometry]; // 展开状态可能在隐藏期间被自测/默认值改变,显示前对齐几何
    NSRect target = [self targetFrameNearDockRect:rect edge:edge];
    if (!self.window.isVisible) {
        [self.window setFrame:target display:NO];
        [self makeKeyWindow];
        [self.window setFrame:target display:YES animate:YES];
    } else {
        [self.window setFrame:target display:YES animate:YES];
        [self makeKeyWindow];
    }
    [self installClickMonitor];
}

// 工作台显示时必须成为 key window 以接收真实键盘事件(Esc 两级关闭)。
// orb/HUD 面板保持 nonactivating,只有工作台激活 app 并 makeKey。
- (void)makeKeyWindow {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [NSApp activateIgnoringOtherApps:YES]; // 当前 SDK 无 activateWithOptions:,沿用此 API
#pragma clang diagnostic pop
    [self.window makeKeyAndOrderFront:nil];
    [self.window orderFrontRegardless];
    self.lastShowMadeKey = YES;
}

- (void)close {
    [self cpInvalidateHoverImmediately];
    BOOL wasKey = self.window.isKeyWindow;
    [self.window orderOut:nil];
    if (wasKey) [NSApp deactivate]; // 焦点交还,避免 app 激活态悬空
    [self removeClickMonitor];
}

#pragma mark - Hover 残留防护(滚动 / 窗口生命周期)

// 滚动时鼠标常常静止,AppKit 不会给被滚走的行补发 mouseExited,hover 蒙层会残留在
// 原位。统一在 clip view bounds 变化(含 live scroll/惯性滚动)时立即清空全部 hover
// (不重启退出动画,连续滚动不拖影),停止后用带代际的短 debounce 按真实 window
// mouse point 重校验,保证任何时刻最多只有实际鼠标下的一个 row 处于 hover;
// 不用常驻 timer。窗口 resign/close/orderOut、app deactivate 同样立即清理,
// 并递增代际取消尚未触发的 revalidate。
- (void)cpInstallHoverGuards {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSScrollView *scroll in @[self.taskScrollView, self.todoScrollView]) {
        scroll.contentView.postsBoundsChangedNotifications = YES;
        [center addObserver:self selector:@selector(cpScrollHoverInvalidate:)
                       name:NSViewBoundsDidChangeNotification object:scroll.contentView];
    }
    [center addObserver:self selector:@selector(cpHoverInvalidateNotification:)
                   name:NSWindowDidResignKeyNotification object:self.window];
    [center addObserver:self selector:@selector(cpHoverInvalidateNotification:)
                   name:NSWindowWillCloseNotification object:self.window];
    [center addObserver:self selector:@selector(cpHoverInvalidateNotification:)
                   name:NSApplicationDidResignActiveNotification object:NSApp];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// 立即清理全部 hover:不重启 150ms 退出动画,overlay model opacity 与 Todo 行尾
// 动作组直接归 0,连续滚动/失焦/关闭场景不拖影、不弹回。
- (void)cpClearAllHoverImmediately {
    NSMutableArray<NSView *> *queue = [NSMutableArray arrayWithArray:self.card.subviews];
    while (queue.count) {
        NSView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([v isKindOfClass:CPHoverButton.class]) [(CPHoverButton *)v cpClearHoverImmediate];
        else if ([v isKindOfClass:CPTodoRowView.class]) [(CPTodoRowView *)v cpClearRowHoverImmediate];
        [queue addObjectsFromArray:v.subviews];
    }
}

- (void)cpInvalidateHoverImmediately {
    self.hoverRevalidateGeneration++; // 取消尚未触发的 revalidate
    [self cpClearAllHoverImmediately];
}

- (void)cpHoverInvalidateNotification:(NSNotification *)note {
    (void)note;
    [self cpInvalidateHoverImmediately];
}

- (void)cpScrollHoverInvalidate:(NSNotification *)note {
    (void)note;
    [self cpInvalidateHoverImmediately]; // 滚动期间一律抑制 hover
    // 停止滚动(bounds 不再变)120ms 后按真实鼠标位置恢复唯一 hover;代际失效防堆积。
    NSInteger generation = self.hoverRevalidateGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation != self.hoverRevalidateGeneration) return;
        [self cpRevalidateHoverUnderMouse];
    });
}

// 命中恢复:鼠标停在 Todo 子按钮(勾选/标题/编辑/删除)上时,必须同时恢复其
// CPTodoRowView 祖先——否则只有子按钮 hover,行高亮与行尾动作组不恢复。
- (void)cpRestoreHoverForHitView:(NSView *)hit {
    CPTodoRowView *row = nil;
    CPHoverButton *button = nil;
    for (NSView *v = hit; v && v != self.card; v = v.superview) {
        if (!row && [v isKindOfClass:CPTodoRowView.class]) row = (CPTodoRowView *)v;
        if (!button && [v isKindOfClass:CPHoverButton.class]) button = (CPHoverButton *)v;
    }
    if (row) [row cpSetRowHovered:YES];
    if (button) [button cpSetHovered:YES];
}

- (void)cpRevalidateHoverUnderMouse {
    if (!self.window.isVisible) return;
    NSPoint p = [self.card convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
    [self cpRestoreHoverForHitView:[self.card hitTest:p]];
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
@property CPReviewStore *reviewStore;
@property CPRippleView *orbRippleView;
@property BOOL orbReduceMotion;
@property BOOL orbHovered;
- (void)show;
- (void)renderWithAgents:(NSArray<CPAgent *> *)agents selectedAgent:(CPAgent *)agent;
- (NSRect)dockRect;
- (void)setMode:(NSInteger)mode;
- (void)updateOrbRipples;
- (void)pillMouseDown:(NSEvent *)event;
- (void)pillMouseDragged:(NSEvent *)event;
- (void)pillMouseUp:(NSEvent *)event;
- (void)mouseEntered:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
@end

@implementation CPDockWindowController

static const CGFloat CPOrbSize = 48.0;
static const CGFloat CPOrbMargin = 18.0; // 透明安全边距:容纳涟漪 1.55 倍扩散、阴影与角标
static const CGFloat CPOrbWindowSize = CPOrbSize + CPOrbMargin * 2.0; // 84
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
    self.reviewStore = [[CPReviewStore alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    [self buildWindow];
    return self;
}

- (void)buildWindow {
    self.window = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize)
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

    CPDockPillView *pill = [[CPDockPillView alloc] initWithFrame:NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize)];
    pill.controller = self;
    pill.wantsLayer = YES;
    self.pill = pill;
    self.window.contentView = pill;

    // 统一涟漪组件(在球体下层):固定基础环 + 8 层明暗成对错峰涟漪,由球心向外同心扩散。
    // CPRippleView 自身 frame 已预留 1.55 倍扩散空间,不改变 pill/球体尺寸。
    NSRect orbRect = NSMakeRect(CPOrbMargin, CPOrbMargin, CPOrbSize, CPOrbSize);
    CGPoint orbCenter = CGPointMake(NSMidX(orbRect), NSMidY(orbRect));
    self.orbRippleView = [[CPRippleView alloc] initWithRingDiameter:CPOrbSize + 4.0 lineWidth:0.75]; // 圆环比球体各大 2pt
    self.orbRippleView.ripplePeakOpacity = 0.28; // 球体底色更亮,白峰峰值略高(黑谷按比例 0.23)
    NSRect rippleFrame = self.orbRippleView.frame;
    self.orbRippleView.frame = NSMakeRect(orbCenter.x - rippleFrame.size.width / 2.0,
                                          orbCenter.y - rippleFrame.size.height / 2.0,
                                          rippleFrame.size.width, rippleFrame.size.height);
    [pill addSubview:self.orbRippleView];

    // Orb floating pill：48x48 球体居中于 84x84 安全窗口内
    NSView *floatingPill = [[NSView alloc] initWithFrame:orbRect];
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

    NSImageView *iconView = [[NSImageView alloc] initWithFrame:NSMakeRect(11, 11, 26, 26)];
    iconView.image = CPSymbol(@"waveform.path.ecg", 22, CPAccent());
    iconView.contentTintColor = CPAccent();
    [floatingPill addSubview:iconView];
    self.iconView = iconView;

    // Badge: 挂在 pill 上(不随球体缩放),定位于球体右上角外沿、安全区内
    NSView *badgeView = [[NSView alloc] initWithFrame:NSMakeRect(60, 60, 16, 16)];
    badgeView.wantsLayer = YES;
    badgeView.layer.backgroundColor = CPAccent().CGColor;
    badgeView.layer.cornerRadius = 8.0;
    badgeView.layer.shadowColor = [NSColor colorWithSRGBRed:0.0 green:0.0 blue:0.0 alpha:0.16].CGColor;
    badgeView.layer.shadowOffset = CGSizeMake(0, 2);
    badgeView.layer.shadowRadius = 4.0;
    badgeView.layer.shadowOpacity = 1.0;
    badgeView.hidden = YES;
    [pill addSubview:badgeView];
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
    [self updateOrbRipples];

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
    // 悬浮球模式下只跟踪球体可见圆形,透明安全边距不响应 hover。
    NSRect trackRect = (self.mode == 0 && !self.docked && !self.floatingPill.hidden)
        ? self.floatingPill.frame : self.pill.bounds;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:trackRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
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
        if (self.mode == 0) {
            // freeX/freeY 始终表示球体可见圆形的屏幕原点;窗口加上透明安全边距。
            x = self.freeX - CPOrbMargin;
            y = self.freeY - CPOrbMargin;
            w = CPOrbWindowSize;
            h = CPOrbWindowSize;
            self.floatingPill.hidden = NO;
            self.barView.hidden = YES;
            self.stripView.hidden = YES;
        } else {
            x = self.freeX;
            y = self.freeY;
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
    [self updateOrbRipples];
}

- (void)peek:(BOOL)show {
    if (!self.docked || self.mode != 0) return;
    NSScreen *screen = self.targetScreen;
    NSRect visible = screen.visibleFrame;
    CGFloat y = self.freeY - CPOrbMargin;
    CGFloat h = CPOrbWindowSize;
    CGFloat w = CPOrbWindowSize;
    CGFloat x;
    if (self.dockEdge == NSRectEdgeMaxX) {
        x = NSMaxX(visible) - CPOrbSize - CPOrbMargin; // 球体右沿贴屏幕边
    } else {
        x = NSMinX(visible) - CPOrbMargin; // 球体左沿贴屏幕边
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
        self.orbHovered = YES;
        [self updateOrbRipples];
        // hover 反馈只允许静态颜色变化:禁止整体放大、阴影呼吸、图标跳动。
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.18;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.floatingPill.animator.layer.borderColor = CPAccent().CGColor;
        }];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (self.dragging) return;
    if (self.docked && self.mode == 0) {
        [self scheduleUnpeek];
    } else if (!self.docked && self.mode == 0) {
        self.orbHovered = NO;
        [self updateOrbRipples];
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.22;
            context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
            self.floatingPill.animator.layer.borderColor = CPBorder().CGColor;
        }];
    }
}

- (void)startPulseAnimation {
    [self updateOrbRipples];
}

// 悬浮球统一涟漪:状态色 + 速度由全部 agent 的最高优先状态决定。
// reduce motion 时只留固定状态环(实色);hover/drag 时隐藏动效。
- (void)updateOrbRipples {
    BOOL orbVisible = (self.mode == 0 && !self.docked && !self.floatingPill.hidden);
    self.orbRippleView.hidden = !orbVisible;
    if (!orbVisible) {
        // 悬浮球不可见:移除全部无限涟漪(不可见时不参与合成),并作废参数缓存,
        // 下次可见时 updateRipples 一定全量重应用。
        for (CAShapeLayer *ring in self.orbRippleView.rippleLayers) [ring removeAllAnimations];
        for (CAShapeLayer *ring in self.orbRippleView.rippleTroughLayers) [ring removeAllAnimations];
        [self.orbRippleView invalidateRippleCache];
        return;
    }
    self.orbRippleView.displayStatus = CPDisplayStatusForAgents(self.agents, self.reviewStore);
    self.orbRippleView.reduceMotion = self.orbReduceMotion;
    self.orbRippleView.rippleSuppressed = self.orbHovered || self.dragging;
    [self.orbRippleView updateRipples];
}

- (void)pillMouseDown:(NSEvent *)event {
    [self cancelUnpeek];
    self.dragging = YES;
    self.didMove = NO;
    self.dragStartMouse = [NSEvent mouseLocation];
    self.dragStartOrigin = NSMakePoint(self.freeX, self.freeY); // 球体可见圆形原点
    if (self.docked) {
        self.docked = NO;
        NSPoint loc = self.dragStartMouse;
        self.freeX = loc.x - [self currentWidth] / 2.0;
        self.freeY = loc.y - [self currentHeight] / 2.0;
        [self applyFrame];
        self.dragStartOrigin = NSMakePoint(self.freeX, self.freeY);
    }
    [self updateOrbRipples];
    if (self.mode == 0) {
        // pressed 反馈只做静态颜色变化,禁止悬浮球缩放与阴影变化。
        self.floatingPill.layer.borderColor = CPAccent().CGColor;
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
    self.floatingPill.layer.borderColor = self.orbHovered ? CPAccent().CGColor : CPBorder().CGColor;
    if (self.didMove) {
        [self snapToEdge];
    } else if (self.onPillClicked) {
        self.onPillClicked();
    }
    [self updateOrbRipples];
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
    self.orbReduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;

    // 角标:0 隐藏;1–9 圆形;10–99 胶囊(宽度随文字);>=100 显示 "99+"。
    NSInteger count = CPBadgeCountForAgents(agents, self.reviewStore);
    NSString *badgeText = count >= 100 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)count];
    NSFont *badgeFont = [NSFont systemFontOfSize:9 weight:NSFontWeightBold];
    CGFloat badgeH = 16.0;
    CGFloat badgeW = badgeH; // 1–9 圆形
    if (count >= 10) {
        CGFloat textW = ceil([badgeText sizeWithAttributes:@{NSFontAttributeName: badgeFont}].width);
        badgeW = MAX(badgeH, textW + 8.0); // 胶囊,宽度随文字
    }
    // 球体右上角外沿(45° 方向),仍在 84x84 安全区内,不遮图标。
    CGFloat cx = CPOrbMargin + CPOrbSize / 2.0 + (CPOrbSize / 2.0) * 0.7071;
    CGFloat cy = cx;
    self.badgeView.frame = NSMakeRect(round(cx - badgeW / 2.0), round(cy - badgeH / 2.0), badgeW, badgeH);
    self.badgeView.layer.cornerRadius = badgeH / 2.0;
    self.badgeLabel.font = badgeFont;
    self.badgeLabel.frame = self.badgeView.bounds; // 文字水平垂直居中
    self.badgeLabel.stringValue = badgeText;
    self.badgeView.hidden = count == 0;
    self.badgeLabel.hidden = count == 0;
    [self renderDockAgents];
    [self updateOrbRipples];
}

- (NSRect)dockRect {
    // 悬浮球可见时返回球体圆形框(不含透明安全边距),供工作台定位与点击判定。
    if (self.mode == 0 && !self.floatingPill.hidden) {
        return NSInsetRect(self.window.frame, CPOrbMargin, CPOrbMargin);
    }
    return self.window.frame;
}

@end

@implementation CPDockPillView
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    if ([hit isKindOfClass:NSButton.class]) return hit;
    // 悬浮球模式下,透明安全边距不吞点击(穿透到下层)。
    CPDockWindowController *c = (CPDockWindowController *)self.controller;
    if (c && c.mode == 0 && !c.floatingPill.hidden && !NSPointInRect(point, c.floatingPill.frame)) return nil;
    return self;
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

static const CGFloat CPHUDContentWidth = 400.0;
static const CGFloat CPHUDContentHeight = 244.0;
static const CGFloat CPHUDTaskAreaHeight = 116.0; // 任务区固定高度:恰好露出约 2 张卡,其余滚动
static const CGFloat CPHUDInset = 14.0;
static const CGFloat CPHUDCollapsedWidth = 6.0;
static const CGFloat CPHUDCollapsedHeight = 72.0;
static const CGFloat CPHUDHandleVisualWidth = 3.0;
static const CGFloat CPHUDHandleVisualHeight = 44.0;

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

@class CPHUDWindowController;
// 图例「?」小圆钮:hover(或点击,键盘可达)时在其上方展开状态图例浮层。
@interface CPLegendButton : CPHoverButton
@property (weak) CPHUDWindowController *hud;
@end

// HUD 任务卡按钮:点击指向 taskCardClicked:(直达所属 Agent),稳定携带 taskID。
// 点击时按 taskID 在当前数据里重新解析任务对象,刷新/重建后不会因旧指针或索引错位打开错误任务。
@interface CPHUDTaskCardButton : CPHoverButton
@property NSString *taskID;
@end

@implementation CPHUDTaskCardButton @end

@interface CPHUDWindowController : NSObject
@property NSPanel *window;
@property NSView *shadowCarrier;
@property NSView *visualView; // 强不透明深石墨卡片(圆角裁切)
@property NSView *container;
@property NSView *handleView;
@property NSView *railView;
@property NSView *backgroundClickView;
@property NSTrackingArea *trackingArea;
@property NSTimer *hoverTimer;
@property BOOL expanded;
@property BOOL stickyExpanded; // --visual-test-hud: 强制展开不收回
@property BOOL pendingCollapse;
@property NSUInteger transitionGen; // 展开/收回动画代际:新动画使旧 completion 失效,防止快速进出时互相收尾留残影
@property NSArray<CPAgent *> *agents;
@property CPAgent *selectedAgent;
@property CPReviewStore *reviewStore;
@property NSStackView *agentList;
@property NSStackView *taskList;
@property NSScrollView *taskScrollView;
// 任务卡打开入口(安全注入点):默认走 CPOpenAgentTask 深链/唤起;自测注入假实现,绝不真的打开 Codex/Kimi。
@property (copy) BOOL (^taskOpener)(CPAgent *agent, CPTask *task);
@property NSTextField *agentNameLabel;
@property NSTextField *agentStatusLabel;
@property NSTextField *agentUpdatedLabel;
@property NSView *bottomBar;      // 底行:左侧任务数量/滑动提示,右侧图例「?」钮
@property NSTextField *moreLabel;
@property NSButton *legendButton;
@property NSPanel *legendPanel;
@property void (^onClicked)(void);
- (void)show;
- (void)updateWithAgents:(NSArray<CPAgent *> *)agents selectedAgent:(CPAgent *)agent;
- (NSRect)expandedFrameInVisibleRect:(NSRect)visible;
- (NSRect)collapsedFrameInVisibleRect:(NSRect)visible;
- (void)showLegend;
- (void)hideLegend;
@end

@implementation CPLegendButton
- (void)mouseEntered:(NSEvent *)event { [super mouseEntered:event]; [self.hud showLegend]; }
- (void)mouseExited:(NSEvent *)event { [super mouseExited:event]; [self.hud hideLegend]; }
@end

@implementation CPHUDWindowController

static const CGFloat CPHUDAgentRail = 64.0;

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

    self.handleView = [[NSView alloc] initWithFrame:NSMakeRect(CPHUDCollapsedWidth - CPHUDHandleVisualWidth,
                                                               (CPHUDCollapsedHeight - CPHUDHandleVisualHeight) / 2.0,
                                                               CPHUDHandleVisualWidth,
                                                               CPHUDHandleVisualHeight)];
    self.handleView.wantsLayer = YES;
    self.handleView.layer.backgroundColor = [CPAccent() colorWithAlphaComponent:0.58].CGColor;
    self.handleView.layer.cornerRadius = CPHUDHandleVisualWidth / 2.0;
    self.handleView.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [self.shadowCarrier addSubview:self.handleView];

    // 强不透明深石墨/深海军蓝卡片:1px 描边 + 圆角裁切,阴影由外层 carrier 投影。
    NSView *visualView = [[NSView alloc] initWithFrame:NSMakeRect(CPHUDInset, CPHUDInset, CPHUDContentWidth, CPHUDContentHeight)];
    visualView.wantsLayer = YES;
    visualView.layer.backgroundColor = CPSurface().CGColor;
    visualView.layer.cornerRadius = 16.0;
    visualView.layer.borderWidth = 1.0;
    visualView.layer.borderColor = CPBorder().CGColor;
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

    // 左侧 Agent rail:只放图标状态按钮
    NSView *rail = [[NSView alloc] initWithFrame:NSZeroRect];
    rail.wantsLayer = YES;
    rail.layer.backgroundColor = CPBg().CGColor;
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:rail];
    self.railView = rail;

    self.agentList = [NSStackView stackViewWithViews:@[]];
    self.agentList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.agentList.spacing = 10; // 图标/环缩小后同步收紧节奏
    self.agentList.alignment = NSLayoutAttributeCenterX;
    self.agentList.translatesAutoresizingMaskIntoConstraints = NO;
    [rail addSubview:self.agentList];

    NSView *railSep = [[NSView alloc] initWithFrame:NSZeroRect];
    railSep.wantsLayer = YES;
    railSep.layer.backgroundColor = CPBorder().CGColor;
    railSep.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:railSep];

    // 右侧:Agent 名 / 真实状态 / 更新时间 / 任务卡
    NSTextField *agentName = [NSTextField labelWithString:@"Codex"];
    agentName.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
    agentName.textColor = CPFg();
    agentName.lineBreakMode = NSLineBreakByTruncatingTail;
    agentName.maximumNumberOfLines = 1;
    agentName.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:agentName];
    self.agentNameLabel = agentName;

    NSTextField *agentStatus = [NSTextField labelWithString:@"空闲"];
    agentStatus.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    agentStatus.textColor = CPMuted();
    agentStatus.lineBreakMode = NSLineBreakByTruncatingTail;
    agentStatus.maximumNumberOfLines = 1;
    // 与更新时间竞争宽度时,状态标签先截断,保证时间不重叠、不被挤没。
    [agentStatus setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    agentStatus.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:agentStatus];
    self.agentStatusLabel = agentStatus;

    NSTextField *agentUpdated = [NSTextField labelWithString:@""];
    agentUpdated.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    agentUpdated.textColor = CPMuted();
    agentUpdated.lineBreakMode = NSLineBreakByTruncatingTail;
    agentUpdated.maximumNumberOfLines = 1;
    agentUpdated.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:agentUpdated];
    self.agentUpdatedLabel = agentUpdated;

    // 任务区域 NSScrollView 化:默认可见约 2 张卡,超出部分触控板/滚轮纵向滑动浏览;
    // overlay scroller 自动隐藏,滚动事件由滚动区消费,不会误触背景「打开工作台」。
    NSScrollView *taskScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    taskScroll.translatesAutoresizingMaskIntoConstraints = NO;
    taskScroll.drawsBackground = NO;
    taskScroll.borderType = NSNoBorder;
    taskScroll.hasVerticalScroller = YES;
    taskScroll.hasHorizontalScroller = NO;
    taskScroll.scrollerStyle = NSScrollerStyleOverlay;
    taskScroll.scrollerKnobStyle = NSScrollerKnobStyleDark;
    taskScroll.autohidesScrollers = YES;
    taskScroll.horizontalScrollElasticity = NSScrollElasticityNone;
    self.taskScrollView = taskScroll;
    [container addSubview:taskScroll];

    self.taskList = [CPFlippedStackView stackViewWithViews:@[]]; // 翻转:首个任务在顶部,滚动回顶即 origin 0
    self.taskList.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.taskList.spacing = 8;
    self.taskList.alignment = NSLayoutAttributeLeading;
    self.taskList.translatesAutoresizingMaskIntoConstraints = NO;
    taskScroll.documentView = self.taskList;

    // 底行(单行,不拉长 HUD 高度):左侧任务数量/滑动提示,右侧 14x14 图例「?」小圆钮。
    NSView *bottomBar = [[NSView alloc] initWithFrame:NSZeroRect];
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:bottomBar];
    self.bottomBar = bottomBar;

    NSTextField *more = CPLabel(@"", 11, NSFontWeightRegular, CPMuted());
    more.maximumNumberOfLines = 1;
    more.translatesAutoresizingMaskIntoConstraints = NO;
    [bottomBar addSubview:more];
    self.moreLabel = more;

    // 图例钮:低对比 1px 描边 + muted 文字,无 accent、无系统默认按钮样式。
    CPLegendButton *legend = [CPLegendButton buttonWithTitle:@"?" target:self action:@selector(legendClicked:)];
    legend.bordered = NO;
    legend.hud = self;
    legend.title = @"?";
    legend.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    legend.contentTintColor = CPMuted();
    legend.toolTip = @"状态图例";
    legend.accessibilityLabel = @"状态图例";
    legend.cpAlwaysBorder = YES;
    legend.layer.cornerRadius = 7.0;
    legend.translatesAutoresizingMaskIntoConstraints = NO;
    [bottomBar addSubview:legend];
    self.legendButton = legend;

    [NSLayoutConstraint activateConstraints:@[
        [rail.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [rail.topAnchor constraintEqualToAnchor:container.topAnchor],
        [rail.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [rail.widthAnchor constraintEqualToConstant:CPHUDAgentRail],

        [self.agentList.topAnchor constraintEqualToAnchor:rail.topAnchor constant:16],
        [self.agentList.centerXAnchor constraintEqualToAnchor:rail.centerXAnchor],
        [self.agentList.bottomAnchor constraintLessThanOrEqualToAnchor:rail.bottomAnchor constant:-12],

        [railSep.leadingAnchor constraintEqualToAnchor:rail.trailingAnchor],
        [railSep.topAnchor constraintEqualToAnchor:container.topAnchor],
        [railSep.bottomAnchor constraintEqualToAnchor:container.bottomAnchor],
        [railSep.widthAnchor constraintEqualToConstant:1],

        [agentName.leadingAnchor constraintEqualToAnchor:railSep.trailingAnchor constant:18],
        [agentName.topAnchor constraintEqualToAnchor:container.topAnchor constant:18],
        [agentName.trailingAnchor constraintLessThanOrEqualToAnchor:container.trailingAnchor constant:-18],

        [agentStatus.leadingAnchor constraintEqualToAnchor:agentName.leadingAnchor],
        [agentStatus.topAnchor constraintEqualToAnchor:agentName.bottomAnchor constant:5],
        // 状态长文本先截断,绝不让它压到右侧更新时间;两者之间至少留 12pt。
        [agentStatus.trailingAnchor constraintLessThanOrEqualToAnchor:agentUpdated.leadingAnchor constant:-12],

        [agentUpdated.leadingAnchor constraintGreaterThanOrEqualToAnchor:agentStatus.trailingAnchor constant:12],
        [agentUpdated.centerYAnchor constraintEqualToAnchor:agentStatus.centerYAnchor],
        [agentUpdated.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18],

        [self.taskScrollView.leadingAnchor constraintEqualToAnchor:agentName.leadingAnchor],
        [self.taskScrollView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18],
        [self.taskScrollView.topAnchor constraintEqualToAnchor:agentStatus.bottomAnchor constant:16],
        // 固定约 2 张卡高度(2×54+8),HUD 外框尺寸不变;更多任务在区内滚动。
        [self.taskScrollView.heightAnchor constraintEqualToConstant:CPHUDTaskAreaHeight],
        [self.taskScrollView.bottomAnchor constraintLessThanOrEqualToAnchor:bottomBar.topAnchor constant:-8],

        // documentView 宽度跟随 clip view,任务卡横向 fill 不溢出;高度由 stack 内容驱动。
        [self.taskList.leadingAnchor constraintEqualToAnchor:taskScroll.contentView.leadingAnchor],
        [self.taskList.topAnchor constraintEqualToAnchor:taskScroll.contentView.topAnchor],
        [self.taskList.widthAnchor constraintEqualToAnchor:taskScroll.contentView.widthAnchor],

        [bottomBar.leadingAnchor constraintEqualToAnchor:agentName.leadingAnchor],
        [bottomBar.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18],
        [bottomBar.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-12],
        [bottomBar.heightAnchor constraintEqualToConstant:20],

        [more.leadingAnchor constraintEqualToAnchor:bottomBar.leadingAnchor],
        [more.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
        [more.trailingAnchor constraintLessThanOrEqualToAnchor:legend.leadingAnchor constant:-8],

        [legend.trailingAnchor constraintEqualToAnchor:bottomBar.trailingAnchor],
        [legend.centerYAnchor constraintEqualToAnchor:bottomBar.centerYAnchor],
        [legend.widthAnchor constraintEqualToConstant:14],
        [legend.heightAnchor constraintEqualToConstant:14]
    ]];

    [self updateTracking];
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
    if (self.stickyExpanded) return; // --visual-test-hud 保持展开
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
    CGFloat x, y;
    if (self.expanded) {
        // 展开时把手贴在卡片右缘顶部,成为卡片的延续(tab),同色系衔接。
        x = MAX(0, sz.width - CPHUDInset - CPHUDCollapsedWidth);
        y = MAX(0, sz.height - CPHUDInset - CPHUDCollapsedHeight);
    } else {
        x = MAX(0, sz.width - CPHUDHandleVisualWidth);
        y = MAX(0, (sz.height - CPHUDHandleVisualHeight) / 2.0);
    }
    CGFloat width = self.expanded ? CPHUDCollapsedWidth : CPHUDHandleVisualWidth;
    CGFloat height = self.expanded ? CPHUDCollapsedHeight : CPHUDHandleVisualHeight;
    self.handleView.frame = NSMakeRect(x, y, width, height);
}

- (void)cpSetRailAnimationsPaused:(BOOL)paused {
    for (NSView *v in self.agentList.arrangedSubviews) {
        if ([v isKindOfClass:CPAgentStatusButton.class]) ((CPAgentStatusButton *)v).animationsPaused = paused;
    }
}

- (void)expand {
    if (self.expanded) return;
    self.expanded = YES;
    [self cpSetRailAnimationsPaused:NO]; // 可见:恢复涟漪
    NSUInteger gen = ++self.transitionGen;
    self.visualView.alphaValue = 0.0;
    self.visualView.hidden = NO;
    // 把手只负责唤出。展开后隐藏，避免在右上角形成一条“滚动条/障碍物”。
    self.handleView.hidden = YES;
    NSRect frame = [self expandedFrame];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.22;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [[self.window animator] setFrame:frame display:YES];
        self.visualView.animator.alphaValue = 1.0;
    } completionHandler:^{
        if (gen != self.transitionGen) return; // 期间已开始收回,放弃本次收尾
        [self updateTracking];
    }];
    self.shadowCarrier.layer.shadowColor = [NSColor colorWithSRGBRed:0.078 green:0.078 blue:0.086 alpha:0.18].CGColor;
    self.shadowCarrier.layer.shadowOffset = CGSizeMake(0, 8);
    self.shadowCarrier.layer.shadowRadius = 24.0;
    self.shadowCarrier.layer.shadowOpacity = 1.0;
    self.shadowCarrier.layer.shadowPath = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(CPHUDInset, CPHUDInset, CPHUDContentWidth, CPHUDContentHeight) xRadius:16 yRadius:16].CGPath;
}

- (void)collapse {
    if (!self.expanded || self.stickyExpanded) return;
    [self hideLegend]; // 收回 HUD 时图例浮层一并收起
    self.expanded = NO;
    NSUInteger gen = ++self.transitionGen;
    self.shadowCarrier.layer.shadowOpacity = 0.0;
    NSRect frame = [self collapsedFrame];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = 0.18;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        self.visualView.animator.alphaValue = 0.0;
        [[self.window animator] setFrame:frame display:YES];
    } completionHandler:^{
        if (gen != self.transitionGen) return; // 期间已重新展开,放弃本次收尾
        self.visualView.hidden = YES;
        self.visualView.alphaValue = 1.0;
        [self cpSetRailAnimationsPaused:YES]; // 不可见:暂停 8 层无限涟漪,不再参与合成
        self.handleView.layer.backgroundColor = [CPAccent() colorWithAlphaComponent:0.58].CGColor;
        self.handleView.layer.borderWidth = 0.0;
        self.handleView.layer.cornerRadius = CPHUDHandleVisualWidth / 2.0;
        self.handleView.hidden = NO;
        [self layoutHandleToTopRightOfCarrier];
        [self updateTracking];
    }];
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

    // 更新时间:选中 Agent 最近一次任务活动,格式化处理。
    NSDate *latest = nil;
    for (CPTask *t in agent.tasks) {
        if (!latest || [t.updatedAt compare:latest] == NSOrderedDescending) latest = t.updatedAt;
    }
    if (latest) {
        self.agentUpdatedLabel.stringValue = [NSString stringWithFormat:@"更新于 %@", CPFormatDateCN(latest)];
    } else {
        self.agentUpdatedLabel.stringValue = @"暂无活动";
    }

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
        CPAgentStatusButton *btn = [[CPAgentStatusButton alloc] initWithFrame:NSMakeRect(0, 0, 30, 30)];
        btn.reduceMotion = reduceMotion;
        btn.target = self;
        btn.action = @selector(agentButtonClicked:);
        btn.tag = (NSInteger)i;
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [btn updateWithAgent:a displayStatus:ds selected:(a == agent)];
        [btn.widthAnchor constraintEqualToConstant:30].active = YES;
        [btn.heightAnchor constraintEqualToConstant:30].active = YES;
        [self.agentList addArrangedSubview:btn];
    }
    // HUD 收起时 rail 不可见:暂停全部无限涟漪,不参与合成;展开时恢复。
    [self cpSetRailAnimationsPaused:!self.expanded];

    // Task list
    while (self.taskList.arrangedSubviews.count > 0) {
        NSView *v = self.taskList.arrangedSubviews.lastObject;
        [self.taskList removeArrangedSubview:v];
        [v removeFromSuperview];
    }

    // 右侧只渲染当前选中 Agent 的真实任务,全部建卡,任务区内纵向滚动浏览。
    NSArray<CPTask *> *displayTasks = agent.tasks;
    if (displayTasks.count == 0) {
        NSTextField *empty = [NSTextField labelWithString:@"当前没有任务"];
        empty.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        empty.textColor = CPMuted();
        [self.taskList addArrangedSubview:empty];
        self.moreLabel.stringValue = @"";
    } else {
        for (CPTask *task in displayTasks) {
            NSButton *card = [self taskCard:task];
            [self.taskList addArrangedSubview:card];
            [card.widthAnchor constraintEqualToAnchor:self.taskList.widthAnchor].active = YES;
        }
        // 超过默认可见的约 2 张时,底行给轻量滑动提示,不再截断任务列表。
        self.moreLabel.stringValue = displayTasks.count > 2
            ? [NSString stringWithFormat:@"共 %lu 个活动 · 可滚动查看", (unsigned long)displayTasks.count]
            : @"";
    }
    // Agent 切换/数据刷新重建内容后回到列表顶部,避免错位。
    [self.taskScrollView.contentView scrollToPoint:NSZeroPoint];
    [self.taskScrollView reflectScrolledClipView:self.taskScrollView.contentView];
}

// 任务卡点击:直达所属 Agent 的对应任务。
// 路由顺序:Codex/kimi-client 走 CPDeepLinkForAgentTask 精确深链;kimi-cli 等无精确深链的来源
// 由 CPOpenAgentTask 降级为至少唤起所属 Agent 应用;只有连所属应用都打不开时才回退工作台。
// 按卡片携带的 taskID 在当前选中 Agent 的任务里重新解析,刷新后不会错位打开错误任务。
- (void)taskCardClicked:(CPHUDTaskCardButton *)sender {
    CPAgent *agent = self.selectedAgent ?: self.agents.firstObject;
    if (!agent || !sender.taskID.length) return;
    CPTask *task = nil;
    for (CPTask *t in agent.tasks) {
        if ([t.taskID isEqualToString:sender.taskID]) { task = t; break; }
    }
    if (!task) return; // 任务已在刷新中消失:不做动作,不伪造已查看
    BOOL opened = self.taskOpener ? self.taskOpener(agent, task) : CPOpenAgentTask(agent, task);
    if (!opened) {
        // 无法打开所属 Agent:回退打开工作台,已查看标记交给工作台打开详情的原有逻辑。
        [self hudClicked:sender];
        return;
    }
    // 成功打开所属 Agent:这条提醒视为已查看,角标经 CPTaskReviewed 立即更新。
    if (task.status == CPStatusCompleted ||
        task.status == CPStatusAttention ||
        task.status == CPStatusFailed ||
        task.status == CPStatusWaiting) {
        [self.reviewStore markTaskReviewed:task agentID:agent.agentID];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CPTaskReviewed" object:nil];
    }
}

// 状态图例浮层:深色 surface-warm 底 + 1px border-soft 描边 + 圆角 8 + 阴影;
// 五行速查(7px 色点 + 状态名),底部一行小字说明取值规则。
- (void)buildLegendPanel {
    CGFloat width = 200.0, rowH = 20.0, padX = 12.0, padTop = 10.0, footerH = 28.0;
    CGFloat height = padTop + rowH * 5 + footerH + 10.0;
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                                                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                  backing:NSBackingStoreBuffered
                                                    defer:NO];
    panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    panel.level = NSStatusWindowLevel + 3;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                               NSWindowCollectionBehaviorFullScreenAuxiliary |
                               NSWindowCollectionBehaviorStationary;

    NSView *card = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, height)];
    card.wantsLayer = YES;
    card.layer.backgroundColor = CPSurface().CGColor; // surface-warm
    card.layer.cornerRadius = 8.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = CPBorder().CGColor; // border-soft
    card.layer.masksToBounds = YES;
    panel.contentView = card;

    NSArray<NSArray *> *rows = @[
        @[@"失败", CPRed()],
        @[@"等待处理", CPOrange()],
        @[@"已就绪", CPBlue()],
        @[@"运行中", CPGreen()],
        @[@"待机", CPDisplayStatusColor(CPDisplayStatusIdle)],
    ];
    for (NSUInteger i = 0; i < rows.count; i++) {
        CGFloat y = height - padTop - rowH * (CGFloat)(i + 1) + (rowH - 7.0) / 2.0;
        NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(padX, y, 7, 7)];
        dot.image = CPDotImage(7, rows[i][1]);
        [card addSubview:dot];
        NSTextField *label = CPLabel(rows[i][0], 12, NSFontWeightRegular, CPFg2());
        label.maximumNumberOfLines = 1;
        label.frame = NSMakeRect(padX + 13.0, height - padTop - rowH * (CGFloat)(i + 1) + 2.0, width - padX * 2 - 13.0, rowH - 4.0);
        [card addSubview:label];
    }

    NSView *sep = [[NSView alloc] initWithFrame:NSMakeRect(padX, footerH + 4.0, width - padX * 2, 1)];
    sep.wantsLayer = YES;
    sep.layer.backgroundColor = CPBorder().CGColor;
    [card addSubview:sep];

    NSTextField *footer = CPLabel(@"Agent 环跟随最近更新的任务", 10, NSFontWeightRegular, CPMuted());
    footer.maximumNumberOfLines = 1;
    footer.frame = NSMakeRect(padX, 8.0, width - padX * 2, 14.0);
    [card addSubview:footer];

    self.legendPanel = panel;
}

// hover/点击(键盘可达)在「?」钮上方展开图例;移走/失焦/收回 HUD 时收起。
- (void)showLegend {
    if (!self.legendPanel) [self buildLegendPanel];
    if (self.legendButton.window) {
        NSRect inWindow = [self.legendButton convertRect:self.legendButton.bounds toView:nil];
        NSRect onScreen = [self.legendButton.window convertRectToScreen:inWindow];
        NSRect frame = self.legendPanel.frame;
        frame.origin.x = NSMaxX(onScreen) - frame.size.width;
        frame.origin.y = NSMaxY(onScreen) + 6.0;
        [self.legendPanel setFrame:frame display:NO];
    }
    [self.legendPanel orderFront:nil];
}

- (void)hideLegend {
    [self.legendPanel orderOut:nil];
}

- (void)legendClicked:(id)sender {
    (void)sender;
    if (self.legendPanel.isVisible) [self hideLegend];
    else [self showLegend];
}

// 任务卡:标题(截断) + 一行真实活动/状态,点击直达所属 Agent 的对应任务(见 taskCardClicked:)。
- (NSButton *)taskCard:(CPTask *)task {
    CPHUDTaskCardButton *card = [CPHUDTaskCardButton buttonWithTitle:@"" target:self action:@selector(taskCardClicked:)];
    card.taskID = task.taskID;
    card.bordered = NO;
    [card setButtonType:NSButtonTypeMomentaryChange];
    card.wantsLayer = YES;
    card.layer.cornerRadius = 12.0;
    card.layer.borderWidth = 1.0;
    card.layer.borderColor = CPBorder().CGColor;
    ((CPHoverButton *)card).cpBaseBackground = CPBg();
    card.translatesAutoresizingMaskIntoConstraints = NO;
    [card.heightAnchor constraintEqualToConstant:54].active = YES;

    NSImageView *dot = [[NSImageView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
    dot.image = CPStatusDot(8, task.status);
    dot.translatesAutoresizingMaskIntoConstraints = NO;
    [dot.widthAnchor constraintEqualToConstant:8].active = YES;
    [dot.heightAnchor constraintEqualToConstant:8].active = YES;

    NSTextField *title = [NSTextField labelWithString:task.title];
    title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
    title.textColor = CPFg();
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.maximumNumberOfLines = 1;

    NSString *activity = task.activity.length ? task.activity : CPStatusTitle(task.status);
    NSTextField *sub = [NSTextField labelWithString:[NSString stringWithFormat:@"%@ · %@", CPStatusTitle(task.status), activity]];
    sub.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    sub.textColor = CPMuted();
    sub.lineBreakMode = NSLineBreakByTruncatingTail;
    sub.maximumNumberOfLines = 1;

    NSStackView *text = [NSStackView stackViewWithViews:@[title, sub]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 2;

    NSStackView *h = [NSStackView stackViewWithViews:@[dot, text]];
    h.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    h.alignment = NSLayoutAttributeCenterY;
    h.spacing = 10;
    h.translatesAutoresizingMaskIntoConstraints = NO;
    [card addSubview:h];
    [NSLayoutConstraint activateConstraints:@[
        [h.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [h.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14],
        [h.centerYAnchor constraintEqualToAnchor:card.centerYAnchor]
    ]];
    return card;
}

@end

#pragma mark - Refresh Pipeline (性能:后台读取 + 合并 + 签名跳过)

// 可见数据签名:逐 agent/task 拼接会影响界面的字段(id/状态/更新时间/tokens/标题/活动)。
// 后台读出的新数据与已应用签名一致时,跳过工作台/Dock/HUD/菜单全部重建——
// 否则每 3s 反复拆建 AppKit 视图、重挂 8 层无限涟漪,是主线程卡顿与 CPU 的主要来源之一。
static NSString *CPAgentsSignature(NSArray<CPAgent *> *agents) {
    NSMutableString *sig = [NSMutableString string];
    for (CPAgent *a in agents) {
        [sig appendFormat:@"A:%@|%d|", a.agentID, (int)a.status];
        for (CPTask *t in a.tasks) {
            [sig appendFormat:@"T:%@|%d|%.3f|%ld|%tu|%tu;",
                              t.taskID, (int)t.status, t.updatedAt.timeIntervalSince1970,
                              (long)t.tokensUsed, t.title.hash, t.activity.hash];
        }
    }
    return sig;
}

// 刷新闸门(仅主线程使用):同一时刻最多一个后台读取;读取期间到达的请求合并为一次 pending,
// 结束后补跑一次,过期结果不会覆盖更新的读取。
@interface CPRefreshGate : NSObject
@property (nonatomic, readonly) BOOL inFlight;
- (BOOL)beginRefresh;                 // YES=获准执行;NO=已有读取在途(本次请求被合并为 pending)
- (BOOL)endRefreshAndShouldRunAgain;  // 结束当前读取;YES=期间有合并请求,需要再补跑一次
@end
@implementation CPRefreshGate {
    BOOL _inFlight;
    BOOL _pending;
}
- (BOOL)beginRefresh {
    if (_inFlight) { _pending = YES; return NO; }
    _inFlight = YES;
    return YES;
}
- (BOOL)endRefreshAndShouldRunAgain {
    _inFlight = NO;
    BOOL again = _pending;
    _pending = NO;
    return again;
}
@end

#pragma mark - App Delegate

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property CPStateReader *reader;
@property NSTimer *timer;
@property CPDockWindowController *dock;
@property CPWorkbenchCardController *card;
@property CPHUDWindowController *hud;
@property NSArray<CPAgent *> *agents;
@property BOOL hudVisualTest; // --visual-test-hud
@property BOOL detailVisualTest; // --visual-test-detail
@property BOOL kimiVisualTest;   // --visual-test-kimi
@property dispatch_queue_t refreshQueue;          // 串行后台队列:SQLite/rollout 读取不阻塞主线程
@property CPRefreshGate *refreshGate;             // 同一时刻最多一个读取,多余的合并为 pending
@property NSUInteger refreshGeneration;           // 读取代际:过期结果不覆盖更新的读取
@property NSString *lastAppliedSignature;         // 已应用数据的签名:一致则跳过全部重建
@property NSInteger appliedRefreshCount;          // 实际执行渲染的轮次(自测断言用)
- (void)applyAgents:(NSArray<CPAgent *> *)agents signature:(NSString *)signature;
@end

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
            NSButton *fake = NSButton.new;
            fake.tag = 0;
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
                NSButton *fakeTask = NSButton.new;
                fakeTask.tag = 0;
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
            CPRunningSelfTests = YES;
            CPTodoUseIsolatedStore = YES;
            [NSApplication sharedApplication];

            CPWorkbenchCardController *card = CPWorkbenchCardController.new;
            // 展开状态来自用户 defaults,几何断言必须确定:统一按收起态测试。
            card.todoExpanded = NO;
            [card applyTodoExpandedState];
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
            NSButton *attentionRow = NSButton.new;
            attentionRow.tag = 0;
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
            NSButton *row9 = NSButton.new;
            row9.tag = 0;
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
            NSButton *row9b = NSButton.new;
            row9b.tag = 0;
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
            NSButton *row9c = NSButton.new;
            row9c.tag = 0;
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
            NSScreen *todoScreen = todoCard.window.screen ?: NSScreen.screens.firstObject ?: NSScreen.mainScreen;
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
                          todoPersist && todoAgentNull && todoStrip && todoNoOverlay && todoExpand &&
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

            BOOL passed = centered && draggableHeader && labeledWorkbench && onlyRealAgents && labeledAgent && buttonReceivesClick &&
                          agentStatusDotsAligned && attentionBadgeClearsOnOpen &&
                          cardMasksToBounds && shadowCarrierNoMasks && cardIsChildOfShadowCarrier && windowHasWorkbenchInset &&
                          fixedCardSize && twoColumn && rightOverlayHidden &&
                          hudCollapsed6x72 && hudCollapsedOnMainScreen && hudExpandedSizeOK && hudExpandedOnMainScreen &&
                          shadowCarrierScales && handleAnchoredTopRight && contentNotSizable && hudClickViewIsBackgroundView &&
                          hudVisualFrameExact && hudExpandedHandleHidden && m2ui && m3ui && m3entries && m4ui && m5ui && m7ui && m8ui && m9ui && m10ui &&
                          hoverResidualOK && hoverMotionOK && todoUI && perfUI && m13ui;
            NSMutableString *result = [NSMutableString stringWithFormat:
                @"Codex Pulse UI self-test: center=%@ drag=%@ workbench-label=%@ real-agents=%@ agent-label=%@ button-hit=%@ "
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
            [result appendFormat:@"Bugfix UI self-test: agent-dot-column=%@ attention-badge-clears=%@\n",
                agentStatusDotsAligned ? @"OK" : @"FAIL",
                attentionBadgeClearsOnOpen ? @"OK" : @"FAIL"];
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
            [result appendFormat:@"Todo self-test: add=%@ blank-ignored=%@ complete=%@ restore=%@ edit=%@ delete=%@ persist=%@ agent-null=%@ strip=%@ no-overlay=%@ expand=%@ auto-reposition=%@ expand-no-overlay=%@ card-style=%@ ui-count=%@ badge-isolated=%@\n",
                todoAdd ? @"OK" : @"FAIL",
                todoBlankIgnored ? @"OK" : @"FAIL",
                todoComplete ? @"OK" : @"FAIL",
                todoRestore ? @"OK" : @"FAIL",
                todoEdit ? @"OK" : @"FAIL",
                todoDelete ? @"OK" : @"FAIL",
                todoPersist ? @"OK" : @"FAIL",
                todoAgentNull ? @"OK" : @"FAIL",
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
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
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
            printf("Codex Pulse self-test: %lu agents, %ld tasks, local read OK\n", (unsigned long)agents.count, (long)taskCount);
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
            sqlite3_finalize(kClientInsert);
            sqlite3_close(kClientHandle);
            [@"{\"client-key-1\":\"running\",\"client-key-2\":\"completed\"}"
                writeToFile:kClientStatus atomically:YES encoding:NSUTF8StringEncoding error:nil];
            setenv("CP_KIMI_CLIENT_DB", kClientDB.UTF8String, 1);
            setenv("CP_KIMI_CLIENT_STATUS", kClientStatus.UTF8String, 1);
            CPKimiSource *kClientSource = [[CPKimiSource alloc] initWithCache:CPStateCache.new];
            CPAgent *kClientAgent = [kClientSource readAgent];
            CPTask *kClientRunning = nil, *kClientCompleted = nil;
            for (CPTask *t in kClientAgent.tasks) {
                if ([t.taskID isEqualToString:@"kimi-client-client-id-1"]) kClientRunning = t;
                if ([t.taskID isEqualToString:@"kimi-client-client-id-2"]) kClientCompleted = t;
            }
            BOOL kClientOK = kClientAgent.tasks.count == 2 && kClientSource.lastClientCount == 2 &&
                kClientRunning.status == CPStatusWorking && kClientCompleted.status == CPStatusCompleted &&
                [kClientRunning.projectName isEqualToString:@"client-project"] &&
                [kClientCompleted.projectName isEqualToString:@"Kimi"] &&
                [kClientRunning.sourceKind isEqualToString:@"kimi-client"];
            printf("Kimi client self-test: sqlite-index=%s status-map=%s source-split=%s\n",
                   kClientAgent.tasks.count == 2 ? "OK" : "FAIL",
                   (kClientRunning.status == CPStatusWorking && kClientCompleted.status == CPStatusCompleted) ? "OK" : "FAIL",
                   kClientOK ? "OK" : "FAIL");
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
                       kHitParses == 600 && kHitCache.entries.count == 600 && // 第二轮零重解析,容量不抖动
                       kLruSecond < 0.5 && kLruThird < 0.5; // 耗时只做宽松上限(同进程连续 refresh 实测)
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
                          k16 && k17 && k18 && k19;
            NSString *kLine = [NSString stringWithFormat:
                @"Kimi self-test: cli-v2=%@ cli-v1=%@ archived-filter=%@ custom-title=%@ title-truncate=%@ status-working=%@ status-failed=%@ stale-not-working=%@ desktop-waiting=%@ dedupe-skip=%@ sort-desc=%@ cache-hit=%@ cache-invalidate=%@ empty-state=%@ cap50=%@ lru-stable=%@ desktop-context-cache=%@ long-turn-working=%@ touched-stale-idle=%@\n",
                k1 ? @"OK" : @"FAIL", k2 ? @"OK" : @"FAIL", k3 ? @"OK" : @"FAIL", k4 ? @"OK" : @"FAIL",
                k5 ? @"OK" : @"FAIL", k6 ? @"OK" : @"FAIL", k7 ? @"OK" : @"FAIL", k8 ? @"OK" : @"FAIL",
                k9 ? @"OK" : @"FAIL", k10 ? @"OK" : @"FAIL", k11 ? @"OK" : @"FAIL", k12 ? @"OK" : @"FAIL",
                k13 ? @"OK" : @"FAIL", k14 ? @"OK" : @"FAIL", k15 ? @"OK" : @"FAIL", k16 ? @"OK" : @"FAIL",
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
            return (taskCount > 0 && internalThreadsFiltered && m2 && taskRoutingOK && m6 && kimiOK && perfOK) ? 0 : 2;
        }
        if (argc > 1 && strcmp(argv[1], "--kimi-probe") == 0) {
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
        if (CPAnotherInstanceIsRunning()) return 0;
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        delegate.hudVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-hud") == 0;
        delegate.detailVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-detail") == 0;
        delegate.kimiVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-kimi") == 0;
        CPRunningSelfTests = delegate.detailVisualTest || delegate.kimiVisualTest;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
