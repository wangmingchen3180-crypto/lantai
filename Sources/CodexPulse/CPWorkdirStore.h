#import <Foundation/Foundation.h>

@interface CPWorkdirEntry : NSObject
@property (copy) NSString *workdirID;   // 稳定 UUID 字符串
@property (copy) NSString *name;        // 显示名
@property (copy) NSString *path;        // 绝对路径
@end

@interface CPWorkdirStore : NSObject
+ (NSString *)defaultsKey;                       // @"control.workdirs.v1"
- (instancetype)initWithSuiteName:(NSString *)suiteName; // nil 表示 standardUserDefaults；自测用独立 suite
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults; // Bridge 与自测共用同一份 defaults 对象
- (NSArray<CPWorkdirEntry *> *)allEntries;       // 已过滤畸形项
- (CPWorkdirEntry *)entryWithID:(NSString *)workdirID;
- (CPWorkdirEntry *)addPath:(NSString *)path name:(NSString *)name; // 生成 UUID；重复路径返回已有项而不新增
- (BOOL)renameEntry:(NSString *)workdirID to:(NSString *)name;
- (BOOL)removeEntry:(NSString *)workdirID;
@end
