#import <XCTest/XCTest.h>
#import "CPStatusEngine.h"
#import "CPReviewStore.h"
#import "CPTestHelpers.h"

@interface CPStatusEngineTests : XCTestCase
@end

@implementation CPStatusEngineTests

// 原自测: M2 self-test prio-failed / prio-waiting / prio-attention / prio-blue /
// prio-working / prio-idle / latest-working / completed-visible
- (void)testDisplayStatusPriority {
    NSString *suite = [NSString stringWithFormat:@"com.codexpulse.xctest.prio.%d",
                       NSProcessInfo.processInfo.processIdentifier];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:suite];
    [defaults removePersistentDomainForName:suite];
    CPReviewStore *store = [[CPReviewStore alloc] initWithDefaults:defaults];

    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"a", CPStatusWorking, 1),
                                             CPTestTask(@"b", CPStatusCompleted, 1),
                                             CPTestTask(@"c", CPStatusAttention, 1),
                                             CPTestTask(@"d", CPStatusFailed, 1)], @"x", store),
                   CPDisplayStatusFailed);
    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"a", CPStatusWorking, 1),
                                             CPTestTask(@"b", CPStatusCompleted, 1),
                                             CPTestTask(@"c", CPStatusWaiting, 1)], @"x", store),
                   CPDisplayStatusWaiting);
    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"c", CPStatusAttention, 1),
                                             CPTestTask(@"a", CPStatusWorking, 1)], @"x", store),
                   CPDisplayStatusWaiting);
    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"b", CPStatusCompleted, 1),
                                             CPTestTask(@"a", CPStatusWorking, 1)], @"x", store),
                   CPDisplayStatusCompletedPendingReview);
    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"a", CPStatusWorking, 1),
                                             CPTestTask(@"e", CPStatusIdle, 1)], @"x", store),
                   CPDisplayStatusWorking);
    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"e", CPStatusIdle, 1)], @"x", store),
                   CPDisplayStatusIdle);
    XCTAssertEqual(CPDisplayStatusForTasks(@[], @"x", store), CPDisplayStatusIdle);
    XCTAssertEqual(CPDisplayStatusForTasks(@[CPTestTask(@"old-wait", CPStatusWaiting, 1),
                                             CPTestTask(@"new-work", CPStatusWorking, 2)], @"x", store),
                   CPDisplayStatusWorking);

    CPTask *reviewedComplete = CPTestTask(@"reviewed-complete", CPStatusCompleted, 4);
    [store markTaskReviewed:reviewedComplete agentID:@"x"];
    XCTAssertEqual(CPDisplayStatusForTasks(@[reviewedComplete], @"x", store),
                   CPDisplayStatusCompletedPendingReview);

    [defaults removePersistentDomainForName:suite];
    [defaults synchronize];
}

// 原自测: M2 self-test completed-persists / resumed-working / pending-attention /
// failure-persists / no-event-idle
- (void)testInferTaskStatusPriority {
    NSDate *now = [NSDate dateWithTimeIntervalSince1970:1000.0];
    NSDate *oldStart = [NSDate dateWithTimeIntervalSince1970:900.0];
    NSDate *completedAt = [NSDate dateWithTimeIntervalSince1970:950.0];
    NSDate *newerLog = [NSDate dateWithTimeIntervalSince1970:999.5];
    XCTAssertEqual(CPInferTaskStatus(newerLog, oldStart, completedAt, NO, nil, now), CPStatusCompleted);

    NSDate *resumedAt = [NSDate dateWithTimeIntervalSince1970:990.0];
    XCTAssertEqual(CPInferTaskStatus(newerLog, resumedAt, completedAt, NO, nil, now), CPStatusWorking);
    XCTAssertEqual(CPInferTaskStatus(newerLog, resumedAt, completedAt, YES, nil, now), CPStatusAttention);

    NSDate *failedAt = [NSDate dateWithTimeIntervalSince1970:995.0];
    XCTAssertEqual(CPInferTaskStatus(failedAt, resumedAt, completedAt, NO, failedAt, now), CPStatusFailed);
    XCTAssertEqual(CPInferTaskStatus(nil, nil, nil, NO, nil, now), CPStatusIdle);
}

@end
