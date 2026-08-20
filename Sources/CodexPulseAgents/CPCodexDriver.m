#import "CPCodexDriver.h"
#import <errno.h>
#import <math.h>
#import <signal.h>
#import <unistd.h>

static const NSTimeInterval kCPCodexDefaultTimeout = 30.0;
static const NSInteger kCPCodexMaxRestarts = 3;
static const NSInteger kCPCodexMethodNotFound = -32601;
static NSString * const kCPCodexDenyReason = @"澜台暂不支持远程审批";

NSString *CPCodexFindBinary(void) {
    NSString *bundled = @"/Applications/ChatGPT.app/Contents/Resources/codex";
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm isExecutableFileAtPath:bundled]) return bundled;
    NSString *pathEnv = NSProcessInfo.processInfo.environment[@"PATH"] ?: @"";
    for (NSString *dir in [pathEnv componentsSeparatedByString:@":"]) {
        if (!dir.length) continue;
        NSString *candidate = [dir stringByAppendingPathComponent:@"codex"];
        if ([fm isExecutableFileAtPath:candidate]) return candidate;
    }
    return nil;
}

static NSString *CPCodexClientVersion(void) {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version.length ? version : @"0.0";
}

static NSString *CPCodexIDKey(id reqID) {
    return reqID ? [NSString stringWithFormat:@"%@", reqID] : @"";
}

static BOOL CPCodexMethodMatches(NSString *method, NSString *slashName, NSString *camelTail) {
    if (!method.length) return NO;
    if ([method isEqualToString:slashName]) return YES;
    if ([method.lowercaseString isEqualToString:slashName]) return YES;
    return camelTail.length && [method hasSuffix:camelTail];
}

static NSString *CPCodexStringAt(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary *CPCodexDictAt(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static NSArray *CPCodexArrayAt(NSDictionary *dict, NSString *key) {
    id value = dict[key];
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

static BOOL CPCodexIsHiddenModel(NSDictionary *row) {
    id hidden = row[@"hidden"];
    return [hidden respondsToSelector:@selector(boolValue)] && [hidden boolValue];
}

static BOOL CPCodexIsDefaultModel(NSDictionary *row) {
    id flag = row[@"isDefault"];
    return [flag respondsToSelector:@selector(boolValue)] && [flag boolValue];
}

// 只取手机需要的字段。id / model / displayName / description / hidden / isDefault
// 缺了也不崩：没有标识就跳过，hidden==true 丢掉，其余给空串或 NO。
static NSArray<CPAgentModel *> *CPCodexParseModels(id result) {
    NSArray *rows = nil;
    if ([result isKindOfClass:NSArray.class]) {
        rows = result;
    } else if ([result isKindOfClass:NSDictionary.class]) {
        rows = CPCodexArrayAt(result, @"data");
    }
    if (!rows.count) return @[];
    NSMutableArray<CPAgentModel *> *out = NSMutableArray.array;
    NSMutableSet<NSString *> *seen = NSMutableSet.set;
    for (id item in rows) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        if (CPCodexIsHiddenModel(row)) continue;
        NSString *modelID = CPCodexStringAt(row, @"id");
        if (!modelID.length) modelID = CPCodexStringAt(row, @"model");
        if (!modelID.length) continue;
        if ([seen containsObject:modelID]) continue;
        [seen addObject:modelID];
        CPAgentModel *model = CPAgentModel.new;
        model.modelID = modelID;
        NSString *name = CPCodexStringAt(row, @"displayName");
        if (!name.length) name = CPCodexStringAt(row, @"model");
        if (!name.length) name = modelID;
        model.name = name;
        model.descriptionText = CPCodexStringAt(row, @"description") ?: @"";
        model.isDefault = CPCodexIsDefaultModel(row);
        [out addObject:model];
    }
    return out;
}

#pragma mark - 路径脱敏（第一层，折叠时做；Bridge 推送前还会再兜一遍）

static NSString *CPCodexRedactActivity(NSString *text, NSString *workdir, NSString *projectName) {
    if (!text.length) return @"";
    NSMutableString *out = [text mutableCopy];
    if (workdir.length) {
        NSString *name = projectName.length ? projectName : workdir.lastPathComponent;
        NSString *prefix = [workdir hasSuffix:@"/"] ? workdir : [workdir stringByAppendingString:@"/"];
        [out replaceOccurrencesOfString:prefix
                             withString:[name stringByAppendingString:@"/"]
                                options:0 range:NSMakeRange(0, out.length)];
        [out replaceOccurrencesOfString:workdir withString:name options:0 range:NSMakeRange(0, out.length)];
    }
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [out replaceOccurrencesOfString:home withString:@"~" options:0 range:NSMakeRange(0, out.length)];
    }
    static NSRegularExpression *userRE;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        userRE = [NSRegularExpression regularExpressionWithPattern:@"/Users/[^/\\s]+" options:0 error:nil];
    });
    return [userRE stringByReplacingMatchesInString:out options:0
                                              range:NSMakeRange(0, out.length) withTemplate:@"~"];
}

#pragma mark - 折叠时的文案

static NSString *CPCodexPatchMark(NSDictionary *change) {
    NSString *type = CPCodexStringAt(CPCodexDictAt(change, @"kind"), @"type");
    if ([type isEqualToString:@"add"]) return @"+";
    if ([type isEqualToString:@"delete"]) return @"-";
    return @"~";
}

