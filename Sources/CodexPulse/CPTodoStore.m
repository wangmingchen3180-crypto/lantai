#import "CPTodoStore.h"
#import "CPStatusEngine.h"
#import <sqlite3.h>

#pragma mark - Todo Store

// 轻量个人待办:独立于 Agent,与只读的 Codex 状态库完全无关。
// agent_id/thread_id 为 nullable 预留字段,供未来可选的 Agent 联动;当前 UI 恒不写入(恒 NULL)。
// Todo 计数只显示在工作台 Todo 栏内,绝不进入 HUD/Dock badge/悬浮球角标/Agent 状态灯等提醒聚合。


@implementation CPTodoStore {
    sqlite3 *_db;
}

+ (NSString *)defaultPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Codex Pulse"];
    return [dir stringByAppendingPathComponent:@"todos.sqlite"];
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (!self) return nil;
    self.path = path;
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    if (sqlite3_open_v2(path.UTF8String, &_db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (_db) { sqlite3_close(_db); _db = NULL; }
        return nil;
    }
    sqlite3_busy_timeout(_db, 150);
    // schema 版本:user_version=0 表示未初始化;升级走 switch 式迁移,当前仅 0→1 建表。
    int userVersion = 0;
    sqlite3_stmt *verStmt = NULL;
    if (sqlite3_prepare_v2(_db, "PRAGMA user_version", -1, &verStmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(verStmt) == SQLITE_ROW) userVersion = sqlite3_column_int(verStmt, 0);
    }
    if (verStmt) sqlite3_finalize(verStmt);
    switch (userVersion) {
        case 0: {
            const char *sql =
                "CREATE TABLE IF NOT EXISTS todos("
                "id INTEGER PRIMARY KEY AUTOINCREMENT, "
                "title TEXT NOT NULL, "
                "completed INTEGER NOT NULL DEFAULT 0, "
                "agent_id TEXT NULL, "
                "thread_id TEXT NULL, "
                "created_at REAL NOT NULL, "
                "updated_at REAL NOT NULL)";
            char *errmsg = NULL;
            if (sqlite3_exec(_db, sql, NULL, NULL, &errmsg) != SQLITE_OK) {
                NSLog(@"[CPTodoStore] migrate 0→1 CREATE TABLE failed: %s", errmsg ? errmsg : sqlite3_errmsg(_db));
                if (errmsg) sqlite3_free(errmsg);
            } else if (sqlite3_exec(_db, "PRAGMA user_version = 1", NULL, NULL, &errmsg) != SQLITE_OK) {
                NSLog(@"[CPTodoStore] migrate 0→1 set user_version failed: %s", errmsg ? errmsg : sqlite3_errmsg(_db));
                if (errmsg) sqlite3_free(errmsg);
            }
            break;
        }
        default:
            break; // 已是最新或未知更高版本:保持只读兼容,将来在此加 case
    }
    return self;
}

- (void)dealloc {
    if (_db) sqlite3_close(_db);
}

- (NSArray<CPTodo *> *)allTodos {
    NSMutableArray<CPTodo *> *todos = NSMutableArray.array;
    if (!_db) return todos;
    const char *sql = "SELECT id, title, completed, agent_id, thread_id, created_at, updated_at "
                      "FROM todos ORDER BY completed ASC, created_at ASC, id ASC";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            CPTodo *todo = CPTodo.new;
            todo.todoID = (NSInteger)sqlite3_column_int64(stmt, 0);
            todo.title = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 1)] ?: @"";
            todo.completed = sqlite3_column_int(stmt, 2) != 0;
            todo.agentID = sqlite3_column_text(stmt, 3)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 3)] : nil;
            todo.threadID = sqlite3_column_text(stmt, 4)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 4)] : nil;
            todo.createdAt = CPDateFromSeconds(sqlite3_column_double(stmt, 5)) ?: NSDate.date;
            todo.updatedAt = CPDateFromSeconds(sqlite3_column_double(stmt, 6)) ?: NSDate.date;
            [todos addObject:todo];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    return todos;
}

