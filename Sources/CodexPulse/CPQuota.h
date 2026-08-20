#import <Foundation/Foundation.h>
#import "CPModels.h"

// 额度窗口标题:按分钟数归到 5小时 / 周 / 月,对不上就写「N小时」或「N天」。
NSString *CPQuotaTitleForMinutes(NSInteger minutes);

// 重置倒计时:「12分钟后重置」/「3小时后重置」/「2天后重置」。已过期写「已重置」。
NSString *CPQuotaResetPhrase(NSDate *resetsAt, NSDate *now);

// 紧凑一行,给菜单栏:「周 57% · 3天后重置」。读不到或还没有窗口时返回 @""。
NSString *CPQuotaCompactLine(CPQuotaSnapshot *snapshot);

// 菜单栏一行:「Codex  周 57% · 3天后重置」。snapshot 为 nil 时返回 nil(不画这一行)。
NSString *CPQuotaMenuTitle(NSString *agentName, CPQuotaSnapshot *snapshot);

// 解析 app-server account/rateLimits/read 的 result,或 rollout 里的 rate_limits。
// 认 camelCase 和 snake_case。解析失败返回 nil。
CPQuotaSnapshot *CPQuotaFromCodexRateLimits(NSDictionary *payload, NSString *agentID, NSDate *now);

// 解析 Kimi GetUsages + GetSubscriptionStats。优先用 ratio,其次 used/limit。
CPQuotaSnapshot *CPQuotaFromKimiResponses(NSDictionary *usages, NSDictionary *stats, NSString *agentID, NSDate *now);

// 只读 Kimi 桌面端 Cookies 里的 kimi-auth。不解密、不写盘、不打日志。没有或加密则为 nil。
NSString *CPKimiDesktopAuthToken(void);

// 同步取 Kimi 额度。调用方必须在后台队列。失败返回 health=Missing 的快照,不抛。
CPQuotaSnapshot *CPKimiFetchQuotaSnapshot(void);