static NSString *CPCodexDiffCounts(NSString *diff) {
    if (!diff.length) return @"";
    NSInteger added = 0, removed = 0;
    for (NSString *line in [diff componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:@"+++"] || [line hasPrefix:@"---"]) continue;
        if ([line hasPrefix:@"+"]) added += 1;
        else if ([line hasPrefix:@"-"]) removed += 1;
    }
    if (!added && !removed) return @"";
    return [NSString stringWithFormat:@" (+%ld -%ld)", (long)added, (long)removed];
}

// 统一 diff 里出现过的文件名。手机上要的是「动了哪些文件」，不是几千行补丁正文。
static NSArray<NSString *> *CPCodexDiffFiles(NSString *diff) {
    NSMutableArray<NSString *> *files = NSMutableArray.array;
    for (NSString *line in [diff componentsSeparatedByString:@"\n"]) {
        if (![line hasPrefix:@"+++ "]) continue;
        NSString *path = [line substringFromIndex:4];
        if ([path hasPrefix:@"b/"]) path = [path substringFromIndex:2];
        path = [path stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!path.length || [path isEqualToString:@"/dev/null"]) continue;
        if (![files containsObject:path]) [files addObject:path];
    }
    return files;
}

#pragma mark - JSONL buffer

@implementation CPCodexJSONLBuffer {
    NSMutableData *_buf;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _buf = NSMutableData.data;
    return self;
}

- (NSArray<NSString *> *)appendBytes:(const void *)bytes length:(NSUInteger)length {
    if (bytes && length) [_buf appendBytes:bytes length:length];
    NSMutableArray<NSString *> *lines = NSMutableArray.array;
    const uint8_t *p = _buf.bytes;
    NSUInteger n = _buf.length;
    NSUInteger start = 0;
    for (NSUInteger i = 0; i < n; i++) {
        if (p[i] != '\n') continue;
        NSUInteger len = i - start;
        if (len > 0 && p[i - 1] == '\r') len -= 1;
        if (len > 0) {
            NSString *line = [[NSString alloc] initWithBytes:p + start length:len encoding:NSUTF8StringEncoding];
            if (line) [lines addObject:line];
        }
        start = i + 1;
    }
    if (start == 0) return lines;
    if (start >= n) {
        _buf.length = 0;
    } else {
        [_buf replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
    }
    return lines;
}

@end

#pragma mark - stdio transport

@interface CPCodexStdioTransport : NSObject <CPCodexTransport>
- (instancetype)initWithLaunchPath:(NSString *)launchPath;
@end

@implementation CPCodexStdioTransport {
    NSString *_launchPath;
    NSTask *_task;
    NSFileHandle *_stdinHandle;
    NSFileHandle *_stdoutHandle;
    NSFileHandle *_stderrHandle;
    CPCodexJSONLBuffer *_buffer;
    BOOL _closedEmitted;
    BOOL _alive;
}
@synthesize onLine = _onLine;
@synthesize onClosed = _onClosed;

- (instancetype)initWithLaunchPath:(NSString *)launchPath {
    self = [super init];
    if (!self) return nil;
    _launchPath = [launchPath copy];
    _buffer = CPCodexJSONLBuffer.new;
    return self;
}

- (BOOL)isAlive {
    return _alive;
}

- (void)emitClosed {
    if (_closedEmitted) return;
    _closedEmitted = YES;
    _alive = NO;
    void (^cb)(void) = self.onClosed;
    if (cb) cb();
}

- (BOOL)start {
    [self stop];
    _closedEmitted = NO;
    _buffer = CPCodexJSONLBuffer.new;
    if (!_launchPath.length) return NO;

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = _launchPath;
    task.arguments = @[@"app-server", @"--listen", @"stdio://"];
    NSPipe *inPipe = [NSPipe pipe];
    NSPipe *outPipe = [NSPipe pipe];
    NSPipe *errPipe = [NSPipe pipe];
    task.standardInput = inPipe;
    task.standardOutput = outPipe;
    task.standardError = errPipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSLog(@"[CPCodexDriver] stdio 子进程启动失败");
        return NO;
    }

    _task = task;
    _stdinHandle = inPipe.fileHandleForWriting;
    _stdoutHandle = outPipe.fileHandleForReading;
    _stderrHandle = errPipe.fileHandleForReading;
    _alive = YES;

    __weak typeof(self) weakSelf = self;
    // 自测进程没有常驻 runloop，readabilityHandler 可能根本不触发；阻塞 read 更稳。
    int stdoutFD = _stdoutHandle.fileDescriptor;
    int stderrFD = _stderrHandle.fileDescriptor;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint8_t buf[4096];
        while (YES) {
            ssize_t n = read(stdoutFD, buf, sizeof(buf));
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (n == 0) break;
            CPCodexStdioTransport *strongSelf = weakSelf;
            if (!strongSelf) break;
            NSArray<NSString *> *lines = [strongSelf->_buffer appendBytes:buf length:(NSUInteger)n];
            void (^onLine)(NSString *) = strongSelf.onLine;
            for (NSString *line in lines) {
                if (onLine) onLine(line);
            }
        }
        [weakSelf emitClosed];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        uint8_t buf[4096];
        while (YES) {
            ssize_t n = read(stderrFD, buf, sizeof(buf));
            if (n < 0) {
                if (errno == EINTR) continue;
                break;
            }
            if (n == 0) break;
        }
    });
    task.terminationHandler = ^(NSTask *finished) {
        (void)finished;
        [weakSelf emitClosed];
    };
    return YES;
}