- (CPTodo *)todoWithID:(NSInteger)todoID {
    if (!_db) return nil;
    const char *sql = "SELECT id, title, completed, agent_id, thread_id, created_at, updated_at "
                      "FROM todos WHERE id=? LIMIT 1";
    sqlite3_stmt *stmt = NULL;
    CPTodo *todo = nil;
    if (sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_int64(stmt, 1, todoID);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            todo = CPTodo.new;
            todo.todoID = (NSInteger)sqlite3_column_int64(stmt, 0);
            todo.title = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 1)] ?: @"";
            todo.completed = sqlite3_column_int(stmt, 2) != 0;
            todo.agentID = sqlite3_column_text(stmt, 3)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 3)] : nil;
            todo.threadID = sqlite3_column_text(stmt, 4)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 4)] : nil;
            todo.createdAt = CPDateFromSeconds(sqlite3_column_double(stmt, 5)) ?: NSDate.date;
            todo.updatedAt = CPDateFromSeconds(sqlite3_column_double(stmt, 6)) ?: NSDate.date;
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    return todo;
}

- (NSInteger)pendingCount {
    if (!_db) return 0;
    NSInteger count = 0;
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(_db, "SELECT COUNT(*) FROM todos WHERE completed=0", -1, &stmt, NULL) == SQLITE_OK) {
        if (sqlite3_step(stmt) == SQLITE_ROW) count = (NSInteger)sqlite3_column_int64(stmt, 0);
    }
    if (stmt) sqlite3_finalize(stmt);
    return count;
}

- (BOOL)exec:(const char *)sql bind:(void (^)(sqlite3_stmt *stmt))bind {
    if (!_db) return NO;
    sqlite3_stmt *stmt = NULL;
    BOOL ok = NO;
    int rc = sqlite3_prepare_v2(_db, sql, -1, &stmt, NULL);
    if (rc == SQLITE_OK) {
        if (bind) bind(stmt);
        ok = sqlite3_step(stmt) == SQLITE_DONE;
        if (!ok) {
            NSLog(@"[CPTodoStore] exec step failed: %s | sql=%s", sqlite3_errmsg(_db), sql);
        }
    } else {
        NSLog(@"[CPTodoStore] exec prepare failed: %s | sql=%s", sqlite3_errmsg(_db), sql);
    }
    if (stmt) sqlite3_finalize(stmt);
    return ok;
}

- (CPTodo *)addTodoWithTitle:(NSString *)title {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return nil;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL ok = [self exec:"INSERT INTO todos(title, completed, created_at, updated_at) VALUES(?, 0, ?, ?)"
                    bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_text(stmt, 1, trimmed.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 2, now);
        sqlite3_bind_double(stmt, 3, now);
    }];
    if (!ok) {
        NSLog(@"[CPTodoStore] addTodo failed: %s", _db ? sqlite3_errmsg(_db) : "no db");
        return nil;
    }
    CPTodo *todo = CPTodo.new;
    todo.todoID = (NSInteger)sqlite3_last_insert_rowid(_db);
    todo.title = trimmed;
    todo.completed = NO;
    todo.createdAt = [NSDate dateWithTimeIntervalSince1970:now];
    todo.updatedAt = todo.createdAt;
    return todo;
}

- (void)setTodo:(NSInteger)todoID completed:(BOOL)completed {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    BOOL ok = [self exec:"UPDATE todos SET completed=?, updated_at=? WHERE id=?"
                    bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_int(stmt, 1, completed ? 1 : 0);
        sqlite3_bind_double(stmt, 2, now);
        sqlite3_bind_int64(stmt, 3, todoID);
    }];
    if (!ok) NSLog(@"[CPTodoStore] setTodo(%ld) completed=%d failed: %s",
                   (long)todoID, (int)completed, _db ? sqlite3_errmsg(_db) : "no db");
}

- (void)updateTodo:(NSInteger)todoID title:(NSString *)title {
    NSString *trimmed = [title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!trimmed.length) return;
    BOOL ok = [self exec:"UPDATE todos SET title=?, updated_at=? WHERE id=?"
                    bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_text(stmt, 1, trimmed.UTF8String, -1, SQLITE_TRANSIENT);
        sqlite3_bind_double(stmt, 2, NSDate.date.timeIntervalSince1970);
        sqlite3_bind_int64(stmt, 3, todoID);
    }];
    if (!ok) NSLog(@"[CPTodoStore] updateTodo(%ld) failed: %s",
                   (long)todoID, _db ? sqlite3_errmsg(_db) : "no db");
}

- (void)deleteTodo:(NSInteger)todoID {
    BOOL ok = [self exec:"DELETE FROM todos WHERE id=?"
                    bind:^(sqlite3_stmt *stmt) {
        sqlite3_bind_int64(stmt, 1, todoID);
    }];
    if (!ok) NSLog(@"[CPTodoStore] deleteTodo(%ld) failed: %s",
                   (long)todoID, _db ? sqlite3_errmsg(_db) : "no db");
}

@end

