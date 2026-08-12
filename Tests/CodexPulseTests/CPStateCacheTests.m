#import <XCTest/XCTest.h>
#import "CPStateCache.h"
#import "CPTestHelpers.h"

@interface CPStateCacheTests : XCTestCase
@end

@implementation CPStateCacheTests

// 原自测: Kimi self-test 内嵌 k16b（lru-stable 中的小容量逐出语义）
// capacity=4 写入 6 个文件 → 条目数 4、最久未用被逐出、热条目命中不重解析
- (void)testLRUEvictionKeepsHotEntries {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codexpulse-xctest-cache-%d", NSProcessInfo.processInfo.processIdentifier]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    CPStateCache *cache = CPStateCache.new;
    cache.capacity = 4;
    __block NSInteger parseCount = 0;
    for (int i = 0; i < 6; i++) {
        NSString *fp = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"f%d.json", i]];
        [@"{}" writeToFile:fp atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [cache objectForPath:fp parser:^id(NSString *p) { parseCount++; return @""; }];
    }
    NSString *newest = [dir stringByAppendingPathComponent:@"f5.json"];
    NSString *oldest = [dir stringByAppendingPathComponent:@"f0.json"];
    NSInteger parseBefore = parseCount;
    [cache objectForPath:newest parser:^id(NSString *p) { parseCount++; return @""; }];

    XCTAssertEqual(cache.entries.count, (NSUInteger)4);
    XCTAssertNil(cache.entries[oldest]);
    XCTAssertNotNil(cache.entries[newest]);
    XCTAssertEqual(parseCount, parseBefore);

    [fm removeItemAtPath:dir error:nil];
}

// 原自测: Kimi self-test cache-hit（同一 path 两轮 objectForPath，解析器只调一次）
- (void)testCacheHitSkipsReparse {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codexpulse-xctest-hit-%d", NSProcessInfo.processInfo.processIdentifier]];
    NSFileManager *fm = NSFileManager.defaultManager;
    [fm removeItemAtPath:dir error:nil];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];

    // 使用落盘 fixture 作为代表性 JSONL 内容
    NSURL *fixture = CPTestFixtureURL(@"rollout-task-started.jsonl");
    XCTAssertNotNil(fixture);
    NSString *path = [dir stringByAppendingPathComponent:@"sample.jsonl"];
    [[NSData dataWithContentsOfURL:fixture] writeToFile:path atomically:YES];

    CPStateCache *cache = CPStateCache.new;
    __block NSInteger parses = 0;
    id first = [cache objectForPath:path parser:^id(NSString *p) {
        parses++;
        return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    }];
    id second = [cache objectForPath:path parser:^id(NSString *p) {
        parses++;
        return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    }];
    XCTAssertEqual(parses, 1);
    XCTAssertEqualObjects(first, second);

    [fm removeItemAtPath:dir error:nil];
}

@end