- (void)sendLine:(NSString *)line {
    if (!_alive || !_stdinHandle || !line.length) return;
    NSString *payload = [line hasSuffix:@"\n"] ? line : [line stringByAppendingString:@"\n"];
    NSData *data = [payload dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    if (![_stdinHandle writeData:data error:&error]) {
        [self emitClosed];
    }
}

- (void)stop {
    _stdoutHandle.readabilityHandler = nil;
    _stderrHandle.readabilityHandler = nil;
    if (_task.running) {
        pid_t pid = _task.processIdentifier;
        [_task terminate];
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
        while (_task.running && [deadline timeIntervalSinceNow] > 0) {
            usleep(20000);
        }
        if (_task.running && pid > 1) kill(pid, SIGKILL);
    }
    _stdinHandle = nil;
    _stdoutHandle = nil;
    _stderrHandle = nil;
    _task = nil;
    _alive = NO;
    _closedEmitted = YES;
}

- (void)dealloc {
    [self stop];
}

@end

#pragma mark - pending RPC

@interface CPCodexPending : NSObject
@property (copy) NSString *method;
@property (copy) void (^completion)(id result, NSInteger errorCode);
@end
@implementation CPCodexPending
@end

#pragma mark - driver

@interface CPCodexDriver ()
- (instancetype)initWithTransport:(id<CPCodexTransport>)transport
                       binaryPath:(NSString *)binaryPath
                        autoStart:(BOOL)autoStart;
- (void)refreshModelsLocked;
@end

@implementation CPCodexDriver {
    id<CPCodexTransport> _injected;
    id<CPCodexTransport> _active;
    NSString *_binaryPath;
    dispatch_queue_t _queue;
    void *_queueKey;
    BOOL _healthy;
    BOOL _stopping;
    BOOL _incompatible;
    BOOL _handshakeInFlight;
    NSUInteger _epoch;
    NSInteger _restartAttempts;
    NSInteger _nextID;
    NSMutableDictionary<NSString *, CPCodexPending *> *_pending;
    NSMutableSet<NSString *> *_managed;
    NSMutableDictionary<NSString *, NSString *> *_activeTurn;
    NSMutableDictionary<NSString *, NSString *> *_workdirByThread;   // 脱敏用，绝不外发
    NSMutableDictionary<NSString *, NSString *> *_projectByThread;
    NSMutableDictionary<NSString *, NSString *> *_commandByItem;     // item/started 记下命令行，供 run 条目做标题
    NSArray<CPAgentModel *> *_models;                                // model/list 缓存；失败则为空
}

- (instancetype)init {
    return [self initWithTransport:nil binaryPath:CPCodexFindBinary() autoStart:YES];
}

- (instancetype)initWithTransport:(id<CPCodexTransport>)transport
                       binaryPath:(NSString *)binaryPath {
    return [self initWithTransport:transport binaryPath:binaryPath autoStart:NO];
}

- (instancetype)initWithTransport:(id<CPCodexTransport>)transport
                       binaryPath:(NSString *)binaryPath
                        autoStart:(BOOL)autoStart {
    self = [super init];
    if (!self) return nil;
    _injected = transport;
    _binaryPath = [binaryPath copy];
    _requestTimeout = kCPCodexDefaultTimeout;
    _pending = NSMutableDictionary.dictionary;
    _managed = NSMutableSet.set;
    _activeTurn = NSMutableDictionary.dictionary;
    _workdirByThread = NSMutableDictionary.dictionary;
    _projectByThread = NSMutableDictionary.dictionary;
    _commandByItem = NSMutableDictionary.dictionary;
    _models = @[];
    _queue = dispatch_queue_create("com.lantai.codex-driver", DISPATCH_QUEUE_SERIAL);
    _queueKey = &_queueKey;
    dispatch_queue_set_specific(_queue, _queueKey, (void *)1, NULL);
    if (autoStart && _binaryPath.length) {
        __weak typeof(self) weakSelf = self;
        dispatch_async(_queue, ^{ [weakSelf startNowLocked]; });
    }
    return self;
}

- (NSString *)agentID {
    return @"codex";
}

- (BOOL)isHealthy {
    @synchronized (self) { return _healthy; }
}

- (void)setHealthyLocked:(BOOL)healthy {
    BOOL changed = NO;
    @synchronized (self) {
        changed = (_healthy != healthy);
        _healthy = healthy;
    }
    // 回调在锁外发，否则一个慢消费者会把整个 driver 卡住。
    if (!changed) return;
    void (^live)(NSString *, BOOL) = self.onActivityLive;
    if (live) live(self.agentID, healthy);
}

- (NSArray<NSString *> *)controlCapabilities {
    return @[@"control", @"interrupt"];
}

- (BOOL)isManagedTaskID:(NSString *)taskID {
    if (!taskID.length) return NO;
    __block BOOL managed = NO;
    [self onQueue:^{
        managed = [self->_managed containsObject:taskID];
    } wait:YES];
    return managed;
}

- (NSArray<CPAgentModel *> *)availableModels {
    __block NSArray<CPAgentModel *> *models = @[];
    [self onQueue:^{
        models = self->_models ?: @[];
    } wait:YES];
    return models;
}

- (void)onQueue:(void (^)(void))block wait:(BOOL)wait {
    if (dispatch_get_specific(_queueKey)) {
        block();
        return;
    }
    if (wait) dispatch_sync(_queue, block);
    else dispatch_async(_queue, block);
}

- (void)startNow {
    [self onQueue:^{ [self startNowLocked]; } wait:YES];
}

- (void)startNowLocked {
    if (_stopping || _incompatible) return;
    if (!_injected && !_binaryPath.length) return;
    if (_active.isAlive) {
        if (!_healthy && !_handshakeInFlight) [self sendHandshakeLocked];
        return;
    }
    if (!_active) {
        _active = _injected ?: [[CPCodexStdioTransport alloc] initWithLaunchPath:_binaryPath];
        [self wireTransportLocked];
    }
    if (![_active start]) {
        [self setHealthyLocked:NO];
        [self scheduleRestartLocked];
        return;
    }
    [self sendHandshakeLocked];
}

- (void)wireTransportLocked {
    __weak typeof(self) weakSelf = self;
    _active.onLine = ^(NSString *line) {
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf onQueue:^{ [strongSelf handleLineLocked:line]; } wait:NO];
    };
    _active.onClosed = ^{
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        // 快照里的 capabilities 直接读 isHealthy，必须先于队列排空翻掉。
        [strongSelf setHealthyLocked:NO];
        [strongSelf onQueue:^{ [strongSelf noteClosedLocked]; } wait:NO];
    };
}

