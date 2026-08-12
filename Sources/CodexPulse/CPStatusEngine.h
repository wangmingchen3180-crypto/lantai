#import <Cocoa/Cocoa.h>
#import <sqlite3.h>
#import "CPModels.h"

@class CPReviewStore;

FOUNDATION_EXPORT BOOL CPRunningSelfTests;
FOUNDATION_EXPORT BOOL CPTodoUseIsolatedStore;

CGFloat CPContrastAdjustChannel(CGFloat v);
NSColor *CPDyn(CGFloat lr, CGFloat lg, CGFloat lb, CGFloat dr, CGFloat dg, CGFloat db);
NSColor *CPAccent(void);
NSColor *CPBg(void);
NSColor *CPSurface(void);
NSColor *CPBorder(void);
NSColor *CPFg(void);
NSColor *CPFg2(void);
NSColor *CPMuted(void);
NSColor *CPBlue(void);
NSColor *CPOrange(void);
NSColor *CPRed(void);
NSColor *CPGreen(void);
NSColor *CPHairline(void);

NSString *CPStatusTitle(CPStatus s);
NSString *CPStatusSymbol(CPStatus s);
NSColor *CPStatusColor(CPStatus s);
NSImage *CPDotImage(CGFloat size, NSColor *color);
NSImage *CPStatusDot(CGFloat size, CPStatus status);
NSDate *CPDateFromMillis(sqlite3_int64 v);
NSDate * CPDateFromSeconds(NSTimeInterval v);
CPStatus CPInferTaskStatus(NSDate * lastLog, NSDate * lastStarted, NSDate * lastComplete,
                           BOOL attentionPending, NSDate * lastError, NSDate *now);
NSInteger CPStatusTiePriority(CPStatus status);
NSString *CPCleanTitle(const unsigned char * text);
NSString *CPFormatTokens(NSInteger tokens);
NSString *CPFormatDateCN(NSDate * date);

CPDisplayStatus CPDisplayStatusForTask(CPTask *task, NSString *agentID, CPReviewStore * reviewStore);
CPDisplayStatus CPDisplayStatusForTasks(NSArray<CPTask *> *tasks, NSString *agentID, CPReviewStore * reviewStore);
CPDisplayStatus CPDisplayStatusForAgents(NSArray<CPAgent *> *agents, CPReviewStore * reviewStore);
NSString *CPDisplayStatusTitle(CPDisplayStatus s);
NSColor *CPDisplayStatusColor(CPDisplayStatus s);
NSInteger CPBadgeCountForAgents(NSArray<CPAgent *> *agents, CPReviewStore * reviewStore);
