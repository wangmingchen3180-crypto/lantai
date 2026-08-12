#import "CPWorkbenchController.h"
#import "CPStatusEngine.h"
#import "CPScreenPolicy.h"
#import "CPAgentSources.h"
#import "CPRouting.h"

#pragma mark - Workbench Card

// 工作台任务行按钮:稳定携带 agentID+taskID。点击时按 ID 在当前数据里重解析,
// 刷新重排后不会因旧数组索引错位打开错误任务;任务已消失则静默忽略。
@implementation CPWorkbenchTaskRowButton @end


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
@implementation CPFlippedStackView
- (BOOL)isFlipped { return YES; }
@end

// Todo 行(B 版):hover 时行底色经独立 wash overlay 淡入(对照原型 .row:hover 5% 白),
// 并同时放行尾编辑铅笔与删除垃圾桶;非 hover 两个动作钮完全透明,绝不常驻抢眼。
// 与按钮同一套可中断 opacity 动画;hide/移出窗口/移出父视图时强制复位,不留残留。
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
@implementation CPTodoDeleteButton
- (void)cpSetHovered:(BOOL)hovered {
    [super cpSetHovered:hovered];
    NSColor *tint = hovered ? CPRed() : CPMuted();
    self.image = CPSymbol(@"trash", 11, tint);
    self.contentTintColor = tint;
}
@end

// Todo 编辑钮(B 版铅笔):平时透明(由行 hover 放行),hover 图标本身时提亮为 CPFg2。
@implementation CPTodoEditButton
- (void)cpSetHovered:(BOOL)hovered {
    [super cpSetHovered:hovered];
    NSColor *tint = hovered ? CPFg2() : CPMuted();
    self.image = CPSymbol(@"pencil", 11, tint);
    self.contentTintColor = tint;
}
@end

// 详情抽屉容器:显示时吞掉覆盖区内的全部命中与鼠标事件,点击不得穿透到下层任务列表。
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
@implementation CPHitPassthroughStackView
- (NSView *)hitTest:(NSPoint)point { (void)point; return nil; }
@end


// 工作台面板:borderless 窗口默认 canBecomeKey=NO,加上 NonactivatingPanel 更是永远无法成为 key,
// 真实 Esc 等键盘事件进不来。工作台需要接收键盘(第一次 Esc 关详情、第二次关工作台),
// 因此用专用子类声明可以成为 key/main window;悬浮球与 HUD 仍用 NonactivatingPanel 不抢焦点。
@implementation CPWorkbenchPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return YES; }
@end

@implementation CPWorkbenchCardController

const CGFloat CPWorkbenchInset = 20.0;

const CGFloat CPCardWidth = 520.0;
const CGFloat CPCardHeight = 360.0; // 内容区高度(头部 + 三列);Todo 栏在此基础上向下加高卡片

// Todo 栏布局常量(方案 B 精致卡片型):Todo 区是 CPBg 工作台上的一张 CPSurface 卡片
// (hairline 描边 + 10px 圆角,四周 12pt 外部留白),收起态 shell 精确等于 34pt 卡片头横条
// (对照原型 .vB:12px 是 .todo 外部 padding,shell 收起只等于 strip,不含任何内部空尾);
// 展开时卡片/窗口整体向下加高 CPTodoExpandedExtra,任务区高度不变;展开内容自己的
// 底内边距留在 expanded content 内,不污染 collapsed shell。
// 尺寸对齐原型 B:strip padding 10px 12px;行 min-height 30;输入框 padding 7px 10px;
// 列表 5 行可见,超出滚动;展开内容底内边距 10。
const CGFloat CPTodoStripHeight = 34.0;
const CGFloat CPTodoCardMargin = 12.0; // Todo 卡片距工作台卡片左右/底部的外部留白
const CGFloat CPTodoCollapsedHeight = CPTodoStripHeight; // 收起 = 34 横条,无内部空尾
const CGFloat CPTodoRowHeight = 30.0; // B 版行 min-height 30
const CGFloat CPTodoExpandedExtra = 210.0; // 2 上间距 + 32 输入行 + 8 间距 + 158 列表(5 行) + 10 下内边距

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
NSRect CPCenteredRectInVisibleFrame(NSRect visible, NSSize size) {
    CGFloat x = NSMidX(visible) - size.width / 2.0;
    CGFloat y = NSMidY(visible) - size.height / 2.0;
    x = MAX(NSMinX(visible) + CPWorkbenchInset, MIN(x, NSMaxX(visible) - size.width - CPWorkbenchInset));
    y = MAX(NSMinY(visible) + CPWorkbenchInset, MIN(y, NSMaxY(visible) - size.height - CPWorkbenchInset));
    return NSIntegralRect(NSMakeRect(x, y, size.width, size.height));
}

NSRect CPRectAtTopRightOfVisibleFrame(NSRect visible, NSSize size) {
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
        NSScreen *screen = self.window.screen ?: CPTargetScreen();
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

- (NSButton *)taskRow:(CPTask *)task agentID:(NSString *)agentID {
    CPWorkbenchTaskRowButton *row = [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:self action:@selector(taskClicked:)];
    row.bordered = NO;
    [row setButtonType:NSButtonTypeMomentaryChange];
    row.wantsLayer = YES;
    row.layer.cornerRadius = 10.0;
    row.layer.borderWidth = 0.0;
    row.cpBaseBackground = NSColor.clearColor;
    row.cpHoverWash = 0.04; // 对照原型 .task:hover
    row.cpPressedWash = 0.07;
    row.agentID = agentID;
    row.taskID = task.taskID;
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
        NSString *emptyText = (agent.health == CPAgentHealthMissing) ? @"数据源不可用" : @"暂无活动任务";
        [self.taskStack addArrangedSubview:CPLabel(emptyText, 12, NSFontWeightRegular, CPMuted())];
        self.selectedTask = nil;
        [self closeDetailDrawer];
    } else {
        for (CPTask *task in tasks) {
            NSButton *taskRowBtn = [self taskRow:task agentID:self.selectedAgent.agentID];
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

- (void)taskClicked:(CPWorkbenchTaskRowButton *)sender {
    if (![sender isKindOfClass:CPWorkbenchTaskRowButton.class] || !sender.taskID.length) return;
    CPAgent *agent = nil;
    for (CPAgent *a in self.agents) {
        if ([a.agentID isEqualToString:sender.agentID]) { agent = a; break; }
    }
    if (!agent) return;
    CPTask *task = nil;
    for (CPTask *t in agent.tasks) {
        if ([t.taskID isEqualToString:sender.taskID]) { task = t; break; }
    }
    if (!task) return; // 任务已在刷新中消失:不做动作,不伪造已查看
    self.selectedAgent = agent;
    self.selectedTask = task;
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
    NSScreen *screen = CPTargetScreen();
    if (!screen) {
        NSSize size = NSMakeSize(CPCardWidth + CPWorkbenchInset * 2.0, self.cardHeight + CPWorkbenchInset * 2.0);
        return NSMakeRect(0, 0, size.width, size.height);
    }
    return [self targetFrameInVisibleRect:screen.visibleFrame];
}

- (void)ensureFrameIntersectsVisibleScreen {
    if (!self.window.isVisible) return;
    NSScreen *screen = CPTargetScreen();
    if (!screen) return;
    NSRect visible = screen.visibleFrame;
    if (NSIntersectsRect(self.window.frame, visible)) return;
    NSRect target = [self targetFrameInVisibleRect:visible];
    [self.window setFrame:target display:YES];
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

