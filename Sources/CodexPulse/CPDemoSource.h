#import <Cocoa/Cocoa.h>
#import "CPAgentSources.h"

// 虚构数据源。不碰本机任何 Agent 文件,任务全部写死在代码里。
// 用途:1) 截图与录屏不泄露真实项目名;2) 没装 Codex/Kimi 的人能看到界面长什么样。
@interface CPDemoSource : NSObject <CPAgentSource>
- (instancetype)initWithAgentID:(NSString *)agentID;
@end

// --demo 启用:返回 Codex + Kimi 两个虚构 Agent,覆盖全部五种展示状态。
NSArray<id<CPAgentSource>> *CPDemoAgentSources(void);
