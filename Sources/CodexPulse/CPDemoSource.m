#import "CPDemoSource.h"
#import "CPStatusEngine.h"
#import "CPQuota.h"

@interface CPDemoSource ()
@property (nonatomic, copy) NSString *demoAgentID;
@end

@implementation CPDemoSource

- (instancetype)initWithAgentID:(NSString *)agentID {
    self = [super init];
    if (!self) return nil;
    _demoAgentID = [agentID copy];
    return self;
}

// 相对当前时间构造更新时刻,这样「更新于 x 分钟前」在任何时候截图都成立。
static CPTask *CPDemoTask(NSString *taskID, NSString *title, NSString *project,
                          NSString *sourceKind, CPStatus status,
                          NSTimeInterval minutesAgo, NSInteger tokens, NSString *activity) {
    CPTask *task = CPTask.new;
    task.taskID = taskID;
    task.title = title;
    task.projectName = project;
    task.projectPath = [@"~/Developer" stringByAppendingPathComponent:project];
    task.sourceKind = sourceKind;
    task.status = status;
    task.activity = activity;
    task.tokensUsed = tokens;
    task.updatedAt = [NSDate dateWithTimeIntervalSinceNow:-minutesAgo * 60.0];
    task.createdAt = [NSDate dateWithTimeIntervalSinceNow:-(minutesAgo + 45.0) * 60.0];
    return task;
}

- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = self.demoAgentID;
    agent.placeholder = NO;
    agent.health = CPAgentHealthOK;

    if ([self.demoAgentID isEqualToString:@"kimi"]) {
        agent.name = @"Kimi";
        agent.iconName = @"moon";
        agent.color = CPMuted();
        agent.tasks = [@[
            CPDemoTask(@"demo-kimi-1", @"把 README 拆成中英两份并保持对等", @"lantai",
                       @"kimi-client", CPStatusWorking, 2, 18400,
                       @"正在改写英文版的 Known limitations 一节。"),
            CPDemoTask(@"demo-kimi-2", @"调研 macOS 公证流程与 notarytool 配置", @"lantai",
                       @"kimi-client", CPStatusCompleted, 34, 26100,
                       @"已整理成三步:开发者 ID 签名、notarytool submit、stapler 装订。"),
            CPDemoTask(@"demo-kimi-3", @"对比三种涟漪实现的 CPU 开销", @"lantai",
                       @"kimi-client", CPStatusIdle, 210, 9800,
                       @"明暗双环方案在 8 层下稳定占用最低,已采纳。")
        ] mutableCopy];
    } else {
        agent.name = @"Codex";
        agent.iconName = @"terminal.fill";
        agent.color = CPAccent();
        agent.tasks = [@[
            CPDemoTask(@"demo-codex-1", @"修复工作台详情页的点击穿透", @"lantai",
                       @"codex", CPStatusAttention, 1, 31200,
                       @"改动会影响 hitTest 边界,需要你确认是否继续。"),
            CPDemoTask(@"demo-codex-2", @"重构 HUD 选中态的涟漪层级", @"lantai",
                       @"codex", CPStatusWorking, 4, 22750,
                       @"正在把 CPRippleView 的 8 层错峰改为按状态派生周期。"),
            CPDemoTask(@"demo-codex-3", @"给 CPTodoStore 补并发写入测试", @"lantai",
                       @"codex", CPStatusCompleted, 26, 15300,
                       @"新增 4 个用例,覆盖并发插入与失败回滚,全部通过。"),
            CPDemoTask(@"demo-codex-4", @"接入 Claude Desktop 只读适配器", @"lantai",
                       @"codex", CPStatusFailed, 68, 7400,
                       @"未找到约定的本地会话索引,适配器探测失败。"),
            CPDemoTask(@"demo-codex-5", @"整理 v0.4 版本路线", @"notes",
                       @"codex", CPStatusCompleted, 155, 5200,
                       @"已写入 BACKLOG.md,涟漪设计语言列为本轮主线。")
        ] mutableCopy];
    }

    agent.status = CPOverallStatusForTasks(agent.tasks);
    CPQuotaSnapshot *quota = CPQuotaSnapshot.new;
    quota.agentID = agent.agentID;
    quota.health = CPAgentHealthOK;
    quota.updatedAt = NSDate.date;
    quota.windows = NSMutableArray.array;
    if ([self.demoAgentID isEqualToString:@"kimi"]) {
        [quota.windows addObject:({
            CPQuotaWindow *w = CPQuotaWindow.new;
            w.windowID = @"session"; w.title = @"5小时"; w.usedPercent = 0; w.windowMinutes = 300;
            w.resetsAt = [NSDate dateWithTimeIntervalSinceNow:4 * 3600];
            w;
        })];
        [quota.windows addObject:({
            CPQuotaWindow *w = CPQuotaWindow.new;
            w.windowID = @"weekly"; w.title = @"周"; w.usedPercent = 15; w.windowMinutes = 10080;
            w.resetsAt = [NSDate dateWithTimeIntervalSinceNow:2.5 * 86400];
            w;
        })];
    } else {
        [quota.windows addObject:({
            CPQuotaWindow *w = CPQuotaWindow.new;
            w.windowID = @"weekly"; w.title = @"周"; w.usedPercent = 57; w.windowMinutes = 10080;
            w.resetsAt = [NSDate dateWithTimeIntervalSinceNow:2.9 * 86400];
            w;
        })];
    }
    agent.quota = quota;
    return agent;
}

@end

NSArray<id<CPAgentSource>> *CPDemoAgentSources(void) {
    return @[[[CPDemoSource alloc] initWithAgentID:@"codex"],
             [[CPDemoSource alloc] initWithAgentID:@"kimi"]];
}
