#import <XCTest/XCTest.h>
#import "CPRouting.h"
#import "CPTestHelpers.h"

@interface CPRoutingTests : XCTestCase
@end

@implementation CPRoutingTests

// 原自测: Task routing self-test codex-thread / kimi-cli-fallback /
// kimi-desktop-link / unknown-fallback / placeholder-fallback
- (void)testDeepLinkSelection {
    CPTask *routeTask = CPTestTask(@"thread-123", CPStatusWorking, 1);
    routeTask.sourceKind = @"codex";
    CPAgent *routeCodex = CPTestAgent(@"codex", @[routeTask]);
    CPAgent *routeKimi = CPTestAgent(@"kimi", @[routeTask]);
    CPAgent *routeUnknown = CPTestAgent(@"unknown", @[routeTask]);

    XCTAssertEqualObjects(CPDeepLinkForAgentTask(routeCodex, routeTask).absoluteString,
                          @"codex://threads/thread-123");

    routeTask.sourceKind = @"kimi-cli";
    XCTAssertNil(CPDeepLinkForAgentTask(routeKimi, routeTask));

    CPTask *routeDesktopTask = CPTestTask(@"kimi-client-u1", CPStatusWorking, 1);
    routeDesktopTask.sourceKind = @"kimi-client";
    CPAgent *routeKimiDesktop = CPTestAgent(@"kimi", @[routeDesktopTask]);
    BOOL kimiSchemeRegistered = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"kimi-work://"]] != nil;
    NSURL *desktopLink = CPDeepLinkForAgentTask(routeKimiDesktop, routeDesktopTask);
    if (kimiSchemeRegistered) {
        XCTAssertEqualObjects(desktopLink.absoluteString, @"kimi-work://chat/u1");
    } else {
        XCTAssertNil(desktopLink);
    }

    XCTAssertNil(CPDeepLinkForAgentTask(routeUnknown, routeTask));

    routeKimi.placeholder = YES;
    XCTAssertNil(CPDeepLinkForAgentTask(routeKimi, routeTask));
}

@end
