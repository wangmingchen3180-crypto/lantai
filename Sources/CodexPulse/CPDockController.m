#import "CPDockController.h"
#import "CPStatusEngine.h"
#import "CPScreenPolicy.h"

#pragma mark - Dock Capsule

@interface CPDockWindowController ()
@property BOOL updatingTracking; // 重建 tracking area / 改窗口尺寸时吞掉同步 enter/exit,避免误收
@property NSUInteger transitionGen; // 贴边探出/收回/吸附动画代际,快速进出时作废旧 completion
@end

@implementation CPDockWindowController

const CGFloat CPOrbSize = 48.0;
const CGFloat CPOrbMargin = 18.0; // 透明安全边距:容纳涟漪 1.55 倍扩散、阴影与角标
const CGFloat CPOrbWindowSize = CPOrbSize + CPOrbMargin * 2.0; // 84
const CGFloat CPStripWidth = 6.0;
const CGFloat CPHotZone = 28.0;
const CGFloat CPMargin = 18.0;
const CGFloat CPSnapThreshold = 24.0; // 球体贴边沿与屏幕边的间隙;60 时离边仍很宽也会吸住
const CGFloat CPBarHeight = 48.0;
const CGFloat CPBarItem = 34.0;
const CGFloat CPBarWorkbenchWidth = 82.0;
static const CGFloat CPDockPeekDuration = 0.20;
static const CGFloat CPDockUnpeekDuration = 0.18;
static const CGFloat CPDockSnapDuration = 0.22;
static const CGFloat CPDockSlide = 36.0; // 探出/收回时球体沿贴边方向滑入滑出的距离

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.docked = NO;
    self.peeked = NO;
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
    self.window.animationBehavior = NSWindowAnimationBehaviorNone;
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
    stripView.alphaValue = 1.0;
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
    barView.toolTip = @"澜台快捷栏：打开工作台或查看 Agent 状态";
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
    logo.toolTip = @"打开澜台工作台";
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

- (NSRect)hoverTrackingRect {
    // 球体可见时(自由漂浮或贴边探出)只跟踪 48pt 圆,不含 18pt 透明安全边距。
    // 贴边收起时跟踪 28pt 热区细条。两态热区都对齐可见物,避免「离得远才收、离得近不收」。
    if (self.mode == 0 && !self.floatingPill.hidden) return self.floatingPill.frame;
    return self.pill.bounds;
}

- (NSRect)keepAliveScreenRect {
    NSRect local = [self hoverTrackingRect];
    NSRect win = self.window.frame;
    return NSOffsetRect(local, win.origin.x, win.origin.y);
}

- (BOOL)mouseInKeepAlive {
    return NSPointInRect(NSEvent.mouseLocation, [self keepAliveScreenRect]);
}

- (void)updateTracking {
    self.updatingTracking = YES;
    if (self.trackingArea) [self.pill removeTrackingArea:self.trackingArea];
    NSRect trackRect = [self hoverTrackingRect];
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    if (self.window) {
        NSPoint mouseInPill = [self.pill convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil];
        if (NSPointInRect(mouseInPill, trackRect)) options |= NSTrackingAssumeInside;
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:trackRect
                                                     options:options
                                                       owner:self
                                                    userInfo:nil];
    [self.pill addTrackingArea:self.trackingArea];
    self.updatingTracking = NO;
}

- (NSScreen *)targetScreen {
    return CPTargetScreen();
}

- (void)reclampToVisibleScreen {
    if (!CPTargetScreen()) return;
    [self snapToEdgeAllowingAnimation:NO];
}

- (NSRect)initialFrame {
    NSScreen *screen = self.targetScreen;
    if (!screen) return NSMakeRect(0, 0, CPOrbSize, CPOrbSize);
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
    self.peeked = NO;
    self.transitionGen++;
    [self cancelUnpeek];
    NSScreen *screen = self.targetScreen;
    if (!screen) {
        [self renderDockAgents];
        [self applyFrame];
        return;
    }
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
    if (!screen) {
        NSRect rf = self.barView.frame;
        return NSMakeRect(0, 24, rf.size.width, rf.size.height);
    }
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

- (CGFloat)dockAnimDuration:(CGFloat)preferred {
    if (CPRunningSelfTests) return 0.0;
    if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion) return 0.0;
    return preferred;
}

- (NSRect)orbRestFrame {
    return NSMakeRect(CPOrbMargin, CPOrbMargin, CPOrbSize, CPOrbSize);
}

- (NSRect)orbTuckFrame {
    NSRect rest = [self orbRestFrame];
    rest.origin.x += (self.dockEdge == NSRectEdgeMaxX) ? CPDockSlide : -CPDockSlide;
    return rest;
}

