#import <Cocoa/Cocoa.h>
#import "CPModels.h"
#import "CPStateCache.h"

@protocol CPAgentSource <NSObject>
- (CPAgent *)readAgent;
@end

@interface CPRolloutState : NSObject
@property NSDate *lastStarted;
@property NSDate *lastComplete;
@property BOOL attentionPending;
@end
@interface CPStateReader : NSObject
@property (nonatomic) CPStateCache *cache;
@property (nonatomic) NSArray<id<CPAgentSource>> *sources;
- (NSArray<CPAgent *> *)readAgents;
// rollout 尾部解析按 (mtime,size) 缓存:文件未变直接复用上轮结果,不重复读 256KB/逐行 JSON。
- (CPRolloutState *)rolloutStateForPath:(NSString *)path;
@end
@interface CPCodexSource : NSObject <CPAgentSource>
@property (nonatomic) CPStateCache *cache;
- (instancetype)initWithCache:(CPStateCache *)cache;
@end
@interface CPKimiWireState : NSObject
@property BOOL turnActive;            // 尾部最后一个 turn 未见结束
@property NSString *lastEndReason;    // 最近一次 turn 结束原因(completed/cancelled/error…)
@property BOOL attentionPending;      // 未解决的用户输入请求 / 中断待处理
@property NSString *firstUserInput;   // desktop TurnBegin payload.user_input(标题兜底)
@property NSDate *lastEventAt;
@end
@interface CPKimiSource : NSObject <CPAgentSource>
@property (nonatomic) CPStateCache *cache;
@property (nonatomic) NSInteger lastClientCount;  // Kimi App conversations.sqlite 会话数
@property (nonatomic) NSInteger lastCLICount;     // 最近一次读取到的非归档 CLI 会话数(probe 用)
@property (nonatomic) NSInteger lastDesktopCount; // 最近一次读取到的 desktop 会话数(probe 用)
- (instancetype)initWithCache:(CPStateCache *)cache;
- (NSArray<CPTask *> *)readCLITasksIntoRawIDs:(NSMutableSet<NSString *> *)rawIDs;
@end
@interface CPKimiCLISource : NSObject <CPAgentSource>
@property (nonatomic) CPKimiSource *parser;
- (instancetype)initWithCache:(CPStateCache *)cache;
@end


FOUNDATION_EXPORT NSString * const CPEnabledAgentProvidersKey;
FOUNDATION_EXPORT NSString * const CPAgentSourcesChangedNotification;

NSArray<NSDictionary *> *CPAgentProviderCatalog(void);
NSArray<NSString *> *CPEnabledAgentProviderIDs(void);
BOOL CPAgentProviderIsDetected(NSString *providerID);
void CPEnableAgentProvider(NSString *providerID);
CPStatus CPOverallStatusForTasks(NSArray<CPTask *> *tasks);
NSDate * CPDateFromISO8601(NSString * value);
CPRolloutState * CPReadRolloutState(NSString *path);

FOUNDATION_EXPORT const char *CPCodexVisibleThreadsSQL;
