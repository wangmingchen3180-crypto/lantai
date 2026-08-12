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

@interface CPAgent : NSObject
@property NSString *agentID;
@property NSString *name;
@property NSString *iconName;
@property NSColor *color;
@property BOOL placeholder;
@property CPStatus status;
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

