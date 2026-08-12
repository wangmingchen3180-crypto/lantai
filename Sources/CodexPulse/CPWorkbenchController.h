#import <Cocoa/Cocoa.h>
#import "CPModels.h"
#import "CPReviewStore.h"
#import "CPControls.h"
#import "CPTodoStore.h"


FOUNDATION_EXPORT const CGFloat CPWorkbenchInset;
FOUNDATION_EXPORT const CGFloat CPCardWidth;
FOUNDATION_EXPORT const CGFloat CPCardHeight;
FOUNDATION_EXPORT const CGFloat CPTodoStripHeight;
FOUNDATION_EXPORT const CGFloat CPTodoCardMargin;
FOUNDATION_EXPORT const CGFloat CPTodoCollapsedHeight;
FOUNDATION_EXPORT const CGFloat CPTodoRowHeight;
FOUNDATION_EXPORT const CGFloat CPTodoExpandedExtra;

NSRect CPCenteredRectInVisibleFrame(NSRect visible, NSSize size);
NSRect CPRectAtTopRightOfVisibleFrame(NSRect visible, NSSize size);

@interface CPWorkbenchTaskRowButton : CPHoverButton
@property NSString *agentID;
@property NSString *taskID;
@end
@interface CPDraggableHeaderView : NSView
@property BOOL draggingWindow;
@property NSPoint dragStartMouse;
@property NSPoint dragStartOrigin;
@end
@interface CPFlippedStackView : NSStackView
@end
@interface CPTodoRowView : NSView
- (void)cpSetRowHovered:(BOOL)hovered;
@property (nonatomic, weak) NSButton *cpDeleteButton;
@property (nonatomic, weak) NSButton *cpEditButton;
@property (nonatomic, readonly) CALayer *cpHoverOverlay; // 自测断言用
@end
@interface CPTodoDeleteButton : CPHoverButton
@end
@interface CPTodoEditButton : CPHoverButton
@end
@interface CPClickBarrierView : NSView
@end
@interface CPHitPassthroughStackView : NSStackView
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
// Cross-file / self-test API (previously file-local via same-TU visibility)
- (CGFloat)cardHeight;
- (CGFloat)todoBarHeight;
- (void)applyTodoExpandedState;
- (void)handleEscape;
- (void)taskClicked:(CPWorkbenchTaskRowButton *)sender;

- (void)renderTodos;
- (void)cpUpdateTodoInputFocus:(BOOL)focused;
- (void)closeDetailDrawer;
- (void)cpClearAllHoverImmediately;
- (void)cpRestoreHoverForHitView:(NSView *)hit;
- (void)agentClicked:(NSButton *)sender;
@end
@interface CPWorkbenchPanel : NSPanel
@end

