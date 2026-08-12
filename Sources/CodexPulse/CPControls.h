#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import "CPModels.h"
#import "CPStatusEngine.h"


CGFloat CPRippleDurationForStatus(CPDisplayStatus s);

FOUNDATION_EXPORT const CGFloat CPRippleScaleTo;
FOUNDATION_EXPORT const CGFloat CPRippleLineWidthFrom;
FOUNDATION_EXPORT const CGFloat CPRippleLineWidthTo;
FOUNDATION_EXPORT const NSInteger CPRippleLayerCount;
FOUNDATION_EXPORT const CGFloat CPRippleCrestAlpha;
FOUNDATION_EXPORT const CGFloat CPRippleTroughAlpha;

NSTextField *CPLabel(NSString *text, CGFloat size, NSFontWeight weight, NSColor *color);
BOOL CPHoverReduceMotion(void);
void CPAnimateWashOpacity(CALayer * overlay, CGFloat target);
NSButton *CPIconButton(NSString *symbol, id target, SEL action, NSString * tooltip);
NSImage *CPSymbol(NSString *name, CGFloat pointSize, NSColor * color);
NSArray<NSString *> *CPBundleIDsForAgent(NSString *agentID);
NSImage *CPAppIconForAgent(NSString *agentID, CGFloat side);

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
@interface CPHoverButton : NSButton
@property (nonatomic, strong) NSColor *cpBaseBackground;
@property (nonatomic) BOOL cpAlwaysBorder; // 常驻 1px 描边(如详情关闭按钮)
// 可选的视觉层:设置后底色/描边/wash 都画在这层上,按钮自身 layer 保持透明。
// 用于"点击热区 > 可见图形"的场景(如详情返回钮:24pt 热区 + 与标题行高等大的小圆)。
@property (nonatomic, strong) CALayer *cpVisualLayer;
@property (nonatomic, readonly) CALayer *cpHoverOverlay; // 自测断言用
@property (nonatomic) CGFloat cpHoverWash;   // hover 白 wash 不透明度,默认 0.07(图标钮);行级 0.04~0.05
@property (nonatomic) CGFloat cpPressedWash; // pressed 白 wash 不透明度,默认 0.10

- (void)cpClearHover;
- (void)cpClearHoverImmediate;
- (void)cpRevalidateHover;
- (void)cpSetHovered:(BOOL)hovered;
@end
@interface CPAgentStatusButton : NSButton
@property NSString *agentID;
@property (nonatomic) BOOL reduceMotion;
@property (nonatomic) BOOL animationsPaused; // HUD 收起/不可见时暂停 8 层无限涟漪(可见性驱动降载)
@property CPDisplayStatus displayStatus;
@property (nonatomic) BOOL statusSelected;
@property CAShapeLayer *ringLayer;
@property CAShapeLayer *innerRingLayer;
@property NSArray<CAShapeLayer *> *rippleLayers;       // 8 层白峰(波层在图标之下)
@property NSArray<CAShapeLayer *> *rippleTroughLayers; // 8 层黑谷
@property NSImageView *iconView;
- (void)updateWithAgent:(CPAgent *)agent displayStatus:(CPDisplayStatus)status selected:(BOOL)selected;
@end

