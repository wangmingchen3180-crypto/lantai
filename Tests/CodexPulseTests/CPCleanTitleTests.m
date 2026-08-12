#import <XCTest/XCTest.h>
#import "CPStatusEngine.h"

@interface CPCleanTitleTests : XCTestCase
@end

@implementation CPCleanTitleTests

// 原自测: M6 self-test clean-dirty / clean-loose-tag / clean-transcript /
// clean-plain / clean-nil / clean-truncate / clean-mdlink / clean-mdlink-multi /
// clean-bare-uri / clean-mdlink-truncate
- (void)testCleanDirtyBrowserContext {
    XCTAssertEqualObjects(
        CPCleanTitle((const unsigned char *)"想让你设计一个loop [11] user: <in-app-browser-context>秘密上下文</in-app-browser-context>"),
        @"想让你设计一个loop");
}

- (void)testCleanLooseTag {
    XCTAssertEqualObjects(
        CPCleanTitle((const unsigned char *)"<in-app-browser-context> 修复登录页崩溃"),
        @"修复登录页崩溃");
}

- (void)testCleanTranscript {
    XCTAssertEqualObjects(
        CPCleanTitle((const unsigned char *)"The following is the Codex agent history.\n>>> TRANSCRIPT START\n[3] user: 帮我修复构建错误\n>>> TRANSCRIPT END"),
        @"帮我修复构建错误");
}

- (void)testCleanPlain {
    XCTAssertEqualObjects(CPCleanTitle((const unsigned char *)"普通标题"), @"普通标题");
}

- (void)testCleanNil {
    XCTAssertEqualObjects(CPCleanTitle(NULL), @"未命名任务");
}

- (void)testCleanTruncate {
    NSString *longRaw = [@"" stringByPaddingToLength:100 withString:@"a" startingAtIndex:0];
    NSString *ctLong = CPCleanTitle((const unsigned char *)longRaw.UTF8String);
    XCTAssertEqual(ctLong.length, (NSUInteger)59);
    XCTAssertTrue([ctLong hasSuffix:@"…"]);
}

- (void)testCleanMarkdownLink {
    XCTAssertEqualObjects(
        CPCleanTitle((const unsigned char *)"[投资事件档案建立](chatgpt-conversation://abc123)"),
        @"投资事件档案建立");
}

- (void)testCleanMarkdownLinkMulti {
    XCTAssertEqualObjects(
        CPCleanTitle((const unsigned char *)"[方案一](chatgpt-conversation://x) 和 [方案二](https://example.com \"标题\") 比较"),
        @"方案一 和 方案二 比较");
}

- (void)testCleanBareURI {
    XCTAssertEqualObjects(
        CPCleanTitle((const unsigned char *)"整理纪要 chatgpt-conversation://deadbeef"),
        @"整理纪要");
}

- (void)testCleanMarkdownLinkTruncate {
    NSString *mdLongRaw = [NSString stringWithFormat:@"[%@](chatgpt-conversation://x)",
                           [@"" stringByPaddingToLength:100 withString:@"b" startingAtIndex:0]];
    NSString *ctMdLong = CPCleanTitle((const unsigned char *)mdLongRaw.UTF8String);
    XCTAssertEqual(ctMdLong.length, (NSUInteger)59);
    XCTAssertTrue([ctMdLong hasSuffix:@"…"]);
}

@end
