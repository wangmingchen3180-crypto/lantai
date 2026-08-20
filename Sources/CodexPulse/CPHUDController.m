#import "CPHUDController.h"
#import "CPStatusEngine.h"
#import "CPScreenPolicy.h"
#import "CPRouting.h"
#import "CPWorkbenchController.h"
#import "CPQuota.h"

#pragma mark - Status HUD


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

// CodexBar 菜单栏图标:18pt 里两根短胶囊,上 6pt / 下 4pt / 宽 15pt。HUD 里放大一倍,仍是图标不是通栏进度条。
static const CGFloat CPHUDQuotaMeterWidth = 30.0;
static const CGFloat CPHUDQuotaMeterHeight = 22.0;
static const CGFloat CPHUDQuotaTopBarHeight = 10.0;
static const CGFloat CPHUDQuotaBottomBarHeight = 7.0;
static const CGFloat CPHUDQuotaBarGap = 3.0;

static BOOL CPQuotaWindowIsSession(CPQuotaWindow *window) {
    return window.windowMinutes >= 270 && window.windowMinutes <= 330;
}

static BOOL CPQuotaWindowIsWeek(CPQuotaWindow *window) {
    return window.windowMinutes >= 10020 && window.windowMinutes <= 10140;
}

static NSString *CPHUDQuotaLimitTip(CPQuotaWindow *window) {
    if (!window) return nil;
    NSString *title = window.title.length ? window.title : @"额度";
    return [NSString stringWithFormat:@"%@限额 %.0f%%", title, window.usedPercent];
}

@interface CPHUDQuotaView : NSView
@property CPQuotaWindow *topWindow;
@property CPQuotaWindow *bottomWindow;
@property BOOL available;
- (void)applySnapshot:(CPQuotaSnapshot *)quota;
@end

@implementation CPHUDQuotaView

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    return self;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)applySnapshot:(CPQuotaSnapshot *)quota {
    self.topWindow = nil;
    self.bottomWindow = nil;
    self.available = quota && quota.health != CPAgentHealthMissing && quota.windows.count > 0;
    if (self.available) {
        for (CPQuotaWindow *window in quota.windows) {
            if (!self.topWindow && CPQuotaWindowIsSession(window)) self.topWindow = window;
            if (!self.bottomWindow && CPQuotaWindowIsWeek(window)) self.bottomWindow = window;
        }
        for (CPQuotaWindow *window in quota.windows) {
            if (window == self.topWindow || window == self.bottomWindow) continue;
            if (!self.topWindow) self.topWindow = window;
            else if (!self.bottomWindow) self.bottomWindow = window;
        }
        if (!self.topWindow && self.bottomWindow) {
            self.topWindow = self.bottomWindow;
            self.bottomWindow = nil;
        }
    }
    NSMutableArray<NSString *> *tips = NSMutableArray.array;
    NSString *topTip = CPHUDQuotaLimitTip(self.topWindow);
    NSString *bottomTip = CPHUDQuotaLimitTip(self.bottomWindow);
    if (topTip) [tips addObject:topTip];
    if (bottomTip) [tips addObject:bottomTip];
    if (!self.available) {
        self.toolTip = quota ? @"额度不可用" : nil;
    } else {
        self.toolTip = tips.count ? [tips componentsJoinedByString:@"\n"] : nil;
    }
    self.hidden = (quota == nil);
    [self setNeedsDisplay:YES];
}

- (void)drawCapsuleInRect:(NSRect)rect usedPercent:(double)percent dimmed:(BOOL)dimmed {
    if (rect.size.width < 1 || rect.size.height < 1) return;
    CGFloat radius = rect.size.height / 2.0;
    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:radius yRadius:radius];
    CGFloat trackAlpha = dimmed ? 0.10 : 0.22;
    CGFloat strokeAlpha = dimmed ? 0.18 : 0.40;
    [[[NSColor whiteColor] colorWithAlphaComponent:trackAlpha] setFill];
    [track fill];

    if (!dimmed && percent > 0) {
        [NSGraphicsContext saveGraphicsState];
        [track addClip];
        CGFloat fillWidth = floor(rect.size.width * MIN(100.0, MAX(0.0, percent)) / 100.0);
        if (fillWidth > 0) {
            [[[NSColor whiteColor] colorWithAlphaComponent:0.92] setFill];
            NSRectFill(NSMakeRect(rect.origin.x, rect.origin.y, fillWidth, rect.size.height));
        }
        [NSGraphicsContext restoreGraphicsState];
    }

    NSRect strokeRect = NSInsetRect(rect, 0.5, 0.5);
    CGFloat strokeRadius = MAX(0, strokeRect.size.height / 2.0);
    NSBezierPath *stroke = [NSBezierPath bezierPathWithRoundedRect:strokeRect xRadius:strokeRadius yRadius:strokeRadius];
    stroke.lineWidth = 1.0;
    [[[NSColor whiteColor] colorWithAlphaComponent:strokeAlpha] setStroke];
    [stroke stroke];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect top = NSMakeRect(0, 0, self.bounds.size.width, CPHUDQuotaTopBarHeight);
    NSRect bottom = NSMakeRect(0, CPHUDQuotaTopBarHeight + CPHUDQuotaBarGap,
                               self.bounds.size.width, CPHUDQuotaBottomBarHeight);
    if (self.available && self.topWindow) {
        [self drawCapsuleInRect:top usedPercent:self.topWindow.usedPercent dimmed:NO];
    } else {
        [self drawCapsuleInRect:top usedPercent:0 dimmed:YES];
    }
    if (self.available && self.bottomWindow) {
        [self drawCapsuleInRect:bottom usedPercent:self.bottomWindow.usedPercent dimmed:NO];
    } else {
        [self drawCapsuleInRect:bottom usedPercent:0 dimmed:YES];
    }
}

