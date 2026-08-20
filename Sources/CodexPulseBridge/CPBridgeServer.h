#import <Cocoa/Cocoa.h>
#import "CPModels.h"
#import "CPTodoStore.h"
#import "CPAgentSources.h"
#import "CPReviewStore.h"
#import "CPBridgePairing.h"
#import "CPAgentControl.h"

// 手机连接总开关。Bridge 会在局域网上开放明文 HTTP 端口，属于用户必须主动同意的
// 行为，因此默认关闭：键不存在时一律视为 NO，不用 registerDefaults 兜底。
FOUNDATION_EXPORT NSString * const CPBridgeEnabledDefaultsKey; // bridge.enabled.v1
BOOL CPBridgeIsEnabled(void);
void CPBridgeSetEnabled(BOOL enabled);

FOUNDATION_EXPORT NSString * const CPBridgePortDefaultsKey;
FOUNDATION_EXPORT NSString * const CPControlWorkdirsDefaultsKey; // control.workdirs.v1
FOUNDATION_EXPORT NSString * const CPTodosDidChangeNotification;
// 配对成功:userInfo[@"deviceName"];配对卡据此自动关闭,不必让用户手动关。
FOUNDATION_EXPORT NSString * const CPBridgeDevicePairedNotification;

@interface CPBridgeServer : NSObject
@property CPStateReader *reader;
@property CPTodoStore *todoStore;
@property CPReviewStore *reviewStore;
@property NSArray<CPAgent *> *latestAgents; // AppDelegate 合入后的快照;nil 则现场读 reader
@property CPBridgePairing *pairing;
@property CPAgentControlRegistry *controlRegistry; // nil 等价于没有任何 driver
@property NSString *mobileDirectory;       // 默认 bundle Resources/mobile
@property NSInteger portMin;               // 默认 8787;0 表示系统分配
@property NSInteger portMax;               // 默认 8797
@property BOOL loopbackOnly;               // 自测绑 127.0.0.1,生产绑 0.0.0.0
@property BOOL persistPort;                // 自测不写 NSUserDefaults
@property NSUserDefaults *defaults;        // 默认 standardUserDefaults；自测用独立 suite，避免污染用户配置
@property NSTimeInterval activityFlushInterval; // 每任务推送间隔，默认 0.25s；自测可改
@property (readonly) NSInteger port;
@property (readonly) BOOL running;
- (BOOL)start;
- (void)stop;
- (NSDictionary *)snapshotDictionary;
- (void)publishSnapshotNow; // 白名单/设备权限变更后主动重推；agent 签名检测看不到这些变化
- (NSString *)preferredLANAddress;

// 实时活动流入口。driver 只交折叠好的事件，限流/截断/补抓都在这里做。
- (void)ingestActivityEntry:(CPActivityEntry *)entry;
- (void)flushActivityForAgentID:(NSString *)agentID taskID:(NSString *)taskID; // item/turn 结束
- (void)setActivityLive:(BOOL)live forAgentID:(NSString *)agentID;             // driver 健康翻转
- (NSDictionary *)activityStreamJSONForAgentID:(NSString *)agentID taskID:(NSString *)taskID; // 无流返回 nil

- (int)firstSSEFileDescriptorForTesting; // 自测:当前第一条 SSE 连接的 fd,无则 -1
- (NSInteger)activityEventCountForTesting;   // 自测:累计推出的 activity 事件条数
- (void)flushActivityNowForTesting;          // 自测:排空入口队列并立即推送
@end
