#import "CPAgentSources.h"
#import "CPStatusEngine.h"
#import <sqlite3.h>
#import <string.h>

#pragma mark - State Reader

const char *CPCodexVisibleThreadsSQL =
    "SELECT id, COALESCE(NULLIF(name,''), NULLIF(title,''), NULLIF(preview,''), '未命名任务'), "
    "cwd, created_at_ms, updated_at_ms, tokens_used, rollout_path FROM threads "
    "WHERE archived=0 AND preview<>'' "
    "AND COALESCE(thread_source,'') <> 'subagent' AND COALESCE(source,'') NOT LIKE '%\"subagent\"%' "
    "ORDER BY recency_at_ms DESC, updated_at_ms DESC LIMIT 10";

@implementation CPRolloutState @end

NSDate *CPDateFromISO8601(NSString *value) {
    if (!value.length) return nil;
    static NSISO8601DateFormatter *formatter = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = NSISO8601DateFormatter.new;
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter dateFromString:value];
}

// 只读 rollout 尾部，避免加载整段长会话；完成/启动事件都位于每轮末端。
CPRolloutState *CPReadRolloutState(NSString *path) {
    CPRolloutState *state = CPRolloutState.new;
    if (!path.length) return state;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return state;

    NSData *tail = nil;
    @try {
        unsigned long long length = [handle seekToEndOfFile];
        unsigned long long start = length > 262144 ? length - 262144 : 0;
        [handle seekToFileOffset:start];
        tail = [handle readDataToEndOfFile];
        [handle closeFile];
        if (start > 0 && tail.length) {
            const uint8_t *bytes = tail.bytes;
            NSUInteger firstNewline = NSNotFound;
            for (NSUInteger i = 0; i < tail.length; i++) {
                if (bytes[i] == '\n') { firstNewline = i; break; }
            }
            if (firstNewline == NSNotFound || firstNewline + 1 >= tail.length) return state;
            tail = [tail subdataWithRange:NSMakeRange(firstNewline + 1, tail.length - firstNewline - 1)];
        }
    } @catch (__unused NSException *exception) {
        return state;
    }

    NSString *text = [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
    if (!text.length) return state;
    NSMutableDictionary<NSString *, NSDate *> *pendingAttention = NSMutableDictionary.dictionary;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSData *lineData = [line dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *payload = entry[@"payload"];
        if (![payload isKindOfClass:NSDictionary.class]) continue;
        NSString *entryType = entry[@"type"];
        NSString *payloadType = payload[@"type"];
        NSDate *timestamp = CPDateFromISO8601(entry[@"timestamp"]);

        if ([entryType isEqualToString:@"event_msg"] && [payloadType isEqualToString:@"task_started"]) {
            state.lastStarted = timestamp;
            [pendingAttention removeAllObjects];
            continue;
        }
        if ([entryType isEqualToString:@"event_msg"] && [payloadType isEqualToString:@"task_complete"]) {
            state.lastComplete = timestamp;
            [pendingAttention removeAllObjects];
            continue;
        }
        if (![entryType isEqualToString:@"response_item"]) continue;
        if ([payloadType isEqualToString:@"custom_tool_call"] || [payloadType isEqualToString:@"function_call"]) {
            NSString *name = [payload[@"name"] description].lowercaseString;
            NSString *input = [payload[@"input"] description];
            BOOL asksForInput = [name containsString:@"request_user_input"];
            BOOL asksForApproval = [input containsString:@"sandbox_permissions"] && [input containsString:@"require_escalated"];
            if (asksForInput || asksForApproval) {
                NSString *callID = [payload[@"call_id"] description];
                if (!callID.length) callID = [payload[@"id"] description];
                if (callID.length) pendingAttention[callID] = timestamp ?: NSDate.distantPast;
            }
        } else if ([payloadType isEqualToString:@"custom_tool_call_output"] || [payloadType isEqualToString:@"function_call_output"]) {
            NSString *callID = [payload[@"call_id"] description];
            if (!callID.length) callID = [payload[@"id"] description];
            if (callID.length) [pendingAttention removeObjectForKey:callID];
        }
    }
    state.attentionPending = pendingAttention.count > 0;
    return state;
}


// 应用内 Agent 注册表:内置适配器与用户启用状态分离。开源用户只需在“添加 Agent”
// 里选择已安装的客户端;提供新 harness 时只需新增 CPAgentSource 并在此目录注册。
NSString * const CPEnabledAgentProvidersKey = @"agents.enabledProviders.v1";
NSString * const CPAgentSourcesChangedNotification = @"CPAgentSourcesChanged";

NSArray<NSDictionary *> *CPAgentProviderCatalog(void) {
    static NSArray<NSDictionary *> *catalog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        catalog = @[
            @{ @"id": @"codex", @"name": @"Codex", @"detail": @"Codex Desktop 本地任务" },
            @{ @"id": @"kimi", @"name": @"Kimi", @"detail": @"Kimi App 客户端任务" },
            @{ @"id": @"kimi-cli", @"name": @"Kimi CLI", @"detail": @"Kimi Code 终端会话（可选）" },
        ];
    });
    return catalog;
}