- (void)sendHandshakeLocked {
    if (_handshakeInFlight) return;
    _handshakeInFlight = YES;
    NSDictionary *params = @{
        @"clientInfo": @{
            @"name": @"lantai",
            @"title": @"澜台",
            @"version": CPCodexClientVersion()
        }
    };
    __weak typeof(self) weakSelf = self;
    [self rpcLocked:@"initialize" params:params completion:^(id result, NSInteger errorCode) {
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_handshakeInFlight = NO;
        if (errorCode == 0 && [result isKindOfClass:NSDictionary.class]) {
            strongSelf->_restartAttempts = 0;
            [strongSelf setHealthyLocked:YES];
            [strongSelf refreshModelsLocked];
            return;
        }
        [strongSelf setHealthyLocked:NO];
        if (errorCode == kCPCodexMethodNotFound) {
            strongSelf->_incompatible = YES;
            return;
        }
        [strongSelf->_active stop];
        strongSelf->_active = nil;
        [strongSelf scheduleRestartLocked];
    }];
}

- (void)refreshModelsLocked {
    // 只取第一页。model/list 有 nextCursor，官方可见模型目前一页就够（2026-08-17 实测 6 个、
    // nextCursor 为空）；翻页留给目录真的超过 limit 再说。不传 includeHidden，只要默认选择器里那批。
    __weak typeof(self) weakSelf = self;
    [self rpcLocked:@"model/list" params:@{ @"limit": @50 } completion:^(id result, NSInteger errorCode) {
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorCode != 0) {
            strongSelf->_models = @[];
            return;
        }
        strongSelf->_models = CPCodexParseModels(result);
    }];
}

- (void)noteClosedLocked {
    BOOL wasStopping = _stopping;
    [self setHealthyLocked:NO];
    _handshakeInFlight = NO;
    _active = nil;
    [_managed removeAllObjects];
    [_activeTurn removeAllObjects];
    _models = @[];
    [self forgetActivityStateLocked];
    [self failAllPendingLocked:-1];
    if (!wasStopping && !_incompatible) [self scheduleRestartLocked];
}

- (void)scheduleRestartLocked {
    if (_stopping || _incompatible) return;
    if (!_injected && !_binaryPath.length) return;
    if (_restartAttempts >= kCPCodexMaxRestarts) return;
    NSTimeInterval delay = pow(2.0, (double)_restartAttempts); // 1 / 2 / 4
    _restartAttempts += 1;
    NSUInteger epoch = _epoch;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_stopping || strongSelf->_epoch != epoch) return;
        if (strongSelf.isHealthy) return;
        [strongSelf startNowLocked];
    });
}

- (void)shutdown {
    [self onQueue:^{
        self->_stopping = YES;
        self->_epoch += 1;
        [self setHealthyLocked:NO];
        [self failAllPendingLocked:-1];
        [self->_active stop];
        self->_active = nil;
        [self->_managed removeAllObjects];
        [self->_activeTurn removeAllObjects];
        self->_models = @[];
        [self forgetActivityStateLocked];
    } wait:YES];
}

- (void)executeCommand:(CPAgentCommand *)command
            completion:(void (^)(BOOL ok, NSString *errorMessage, NSString *resultTaskID))completion {
    [self onQueue:^{
        [self executeLocked:command completion:completion];
    } wait:NO];
}

- (void)finish:(void (^)(BOOL, NSString *, NSString *))completion
            ok:(BOOL)ok
         error:(NSString *)error
        taskID:(NSString *)taskID {
    if (completion) completion(ok, error, taskID);
}

- (void)executeLocked:(CPAgentCommand *)command
           completion:(void (^)(BOOL ok, NSString *errorMessage, NSString *resultTaskID))completion {
    if (!self.isHealthy || !_active.isAlive) {
        [self finish:completion ok:NO error:@"Codex 控制通道不可用" taskID:nil];
        return;
    }
    switch (command.action) {
        case CPCommandActionStart:
            [self runStartLocked:command completion:completion];
            break;
        case CPCommandActionSteer:
            [self runSteerLocked:command completion:completion];
            break;
        case CPCommandActionInterrupt:
            [self runInterruptLocked:command completion:completion];
            break;
    }
}

