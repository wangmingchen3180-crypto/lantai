#import "CPTestHelpers.h"

@interface CPTestHelpersMarker : NSObject
@end
@implementation CPTestHelpersMarker
@end

CPTask *CPTestTask(NSString *taskID, CPStatus status, NSTimeInterval updatedAt) {
    CPTask *t = CPTask.new;
    t.taskID = taskID;
    t.title = taskID;
    t.projectName = @"proj";
    t.projectPath = @"~/proj";
    t.activity = @"activity";
    t.status = status;
    t.updatedAt = [NSDate dateWithTimeIntervalSince1970:updatedAt];
    return t;
}

CPAgent *CPTestAgent(NSString *agentID, NSArray<CPTask *> *tasks) {
    CPAgent *a = CPAgent.new;
    a.agentID = agentID;
    a.name = agentID;
    a.iconName = @"sparkles";
    a.tasks = [NSMutableArray arrayWithArray:tasks];
    return a;
}

NSURL *CPTestFixtureURL(NSString *name) {
    NSBundle *bundle = [NSBundle bundleForClass:CPTestHelpersMarker.class];
    NSURL *url = [bundle URLForResource:name.stringByDeletingPathExtension
                          withExtension:name.pathExtension
                           subdirectory:@"Fixtures"];
    if (url) return url;
    // clang -fsyntax-only / 非 bundle 运行时回退到源树相对路径
    NSString *cwd = [NSFileManager.defaultManager currentDirectoryPath];
    NSString *path = [[cwd stringByAppendingPathComponent:@"Tests/CodexPulseTests/Fixtures"]
                      stringByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
        return [NSURL fileURLWithPath:path];
    }
    return nil;
}