NSArray<NSString *> *CPEnabledAgentProviderIDs(void) {
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:CPEnabledAgentProvidersKey];
    if (![stored isKindOfClass:NSArray.class]) return @[@"codex", @"kimi"];
    NSMutableArray<NSString *> *valid = NSMutableArray.array;
    NSSet *known = [NSSet setWithArray:[CPAgentProviderCatalog() valueForKey:@"id"]];
    for (id item in stored) if ([item isKindOfClass:NSString.class] && [known containsObject:item]) [valid addObject:item];
    return valid;
}

BOOL CPAgentProviderIsDetected(NSString *providerID) {
    NSString *home = NSHomeDirectory();
    if ([providerID isEqualToString:@"codex"]) {
        return [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@".codex/state_5.sqlite"]];
    }
    if ([providerID isEqualToString:@"kimi"]) {
        NSString *db = [home stringByAppendingPathComponent:@"Library/Application Support/kimi-desktop/daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite"];
        return [NSFileManager.defaultManager fileExistsAtPath:db] ||
               [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.moonshot.kimichat"] != nil;
    }
    if ([providerID isEqualToString:@"kimi-cli"]) {
        return [NSFileManager.defaultManager fileExistsAtPath:[home stringByAppendingPathComponent:@".kimi-code/sessions"]];
    }
    return NO;
}

void CPEnableAgentProvider(NSString *providerID) {
    if (!providerID.length) return;
    NSMutableArray<NSString *> *enabled = [CPEnabledAgentProviderIDs() mutableCopy];
    if (![enabled containsObject:providerID]) [enabled addObject:providerID];
    [NSUserDefaults.standardUserDefaults setObject:enabled forKey:CPEnabledAgentProvidersKey];
    [NSNotificationCenter.defaultCenter postNotificationName:CPAgentSourcesChangedNotification object:providerID];
}

// Agent 数据源边界:每个 harness(Codex / Kimi / 未来 Claude)实现一个 source,
// 统一输出 CPAgent/CPTask;CPStateReader 只负责按注册数组聚合,不理解任何来源细节。

// Agent 总体状态:取最近更新任务的状态(同刻按严重度决胜)。供各 source 复用。
CPStatus CPOverallStatusForTasks(NSArray<CPTask *> *tasks) {
    CPTask *latest = nil;
    for (CPTask *t in tasks) {
        NSComparisonResult order = latest ? [t.updatedAt compare:latest.updatedAt] : NSOrderedDescending;
        if (!latest || order == NSOrderedDescending ||
            (order == NSOrderedSame && CPStatusTiePriority(t.status) > CPStatusTiePriority(latest.status))) latest = t;
    }
    return latest ? latest.status : CPStatusIdle;
}


#pragma mark - Codex Source


@implementation CPCodexSource

- (instancetype)initWithCache:(CPStateCache *)cache {
    self = [super init];
    if (!self) return nil;
    self.cache = cache;
    return self;
}

- (CPRolloutState *)rolloutStateForPath:(NSString *)path {
    if (!path.length) return CPRolloutState.new;
    CPRolloutState *state = [self.cache objectForPath:path parser:^id(NSString *p) { return CPReadRolloutState(p); }];
    return state ?: CPRolloutState.new;
}

- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"codex";
    agent.name = @"Codex";
    // 品牌图标近似:官方 Codex logo 位图不可直接打包(不引入外部资源),用 SF Symbol terminal.fill
    // 表达 CLI 形态 + accent 品牌色代替。
    agent.iconName = @"terminal.fill";
    agent.color = CPAccent();
    agent.placeholder = NO;
    agent.tasks = NSMutableArray.array;

    NSString *home = NSHomeDirectory();
    NSString *statePath = [home stringByAppendingPathComponent:@".codex/state_5.sqlite"];
    sqlite3 *stateDB = NULL;
    if (sqlite3_open_v2(statePath.UTF8String, &stateDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (stateDB) sqlite3_close(stateDB);
        agent.status = CPStatusIdle;
        return agent;
    }
    sqlite3_busy_timeout(stateDB, 150);

    NSString *logsPath = [home stringByAppendingPathComponent:@".codex/logs_2.sqlite"];
    sqlite3 *logsDB = NULL;
    if (sqlite3_open_v2(logsPath.UTF8String, &logsDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) == SQLITE_OK) {
        sqlite3_busy_timeout(logsDB, 150);
    }

    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(stateDB, CPCodexVisibleThreadsSQL, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)] ?: @"";
            task.title = CPCleanTitle(sqlite3_column_text(stmt, 1));
            task.projectPath = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 2)] ?: @"";
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Codex";
            task.createdAt = CPDateFromMillis(sqlite3_column_int64(stmt, 3));
            task.updatedAt = CPDateFromMillis(sqlite3_column_int64(stmt, 4));
            task.tokensUsed = (NSInteger)sqlite3_column_int64(stmt, 5);
            task.rolloutPath = sqlite3_column_text(stmt, 6)
                ? [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 6)] : @"";
            task.sourceKind = @"codex";
            [self enrichTask:task logsDB:logsDB];
            [agent.tasks addObject:task];
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(stateDB);
    if (logsDB) sqlite3_close(logsDB);

    agent.status = CPOverallStatusForTasks(agent.tasks);
    return agent;
}