- (void)runStartLocked:(CPAgentCommand *)command
            completion:(void (^)(BOOL, NSString *, NSString *))completion {
    NSString *cwd = command.workdir;
    BOOL isDir = NO;
    if (!cwd.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:cwd isDirectory:&isDir] ||
        !isDir) {
        [self finish:completion ok:NO error:@"工作目录无效" taskID:nil];
        return;
    }
    // 不传 approvalPolicy / sandbox:让 app-server 沿用用户自己的 ~/.codex 配置(含各项目的
    // trust_level)。写死策略会盖掉用户设置,同一个项目在手机上反而比桌面端更束手束脚。
    // 需要人点头的审批目前一律自动拒绝(见 handleServerRequestLocked),把审批推到手机是最后一步的事。
    // model 也一样:空就不带这个键,继承 config.toml;有值才写入。2026-08-17 探针确认
    // thread/start.model 会回显到 ThreadStartResponse.model,所以加在这里,不碰 turn/start。
    NSMutableDictionary *threadParams = [@{ @"cwd": cwd } mutableCopy];
    NSString *modelID = [command.modelID stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (modelID.length) threadParams[@"model"] = modelID;
    NSString *projectName = command.workdirName.length ? command.workdirName : cwd.lastPathComponent;
    __weak typeof(self) weakSelf = self;
    [self rpcLocked:@"thread/start" params:threadParams completion:^(id result, NSInteger errorCode) {
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorCode != 0 || ![result isKindOfClass:NSDictionary.class]) {
            [strongSelf finish:completion ok:NO error:@"thread/start 失败" taskID:nil];
            return;
        }
        NSString *threadID = CPCodexStringAt(CPCodexDictAt(result, @"thread"), @"id");
        if (!threadID.length) {
            [strongSelf finish:completion ok:NO error:@"thread/start 失败" taskID:nil];
            return;
        }
        [strongSelf->_managed addObject:threadID];
        strongSelf->_workdirByThread[threadID] = cwd;
        strongSelf->_projectByThread[threadID] = projectName;
        NSDictionary *turnParams = @{
            @"threadId": threadID,
            @"input": @[ @{ @"type": @"text", @"text": command.text ?: @"" } ]
        };
        [strongSelf rpcLocked:@"turn/start" params:turnParams completion:^(id turnResult, NSInteger turnCode) {
            if (turnCode != 0 || ![turnResult isKindOfClass:NSDictionary.class]) {
                [strongSelf finish:completion ok:NO error:@"turn/start 失败" taskID:nil];
                return;
            }
            NSString *turnID = CPCodexStringAt(CPCodexDictAt(turnResult, @"turn"), @"id");
            if (turnID.length) strongSelf->_activeTurn[threadID] = turnID;
            // 受理即成功，不等 turn/completed，否则 busy 闸门会锁住整段工作时间。
            [strongSelf finish:completion ok:YES error:nil taskID:threadID];
        }];
    }];
}

- (void)runSteerLocked:(CPAgentCommand *)command
            completion:(void (^)(BOOL, NSString *, NSString *))completion {
    NSString *threadID = command.taskID;
    NSString *turnID = threadID.length ? _activeTurn[threadID] : nil;
    if (!turnID.length) {
        [self finish:completion ok:NO error:@"当前没有进行中的回合，无法补充指令" taskID:nil];
        return;
    }
    NSDictionary *params = @{
        @"threadId": threadID,
        @"expectedTurnId": turnID,
        @"input": @[ @{ @"type": @"text", @"text": command.text ?: @"" } ]
    };
    __weak typeof(self) weakSelf = self;
    [self rpcLocked:@"turn/steer" params:params completion:^(id result, NSInteger errorCode) {
        (void)result;
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorCode != 0) {
            [strongSelf finish:completion ok:NO error:@"turn/steer 失败" taskID:nil];
            return;
        }
        [strongSelf finish:completion ok:YES error:nil taskID:threadID];
    }];
}

- (void)runInterruptLocked:(CPAgentCommand *)command
                completion:(void (^)(BOOL, NSString *, NSString *))completion {
    NSString *threadID = command.taskID;
    NSString *turnID = threadID.length ? _activeTurn[threadID] : nil;
    if (!turnID.length) {
        [self finish:completion ok:NO error:@"当前没有进行中的回合，无法打断" taskID:nil];
        return;
    }
    NSDictionary *params = @{
        @"threadId": threadID,
        @"turnId": turnID
    };
    __weak typeof(self) weakSelf = self;
    [self rpcLocked:@"turn/interrupt" params:params completion:^(id result, NSInteger errorCode) {
        (void)result;
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (errorCode != 0) {
            [strongSelf finish:completion ok:NO error:@"turn/interrupt 失败" taskID:nil];
            return;
        }
        [strongSelf finish:completion ok:YES error:nil taskID:threadID];
    }];
}

- (void)readRateLimitsWithCompletion:(void (^)(NSDictionary *result, NSString *errorMessage))completion {
    [self onQueue:^{
        if (!self->_healthy || !self->_active.isAlive) {
            if (completion) completion(nil, @"Codex 控制通道未就绪");
            return;
        }
        [self rpcLocked:@"account/rateLimits/read" params:[NSNull null] completion:^(id result, NSInteger errorCode) {
            if (errorCode == 0 && [result isKindOfClass:NSDictionary.class]) {
                if (completion) completion(result, nil);
                return;
            }
            if (errorCode == kCPCodexMethodNotFound) {
                if (completion) completion(nil, @"当前 Codex 版本没有额度接口");
                return;
            }
            if (completion) completion(nil, @"读取额度失败");
        }];
    } wait:NO];
}

