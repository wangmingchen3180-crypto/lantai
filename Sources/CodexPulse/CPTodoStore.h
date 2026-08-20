#import <Cocoa/Cocoa.h>
#import "CPModels.h"

@interface CPTodoStore : NSObject
@property NSString *path;
+ (NSString *)defaultPath;
- (instancetype)initWithPath:(NSString *)path;
- (NSArray<CPTodo *> *)allTodos; // 未完成在前(created_at 升序),已完成在后
- (CPTodo *)todoWithID:(NSInteger)todoID; // 无则 nil;Bridge PATCH/DELETE 靠它区分 404
- (NSInteger)pendingCount;
- (CPTodo *)addTodoWithTitle:(NSString *)title;
- (void)setTodo:(NSInteger)todoID completed:(BOOL)completed;
- (void)updateTodo:(NSInteger)todoID title:(NSString *)title;
- (void)deleteTodo:(NSInteger)todoID;
@end