- (void)enrichTask:(CPTask *)task logsDB:(sqlite3 *)logsDB {
    CPRolloutState *rollout = [self rolloutStateForPath:task.rolloutPath];
    if (!logsDB) {
        task.status = CPInferTaskStatus(nil, rollout.lastStarted, rollout.lastComplete,
                                        rollout.attentionPending, nil, NSDate.date);
        task.activity = task.status == CPStatusCompleted ? @"任务已完成" : @"正在整理任务状态";
        return;
    }
    const char *sql =
        "SELECT MAX(ts + ts_nanos / 1000000000.0), "
        "MAX(CASE WHEN level='ERROR' THEN ts + ts_nanos / 1000000000.0 ELSE 0 END) FROM logs WHERE thread_id=?";
    sqlite3_stmt *stmt = NULL;
    NSDate *lastLog = nil, *lastError = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, task.taskID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            lastLog = CPDateFromSeconds(sqlite3_column_double(stmt, 0));
            lastError = CPDateFromSeconds(sqlite3_column_double(stmt, 1));
        }
    }
    if (stmt) sqlite3_finalize(stmt);

    task.status = CPInferTaskStatus(lastLog, rollout.lastStarted, rollout.lastComplete,
                                    rollout.attentionPending, lastError, NSDate.date);

    task.activity = [self activityForTask:task logsDB:logsDB];
}

- (NSString *)activityForTask:(CPTask *)task logsDB:(sqlite3 *)logsDB {
    const char *sql = "SELECT target FROM logs WHERE thread_id=? ORDER BY ts DESC, ts_nanos DESC LIMIT 1";
    sqlite3_stmt *stmt = NULL;
    NSString *target = nil;
    if (sqlite3_prepare_v2(logsDB, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, task.taskID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW && sqlite3_column_text(stmt, 0))
            target = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)];
    }
    if (stmt) sqlite3_finalize(stmt);
    if ([target containsString:@"tools::parallel"]) return @"正在调用工具";
    if ([target containsString:@"stream_events"]) return @"正在处理模型输出";
    if ([target containsString:@"http_client"] || [target containsString:@"responses"]) return @"正在请求模型";
    if ([target containsString:@"shell"] || [target containsString:@"exec"]) return @"正在运行命令";
    if ([target containsString:@"app_server"]) return @"正在同步 Codex";
    if ([target containsString:@"goal"]) return @"正在推进长期目标";
    return task.status == CPStatusCompleted ? @"任务已完成" : @"Codex 正在活动";
}

@end

#pragma mark - Kimi Source

// Kimi 数据根:生产主源是 Kimi App 自己的 conversations.sqlite;
// CLI 是独立的可选 Agent,旧 daimon-share/sessions 仅保留为兼容解析与回归 fixture。
static NSString *CPKimiClientDatabasePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLIENT_DB"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/kimi-desktop/daimon-share/daimon/agents/main/sessions/hosted-logical/conversations.sqlite"];
}

static NSString *CPKimiClientStatusPath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLIENT_STATUS"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/Application Support/kimi-desktop/kimi-agent/conversation-statuses.json"];
}

static NSString *CPKimiCLIRoot(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLI_ROOT"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:@".kimi-code/sessions"];
}

static NSString *CPKimiDesktopRoot(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_DESKTOP_ROOT"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/kimi-desktop/daimon-share/sessions"];
}

// state.json 两版 schema:v2 是 epoch 毫秒(NSNumber/数字字符串,cwd/id/archived),
// v1 是 ISO8601 字符串(workDir)。两种都要能吃。
static NSDate *CPKimiDateFromValue(id value) {
    if ([value isKindOfClass:NSNumber.class]) return CPDateFromMillis([value longLongValue]);
    if ([value isKindOfClass:NSString.class]) {
        NSString *s = (NSString *)value;
        if (!s.length) return nil;
        if ([s rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound) {
            return CPDateFromMillis(s.longLongValue);
        }
        return CPDateFromISO8601(s);
    }
    return nil;
}

// 只读文件尾部(对齐到行边界),绝不全量读大 wire。
static NSString *CPReadFileTail(NSString *path, unsigned long long maxBytes) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return nil;
    NSData *tail = nil;
    @try {
        unsigned long long length = [handle seekToEndOfFile];
        unsigned long long start = length > maxBytes ? length - maxBytes : 0;
        [handle seekToFileOffset:start];
        tail = [handle readDataToEndOfFile];
        [handle closeFile];
        if (start > 0 && tail.length) {
            const uint8_t *bytes = tail.bytes;
            for (NSUInteger i = 0; i < tail.length; i++) {
                if (bytes[i] == '\n') {
                    tail = i + 1 < tail.length ? [tail subdataWithRange:NSMakeRange(i + 1, tail.length - i - 1)] : NSData.data;
                    break;
                }
            }
        }
    } @catch (__unused NSException *exception) {
        return nil;
    }
    return [[NSString alloc] initWithData:tail encoding:NSUTF8StringEncoding];
}

