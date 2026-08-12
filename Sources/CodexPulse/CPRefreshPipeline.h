#import <Cocoa/Cocoa.h>
#import "CPModels.h"


NSString *CPAgentsSignature(NSArray<CPAgent *> *agents);

@interface CPRefreshGate : NSObject
@property (nonatomic, readonly) BOOL inFlight;
- (BOOL)beginRefresh;                 // YES=获准执行;NO=已有读取在途(本次请求被合并为 pending)
- (BOOL)endRefreshAndShouldRunAgain;  // 结束当前读取;YES=期间有合并请求,需要再补跑一次
@end

