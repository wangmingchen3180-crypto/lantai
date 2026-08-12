#import <XCTest/XCTest.h>
#import "CPTodoStore.h"
#import <sqlite3.h>

@interface CPTodoStoreTests : XCTestCase
@end

@implementation CPTodoStoreTests

// 原自测: Todo self-test add / blank-ignored / complete / restore / edit / delete /
// persist / agent-null / user-version
- (void)testCRUDAndSchemaVersion {
    NSString *todoTestPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codexpulse-todo-xctest-%d.sqlite",
         NSProcessInfo.processInfo.processIdentifier]];
    [[NSFileManager defaultManager] removeItemAtPath:todoTestPath error:nil];

    CPTodoStore *todoStore = [[CPTodoStore alloc] initWithPath:todoTestPath];
    CPTodo *t1 = [todoStore addTodoWithTitle:@"第一条"];
    CPTodo *t2 = [todoStore addTodoWithTitle:@"  第二条  "];
    XCTAssertTrue(t1 && t2 && todoStore.allTodos.count == 2 && todoStore.pendingCount == 2);
    XCTAssertEqualObjects(t2.title, @"第二条");

    XCTAssertNil([todoStore addTodoWithTitle:@"   "]);
    XCTAssertEqual(todoStore.allTodos.count, (NSUInteger)2);

    [todoStore setTodo:t1.todoID completed:YES];
    XCTAssertEqual(todoStore.pendingCount, (NSInteger)1);
    XCTAssertEqual(todoStore.allTodos.firstObject.todoID, t2.todoID);

    [todoStore setTodo:t1.todoID completed:NO];
    XCTAssertEqual(todoStore.pendingCount, (NSInteger)2);

    [todoStore updateTodo:t2.todoID title:@"第二条改"];
    CPTodo *t2After = nil;
    for (CPTodo *t in todoStore.allTodos) if (t.todoID == t2.todoID) t2After = t;
    XCTAssertEqualObjects(t2After.title, @"第二条改");

    [todoStore deleteTodo:t1.todoID];
    XCTAssertEqual(todoStore.allTodos.count, (NSUInteger)1);
    XCTAssertEqual(todoStore.pendingCount, (NSInteger)1);

    CPTodoStore *todoReopen = [[CPTodoStore alloc] initWithPath:todoTestPath];
    CPTodo *t2Persisted = todoReopen.allTodos.firstObject;
    XCTAssertEqual(todoReopen.allTodos.count, (NSUInteger)1);
    XCTAssertEqualObjects(t2Persisted.title, @"第二条改");
    XCTAssertNil(t2Persisted.agentID);
    XCTAssertNil(t2Persisted.threadID);

    int todoUV = -1;
    sqlite3 *todoVerDB = NULL;
    if (sqlite3_open_v2(todoTestPath.UTF8String, &todoVerDB, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *todoVerStmt = NULL;
        if (sqlite3_prepare_v2(todoVerDB, "PRAGMA user_version", -1, &todoVerStmt, NULL) == SQLITE_OK &&
            sqlite3_step(todoVerStmt) == SQLITE_ROW) {
            todoUV = sqlite3_column_int(todoVerStmt, 0);
        }
        if (todoVerStmt) sqlite3_finalize(todoVerStmt);
    }
    if (todoVerDB) sqlite3_close(todoVerDB);
    XCTAssertEqual(todoUV, 1);

    [[NSFileManager defaultManager] removeItemAtPath:todoTestPath error:nil];
}

// 原自测: Todo schema self-test user-version
- (void)testSchemaUserVersionOnFreshStore {
    NSString *todoSchemaPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"codexpulse-todo-schema-xctest-%d.sqlite",
         NSProcessInfo.processInfo.processIdentifier]];
    [[NSFileManager defaultManager] removeItemAtPath:todoSchemaPath error:nil];
    CPTodoStore *todoSchemaStore = [[CPTodoStore alloc] initWithPath:todoSchemaPath];
    CPTodo *todoSchemaItem = [todoSchemaStore addTodoWithTitle:@"schema-v1"];
    int todoSchemaUV = -1;
    sqlite3 *todoSchemaDB = NULL;
    if (sqlite3_open_v2(todoSchemaPath.UTF8String, &todoSchemaDB, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *todoSchemaStmt = NULL;
        if (sqlite3_prepare_v2(todoSchemaDB, "PRAGMA user_version", -1, &todoSchemaStmt, NULL) == SQLITE_OK &&
            sqlite3_step(todoSchemaStmt) == SQLITE_ROW) {
            todoSchemaUV = sqlite3_column_int(todoSchemaStmt, 0);
        }
        if (todoSchemaStmt) sqlite3_finalize(todoSchemaStmt);
    }
    if (todoSchemaDB) sqlite3_close(todoSchemaDB);
    XCTAssertTrue(todoSchemaStore && todoSchemaItem && todoSchemaUV == 1);
    [[NSFileManager defaultManager] removeItemAtPath:todoSchemaPath error:nil];
}

@end