// wire 尾部摘要:两种 wire 格式(CLI:顶层 type + time 毫秒;desktop:message.type + timestamp 秒)归一成同一结构。
@implementation CPKimiWireState @end

static CPKimiWireState *CPKimiParseWireTail(NSString *text, BOOL desktopFormat) {
    CPKimiWireState *state = CPKimiWireState.new;
    if (!text.length) return state;
    NSMutableSet<NSString *> *pendingCalls = NSMutableSet.set;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        if (!line.length) continue;
        NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        if (![entry isKindOfClass:NSDictionary.class]) continue; // 坏行跳过,不崩溃
        if (desktopFormat) {
            NSDictionary *message = entry[@"message"];
            if (![message isKindOfClass:NSDictionary.class]) continue;
            NSString *type = message[@"type"];
            if (![type isKindOfClass:NSString.class]) continue;
            NSDate *when = CPDateFromSeconds([entry[@"timestamp"] doubleValue]);
            if (when) state.lastEventAt = when;
            NSDictionary *payload = [message[@"payload"] isKindOfClass:NSDictionary.class] ? message[@"payload"] : nil;
            if ([type isEqualToString:@"TurnBegin"]) {
                state.turnActive = YES;
                state.attentionPending = NO;
                NSString *input = [payload[@"user_input"] isKindOfClass:NSString.class] ? payload[@"user_input"] : nil;
                if (input.length && !state.firstUserInput) state.firstUserInput = input;
            } else if ([type isEqualToString:@"TurnEnd"]) {
                state.turnActive = NO;
                state.attentionPending = NO;
                state.lastEndReason = @"completed";
            } else if ([type isEqualToString:@"StepInterrupted"]) {
                if (state.turnActive) state.attentionPending = YES; // 回合中断,等待用户处理
            }
            continue;
        }
        // CLI 格式:{"type": "...", "time": <毫秒>, ...}
        NSString *type = [entry[@"type"] isKindOfClass:NSString.class] ? entry[@"type"] : nil;
        if (!type) continue;
        NSNumber *timeMs = [entry[@"time"] isKindOfClass:NSNumber.class] ? entry[@"time"] : nil;
        if (timeMs) state.lastEventAt = CPDateFromMillis(timeMs.longLongValue);
        if ([type isEqualToString:@"turn.ended"]) {
            state.turnActive = NO;
            NSString *reason = [entry[@"reason"] isKindOfClass:NSString.class] ? entry[@"reason"] : nil;
            state.lastEndReason = reason.length ? reason : @"completed";
            [pendingCalls removeAllObjects];
            state.attentionPending = NO;
            continue;
        }
        if ([type isEqualToString:@"turn.begin"]) {
            state.turnActive = YES;
            state.attentionPending = NO;
            [pendingCalls removeAllObjects];
            continue;
        }
        if ([type isEqualToString:@"llm.request"]) {
            state.turnActive = YES; // turn.begin 在尾部窗口之外时,请求即活跃 turn 证据
            continue;
        }
        if (![type isEqualToString:@"context.append_loop_event"]) continue;
        NSDictionary *event = [entry[@"event"] isKindOfClass:NSDictionary.class] ? entry[@"event"] : nil;
        NSString *eventType = [event[@"type"] isKindOfClass:NSString.class] ? event[@"type"] : nil;
        if ([eventType isEqualToString:@"step.begin"]) {
            state.turnActive = YES;
        } else if ([eventType isEqualToString:@"tool.call"]) {
            NSString *name = [[event[@"name"] ?: event[@"toolName"] ?: event[@"tool"] description] lowercaseString];
            NSString *uuid = [event[@"uuid"] description];
            if ([name containsString:@"askuserquestion"] && uuid.length) [pendingCalls addObject:uuid];
        } else if ([eventType isEqualToString:@"tool.result"]) {
            NSString *uuid = [event[@"uuid"] description];
            if (uuid.length) [pendingCalls removeObject:uuid];
        }
    }
    if (pendingCalls.count) state.attentionPending = YES;
    return state;
}

// Kimi 状态映射(保守可解释):
// 未解决的用户输入/中断 → waiting;活跃 turn 证据 + 最近 15 分钟内有活动(state updatedAt 或 wire 事件)→ working;
// 活跃 turn 但活动已旧 → idle(旧会话不得仅因最近修改永远 working);
// 明确 completed → completed,error/failed → failed,cancelled/interrupted 与无证据 → idle。
static CPStatus CPKimiStatus(NSString *stateReason, CPKimiWireState *wire, NSDate *activityAt, NSDate *now) {
    if (wire.attentionPending) return CPStatusWaiting;
    BOOL fresh = activityAt && [now timeIntervalSinceDate:activityAt] < 15 * 60;
    if (wire.turnActive) return fresh ? CPStatusWorking : CPStatusIdle;
    NSString *reason = stateReason.length ? stateReason : wire.lastEndReason;
    if ([reason isEqualToString:@"completed"]) return CPStatusCompleted;
    if ([reason isEqualToString:@"error"] || [reason isEqualToString:@"failed"]) return CPStatusFailed;
    return CPStatusIdle; // cancelled / interrupted / 无证据
}

