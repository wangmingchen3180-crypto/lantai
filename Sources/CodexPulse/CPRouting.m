#import "CPRouting.h"
#import "CPControls.h"

NSURL *CPDeepLinkForAgentTask(CPAgent *agent, CPTask *task) {
    if (!agent || !task || !task.taskID.length || agent.placeholder) return nil;
    NSString *agentID = agent.agentID.lowercaseString;
    if ([agentID isEqualToString:@"codex"]) {
        NSString *escapedID = [task.taskID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        if (!escapedID.length) return nil;
        return [NSURL URLWithString:[NSString stringWithFormat:@"codex://threads/%@", escapedID]];
    }
    if ([agentID isEqualToString:@"kimi"]) {
        if (![task.sourceKind isEqualToString:@"kimi-client"] &&
            ![task.sourceKind isEqualToString:@"kimi-desktop"]) return nil;
        NSString *rawID = task.taskID;
        for (NSString *prefix in @[@"kimi-client-", @"kimi-desktop-"]) {
            if ([rawID hasPrefix:prefix]) { rawID = [rawID substringFromIndex:prefix.length]; break; }
        }
        NSString *escapedID = [rawID stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        if (!escapedID.length) return nil;
        NSURL *probe = [NSURL URLWithString:@"kimi-work://"];
        if (!probe || ![NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:probe]) return nil; // 未注册客户端协议不试深链
        return [NSURL URLWithString:[NSString stringWithFormat:@"kimi-work://chat/%@", escapedID]];
    }
    return nil;
}

// 优先用任务深链精确跳转；不支持深链时至少唤起任务所属 Agent 应用。
BOOL CPOpenAgentTask(CPAgent *agent, CPTask *task) {
    NSURL *deepLink = CPDeepLinkForAgentTask(agent, task);
    if (deepLink && [NSWorkspace.sharedWorkspace openURL:deepLink]) return YES;

    for (NSString *bundleID in CPBundleIDsForAgent(agent.agentID)) {
        NSArray<NSRunningApplication *> *running = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID];
        if (running.count) {
            [running.firstObject activateWithOptions:NSApplicationActivateAllWindows];
            return YES;
        }
        NSURL *appURL = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:bundleID];
        if (!appURL) continue;
        NSWorkspaceOpenConfiguration *configuration = NSWorkspaceOpenConfiguration.configuration;
        configuration.activates = YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:appURL
                                            configuration:configuration
                                        completionHandler:nil];
        return YES;
    }
    return NO;
}
