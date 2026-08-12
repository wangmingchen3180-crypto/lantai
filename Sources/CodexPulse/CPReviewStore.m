#import "CPReviewStore.h"
#import "CPStatusEngine.h"


@implementation CPReviewStore

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    self = [super init];
    if (!self) return nil;
    self.defaults = defaults;
    return self;
}

- (NSString *)signatureForTask:(CPTask *)task {
    return [NSString stringWithFormat:@"%.3f", task.updatedAt.timeIntervalSince1970];
}

- (NSString *)keyForTask:(CPTask *)task agentID:(NSString *)agentID {
    return [NSString stringWithFormat:@"reviewed.%@.%@", agentID, task.taskID];
}

- (BOOL)isTaskReviewed:(CPTask *)task agentID:(NSString *)agentID {
    NSString *stored = [self.defaults stringForKey:[self keyForTask:task agentID:agentID]];
    return stored && [stored isEqualToString:[self signatureForTask:task]];
}

- (void)markTaskReviewed:(CPTask *)task agentID:(NSString *)agentID {
    [self.defaults setObject:[self signatureForTask:task] forKey:[self keyForTask:task agentID:agentID]];
}

@end

NSString * const CPReviewGrandfatheredKey = @"CPReviewGrandfathered";

void CPGrandfatherCompletedReviewsIfNeeded(NSUserDefaults *defaults, CPReviewStore *reviewStore, NSArray<CPAgent *> *agents) {
    if (!defaults || !reviewStore) return;
    if ([defaults boolForKey:CPReviewGrandfatheredKey]) return;
    for (CPAgent *a in agents) {
        if (a.placeholder) continue;
        for (CPTask *t in a.tasks) {
            if (t.status == CPStatusCompleted) {
                [reviewStore markTaskReviewed:t agentID:a.agentID];
            }
        }
    }
    [defaults setBool:YES forKey:CPReviewGrandfatheredKey];
}

// CPAgentStatusButton:HUD rail 的 Agent 状态按钮(方向 A 选中态)。
// 选中信息完全由状态环与涟漪承载:未选中 = 状态色细环(1.5px,opacity ~0.28)+ 涟漪静止;
// 选中 = 环变实色(opacity 1,线宽 2px)+ 8 层明暗成对涟漪常开(按状态周期);
// hover 未选中项只把环透明度提到 ~0.55,不起涟漪、不加背景蒙层(背景永远透明)。