// 会话最近活动时刻:max(state updatedAt, wire 尾部 lastEventAt)。
// turn 进行中 state.json 不刷新,长回合(>15 分钟)靠 wire 尾部事件的 lastEventAt 保活,不会误判 idle;
// 不用 wire 文件 mtime——仅被外部触碰而内容未变的旧会话不得因此显得活跃。
static NSDate *CPKimiActivityAt(NSDate *updatedAt, CPKimiWireState *wire) {
    NSDate *latest = updatedAt;
    if (wire.lastEventAt && (!latest || [wire.lastEventAt compare:latest] == NSOrderedDescending)) latest = wire.lastEventAt;
    return latest;
}

static NSString *CPKimiActivity(NSString *sourceLabel, CPStatus status) {
    NSString *phase = @"会话空闲";
    switch (status) {
        case CPStatusWorking: phase = @"回合进行中"; break;
        case CPStatusWaiting: phase = @"等待用户输入"; break;
        case CPStatusCompleted: phase = @"回合已完成"; break;
        case CPStatusFailed: phase = @"回合出错"; break;
        default: break;
    }
    return [NSString stringWithFormat:@"%@ · %@", sourceLabel, phase];
}

static NSString *CPKimiCleanTitle(NSString *raw) {
    return CPCleanTitle((const unsigned char *)(raw.length ? raw.UTF8String : NULL));
}


@implementation CPKimiSource

- (instancetype)initWithCache:(CPStateCache *)cache {
    self = [super init];
    if (!self) return nil;
    self.cache = cache;
    return self;
}

- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"kimi";
    agent.name = @"Kimi";
    agent.iconName = @"moon";
    agent.color = CPMuted();
    agent.placeholder = NO; // 真实数据源:目录不存在/无会话就是真空态,不再用示例占位
    agent.tasks = NSMutableArray.array;

    // 回归 fixture 保留旧 CLI/desktop 混合路径;真实应用中 Kimi 只读客户端本地索引,
    // 不再把数百个 CLI session 冒充成用户的 Kimi App 对话。
    BOOL legacyFixture = NSProcessInfo.processInfo.environment[@"CP_KIMI_CLIENT_DB"] == nil &&
        (NSProcessInfo.processInfo.environment[@"CP_KIMI_CLI_ROOT"] != nil ||
         NSProcessInfo.processInfo.environment[@"CP_KIMI_DESKTOP_ROOT"] != nil);
    if (legacyFixture) {
        NSMutableSet<NSString *> *cliRawIDs = NSMutableSet.set;
        [agent.tasks addObjectsFromArray:[self readCLITasksIntoRawIDs:cliRawIDs]];
        [agent.tasks addObjectsFromArray:[self readDesktopTasksExcludingRawIDs:cliRawIDs]];
    } else {
        [agent.tasks addObjectsFromArray:[self readClientTasks]];
    }
    [agent.tasks sortUsingComparator:^NSComparisonResult(CPTask *a, CPTask *b) {
        return [b.updatedAt compare:a.updatedAt]; // 非归档会话按 updatedAt 降序
    }];
    while (agent.tasks.count > 50) [agent.tasks removeLastObject]; // 上限 50

    agent.status = CPOverallStatusForTasks(agent.tasks);
    return agent;
}