@end

const CGFloat CPHUDContentWidth = 400.0;
const CGFloat CPHUDContentHeight = 244.0;
const CGFloat CPHUDTaskAreaHeight = 116.0; // 任务区固定高度:恰好露出约 2 张卡,其余滚动
const CGFloat CPHUDInset = 14.0;
const CGFloat CPHUDCollapsedWidth = 6.0;
const CGFloat CPHUDCollapsedHeight = 72.0;
const CGFloat CPHUDHandleVisualWidth = 3.0;
const CGFloat CPHUDHandleVisualHeight = 44.0;


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

// HUD 任务卡按钮:点击指向 taskCardClicked:(直达所属 Agent),稳定携带 taskID。
// 点击时按 taskID 在当前数据里重新解析任务对象,刷新/重建后不会因旧指针或索引错位打开错误任务。

@implementation CPHUDTaskCardButton @end


@implementation CPLegendButton
- (void)mouseEntered:(NSEvent *)event { [super mouseEntered:event]; [self.hud showLegend]; }
- (void)mouseExited:(NSEvent *)event { [super mouseExited:event]; [self.hud hideLegend]; }
@end

@implementation CPHUDWindowController

const CGFloat CPHUDAgentRail = 64.0;

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
    NSScreen *screen = CPTargetScreen();
    NSRect visible = screen ? screen.visibleFrame : NSMakeRect(0, 0, 1440, 900);
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

    CPHUDQuotaView *quotaView = [[CPHUDQuotaView alloc] initWithFrame:NSZeroRect];
    [container addSubview:quotaView];
    self.quotaView = quotaView;

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
        [agentName.trailingAnchor constraintLessThanOrEqualToAnchor:quotaView.leadingAnchor constant:-12],

        [agentStatus.leadingAnchor constraintEqualToAnchor:agentName.leadingAnchor],
        [agentStatus.topAnchor constraintEqualToAnchor:agentName.bottomAnchor constant:5],
        // 状态长文本先截断,绝不让它压到右侧更新时间;两者之间至少留 12pt。
        [agentStatus.trailingAnchor constraintLessThanOrEqualToAnchor:agentUpdated.leadingAnchor constant:-12],

        [agentUpdated.leadingAnchor constraintGreaterThanOrEqualToAnchor:agentStatus.trailingAnchor constant:12],
        [agentUpdated.centerYAnchor constraintEqualToAnchor:agentStatus.centerYAnchor],
        [agentUpdated.trailingAnchor constraintEqualToAnchor:quotaView.leadingAnchor constant:-10],

        [quotaView.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-18],
        [quotaView.centerYAnchor constraintEqualToAnchor:agentName.bottomAnchor constant:2.5],
        [quotaView.widthAnchor constraintEqualToConstant:CPHUDQuotaMeterWidth],
        [quotaView.heightAnchor constraintEqualToConstant:CPHUDQuotaMeterHeight],

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
    return CPTargetScreen();
}

- (void)reclampCollapsedIfNeeded {
    if (self.expanded) return;
    NSScreen *screen = CPTargetScreen();
    if (!screen) return;
    [self.window setFrame:[self collapsedFrameInVisibleRect:screen.visibleFrame] display:YES];
    [self layoutHandleToTopRightOfCarrier];
    [self updateTracking];
}

- (NSRect)expandedFrameInVisibleRect:(NSRect)visible {
    NSSize size = NSMakeSize(CPHUDContentWidth + CPHUDInset * 2.0, CPHUDContentHeight + CPHUDInset * 2.0);
    return CPRectAtTopRightOfVisibleFrame(visible, size);
}

- (NSRect)collapsedFrameInVisibleRect:(NSRect)visible {
    return CPRectAtTopRightOfVisibleFrame(visible, NSMakeSize(CPHUDCollapsedWidth, CPHUDCollapsedHeight));
}

- (NSRect)expandedFrame {
    NSScreen *screen = self.targetScreen;
    if (!screen) return NSMakeRect(0, 0, CPHUDContentWidth + CPHUDInset * 2.0, CPHUDContentHeight + CPHUDInset * 2.0);
    return [self expandedFrameInVisibleRect:screen.visibleFrame];
}

- (NSRect)collapsedFrame {
    NSScreen *screen = self.targetScreen;
    if (!screen) return NSMakeRect(0, 0, CPHUDCollapsedWidth, CPHUDCollapsedHeight);
    return [self collapsedFrameInVisibleRect:screen.visibleFrame];
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
    [(CPHUDQuotaView *)self.quotaView applySnapshot:agent.quota];

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
        NSString *emptyText = (agent.health == CPAgentHealthMissing) ? @"数据源不可用" : @"当前没有任务";
        NSTextField *empty = [NSTextField labelWithString:emptyText];
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