- (NSRect)dockedPeekedWindowFrame {
    NSScreen *screen = self.targetScreen;
    if (!screen) return NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize);
    NSRect visible = screen.visibleFrame;
    CGFloat y = self.freeY - CPOrbMargin;
    CGFloat x = (self.dockEdge == NSRectEdgeMaxX)
        ? (NSMaxX(visible) - CPOrbSize - CPOrbMargin)
        : (NSMinX(visible) - CPOrbMargin);
    return NSMakeRect(x, y, CPOrbWindowSize, CPOrbWindowSize);
}

- (void)layoutStripInPeekedWindow {
    CGFloat y = CPOrbMargin;
    CGFloat x = (self.dockEdge == NSRectEdgeMaxX)
        ? (CPOrbMargin + CPOrbSize - CPStripWidth)
        : CPOrbMargin;
    self.stripView.frame = NSMakeRect(x, y, CPStripWidth, CPOrbSize);
    self.stripLine.frame = NSMakeRect(0, 8, CPStripWidth, CPOrbSize - 16);
}

- (void)resetOrbChrome {
    self.floatingPill.frame = [self orbRestFrame];
    self.floatingPill.alphaValue = 1.0;
    self.badgeView.alphaValue = 1.0;
    self.stripView.alphaValue = 1.0;
}

- (void)applyPeekedFrame {
    NSRect frame = [self dockedPeekedWindowFrame];
    self.updatingTracking = YES;
    [self.window setFrame:frame display:YES];
    self.pill.frame = NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize);
    self.updatingTracking = NO;
    [self resetOrbChrome];
    self.floatingPill.hidden = NO;
    self.barView.hidden = YES;
    self.stripView.hidden = YES;
    [self updateTracking];
    [self updateOrbRipples];
}

- (void)applyFrame {
    NSScreen *screen = self.targetScreen;
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    CGFloat x, y, w, h;
    if (self.docked && self.mode == 0 && self.peeked) {
        [self applyPeekedFrame];
        return;
    }
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
        [self resetOrbChrome];
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
        [self resetOrbChrome];
    }
    self.updatingTracking = YES;
    [self.window setFrame:NSMakeRect(x, y, w, h) display:YES];
    self.pill.frame = NSMakeRect(0, 0, w, h);
    self.updatingTracking = NO;
    [self updateTracking];
    [self updateOrbRipples];
}

- (void)peek:(BOOL)show {
    (void)show;
    if (!self.docked || self.mode != 0) return;
    if (self.peeked) return;
    self.peeked = YES;
    NSUInteger gen = ++self.transitionGen;

    BOOL fromStrip = self.floatingPill.hidden || fabs(self.window.frame.size.width - CPHotZone) <= 0.5;
    NSRect peekedFrame = [self dockedPeekedWindowFrame];
    self.updatingTracking = YES;
    if (fromStrip) {
        [self.window setFrame:peekedFrame display:YES];
        self.pill.frame = NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize);
        [self layoutStripInPeekedWindow];
        self.stripView.hidden = NO;
        self.stripView.alphaValue = 1.0;
        self.floatingPill.frame = [self orbTuckFrame];
        self.floatingPill.alphaValue = 0.0;
        self.badgeView.alphaValue = 0.0;
        self.floatingPill.hidden = NO;
        self.barView.hidden = YES;
    } else {
        if (fabs(self.window.frame.size.width - CPOrbWindowSize) > 0.5) {
            [self.window setFrame:peekedFrame display:YES];
            self.pill.frame = NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize);
        }
        self.floatingPill.hidden = NO;
        self.stripView.hidden = NO;
        [self layoutStripInPeekedWindow];
    }
    self.updatingTracking = NO;
    [self updateTracking];

    CGFloat duration = [self dockAnimDuration:CPDockPeekDuration];
    void (^finish)(void) = ^{
        if (gen != self.transitionGen) return;
        self.floatingPill.frame = [self orbRestFrame];
        self.floatingPill.alphaValue = 1.0;
        self.badgeView.alphaValue = 1.0;
        self.stripView.alphaValue = 0.0;
        self.stripView.hidden = YES;
        [self updateTracking];
        [self updateOrbRipples];
    };
    if (duration <= 0.001) {
        finish();
        return;
    }

    self.orbRippleView.hidden = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = duration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        ctx.allowsImplicitAnimation = YES;
        self.floatingPill.animator.frame = [self orbRestFrame];
        self.floatingPill.animator.alphaValue = 1.0;
        self.badgeView.animator.alphaValue = 1.0;
        self.stripView.animator.alphaValue = 0.0;
    } completionHandler:finish];
}