// Kimi App 3.x 的权威本地索引:
// .../hosted-logical/conversations.sqlite 提供标题、conversation id、workspace、时间与 wire 路径;
// conversation-statuses.json 以 conversation_key 为 key 提供 running/completed。两者都只读。
- (NSArray<CPTask *> *)readClientTasks {
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    self.lastClientCount = 0;
    NSString *dbPath = CPKimiClientDatabasePath();
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(dbPath.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return tasks;
    }
    sqlite3_busy_timeout(db, 150);

    NSDictionary *statusMap = [self.cache objectForPath:CPKimiClientStatusPath() parser:^id(NSString *statusPath) {
        NSData *data = [NSData dataWithContentsOfFile:statusPath];
        id parsed = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
    }] ?: @{};

    const char *sql =
        "SELECT conversation_key, conversation_id, title, COALESCE(workspace_path,''), "
        "created_at_ms, updated_at_ms, COALESCE(kernel_records_path,'') "
        "FROM conversations ORDER BY updated_at_ms DESC LIMIT 50";
    sqlite3_stmt *stmt = NULL;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *(^textAt)(int) = ^NSString *(int column) {
                const unsigned char *value = sqlite3_column_text(stmt, column);
                return value ? [NSString stringWithUTF8String:(const char *)value] : @"";
            };
            NSString *conversationKey = textAt(0);
            NSString *conversationID = textAt(1);
            if (!conversationID.length) continue;
            NSString *wirePath = textAt(6);
            CPKimiWireState *wire = wirePath.length ? [self.cache objectForPath:wirePath parser:^id(NSString *p) {
                return CPKimiParseWireTail(CPReadFileTail(p, 65536), NO);
            }] : nil;
            wire = wire ?: CPKimiWireState.new;

            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithFormat:@"kimi-client-%@", conversationID];
            task.sourceKind = @"kimi-client";
            task.title = CPKimiCleanTitle(textAt(2));
            task.projectPath = textAt(3);
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Kimi";
            task.rolloutPath = wirePath;
            task.createdAt = CPDateFromMillis(sqlite3_column_int64(stmt, 4)) ?: NSDate.date;
            task.updatedAt = CPDateFromMillis(sqlite3_column_int64(stmt, 5)) ?: task.createdAt;
            NSDate *activityAt = CPKimiActivityAt(task.updatedAt, wire);
            if (activityAt) task.updatedAt = activityAt;

            NSString *clientState = [statusMap[conversationKey] isKindOfClass:NSString.class]
                ? [statusMap[conversationKey] lowercaseString] : @"";
            if (wire.attentionPending || [clientState isEqualToString:@"waiting"] || [clientState isEqualToString:@"attention"]) {
                task.status = CPStatusWaiting;
            } else if ([clientState isEqualToString:@"running"]) {
                // 客户端 running 也受 15 分钟新鲜度约束:App 强杀后残留 running 不得永久显示运行中。
                BOOL fresh = activityAt && [NSDate.date timeIntervalSinceDate:activityAt] < 15 * 60;
                if (fresh) {
                    task.status = CPStatusWorking;
                } else {
                    task.status = CPKimiStatus(nil, wire, activityAt, NSDate.date);
                }
            } else if ([clientState isEqualToString:@"failed"] || [clientState isEqualToString:@"error"]) {
                task.status = CPStatusFailed;
            } else if ([clientState isEqualToString:@"completed"]) {
                task.status = CPStatusCompleted;
            } else {
                task.status = CPKimiStatus(nil, wire, activityAt, NSDate.date);
            }
            task.activity = CPKimiActivity(@"Kimi App", task.status);
            [tasks addObject:task];
            self.lastClientCount += 1;
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return tasks;
}

// wire 候选预筛上限:state.json 小文件全部解析(便宜且缓存),wire 尾部只读活跃度最高的前 N 个会话。
// 展示上限 50,留 30 余量;排名靠后的会话即使状态有偏差也会在 cap 50 时被裁掉,不影响 UI。
static const NSInteger CPKimiWireCandidateLimit = 80;

