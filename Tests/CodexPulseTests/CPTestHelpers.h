#import <Cocoa/Cocoa.h>
#import "CPModels.h"

CPTask *CPTestTask(NSString *taskID, CPStatus status, NSTimeInterval updatedAt);
CPAgent *CPTestAgent(NSString *agentID, NSArray<CPTask *> *tasks);

/// 从 test bundle Fixtures/ 或源树相对路径加载 fixture。
NSURL *CPTestFixtureURL(NSString *name);
