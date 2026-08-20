#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, CPCommandAction) {
    CPCommandActionStart, CPCommandActionSteer, CPCommandActionInterrupt
};

typedef NS_ENUM(NSInteger, CPCommandState) {
    CPCommandStateAccepted, CPCommandStateRunning, CPCommandStateSucceeded, CPCommandStateFailed
};

@interface CPAgentCommand : NSObject
@property (copy) NSString *commandID;   // UUID，服务端生成
@property CPCommandAction action;
@property (copy) NSString *agentID;
@property (copy) NSString *taskID;      // start 时为 nil；成功后可由 driver 回填
@property (copy) NSString *text;
@property (copy) NSString *workdir;   // 绝对路径，仅 Bridge 解析白名单后填入；永不来自手机，也不进给手机的 JSON
@property (copy) NSString *workdirName; // 白名单里的项目显示名；driver 用它把绝对路径前缀脱敏成项目名
@property (copy) NSString *modelID;  // 仅 start 使用；空则 thread/start 不传 model，继承 ~/.codex/config.toml
@property CPCommandState state;
@property (copy) NSString *errorMessage; // 仅 failed 时有值
@property NSTimeInterval acceptedAt;
@property NSTimeInterval updatedAt;
@end

#pragma mark - 实时活动流

// app-server 的 70 种通知折叠成这七种，见 docs/BRIDGE_API.md「实时活动流」。
typedef NS_ENUM(NSInteger, CPActivityKind) {
    CPActivityKindSay, CPActivityKindThink, CPActivityKindRun,
    CPActivityKindEdit, CPActivityKindPlan, CPActivityKindUsage, CPActivityKindNote
};

// 同一条目的续写方式。逐字 delta 必须能合并，快照式更新只能覆盖，告警各自成条。
typedef NS_ENUM(NSInteger, CPActivityMerge) {
    CPActivityMergeAppendText,   // text 续写（说话、思考、计划 delta）
    CPActivityMergeAppendDetail, // text 是标题，detail 续写（命令输出）
    CPActivityMergeReplace,      // 后一条整体覆盖前一条（计划、改动、用量）
    CPActivityMergeDistinct      // 永不合并（警告与错误）
};

FOUNDATION_EXPORT NSString *CPActivityKindJSON(CPActivityKind kind);

// Agents 层折叠出来的事件对象。seq 不在这里：它属于 Bridge 的每任务流水号。
@interface CPActivityEntry : NSObject
@property (copy) NSString *agentID;
@property (copy) NSString *taskID;
@property (copy) NSString *itemID;   // 同一条 item 的续写标识；nil 表示不属于任何 item
@property CPActivityKind kind;
@property CPActivityMerge merge;
@property (copy) NSString *text;     // 已脱敏
@property (copy) NSString *detail;   // 已脱敏，可为 nil
@property NSTimeInterval at;
@end

// 手机模型选择器要的字段。官方 Model 还有一堆 effort / modality，这里不搬。
@interface CPAgentModel : NSObject
@property (copy) NSString *modelID;
@property (copy) NSString *name;
@property (copy) NSString *descriptionText;
@property BOOL isDefault;
@end

@protocol CPAgentControlDriver <NSObject>
- (NSString *)agentID;
- (BOOL)isHealthy;                          // NO 表示协议对不上/进程没起来，整体降级只读
- (NSArray<NSString *> *)controlCapabilities; // 例如 @[@"control", @"interrupt"]，不含 "observe"
- (BOOL)isManagedTaskID:(NSString *)taskID;   // 是否为澜台托管任务
- (NSArray<CPAgentModel *> *)availableModels; // 可见模型目录；拉不到时给空数组，不表示不健康
// completion 可能在任意线程回来。
- (void)executeCommand:(CPAgentCommand *)command
            completion:(void (^)(BOOL ok, NSString *errorMessage, NSString *resultTaskID))completion;
@end

@interface CPAgentControlRegistry : NSObject
- (void)registerDriver:(id<CPAgentControlDriver>)driver;
- (id<CPAgentControlDriver>)driverForAgentID:(NSString *)agentID;
- (NSArray<NSString *> *)capabilitiesForAgentID:(NSString *)agentID;
@end
