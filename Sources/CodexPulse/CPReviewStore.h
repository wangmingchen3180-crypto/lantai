#import <Cocoa/Cocoa.h>
#import "CPModels.h"

@interface CPReviewStore : NSObject
@property NSUserDefaults *defaults;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSString *)signatureForTask:(CPTask *)task;
- (BOOL)isTaskReviewed:(CPTask *)task agentID:(NSString *)agentID;
- (void)markTaskReviewed:(CPTask *)task agentID:(NSString *)agentID;
@end

FOUNDATION_EXPORT NSString * const CPReviewGrandfatheredKey;
void CPGrandfatherCompletedReviewsIfNeeded(NSUserDefaults *defaults, CPReviewStore *reviewStore, NSArray<CPAgent *> *agents);

