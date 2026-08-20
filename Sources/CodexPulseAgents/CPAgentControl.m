#import "CPAgentControl.h"

@implementation CPAgentCommand
@end

@implementation CPAgentModel
@end

NSString *CPActivityKindJSON(CPActivityKind kind) {
    switch (kind) {
        case CPActivityKindSay: return @"say";
        case CPActivityKindThink: return @"think";
        case CPActivityKindRun: return @"run";
        case CPActivityKindEdit: return @"edit";
        case CPActivityKindPlan: return @"plan";
        case CPActivityKindUsage: return @"usage";
        case CPActivityKindNote: return @"note";
    }
}

@implementation CPActivityEntry
@end

@implementation CPAgentControlRegistry {
    NSMutableDictionary<NSString *, id<CPAgentControlDriver>> *_drivers;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _drivers = NSMutableDictionary.dictionary;
    return self;
}

- (void)registerDriver:(id<CPAgentControlDriver>)driver {
    NSString *agentID = driver.agentID;
    if (!agentID.length) return;
    @synchronized (self) {
        _drivers[agentID] = driver;
    }
}

- (id<CPAgentControlDriver>)driverForAgentID:(NSString *)agentID {
    if (!agentID.length) return nil;
    @synchronized (self) {
        return _drivers[agentID];
    }
}

- (NSArray<NSString *> *)capabilitiesForAgentID:(NSString *)agentID {
    id<CPAgentControlDriver> driver = [self driverForAgentID:agentID];
    if (!driver || !driver.isHealthy) return @[@"observe"];
    NSMutableArray<NSString *> *caps = [NSMutableArray arrayWithObject:@"observe"];
    NSMutableSet<NSString *> *seen = [NSMutableSet setWithObject:@"observe"];
    for (id item in driver.controlCapabilities ?: @[]) {
        if (![item isKindOfClass:NSString.class]) continue;
        NSString *cap = item;
        if (!cap.length || [seen containsObject:cap]) continue;
        [seen addObject:cap];
        [caps addObject:cap];
    }
    return caps;
}

@end
