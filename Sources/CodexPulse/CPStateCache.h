#import <Cocoa/Cocoa.h>

@interface CPStateCache : NSObject
@property (nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *entries; // path → {mtime,size,value,tick}
@property (nonatomic) uint64_t tick;     // 单调访问序号
@property (nonatomic) NSUInteger capacity; // 默认 1024,测试可调小验证逐出
- (id)objectForPath:(NSString *)path parser:(id (^)(NSString *path))parser;
@end

