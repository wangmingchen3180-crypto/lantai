#import <Cocoa/Cocoa.h>
#import "CPModels.h"

CPTask *CPTestTask(NSString *taskID, CPStatus status, NSTimeInterval updatedAt);
CPAgent *CPTestAgent(NSString *agentID, NSArray<CPTask *> *tasks);
BOOL CPAnotherInstanceIsRunning(void);
int CPRunSelfTests(int argc, const char *argv[]);
int CPRunUISelfTests(int argc, const char *argv[]);
int CPRunKimiProbe(void);

