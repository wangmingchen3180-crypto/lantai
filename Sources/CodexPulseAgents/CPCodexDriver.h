#import <Foundation/Foundation.h>
#import "CPAgentControl.h"

@protocol CPCodexTransport <NSObject>
@property (copy) void (^onLine)(NSString *line);
@property (copy) void (^onClosed)(void);
- (BOOL)start;
- (void)stop;
- (BOOL)isAlive;
- (void)sendLine:(NSString *)line;
@end

// JSONL 分帧：一次投喂可能是半行、多行或超长行，按 \n 切，未完成的留在缓冲里。
@interface CPCodexJSONLBuffer : NSObject
- (NSArray<NSString *> *)appendBytes:(const void *)bytes length:(NSUInteger)length;
@end

@interface CPCodexDriver : NSObject <CPAgentControlDriver>
@property NSTimeInterval requestTimeout; // 默认 30s；自测可改短
// 实时活动流：driver 只负责折叠成事件对象，不认识 HTTP/SSE。组装根(CPAppDelegate)把这三个
// 回调接到 Bridge 上，限流/截断/补抓都在 Bridge 那边做。回调可能在任意线程回来。
@property (copy) void (^onActivityEntry)(CPActivityEntry *entry);
@property (copy) void (^onActivityFlush)(NSString *agentID, NSString *taskID); // item/turn 结束，立即冲刷
@property (copy) void (^onActivityLive)(NSString *agentID, BOOL live);         // app-server 健康翻转
- (instancetype)initWithTransport:(id<CPCodexTransport>)transport
                       binaryPath:(NSString *)binaryPath;
- (void)startNow;
- (void)shutdown;
// 读账号额度。completion 可能在任意线程。失败时 result 为 nil。
- (void)readRateLimitsWithCompletion:(void (^)(NSDictionary *result, NSString *errorMessage))completion;
@end

NSString *CPCodexFindBinary(void);
