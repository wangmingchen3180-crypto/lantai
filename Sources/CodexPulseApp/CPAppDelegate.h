#import <Cocoa/Cocoa.h>
#import "CPModels.h"
#import "CPAgentSources.h"
#import "CPDockController.h"
#import "CPWorkbenchController.h"
#import "CPHUDController.h"
#import "CPRefreshPipeline.h"
#import "CPPairingSheetController.h"
#import "CPControlSettingsController.h"

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
@property BOOL demoMode;         // --demo: 用虚构数据源替换真实 Agent,截图与试用两用
@property (copy) NSString *shotOutputDir; // --shot: 非空则渲染 README 截图后退出
@property dispatch_queue_t refreshQueue;          // 串行后台队列:SQLite/rollout 读取不阻塞主线程
@property CPRefreshGate *refreshGate;             // 同一时刻最多一个读取,多余的合并为 pending
@property NSUInteger refreshGeneration;           // 读取代际:过期结果不覆盖更新的读取
@property NSString *lastAppliedSignature;         // 已应用数据的签名:一致则跳过全部重建
@property NSInteger appliedRefreshCount;          // 实际执行渲染的轮次(自测断言用)
@property CPPairingSheetController *pairingSheet;  // 「连接手机」配对卡,菜单栏唤出
@property CPControlSettingsController *controlSettings; // 「手机指挥设置」卡片
@property NSMutableDictionary<NSString *, CPQuotaSnapshot *> *quotas;
@property NSDate *lastQuotaRefresh;
@property NSTimer *quotaTimer;
@property BOOL quotaRefreshInFlight;
- (void)applyAgents:(NSArray<CPAgent *> *)agents signature:(NSString *)signature;
- (void)screenParametersChanged:(NSNotification *)note;
- (void)showCard;
- (NSMenu *)statusMenu;
- (void)connectPhoneFromMenu:(id)sender;
- (void)openControlSettingsFromMenu:(id)sender;
@end

