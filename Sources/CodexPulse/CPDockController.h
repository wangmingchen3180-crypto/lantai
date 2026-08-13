#import <Cocoa/Cocoa.h>
#import "CPModels.h"
#import "CPReviewStore.h"
#import "CPControls.h"


FOUNDATION_EXPORT const CGFloat CPOrbSize;
FOUNDATION_EXPORT const CGFloat CPOrbMargin;
FOUNDATION_EXPORT const CGFloat CPOrbWindowSize;
FOUNDATION_EXPORT const CGFloat CPStripWidth;
FOUNDATION_EXPORT const CGFloat CPHotZone;
FOUNDATION_EXPORT const CGFloat CPMargin;
FOUNDATION_EXPORT const CGFloat CPSnapThreshold;
FOUNDATION_EXPORT const CGFloat CPBarHeight;
FOUNDATION_EXPORT const CGFloat CPBarItem;
FOUNDATION_EXPORT const CGFloat CPBarWorkbenchWidth;

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
@property BOOL peeked; // 贴边后由 hover 探出球体;与 docked 独立,避免刷新/重排把探出态打回细条
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
/// 屏幕参数变化后：复用吸附/Y clamp，把悬浮球拉回主显示器可见区。
- (void)reclampToVisibleScreen;
- (void)updateOrbRipples;
- (void)pillMouseDown:(NSEvent *)event;
- (void)pillMouseDragged:(NSEvent *)event;
- (void)pillMouseUp:(NSEvent *)event;
- (void)mouseEntered:(NSEvent *)event;
- (void)mouseExited:(NSEvent *)event;
- (void)peek:(BOOL)show;
- (void)unpeek;
- (void)snapToEdge;
- (void)barLogoClicked:(id)sender;
@end

