#import <Cocoa/Cocoa.h>
#import "CPModels.h"
#import "CPReviewStore.h"
#import "CPControls.h"


FOUNDATION_EXPORT const CGFloat CPHUDContentWidth;
FOUNDATION_EXPORT const CGFloat CPHUDContentHeight;
FOUNDATION_EXPORT const CGFloat CPHUDTaskAreaHeight;
FOUNDATION_EXPORT const CGFloat CPHUDInset;
FOUNDATION_EXPORT const CGFloat CPHUDCollapsedWidth;
FOUNDATION_EXPORT const CGFloat CPHUDCollapsedHeight;
FOUNDATION_EXPORT const CGFloat CPHUDHandleVisualWidth;
FOUNDATION_EXPORT const CGFloat CPHUDHandleVisualHeight;
FOUNDATION_EXPORT const CGFloat CPHUDAgentRail;

@class CPHUDWindowController;

@interface CPProgressBarView : NSView
@property NSView *fillView;
@property (nonatomic) CGFloat progress; // 0.0 - 100.0
@end
@interface CPHUDBackgroundView : NSView
@property (weak) id target;
@property SEL action;
@end
@interface CPLegendButton : CPHoverButton
@property (weak) CPHUDWindowController *hud;
@end
@interface CPHUDTaskCardButton : CPHoverButton
@property NSString *taskID;
@end
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
@property NSView *quotaView;
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
- (void)agentButtonClicked:(NSButton *)sender;
- (void)legendClicked:(id)sender;
- (void)taskCardClicked:(CPHUDTaskCardButton *)sender;

- (void)expand;
- (void)collapse;
/// 屏幕参数变化后：收拢态重算贴边位置；展开态不动。
- (void)reclampCollapsedIfNeeded;
@end