// A) Kimi Code CLI:~/.kimi-code/sessions/<workspace>/<session>/state.json(小文件全量解析,按 mtime+size 缓存)。
// 两遍式:第一遍只解析 state.json(归档过滤/计数/标题/时间);第二遍按 max(updatedAt, wire mtime) 元数据
// 预筛出活跃候选,只有候选才读 wire 尾部做状态映射——避免每轮刷新对几百个会话全量 stat+读 wire。
- (NSArray<CPTask *> *)readCLITasksIntoRawIDs:(NSMutableSet<NSString *> *)rawIDs {
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    NSMutableArray<NSString *> *wirePaths = NSMutableArray.array;   // 与 tasks 平行;无 wire 为 @""
    NSMutableArray<NSDate *> *activityHints = NSMutableArray.array; // max(updatedAt, wire mtime),预筛排序用
    NSMutableArray<NSString *> *reasons = NSMutableArray.array;
    self.lastCLICount = 0;
    NSString *root = CPKimiCLIRoot();
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *workspaceDir in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *workspacePath = [root stringByAppendingPathComponent:workspaceDir];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:workspacePath isDirectory:&isDir] || !isDir) continue;
        for (NSString *sessionDir in [fm contentsOfDirectoryAtPath:workspacePath error:nil]) {
            NSString *sessionPath = [workspacePath stringByAppendingPathComponent:sessionDir];
            NSString *statePath = [sessionPath stringByAppendingPathComponent:@"state.json"];
            if (![fm fileExistsAtPath:statePath]) continue;
            NSDictionary *state = [self.cache objectForPath:statePath parser:^id(NSString *p) {
                NSData *data = [NSData dataWithContentsOfFile:p];
                if (!data.length) return nil;
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                return [parsed isKindOfClass:NSDictionary.class] ? parsed : nil; // 坏 JSON 跳过该会话
            }];
            if (!state) continue;
            if ([state[@"archived"] boolValue]) continue; // 归档默认不展示

            NSString *sessionID = [state[@"id"] isKindOfClass:NSString.class] && [state[@"id"] length]
                                      ? state[@"id"] : sessionDir;
            self.lastCLICount++;
            NSString *rawID = [sessionID hasPrefix:@"session_"] ? [sessionID substringFromIndex:8] : sessionID;
            [rawIDs addObject:rawID];

            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithFormat:@"kimi-cli-%@", sessionID];
            task.sourceKind = @"kimi-cli";
            task.projectPath = [state[@"cwd"] isKindOfClass:NSString.class] && [state[@"cwd"] length]
                                   ? state[@"cwd"]
                                   : ([state[@"workDir"] isKindOfClass:NSString.class] ? state[@"workDir"] : @"");
            task.projectName = task.projectPath.lastPathComponent.length ? task.projectPath.lastPathComponent : @"Kimi";
            task.createdAt = CPKimiDateFromValue(state[@"createdAt"]) ?: NSDate.date;
            task.updatedAt = CPKimiDateFromValue(state[@"updatedAt"]) ?: task.createdAt;

            NSString *title = [state[@"title"] isKindOfClass:NSString.class] ? state[@"title"] : nil;
            NSString *lastPrompt = [state[@"lastPrompt"] isKindOfClass:NSString.class] ? state[@"lastPrompt"] : nil;
            // isCustomTitle 为真才信 title;否则用 lastPrompt(可能超长,CPCleanTitle 清洗+截断,绝不铺进 UI)。
            NSString *seed = ([state[@"isCustomTitle"] boolValue] && title.length) ? title
                                                                                   : (lastPrompt.length ? lastPrompt : title);
            task.title = CPKimiCleanTitle(seed);

            NSString *wirePath = [sessionPath stringByAppendingPathComponent:@"agents/main/wire.jsonl"];
            BOOL hasWire = [fm fileExistsAtPath:wirePath];
            NSDate *hint = task.updatedAt;
            if (hasWire) {
                NSDate *wireMtime = [fm attributesOfItemAtPath:wirePath error:nil][NSFileModificationDate];
                if (wireMtime && [wireMtime compare:hint] == NSOrderedDescending) hint = wireMtime;
            }
            [tasks addObject:task];
            [wirePaths addObject:hasWire ? wirePath : @""];
            [activityHints addObject:hint];
            NSString *reason = [state[@"lastTurnReason"] isKindOfClass:NSString.class] ? state[@"lastTurnReason"] : @"";
            [reasons addObject:reason];
        }
    }

    // 第二遍:按活跃度 hint 降序,前 CPKimiWireCandidateLimit 个候选才读 wire 有界尾部(64KB,缓存)。
    NSMutableArray<NSNumber *> *order = NSMutableArray.array;
    for (NSInteger i = 0; i < (NSInteger)tasks.count; i++) [order addObject:@(i)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [activityHints[b.unsignedIntegerValue] compare:activityHints[a.unsignedIntegerValue]];
    }];
    NSMutableIndexSet *candidates = NSMutableIndexSet.indexSet;
    for (NSInteger i = 0; i < (NSInteger)order.count && i < CPKimiWireCandidateLimit; i++) {
        [candidates addIndex:order[i].unsignedIntegerValue];
    }
    NSDate *now = NSDate.date;
    for (NSUInteger i = 0; i < tasks.count; i++) {
        CPTask *task = tasks[i];
        CPKimiWireState *wire = CPKimiWireState.new;
        if ([candidates containsIndex:i] && [wirePaths[i] length]) {
            wire = [self.cache objectForPath:wirePaths[i] parser:^id(NSString *p) {
                return CPKimiParseWireTail(CPReadFileTail(p, 65536), NO);
            }] ?: CPKimiWireState.new;
            // 活跃会话的展示时间用真实活动时刻:长回合 state.updatedAt 不刷新,按它排序会被埋到列表底部。
            NSDate *activityAt = CPKimiActivityAt(task.updatedAt, wire);
            if (activityAt) task.updatedAt = activityAt;
        }
        task.status = CPKimiStatus(reasons[i], wire, CPKimiActivityAt(task.updatedAt, wire), now);
        task.activity = CPKimiActivity(@"Kimi Code CLI", task.status);
    }
    return tasks;
}