- (void)unpeek {
    if (!self.docked || self.mode != 0) return;
    self.peeked = NO;
    NSUInteger gen = ++self.transitionGen;

    if (fabs(self.window.frame.size.width - CPOrbWindowSize) > 0.5) {
        [self applyFrame];
        return;
    }

    self.stripView.hidden = NO;
    [self layoutStripInPeekedWindow];
    self.floatingPill.hidden = NO;

    CGFloat duration = [self dockAnimDuration:CPDockUnpeekDuration];
    void (^collapse)(void) = ^{
        if (gen != self.transitionGen) return;
        [self resetOrbChrome];
        [self applyFrame];
    };
    if (duration <= 0.001) {
        collapse();
        return;
    }

    self.orbRippleView.hidden = YES;
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = duration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];
        ctx.allowsImplicitAnimation = YES;
        self.floatingPill.animator.frame = [self orbTuckFrame];
        self.floatingPill.animator.alphaValue = 0.0;
        self.badgeView.animator.alphaValue = 0.0;
        self.stripView.animator.alphaValue = 1.0;
    } completionHandler:collapse];
}

- (void)scheduleUnpeek {
    [self cancelUnpeek];
    __weak typeof(self) weakSelf = self;
    self.unpeekTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:NO block:^(NSTimer *timer) {
        CPDockWindowController *strongSelf = weakSelf;
        if (!strongSelf) return;
        if ([strongSelf mouseInKeepAlive]) {
            [strongSelf updateTracking];
            return;
        }
        [strongSelf unpeek];
    }];
}

- (void)cancelUnpeek {
    [self.unpeekTimer invalidate];
    self.unpeekTimer = nil;
}

- (void)mouseEntered:(NSEvent *)event {
    if (self.updatingTracking || self.dragging) return;
    if (self.docked && self.mode == 0) {
        [self cancelUnpeek];
        [self peek:YES];
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
    if (self.updatingTracking || self.dragging) return;
    if (self.docked && self.mode == 0) {
        if ([self mouseInKeepAlive]) {
            [self updateTracking];
            return;
        }
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
    BOOL orbVisible = (self.mode == 0 && !self.floatingPill.hidden);
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
    self.transitionGen++;
    self.dragging = YES;
    self.didMove = NO;
    self.dragStartMouse = [NSEvent mouseLocation];
    self.dragStartOrigin = NSMakePoint(self.freeX, self.freeY); // 球体可见圆形原点
    if (self.docked) {
        self.docked = NO;
        self.peeked = NO;
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
    [self snapToEdgeAllowingAnimation:YES];
}

- (void)animateSnapIntoDock {
    NSUInteger gen = ++self.transitionGen;
    self.peeked = YES;
    NSRect peekedFrame = [self dockedPeekedWindowFrame];
    [self resetOrbChrome];
    self.floatingPill.hidden = NO;
    self.stripView.hidden = YES;
    self.barView.hidden = YES;
    self.updatingTracking = YES;
    self.pill.frame = NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize);
    self.updatingTracking = NO;

    CGFloat duration = [self dockAnimDuration:CPDockSnapDuration];
    void (^thenTuck)(void) = ^{
        if (gen != self.transitionGen) return;
        self.updatingTracking = YES;
        [self.window setFrame:peekedFrame display:YES];
        self.pill.frame = NSMakeRect(0, 0, CPOrbWindowSize, CPOrbWindowSize);
        self.updatingTracking = NO;
        [self unpeek];
    };
    if (duration <= 0.001) {
        thenTuck();
        return;
    }

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = duration;
        ctx.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [[self.window animator] setFrame:peekedFrame display:YES];
    } completionHandler:thenTuck];
}

- (void)snapToEdgeAllowingAnimation:(BOOL)allowAnimation {
    NSScreen *screen = self.targetScreen;
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    CGFloat w = [self currentWidth];
    CGFloat h = [self currentHeight];
    CGFloat rightEdge = NSMaxX(visible) - w;
    if (self.mode == 0) {
        if (self.freeX <= NSMinX(visible) + CPSnapThreshold) {
            self.docked = YES;
            self.peeked = NO;
            self.dockEdge = NSRectEdgeMinX;
            self.freeX = NSMinX(visible);
        } else if (self.freeX >= rightEdge - CPSnapThreshold) {
            self.docked = YES;
            self.peeked = NO;
            self.dockEdge = NSRectEdgeMaxX;
            self.freeX = rightEdge;
        } else {
            self.docked = NO;
            self.peeked = NO;
        }
    } else {
        self.docked = NO;
        self.peeked = NO;
    }
    CGFloat maxY = NSMaxY(visible) - h - 8;
    CGFloat minY = NSMinY(visible) + 8;
    self.freeY = MAX(minY, MIN(self.freeY, maxY));
    BOOL animate = allowAnimation && self.docked && self.mode == 0 &&
                   [self dockAnimDuration:CPDockSnapDuration] > 0.001;
    if (animate) [self animateSnapIntoDock];
    else [self applyFrame];
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

