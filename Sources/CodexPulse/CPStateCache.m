#import "CPStateCache.h"


@implementation CPStateCache

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.capacity = 1024;
    return self;
}

- (id)objectForPath:(NSString *)path parser:(id (^)(NSString *path))parser {
    if (!path.length || !parser) return nil;
    if (!self.entries) self.entries = NSMutableDictionary.dictionary;
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate *mtime = attrs[NSFileModificationDate] ?: NSDate.distantPast;
    NSNumber *size = attrs[NSFileSize] ?: @0;
    NSDictionary *cached = self.entries[path];
    self.tick++;
    if (cached && [cached[@"mtime"] isEqual:mtime] && [cached[@"size"] isEqual:size]) {
        // O(1) 命中:只重写 accessTick,不搬动任何队列
        self.entries[path] = @{@"mtime": cached[@"mtime"], @"size": cached[@"size"],
                               @"value": cached[@"value"], @"tick": @(self.tick)};
        id value = cached[@"value"];
        return [value isKindOfClass:NSNull.class] ? nil : value;
    }
    id value = parser(path) ?: NSNull.null;
    if (!cached && self.entries.count >= MAX(self.capacity, (NSUInteger)1)) {
        // 超容量才扫描一次,逐出 accessTick 最小(最久未用)的条目;绝不清空全表
        NSString *victim = nil;
        uint64_t oldest = UINT64_MAX;
        for (NSString *key in self.entries) {
            uint64_t t = [self.entries[key][@"tick"] unsignedLongLongValue];
            if (t < oldest) { oldest = t; victim = key; }
        }
        if (victim) [self.entries removeObjectForKey:victim];
    }
    self.entries[path] = @{@"mtime": mtime, @"size": size, @"value": value, @"tick": @(self.tick)};
    return [value isKindOfClass:NSNull.class] ? nil : value;
}

@end