// B) Kimi 桌面 daimon:…/daimon-share/sessions/<hash>/<uuid>/{context.jsonl,wire.jsonl}。
// 格式不完整/字段缺失直接跳过该会话;context 只读前 256KB,wire 只读尾部 64KB。
- (NSArray<CPTask *> *)readDesktopTasksExcludingRawIDs:(NSSet<NSString *> *)cliRawIDs {
    NSMutableArray<CPTask *> *tasks = NSMutableArray.array;
    self.lastDesktopCount = 0;
    NSString *root = CPKimiDesktopRoot();
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *hashDir in [fm contentsOfDirectoryAtPath:root error:nil]) {
        NSString *hashPath = [root stringByAppendingPathComponent:hashDir];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:hashPath isDirectory:&isDir] || !isDir) continue;
        for (NSString *uuidDir in [fm contentsOfDirectoryAtPath:hashPath error:nil]) {
            NSString *sessionPath = [hashPath stringByAppendingPathComponent:uuidDir];
            NSString *wirePath = [sessionPath stringByAppendingPathComponent:@"wire.jsonl"];
            NSString *contextPath = [sessionPath stringByAppendingPathComponent:@"context.jsonl"];
            if (![fm fileExistsAtPath:wirePath] || ![fm fileExistsAtPath:contextPath]) continue;
            if ([cliRawIDs containsObject:uuidDir]) continue; // 跨源去重:CLI 已收录同一 session
            self.lastDesktopCount++;

            CPKimiWireState *wire = [self.cache objectForPath:wirePath parser:^id(NSString *p) {
                return CPKimiParseWireTail(CPReadFileTail(p, 65536), YES);
            }] ?: CPKimiWireState.new;

            // context.jsonl 头部:取第一条 role=="user" 的消息做标题种子;坏行/缺字段跳过。
            // 与 state/wire 一样纳入 path+mtime+size 缓存,文件未变不重复读 256KB/逐行解析。
            NSString *firstUser = [self.cache objectForPath:contextPath parser:^id(NSString *p) {
                NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:p];
                NSData *headData = nil;
                @try {
                    headData = [handle readDataOfLength:262144];
                    [handle closeFile];
                } @catch (__unused NSException *exception) {}
                NSString *head = headData ? [[NSString alloc] initWithData:headData encoding:NSUTF8StringEncoding] : nil;
                for (NSString *line in [head componentsSeparatedByString:@"\n"]) {
                    if (!line.length) continue;
                    NSDictionary *entry = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                    if (![entry isKindOfClass:NSDictionary.class]) continue;
                    if (![entry[@"role"] isEqualToString:@"user"]) continue;
                    if ([entry[@"content"] isKindOfClass:NSString.class] && [entry[@"content"] length]) {
                        return entry[@"content"];
                    }
                }
                return nil;
            }];

            CPTask *task = CPTask.new;
            task.taskID = [NSString stringWithFormat:@"kimi-desktop-%@", uuidDir];
            task.sourceKind = @"kimi-desktop";
            // 桌面源无可验证 cwd 元数据:按 session 目录名降级。
            task.projectPath = uuidDir;
            task.projectName = uuidDir;
            NSDictionary *attrs = [fm attributesOfItemAtPath:contextPath error:nil];
            task.createdAt = attrs[NSFileCreationDate] ?: NSDate.date;
            task.updatedAt = wire.lastEventAt ?: (attrs[NSFileModificationDate] ?: task.createdAt);
            task.title = CPKimiCleanTitle(firstUser.length ? firstUser : wire.firstUserInput);
            task.status = CPKimiStatus(nil, wire, CPKimiActivityAt(task.updatedAt, wire), NSDate.date);
            task.activity = CPKimiActivity(@"Kimi 桌面", task.status);
            [tasks addObject:task];
        }
    }
    return tasks;
}

@end

#pragma mark - Optional Kimi CLI Source

// CLI 与 Kimi App 是两个产品面:只有用户在“添加 Agent”中显式启用时才展示。

@implementation CPKimiCLISource
- (instancetype)initWithCache:(CPStateCache *)cache {
    self = [super init];
    if (!self) return nil;
    self.parser = [[CPKimiSource alloc] initWithCache:cache];
    return self;
}
- (CPAgent *)readAgent {
    CPAgent *agent = CPAgent.new;
    agent.agentID = @"kimi-cli";
    agent.name = @"Kimi CLI";
    agent.iconName = @"terminal";
    agent.color = CPMuted();
    agent.placeholder = NO;
    NSMutableSet<NSString *> *rawIDs = NSMutableSet.set;
    agent.tasks = [[self.parser readCLITasksIntoRawIDs:rawIDs] mutableCopy];
    [agent.tasks sortUsingComparator:^NSComparisonResult(CPTask *a, CPTask *b) { return [b.updatedAt compare:a.updatedAt]; }];
    while (agent.tasks.count > 50) [agent.tasks removeLastObject];
    agent.status = CPOverallStatusForTasks(agent.tasks);
    return agent;
}
@end

#pragma mark - State Reader 聚合

@implementation CPStateReader

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.cache = CPStateCache.new;
    // 注册表即扩展点:适配器内置,用户的启用选择由“添加 Agent”持久化。
    NSMutableArray<id<CPAgentSource>> *configured = NSMutableArray.array;
    for (NSString *providerID in CPEnabledAgentProviderIDs()) {
        if ([providerID isEqualToString:@"codex"]) {
            [configured addObject:[[CPCodexSource alloc] initWithCache:self.cache]];
        } else if ([providerID isEqualToString:@"kimi"]) {
            [configured addObject:[[CPKimiSource alloc] initWithCache:self.cache]];
        } else if ([providerID isEqualToString:@"kimi-cli"]) {
            [configured addObject:[[CPKimiCLISource alloc] initWithCache:self.cache]];
        }
    }
    self.sources = configured;
    return self;
}

- (NSArray<CPAgent *> *)readAgents {
    NSMutableArray<CPAgent *> *agents = [NSMutableArray arrayWithCapacity:self.sources.count];
    for (id<CPAgentSource> source in self.sources) {
        CPAgent *agent = [source readAgent];
        if (agent) [agents addObject:agent];
    }
    return agents;
}

- (CPRolloutState *)rolloutStateForPath:(NSString *)path {
    if (!path.length) return CPRolloutState.new;
    CPRolloutState *state = [self.cache objectForPath:path parser:^id(NSString *p) { return CPReadRolloutState(p); }];
    return state ?: CPRolloutState.new;
}

@end