- (void)rpcLocked:(NSString *)method
           params:(id)params
       completion:(void (^)(id result, NSInteger errorCode))completion {
    if (!_active.isAlive) {
        if (completion) completion(nil, -1);
        return;
    }
    NSInteger rid = ++_nextID;
    NSNumber *reqID = @(rid);
    NSMutableDictionary *msg = [@{
        @"jsonrpc": @"2.0",
        @"id": reqID,
        @"method": method
    } mutableCopy];
    msg[@"params"] = params ?: @{};
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:msg options:0 error:&error];
    if (!data) {
        if (completion) completion(nil, -1);
        return;
    }
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    CPCodexPending *pending = CPCodexPending.new;
    pending.method = method;
    pending.completion = completion;
    _pending[CPCodexIDKey(reqID)] = pending;
    [_active sendLine:line];

    NSTimeInterval timeout = self.requestTimeout > 0 ? self.requestTimeout : kCPCodexDefaultTimeout;
    NSUInteger epoch = _epoch;
    NSString *key = CPCodexIDKey(reqID);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), _queue, ^{
        CPCodexDriver *strongSelf = weakSelf;
        if (!strongSelf || strongSelf->_epoch != epoch) return;
        CPCodexPending *expired = strongSelf->_pending[key];
        if (!expired) return;
        [strongSelf->_pending removeObjectForKey:key];
        NSLog(@"[CPCodexDriver] 请求超时 method=%@", expired.method);
        if (expired.completion) expired.completion(nil, -2);
    });
}

- (void)failAllPendingLocked:(NSInteger)code {
    NSArray<CPCodexPending *> *items = _pending.allValues;
    [_pending removeAllObjects];
    for (CPCodexPending *item in items) {
        if (item.completion) item.completion(nil, code);
    }
}

- (void)handleLineLocked:(NSString *)line {
    if (!line.length) return;
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![obj isKindOfClass:NSDictionary.class]) return;
    NSDictionary *msg = obj;
    id reqID = msg[@"id"];
    NSString *method = CPCodexStringAt(msg, @"method");
    BOOL hasResult = msg[@"result"] != nil;
    BOOL hasError = msg[@"error"] != nil;

    if (method.length && reqID != nil) {
        [self handleServerRequestLocked:msg];
        return;
    }
    if (method.length && reqID == nil) {
        [self handleNotificationLocked:msg];
        return;
    }
    if (reqID != nil && (hasResult || hasError)) {
        [self handleResponseLocked:msg];
    }
}

- (void)handleResponseLocked:(NSDictionary *)msg {
    NSString *key = CPCodexIDKey(msg[@"id"]);
    CPCodexPending *pending = _pending[key];
    if (!pending) return;
    [_pending removeObjectForKey:key];
    NSDictionary *error = CPCodexDictAt(msg, @"error");
    if (error) {
        NSInteger code = [error[@"code"] respondsToSelector:@selector(integerValue)] ? [error[@"code"] integerValue] : -1;
        // model/list 失败只让目录变空,不能把整条控制通道判死。老版本 codex 没有这个方法。
        if (code == kCPCodexMethodNotFound && ![pending.method isEqualToString:@"model/list"]) {
            NSLog(@"[CPCodexDriver] 协议不兼容 method=%@ code=-32601", pending.method);
            _incompatible = YES;
            [self setHealthyLocked:NO];
        }
        if (pending.completion) pending.completion(nil, code);
        return;
    }
    if (pending.completion) pending.completion(msg[@"result"], 0);
}

- (void)handleNotificationLocked:(NSDictionary *)msg {
    NSString *method = CPCodexStringAt(msg, @"method");
    NSDictionary *params = CPCodexDictAt(msg, @"params") ?: @{};
    if (CPCodexMethodMatches(method, @"turn/started", @"StartedNotification") ||
        CPCodexMethodMatches(method, @"turn/started", @"Started")) {
        NSString *threadID = CPCodexStringAt(params, @"threadId");
        NSString *turnID = CPCodexStringAt(CPCodexDictAt(params, @"turn"), @"id");
        if (!turnID.length) turnID = CPCodexStringAt(params, @"turnId");
        if (threadID.length && turnID.length) _activeTurn[threadID] = turnID;
        return;
    }
    if (CPCodexMethodMatches(method, @"turn/completed", @"CompletedNotification") ||
        CPCodexMethodMatches(method, @"turn/completed", @"Completed")) {
        NSString *threadID = CPCodexStringAt(params, @"threadId");
        if (threadID.length) [_activeTurn removeObjectForKey:threadID];
        [self flushActivityLocked:threadID];
        return;
    }
    [self foldActivityLocked:method params:params];
}

#pragma mark - 实时活动流：折叠

- (void)forgetActivityStateLocked {
    [_workdirByThread removeAllObjects];
    [_projectByThread removeAllObjects];
    [_commandByItem removeAllObjects];
}

- (void)flushActivityLocked:(NSString *)threadID {
    if (!threadID.length || ![_managed containsObject:threadID]) return;
    void (^flush)(NSString *, NSString *) = self.onActivityFlush;
    if (flush) flush(self.agentID, threadID);
}

- (void)emitActivityLocked:(NSString *)threadID
                      kind:(CPActivityKind)kind
                     merge:(CPActivityMerge)merge
                    itemID:(NSString *)itemID
                      text:(NSString *)text
                    detail:(NSString *)detail {
    void (^sink)(CPActivityEntry *) = self.onActivityEntry;
    if (!sink) return;
    if (!text.length && !detail.length) return;
    NSString *workdir = _workdirByThread[threadID];
    NSString *project = _projectByThread[threadID];
    CPActivityEntry *entry = CPActivityEntry.new;
    entry.agentID = self.agentID;
    entry.taskID = threadID;
    entry.itemID = itemID;
    entry.kind = kind;
    entry.merge = merge;
    entry.text = CPCodexRedactActivity(text, workdir, project);
    entry.detail = detail.length ? CPCodexRedactActivity(detail, workdir, project) : nil;
    entry.at = NSDate.date.timeIntervalSince1970;
    sink(entry);
}

