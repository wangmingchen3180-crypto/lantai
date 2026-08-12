#import "CPRefreshPipeline.h"

#pragma mark - Refresh Pipeline (性能:后台读取 + 合并 + 签名跳过)

// 可见数据签名:逐 agent/task 拼接会影响界面的字段(id/状态/更新时间/tokens/标题/活动)。
// 后台读出的新数据与已应用签名一致时,跳过工作台/Dock/HUD/菜单全部重建——
// 否则每 3s 反复拆建 AppKit 视图、重挂 8 层无限涟漪,是主线程卡顿与 CPU 的主要来源之一。
NSString *CPAgentsSignature(NSArray<CPAgent *> *agents) {
    NSMutableString *sig = [NSMutableString string];
    for (CPAgent *a in agents) {
        [sig appendFormat:@"A:%@|%d|", a.agentID, (int)a.status];
        for (CPTask *t in a.tasks) {
            [sig appendFormat:@"T:%@|%d|%.3f|%ld|%tu|%tu;",
                              t.taskID, (int)t.status, t.updatedAt.timeIntervalSince1970,
                              (long)t.tokensUsed, t.title.hash, t.activity.hash];
        }
    }
    return sig;
}

// 刷新闸门(仅主线程使用):同一时刻最多一个后台读取;读取期间到达的请求合并为一次 pending,
// 结束后补跑一次,过期结果不会覆盖更新的读取。
@implementation CPRefreshGate {
    BOOL _inFlight;
    BOOL _pending;
}
- (BOOL)beginRefresh {
    if (_inFlight) { _pending = YES; return NO; }
    _inFlight = YES;
    return YES;
}
- (BOOL)endRefreshAndShouldRunAgain {
    _inFlight = NO;
    BOOL again = _pending;
    _pending = NO;
    return again;
}
@end

