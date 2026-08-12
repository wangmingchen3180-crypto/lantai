#import "CPControls.h"

#pragma mark - Unified Ripple Component (CPRippleView)

// 前向声明:涟漪组件需要在其实际定义(见下文 Agent Status Button 段)之前取状态色/标题。

// 定稿涟漪参数(ripple-selection-preview.html 逐轮确认):
// 8 层同心涟漪,每层明暗成对(一圈半透明白峰 + 一圈半透明黑谷紧邻,两层描边 CALayer 成对扩散);
// 基准周期 12s,层间错峰 1/8 周期(1.5s),缓入缓出(出发极平缓、中后程荡到外围);
// scale 1.0→1.55,线宽 2.0→0.5(能量摊薄),透明度长尾巴衰减(场上同时保持四五层)。
// 状态差异只调周期:失败最快、待机最慢;层数、曲线、错峰比例统一。
CGFloat CPRippleDurationForStatus(CPDisplayStatus s) {
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
const CGFloat CPRippleScaleTo = 1.55;
const CGFloat CPRippleLineWidthFrom = 2.0;
const CGFloat CPRippleLineWidthTo = 0.5;
const NSInteger CPRippleLayerCount = 8;

// 明暗对的整体强度(HUD 深色底):白峰峰值 alpha ~0.22,黑谷 ~0.18;悬浮球(底更亮)略高。
const CGFloat CPRippleCrestAlpha = 0.22;
const CGFloat CPRippleTroughAlpha = 0.18;

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

// CPRippleView:统一水波组件(定稿规范)。
// - 固定中心:自身只承载描边圆环 layer,中心图标由宿主提供且永不缩放;
// - 固定基础环 baseRingLayer:固定半径、固定线宽,始终静止显示状态色;
// - 8 层明暗成对涟漪 rippleLayers(白峰)/rippleTroughLayers(黑谷):scale 1.0 → 1.55,
//   透明度 0→峰值→长尾巴衰减→0,lineWidth 2.0 → 0.5,缓入缓出(0.45,0.08,0.35,1),
//   repeat forever,层间 timeOffset = duration/8(基准 12s 即 1.5s)错拍;
// - 波层在组件内先于基础环加入,宿主把组件放在图标之下,波从图标边缘水面露出;
// - reduce motion:停止所有 CAAnimation,只留固定状态环(实色),不缩放不闪烁;
// - 组件按 1.55 倍扩散预留自身 frame,不改变父视图尺寸,也不改变宿主按钮 frame。

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


NSTextField *CPLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *l = [NSTextField labelWithString:text];
    l.font = [NSFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    l.maximumNumberOfLines = 2;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    return l;
}

// Reduce Motion:动画全部退化为立即切换,不留过渡。
BOOL CPHoverReduceMotion(void) {
    return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
}

// hover wash 唯一动画入口:只动 overlay 的 opacity,不碰布局、不碰 borderWidth。
// 进入 120ms ease-out,退出 150ms ease-in-out;始终从 presentation 当前值起跳,
// 快速打断/反向时画面连续不闪;model opacity 先置为终态,动画结束或被移除都不弹回。
void CPAnimateWashOpacity(CALayer *overlay, CGFloat target) {
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

NSButton *CPIconButton(NSString *symbol, id target, SEL action, NSString *tooltip) {
    NSButton *b = [CPHoverButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:@""] target:target action:action];
    b.bordered = NO;
    b.imageScaling = NSImageScaleProportionallyDown;
    b.contentTintColor = CPMuted();
    b.toolTip = tooltip;
    [b.widthAnchor constraintEqualToConstant:28].active = YES;
    [b.heightAnchor constraintEqualToConstant:28].active = YES;
    return b;
}

NSImage *CPSymbol(NSString *name, CGFloat pointSize, NSColor *color) {
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

NSArray<NSString *> *CPBundleIDsForAgent(NSString *agentID) {
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

NSImage *CPAppIconForAgent(NSString *agentID, CGFloat side) {
    for (NSString *bundleID in CPBundleIDsForAgent(agentID)) {
        NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
        if (!appURL) continue;
        NSImage *icon = [NSWorkspace.sharedWorkspace iconForFile:appURL.path];
        if (icon) return CPCircularIcon(icon, side);
    }
    return nil;
}