// app-server 一共 70 种通知，这里只认契约表里的那些；其余（账号、MCP、realtime 语音、
// fuzzy search、Windows 等）直接返回，不产生条目、不占 seq。
- (void)foldActivityLocked:(NSString *)method params:(NSDictionary *)params {
    if (!method.length) return;
    NSString *threadID = CPCodexStringAt(params, @"threadId");
    // 只有澜台自己拉起的托管线程才有流。桌面端会话不是我们拉起的，手机继续看落盘结果。
    // command/exec/outputDelta 只带 connection 级的 processId，无法归属任务，天然落在这里。
    if (!threadID.length || ![_managed containsObject:threadID]) return;
    NSString *itemID = CPCodexStringAt(params, @"itemId");
    NSString *delta = CPCodexStringAt(params, @"delta");

    if (CPCodexMethodMatches(method, @"item/started", @"ItemStartedNotification")) {
        NSDictionary *item = CPCodexDictAt(params, @"item");
        NSString *iid = CPCodexStringAt(item, @"id");
        NSString *command = CPCodexStringAt(item, @"command");
        if (iid.length && command.length &&
            [CPCodexStringAt(item, @"type") isEqualToString:@"commandExecution"]) {
            // 正常情况下 item/completed 会把它删掉；万一对端不发，也不让它无界长下去。
            if (_commandByItem.count > 200) [_commandByItem removeAllObjects];
            _commandByItem[iid] = command; // 只作为 run 条目的标题来源，本身不产生条目
        }
        return;
    }
    if (CPCodexMethodMatches(method, @"item/completed", @"ItemCompletedNotification")) {
        NSString *iid = CPCodexStringAt(CPCodexDictAt(params, @"item"), @"id");
        if (iid.length) [_commandByItem removeObjectForKey:iid];
        [self flushActivityLocked:threadID]; // item 结束立即冲刷，保证顺序如实
        return;
    }

    if (CPCodexMethodMatches(method, @"item/agentMessage/delta", @"AgentMessageDelta")) {
        [self emitActivityLocked:threadID kind:CPActivityKindSay merge:CPActivityMergeAppendText
                          itemID:itemID text:delta detail:nil];
        return;
    }
    if (CPCodexMethodMatches(method, @"item/reasoning/summaryTextDelta", @"ReasoningSummaryTextDelta") ||
        CPCodexMethodMatches(method, @"item/reasoning/textDelta", @"ReasoningTextDelta")) {
        [self emitActivityLocked:threadID kind:CPActivityKindThink merge:CPActivityMergeAppendText
                          itemID:itemID text:delta detail:nil];
        return;
    }
    if (CPCodexMethodMatches(method, @"item/commandExecution/outputDelta", @"CommandExecutionOutputDelta") ||
        CPCodexMethodMatches(method, @"command/exec/outputDelta", @"CommandExecOutputDelta")) {
        NSString *command = itemID.length ? _commandByItem[itemID] : nil;
        [self emitActivityLocked:threadID kind:CPActivityKindRun merge:CPActivityMergeAppendDetail
                          itemID:itemID text:command ?: @"" detail:delta];
        return;
    }
    if (CPCodexMethodMatches(method, @"item/fileChange/patchUpdated", @"FileChangePatchUpdated")) {
        NSArray *changes = CPCodexArrayAt(params, @"changes") ?: @[];
        NSMutableArray<NSString *> *lines = NSMutableArray.array;
        NSString *only = nil;
        for (id row in changes) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            NSString *path = CPCodexStringAt(row, @"path");
            if (!path.length) continue;
            only = path;
            [lines addObject:[NSString stringWithFormat:@"%@ %@%@", CPCodexPatchMark(row), path,
                              CPCodexDiffCounts(CPCodexStringAt(row, @"diff"))]];
        }
        if (!lines.count) return;
        NSString *text = lines.count == 1
            ? [NSString stringWithFormat:@"改动 %@", only]
            : [NSString stringWithFormat:@"改动 %lu 个文件", (unsigned long)lines.count];
        [self emitActivityLocked:threadID kind:CPActivityKindEdit merge:CPActivityMergeReplace
                          itemID:itemID text:text detail:[lines componentsJoinedByString:@"\n"]];
        return;
    }
    if (CPCodexMethodMatches(method, @"turn/diff/updated", @"TurnDiffUpdated")) {
        NSString *diff = CPCodexStringAt(params, @"diff") ?: @"";
        NSArray<NSString *> *files = CPCodexDiffFiles(diff);
        if (!diff.length) return;
        NSString *text = files.count
            ? (files.count == 1 ? [NSString stringWithFormat:@"本轮改动 %@", files.firstObject]
                                : [NSString stringWithFormat:@"本轮改动 %lu 个文件", (unsigned long)files.count])
            : @"本轮改动";
        NSString *detail = files.count ? [files componentsJoinedByString:@"\n"] : diff;
        [self emitActivityLocked:threadID kind:CPActivityKindEdit merge:CPActivityMergeReplace
                          itemID:@"turn-diff" text:text detail:detail];
        return;
    }
    if (CPCodexMethodMatches(method, @"turn/plan/updated", @"TurnPlanUpdated")) {
        NSArray *plan = CPCodexArrayAt(params, @"plan") ?: @[];
        NSMutableArray<NSString *> *lines = NSMutableArray.array;
        NSInteger done = 0;
        for (id row in plan) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            NSString *step = CPCodexStringAt(row, @"step");
            if (!step.length) continue;
            NSString *status = CPCodexStringAt(row, @"status") ?: @"pending";
            NSString *mark = @"·";
            if ([status isEqualToString:@"completed"]) { mark = @"✓"; done += 1; }
            else if ([status isEqualToString:@"inProgress"]) mark = @"▶";
            [lines addObject:[NSString stringWithFormat:@"%@ %@", mark, step]];
        }
        if (!lines.count) return;
        NSString *text = [NSString stringWithFormat:@"计划 %ld/%lu", (long)done, (unsigned long)lines.count];
        [self emitActivityLocked:threadID kind:CPActivityKindPlan merge:CPActivityMergeReplace
                          itemID:@"turn-plan" text:text detail:[lines componentsJoinedByString:@"\n"]];
        return;
    }
    if (CPCodexMethodMatches(method, @"item/plan/delta", @"PlanDelta")) {
        [self emitActivityLocked:threadID kind:CPActivityKindPlan merge:CPActivityMergeAppendText
                          itemID:itemID text:delta detail:nil];
        return;
    }
    if (CPCodexMethodMatches(method, @"thread/tokenUsage/updated", @"TokenUsageUpdated")) {
        NSDictionary *usage = CPCodexDictAt(params, @"tokenUsage");
        NSDictionary *total = CPCodexDictAt(usage, @"total");
        if (!total) return;
        long long totalTokens = [total[@"totalTokens"] respondsToSelector:@selector(longLongValue)]
            ? [total[@"totalTokens"] longLongValue] : 0;
        long long input = [total[@"inputTokens"] respondsToSelector:@selector(longLongValue)]
            ? [total[@"inputTokens"] longLongValue] : 0;
        long long output = [total[@"outputTokens"] respondsToSelector:@selector(longLongValue)]
            ? [total[@"outputTokens"] longLongValue] : 0;
        NSString *text = [NSString stringWithFormat:@"token 用量 %lld", totalTokens];
        NSString *detail = [NSString stringWithFormat:@"输入 %lld · 输出 %lld", input, output];
        [self emitActivityLocked:threadID kind:CPActivityKindUsage merge:CPActivityMergeReplace
                          itemID:@"usage" text:text detail:detail];
        return;
    }
    if (CPCodexMethodMatches(method, @"guardianWarning", @"GuardianWarning")) {
        [self emitActivityLocked:threadID kind:CPActivityKindNote merge:CPActivityMergeDistinct
                          itemID:nil text:CPCodexStringAt(params, @"message") detail:nil];
        return;
    }
    if (CPCodexMethodMatches(method, @"warning", nil)) {
        [self emitActivityLocked:threadID kind:CPActivityKindNote merge:CPActivityMergeDistinct
                          itemID:nil text:CPCodexStringAt(params, @"message") detail:nil];
        return;
    }
    if (CPCodexMethodMatches(method, @"error", nil)) {
        NSDictionary *error = CPCodexDictAt(params, @"error");
        NSString *message = CPCodexStringAt(error, @"message");
        if (!message.length) return;
        [self emitActivityLocked:threadID kind:CPActivityKindNote merge:CPActivityMergeDistinct
                          itemID:nil text:message
                          detail:CPCodexStringAt(error, @"additionalDetails")];
        return;
    }
    // 其余通知（账号、MCP、realtime、fuzzy search、thread/status/changed 等）安静忽略。
}

