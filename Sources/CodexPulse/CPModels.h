#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, CPStatus) {
    CPStatusWorking, CPStatusWaiting, CPStatusAttention, CPStatusCompleted, CPStatusFailed, CPStatusIdle
};

typedef NS_ENUM(NSInteger, CPDisplayStatus) {
    CPDisplayStatusIdle,
    CPDisplayStatusWorking,
    CPDisplayStatusCompletedPendingReview,
    CPDisplayStatusWaiting,
    CPDisplayStatusFailed
};

// 数据源健康度:OK=正常可读;Missing=约定文件缺失或打不开(与"真的没有任务"区分)。
typedef NS_ENUM(NSInteger, CPAgentHealth) {
    CPAgentHealthOK = 0,
    CPAgentHealthMissing,
};

@interface CPTask : NSObject
@property NSString *taskID;
@property NSString *title;
@property NSString *projectPath;
@property NSString *projectName;
@property NSString *rolloutPath;
@property NSString *sourceKind; // 任务来源:"codex" / "kimi-client" / "kimi-cli"(未来 "claude" 等),路由按它分流
@property NSString *activity;
@property NSDate *createdAt;
@property NSDate *updatedAt;
@property NSInteger tokensUsed;
@property CPStatus status;
@end

@interface CPQuotaWindow : NSObject
@property NSString *windowID;     // session / weekly / monthly
@property NSString *title;        // 由窗口长度决定,例如「5小时」「周」
@property double usedPercent;    // 0–100
@property NSInteger windowMinutes;
@property NSDate *resetsAt;
@end

@interface CPQuotaSnapshot : NSObject
@property NSString *agentID;
@property CPAgentHealth health; // Missing=读不到,与「没有窗口」区分
@property NSMutableArray<CPQuotaWindow *> *windows;
@property NSDate *updatedAt;
@end

@interface CPAgent : NSObject
@property NSString *agentID;
@property NSString *name;
@property NSString *iconName;
@property NSColor *color;
@property BOOL placeholder;
@property CPStatus status;
@property CPAgentHealth health; // 缺省 CPAgentHealthOK;各 source 在数据不可用时置 Missing
@property CPQuotaSnapshot *quota; // 额度是观察结果,不是任务;缺省 nil 表示还没取过
@property NSMutableArray<CPTask *> *tasks;
@end

@interface CPTodo : NSObject
@property NSInteger todoID;
@property NSString *title;
@property BOOL completed;
@property NSString *agentID;  // 预留,当前恒为 nil
@property NSString *threadID; // 预留,当前恒为 nil
@property NSDate *createdAt;
@property NSDate *updatedAt;
@end