- (void)handleServerRequestLocked:(NSDictionary *)msg {
    NSString *method = CPCodexStringAt(msg, @"method") ?: @"";
    id reqID = msg[@"id"];
    NSLog(@"[CPCodexDriver] 自动拒绝反向请求 method=%@", method);

    if ([method isEqualToString:@"item/commandExecution/requestApproval"] ||
        [method isEqualToString:@"item/fileChange/requestApproval"]) {
        [self sendResultLocked:reqID result:@{ @"decision": @"decline" }];
        return;
    }
    if ([method isEqualToString:@"execCommandApproval"] ||
        [method isEqualToString:@"applyPatchApproval"]) {
        [self sendResultLocked:reqID result:@{
            @"decision": @{ @"denied": @{ @"rejection": kCPCodexDenyReason } }
        }];
        return;
    }
    if ([method isEqualToString:@"mcpServer/elicitation/request"]) {
        [self sendResultLocked:reqID result:@{ @"action": @"decline" }];
        return;
    }
    // permissions / tool user input 没有带原因的拒绝体，回 JSON-RPC 错误以免悬挂。
    [self sendErrorLocked:reqID code:-32000 message:kCPCodexDenyReason];
}

- (void)sendResultLocked:(id)reqID result:(id)result {
    if (reqID == nil) return;
    [self sendObjectLocked:@{ @"jsonrpc": @"2.0", @"id": reqID, @"result": result ?: @{} }];
}

- (void)sendErrorLocked:(id)reqID code:(NSInteger)code message:(NSString *)message {
    if (reqID == nil) return;
    [self sendObjectLocked:@{
        @"jsonrpc": @"2.0",
        @"id": reqID,
        @"error": @{ @"code": @(code), @"message": message ?: @"" }
    }];
}

- (void)sendObjectLocked:(NSDictionary *)obj {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:&error];
    if (!data) return;
    NSString *line = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [_active sendLine:line];
}

- (void)dealloc {
    _stopping = YES;
    [_active stop];
}

@end
