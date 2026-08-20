#import "CPBridgeServer.h"
#import "CPStatusEngine.h"
#import "CPRefreshPipeline.h"
#import "CPWorkdirStore.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
#import <string.h>

// HTTP 自己写:BSD socket + 阻塞 accept 专用队列。
// 不用 NSSocketPort(已废弃),也不用 nw_listener(要再包一层 HTTP 解析,SSE 长连接更绕)。
// dispatch_source 听 listen fd 在 --self-test 这种没有常驻 runloop 的进程里接不到连接,
// 所以 accept 放独立串行队列,状态/路由仍走 _queue。只绑 0.0.0.0/127.0.0.1,不做 UPnP。


NSString * const CPBridgeEnabledDefaultsKey = @"bridge.enabled.v1";

BOOL CPBridgeIsEnabled(void) {
    return [NSUserDefaults.standardUserDefaults boolForKey:CPBridgeEnabledDefaultsKey];
}

void CPBridgeSetEnabled(BOOL enabled) {
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:CPBridgeEnabledDefaultsKey];
}

NSString * const CPBridgePortDefaultsKey = @"bridge.port.v1";
NSString * const CPControlWorkdirsDefaultsKey = @"control.workdirs.v1";
NSString * const CPTodosDidChangeNotification = @"CPTodosDidChangeNotification";
NSString * const CPBridgeDevicePairedNotification = @"CPBridgeDevicePairedNotification";
static char kBridgeQueueIdent;

static NSString *CPBridgeStatusJSON(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return @"working";
        case CPStatusWaiting: return @"waiting";
        case CPStatusAttention: return @"attention";
        case CPStatusCompleted: return @"completed";
        case CPStatusFailed: return @"failed";
        case CPStatusIdle: return @"idle";
    }
}

static NSString *CPBridgeDisplayJSON(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusIdle: return @"idle";
        case CPDisplayStatusWorking: return @"working";
        case CPDisplayStatusCompletedPendingReview: return @"completedPendingReview";
        case CPDisplayStatusWaiting: return @"waiting";
        case CPDisplayStatusFailed: return @"failed";
    }
}

static long long CPBridgeMs(NSDate *date) {
    if (!date) return 0;
    return (long long)llround(date.timeIntervalSince1970 * 1000.0);
}

static NSData *CPBridgeJSONData(id obj) {
    if (!obj) obj = @{};
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return data ?: [NSData dataWithBytes:"{}" length:2];
}

static const int kCPBridgeIOTimeoutSec = 5;

// 只改发给手机的文案,不动 CPTask 本身,Mac UI 仍显示原始 activity/title。
static NSString *CPBridgeRedactPaths(NSString *text) {
    if (!text.length) return text ?: @"";
    NSMutableString *out = [text mutableCopy];
    NSString *home = NSHomeDirectory();
    if (home.length) {
        [out replaceOccurrencesOfString:home withString:@"~" options:0 range:NSMakeRange(0, out.length)];
    }
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"/Users/[^/\\s]+"
                                                                       options:0 error:nil];
    return [re stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@"~"];
}

// 实时活动流的硬上限，见 docs/BRIDGE_API.md「服务端的限流义务」。
static const NSUInteger kCPActivityMaxEntries = 40;
static const NSUInteger kCPActivityMaxStreams = 10;
static const NSUInteger kCPActivityMaxText = 400;
static const NSUInteger kCPActivityMaxDetail = 2000;
static const NSTimeInterval kCPActivityFlushInterval = 0.25;

// 截断到字符上限。detail 保留尾部:命令输出的价值在末尾。
// 切点吸附到完整字符边界,免得把 emoji 的代理对劈成半个。
static NSString *CPBridgeClamp(NSString *text, NSUInteger max, BOOL keepTail) {
    if (text.length <= max || max == 0) return text ?: @"";
    if (keepTail) {
        NSUInteger cut = text.length - (max - 1);
        NSRange safe = [text rangeOfComposedCharacterSequenceAtIndex:cut];
        if (safe.location < cut) cut = NSMaxRange(safe);
        return [@"…" stringByAppendingString:[text substringFromIndex:cut]];
    }
    NSUInteger cut = max - 1;
    NSRange safe = [text rangeOfComposedCharacterSequenceAtIndex:cut];
    if (safe.location < cut) cut = safe.location;
    return [[text substringToIndex:cut] stringByAppendingString:@"…"];
}

static void CPBridgeApplyIOTimeouts(int fd) {
    struct timeval tv = {.tv_sec = kCPBridgeIOTimeoutSec, .tv_usec = 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
}

static NSString *CPBridgeMIME(NSString *ext) {
    ext = ext.lowercaseString;
    if ([ext isEqualToString:@"html"] || [ext isEqualToString:@"htm"]) return @"text/html; charset=utf-8";
    if ([ext isEqualToString:@"js"] || [ext isEqualToString:@"mjs"]) return @"text/javascript; charset=utf-8";
    if ([ext isEqualToString:@"css"]) return @"text/css; charset=utf-8";
    if ([ext isEqualToString:@"json"] || [ext isEqualToString:@"map"]) return @"application/json; charset=utf-8";
    if ([ext isEqualToString:@"svg"]) return @"image/svg+xml";
    if ([ext isEqualToString:@"png"]) return @"image/png";
    if ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) return @"image/jpeg";
    if ([ext isEqualToString:@"ico"]) return @"image/x-icon";
    if ([ext isEqualToString:@"woff2"]) return @"font/woff2";
    if ([ext isEqualToString:@"woff"]) return @"font/woff";
    return @"application/octet-stream";
}

static BOOL CPBridgeWriteAll(int fd, const void *bytes, NSUInteger len) {
    const uint8_t *p = bytes;
    NSUInteger off = 0;
    while (off < len) {
        ssize_t n = send(fd, p + off, len - off, 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) return NO;
        off += (NSUInteger)n;
    }
    return YES;
}

static BOOL CPBridgeWriteResponse(int fd, int status, NSString *reason, NSString *contentType, NSData *body) {
    if (!body) body = [NSData data];
    NSString *header = [NSString stringWithFormat:
                        @"HTTP/1.1 %d %@\r\n"
                        @"Content-Type: %@\r\n"
                        @"Content-Length: %lu\r\n"
                        @"Cache-Control: no-store\r\n"
                        @"Connection: close\r\n"
                        @"\r\n",
                        status, reason, contentType, (unsigned long)body.length];
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    if (!CPBridgeWriteAll(fd, headerData.bytes, headerData.length)) return NO;
    if (body.length) return CPBridgeWriteAll(fd, body.bytes, body.length);
    return YES;
}

static BOOL CPBridgeWriteJSON(int fd, int status, NSString *reason, id obj) {
    return CPBridgeWriteResponse(fd, status, reason, @"application/json; charset=utf-8", CPBridgeJSONData(obj));
}

static int CPBridgeListenSocket(BOOL loopback, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) return -1;
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = loopback ? htonl(INADDR_LOOPBACK) : INADDR_ANY;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) { close(fd); return -1; }
    if (listen(fd, 16) < 0) { close(fd); return -1; }
    return fd;
}

static int CPBridgeBoundPort(int fd) {
    struct sockaddr_in addr;
    socklen_t len = sizeof(addr);
    if (getsockname(fd, (struct sockaddr *)&addr, &len) < 0) return 0;
    return ntohs(addr.sin_port);
}

static BOOL CPBridgeReadRequest(int fd, NSString **methodOut, NSString **pathOut,
                                NSDictionary **headersOut, NSData **bodyOut) {
    NSMutableData *buf = NSMutableData.data;
    uint8_t tmp[4096];
    NSInteger headerEnd = NSNotFound;
    while (buf.length < 65536) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) break;
        [buf appendBytes:tmp length:(NSUInteger)n];
        NSRange needle = [buf rangeOfData:[NSData dataWithBytes:"\r\n\r\n" length:4]
                                  options:0 range:NSMakeRange(0, buf.length)];
        if (needle.location != NSNotFound) {
            headerEnd = (NSInteger)needle.location;
            break;
        }
    }
    if (headerEnd == NSNotFound) return NO;
    NSData *headerData = [buf subdataWithRange:NSMakeRange(0, (NSUInteger)headerEnd)];
    NSString *headerText = [[NSString alloc] initWithData:headerData encoding:NSUTF8StringEncoding];
    if (!headerText.length) return NO;
    NSArray<NSString *> *lines = [headerText componentsSeparatedByString:@"\r\n"];
    if (!lines.count) return NO;
    NSArray<NSString *> *req = [lines[0] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (req.count < 2) return NO;
    NSString *method = req[0];
    NSString *rawPath = req[1];
    NSMutableDictionary *headers = NSMutableDictionary.dictionary;
    for (NSUInteger i = 1; i < lines.count; i++) {
        NSString *line = lines[i];
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) continue;
        NSString *key = [line substringToIndex:colon.location].lowercaseString;
        NSString *val = [[line substringFromIndex:colon.location + 1]
                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        headers[key] = val;
    }
    NSUInteger bodyStart = (NSUInteger)headerEnd + 4;
    NSMutableData *body = [[buf subdataWithRange:NSMakeRange(bodyStart, buf.length - bodyStart)] mutableCopy];
    NSInteger contentLength = [headers[@"content-length"] integerValue];
    if (contentLength < 0) contentLength = 0;
    if (contentLength > 1024 * 1024) return NO;
    while ((NSInteger)body.length < contentLength) {
        ssize_t n = recv(fd, tmp, sizeof(tmp), 0);
        if (n < 0) {
            if (errno == EINTR) continue;
            return NO;
        }
        if (n == 0) break;
        [body appendBytes:tmp length:(NSUInteger)n];
        if (body.length > 1024 * 1024) return NO;
    }
    if ((NSInteger)body.length > contentLength) {
        body = [[body subdataWithRange:NSMakeRange(0, (NSUInteger)contentLength)] mutableCopy];
    }
    *methodOut = method;
    *pathOut = rawPath;
    *headersOut = headers;
    *bodyOut = body;
    return YES;
}

@interface CPBridgeSSEClient : NSObject
@property int fd;
@end
@implementation CPBridgeSSEClient
@end

@interface CPBridgeActivityItem : NSObject
@property NSInteger seq;            // 0 表示还在合并中,尚未定稿
@property CPActivityKind kind;
@property CPActivityMerge merge;
@property (copy) NSString *itemID;
@property NSMutableString *text;
@property NSMutableString *detail;
@property NSTimeInterval at;
@end
@implementation CPBridgeActivityItem
@end

@interface CPBridgeActivityStream : NSObject
@property (copy) NSString *key;
@property (copy) NSString *agentID;
@property (copy) NSString *taskID;
@property NSInteger nextSeq;        // 每任务独立,从 1 开始,不复用不回退
@property BOOL live;
@property NSTimeInterval lastPushAt;
@property BOOL pushScheduled;
@property NSMutableArray<CPBridgeActivityItem *> *entries; // 已定稿,最近 40 条
@property NSMutableArray<CPBridgeActivityItem *> *unsent;  // 已定稿但还没进 SSE
@property CPBridgeActivityItem *pending;                   // 正在合并的那条
@end
@implementation CPBridgeActivityStream
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _nextSeq = 1;
    _live = YES;
    _entries = NSMutableArray.array;
    _unsent = NSMutableArray.array;
    return self;
}
@end

@implementation CPBridgeServer {
    int _listenFD;
    dispatch_queue_t _queue;
    dispatch_queue_t _acceptQueue;
    dispatch_source_t _pingTimer;
    dispatch_source_t _watchTimer;
    NSMutableArray<CPBridgeSSEClient *> *_sseClients;
    NSMutableDictionary<NSString *, NSDictionary *> *_opResults;
    NSMutableArray<NSString *> *_opIDs;
    NSMutableDictionary<NSString *, CPAgentCommand *> *_commands;
    NSMutableArray<NSString *> *_commandIDs;
    NSMutableDictionary<NSString *, NSString *> *_inflightByAgent;
    NSMutableDictionary<NSString *, CPBridgeActivityStream *> *_activityStreams;
    NSMutableArray<NSString *> *_activityOrder; // 最旧在前,超过 10 个任务淘汰队首
    NSInteger _activityEvents;
    NSString *_lastAgentSignature;
    BOOL _running;
    NSInteger _port;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _portMin = 8787;
    _portMax = 8797;
    _persistPort = YES;
    _pairing = CPBridgePairing.new;
    _sseClients = NSMutableArray.array;
    _opResults = NSMutableDictionary.dictionary;
    _opIDs = NSMutableArray.array;
    _commands = NSMutableDictionary.dictionary;
    _commandIDs = NSMutableArray.array;
    _inflightByAgent = NSMutableDictionary.dictionary;
    _activityStreams = NSMutableDictionary.dictionary;
    _activityOrder = NSMutableArray.array;
    _activityFlushInterval = kCPActivityFlushInterval;
    _listenFD = -1;
    _queue = dispatch_queue_create("com.codexpulse.bridge", DISPATCH_QUEUE_SERIAL);
    _acceptQueue = dispatch_queue_create("com.codexpulse.bridge.accept", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, &kBridgeQueueIdent, (void *)1, NULL);
    return self;
}

- (void)dealloc {
    [self stop];
}

- (NSArray<CPAgent *> *)currentAgents {
    if (self.latestAgents) return self.latestAgents;
    if (self.reader) return [self.reader readAgents];
    return @[];
}

- (NSString *)appVersion {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return version.length ? version : @"0.3.0";
}

- (NSArray *)sortedTasks:(NSArray<CPTask *> *)tasks {
    return [tasks sortedArrayUsingComparator:^NSComparisonResult(CPTask *a, CPTask *b) {
        NSComparisonResult order = [b.updatedAt compare:a.updatedAt];
        if (order != NSOrderedSame) return order;
        NSInteger pa = CPStatusTiePriority(a.status);
        NSInteger pb = CPStatusTiePriority(b.status);
        if (pb > pa) return NSOrderedAscending;
        if (pb < pa) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

- (NSDictionary *)taskJSON:(CPTask *)task agentID:(NSString *)agentID managed:(BOOL)managed {
    BOOL reviewed = self.reviewStore ? [self.reviewStore isTaskReviewed:task agentID:agentID] : NO;
    NSMutableDictionary *row = [@{
        @"taskID": task.taskID ?: @"",
        @"title": CPBridgeRedactPaths(task.title),
        @"projectName": task.projectName ?: @"",
        @"sourceKind": task.sourceKind ?: @"",
        @"status": CPBridgeStatusJSON(task.status),
        @"activity": CPBridgeRedactPaths(task.activity),
        @"tokensUsed": @(task.tokensUsed),
        @"createdAtMs": @(CPBridgeMs(task.createdAt)),
        @"updatedAtMs": @(CPBridgeMs(task.updatedAt)),
        @"reviewed": reviewed ? @YES : @NO,
        @"managed": managed ? @YES : @NO,
    } mutableCopy];
    // 只有托管任务有流。桌面端会话不是澜台拉起的,手机继续看落盘的 activity 字段。
    if (managed) {
        NSDictionary *stream = [self activityStreamJSONLocked:agentID taskID:task.taskID];
        if (stream) row[@"stream"] = stream;
    }
    return row;
}

- (NSDictionary *)todoJSON:(CPTodo *)todo {
    return @{
        @"todoID": @(todo.todoID),
        @"title": todo.title ?: @"",
        @"completed": todo.completed ? @YES : @NO,
        @"agentID": todo.agentID ?: NSNull.null,
        @"threadID": todo.threadID ?: NSNull.null,
        @"createdAtMs": @(CPBridgeMs(todo.createdAt)),
        @"updatedAtMs": @(CPBridgeMs(todo.updatedAt)),
    };
}

- (NSArray *)todosJSONArray {
    NSMutableArray *rows = NSMutableArray.array;
    for (CPTodo *todo in [self.todoStore allTodos]) [rows addObject:[self todoJSON:todo]];
    return rows;
}

- (NSArray<NSString *> *)capabilitiesForAgentID:(NSString *)agentID {
    if (!self.controlRegistry) return @[@"observe"];
    return [self.controlRegistry capabilitiesForAgentID:agentID] ?: @[@"observe"];
}

- (NSString *)controlRouteForAgentID:(NSString *)agentID {
    id<CPAgentControlDriver> driver = [self.controlRegistry driverForAgentID:agentID];
    return (driver && driver.isHealthy) ? @"native" : @"none";
}

- (BOOL)isManagedTaskID:(NSString *)taskID agentID:(NSString *)agentID {
    id<CPAgentControlDriver> driver = [self.controlRegistry driverForAgentID:agentID];
    return driver ? [driver isManagedTaskID:taskID] : NO;
}

- (NSUserDefaults *)controlDefaults {
    return self.defaults ?: NSUserDefaults.standardUserDefaults;
}

- (CPWorkdirStore *)workdirStore {
    return [[CPWorkdirStore alloc] initWithDefaults:self.controlDefaults];
}

- (NSArray<NSDictionary *> *)workdirsPublicJSON {
    NSMutableArray<NSDictionary *> *out = NSMutableArray.array;
    for (CPWorkdirEntry *entry in [self.workdirStore allEntries]) {
        [out addObject:@{ @"workdirID": entry.workdirID ?: @"", @"name": entry.name ?: @"" }];
    }
    return out;
}

- (NSString *)pathForWorkdirID:(NSString *)workdirID {
    return [self.workdirStore entryWithID:workdirID].path;
}

- (NSArray<NSDictionary *> *)modelsJSONForAgentID:(NSString *)agentID {
    id<CPAgentControlDriver> driver = [self.controlRegistry driverForAgentID:agentID];
    if (!driver || !driver.isHealthy) return @[];
    NSMutableArray<NSDictionary *> *out = NSMutableArray.array;
    for (CPAgentModel *model in driver.availableModels ?: @[]) {
        if (![model isKindOfClass:CPAgentModel.class] || !model.modelID.length) continue;
        [out addObject:@{
            @"modelID": model.modelID,
            @"name": model.name ?: @"",
            @"description": CPBridgeRedactPaths(model.descriptionText) ?: @"",
            @"isDefault": @(model.isDefault),
        }];
    }
    return out;
}

// 活动流状态只在 _queue 上读写,快照又可能从任意线程取,所以统一在队列上组装。
- (NSDictionary *)snapshotDictionary {
    __block NSDictionary *snapshot = nil;
    [self onBridgeQueue:^{ snapshot = [self snapshotDictionaryLocked]; } wait:YES];
    return snapshot;
}

- (NSDictionary *)snapshotDictionaryLocked {
    NSMutableArray *agentsJSON = NSMutableArray.array;
    for (CPAgent *agent in [self currentAgents]) {
        if (agent.placeholder) continue;
        NSMutableArray *tasksJSON = NSMutableArray.array;
        for (CPTask *task in [self sortedTasks:agent.tasks]) {
            BOOL managed = [self isManagedTaskID:task.taskID agentID:agent.agentID];
            [tasksJSON addObject:[self taskJSON:task agentID:agent.agentID managed:managed]];
        }
        CPDisplayStatus display = CPDisplayStatusForTasks(agent.tasks, agent.agentID, self.reviewStore);
        [agentsJSON addObject:@{
            @"agentID": agent.agentID ?: @"",
            @"name": agent.name ?: @"",
            @"health": agent.health == CPAgentHealthMissing ? @"missing" : @"ok",
            @"status": CPBridgeStatusJSON(agent.status),
            @"displayStatus": CPBridgeDisplayJSON(display),
            @"capabilities": [self capabilitiesForAgentID:agent.agentID],
            @"controlRoute": [self controlRouteForAgentID:agent.agentID],
            @"models": [self modelsJSONForAgentID:agent.agentID],
            @"tasks": tasksJSON,
        }];
    }
    return @{
        @"serverTimeMs": @(CPBridgeMs(NSDate.date)),
        @"agents": agentsJSON,
        @"todos": [self todosJSONArray],
        @"workdirs": [self workdirsPublicJSON],
    };
}

- (NSString *)preferredLANAddress {
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return @"127.0.0.1";
    NSString *found = nil;
    NSString *en0 = nil;
    for (struct ifaddrs *ifa = list; ifa; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        if ((ifa->ifa_flags & IFF_LOOPBACK) || !(ifa->ifa_flags & IFF_UP)) continue;
        struct sockaddr_in *sin = (struct sockaddr_in *)ifa->ifa_addr;
        char buf[INET_ADDRSTRLEN];
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof(buf))) continue;
        NSString *ip = @(buf);
        if (!found) found = ip;
        if (ifa->ifa_name && strcmp(ifa->ifa_name, "en0") == 0) en0 = ip;
    }
    freeifaddrs(list);
    return en0 ?: found ?: @"127.0.0.1";
}

- (NSString *)splitPath:(NSString *)rawPath query:(NSString **)queryOut {
    NSRange q = [rawPath rangeOfString:@"?"];
    NSString *path = rawPath;
    NSString *query = nil;
    if (q.location != NSNotFound) {
        path = [rawPath substringToIndex:q.location];
        query = [rawPath substringFromIndex:q.location + 1];
    }
    NSString *decoded = path.stringByRemovingPercentEncoding;
    if (queryOut) *queryOut = query;
    return decoded.length ? decoded : path;
}

- (NSString *)queryValue:(NSString *)query name:(NSString *)name {
    if (!query.length || !name.length) return nil;
    for (NSString *pair in [query componentsSeparatedByString:@"&"]) {
        NSRange eq = [pair rangeOfString:@"="];
        NSString *key = eq.location == NSNotFound ? pair : [pair substringToIndex:eq.location];
        NSString *val = eq.location == NSNotFound ? @"" : [pair substringFromIndex:eq.location + 1];
        NSString *decodedKey = key.stringByRemovingPercentEncoding ?: key;
        if (![decodedKey isEqualToString:name]) continue;
        NSString *decodedVal = val.stringByRemovingPercentEncoding ?: val;
        return decodedVal.length ? decodedVal : nil;
    }
    return nil;
}

- (NSString *)bearerToken:(NSDictionary *)headers {
    NSString *auth = headers[@"authorization"];
    if (![auth isKindOfClass:NSString.class] || !auth.length) return nil;
    if (auth.length < 7) return nil;
    NSString *prefix = [auth substringToIndex:7];
    if ([prefix caseInsensitiveCompare:@"Bearer "] != NSOrderedSame) return nil;
    NSString *token = [[auth substringFromIndex:7] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return token.length ? token : nil;
}

- (BOOL)authorized:(NSDictionary *)headers {
    return [self.pairing isTokenValid:[self bearerToken:headers]];
}

- (id)parseJSON:(NSData *)body {
    if (!body.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

- (NSDictionary *)replayOp:(NSString *)opID {
    if (!opID.length) return nil;
    return _opResults[opID];
}

- (void)rememberOp:(NSString *)opID status:(int)status reason:(NSString *)reason json:(id)json {
    if (!opID.length) return;
    _opResults[opID] = @{@"status": @(status), @"reason": reason ?: @"OK", @"json": json ?: @{}};
    [_opIDs addObject:opID];
    while (_opIDs.count > 200) {
        NSString *old = _opIDs.firstObject;
        [_opIDs removeObjectAtIndex:0];
        [_opResults removeObjectForKey:old];
    }
}

- (void)writeCached:(NSDictionary *)cached fd:(int)fd {
    int status = [cached[@"status"] intValue];
    NSString *reason = cached[@"reason"] ?: @"OK";
    CPBridgeWriteJSON(fd, status, reason, cached[@"json"]);
}

- (void)notifyTodosChanged {
    [self broadcastEvent:@"todos" json:@{@"todos": [self todosJSONArray]}];
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:CPTodosDidChangeNotification object:self];
    });
}

- (NSString *)mobileRoot {
    NSString *root = self.mobileDirectory.length
        ? self.mobileDirectory
        : [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"mobile"];
    return root.stringByStandardizingPath;
}

- (BOOL)serveStaticPath:(NSString *)path fd:(int)fd {
    NSString *rel = [path isEqualToString:@"/"] ? @"index.html" : [path substringFromIndex:1];
    if ([rel containsString:@".."]) return NO;
    NSString *root = [self mobileRoot];
    NSString *full = [[root stringByAppendingPathComponent:rel] stringByStandardizingPath];
    if (![full hasPrefix:root]) return NO;
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:full isDirectory:&isDir] || isDir) return NO;
    NSData *data = [NSData dataWithContentsOfFile:full];
    if (!data) return NO;
    return CPBridgeWriteResponse(fd, 200, @"OK", CPBridgeMIME(full.pathExtension), data);
}

- (void)closeSSE:(CPBridgeSSEClient *)client {
    if (client.fd >= 0) {
        close(client.fd);
        client.fd = -1;
    }
    [_sseClients removeObject:client];
}

- (void)broadcastEvent:(NSString *)event json:(id)json {
    NSData *payload = CPBridgeJSONData(json);
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *frame = [NSString stringWithFormat:@"event: %@\ndata: %@\n\n", event, text];
    NSData *data = [frame dataUsingEncoding:NSUTF8StringEncoding];
    NSArray<CPBridgeSSEClient *> *clients = [_sseClients copy];
    for (CPBridgeSSEClient *client in clients) {
        if (client.fd < 0) continue;
        if (!CPBridgeWriteAll(client.fd, data.bytes, data.length)) [self closeSSE:client];
    }
}

#pragma mark - 实时活动流

- (void)onBridgeQueue:(dispatch_block_t)block wait:(BOOL)wait {
    if (dispatch_get_specific(&kBridgeQueueIdent)) { block(); return; }
    if (wait) dispatch_sync(_queue, block);
    else dispatch_async(_queue, block);
}

- (NSString *)activityKeyForAgentID:(NSString *)agentID taskID:(NSString *)taskID {
    return [NSString stringWithFormat:@"%@\n%@", agentID ?: @"", taskID ?: @""];
}

- (CPBridgeActivityStream *)activityStreamLocked:(NSString *)agentID
                                          taskID:(NSString *)taskID
                                          create:(BOOL)create {
    if (!agentID.length || !taskID.length) return nil;
    NSString *key = [self activityKeyForAgentID:agentID taskID:taskID];
    CPBridgeActivityStream *stream = _activityStreams[key];
    if (stream) {
        if (create) { // 只有写入才算「用过」,读快照不该改变淘汰顺序
            [_activityOrder removeObject:key];
            [_activityOrder addObject:key];
        }
        return stream;
    }
    if (!create) return nil;
    stream = CPBridgeActivityStream.new;
    stream.key = key;
    stream.agentID = agentID;
    stream.taskID = taskID;
    // 首条也要等满一个间隔,否则第一个 delta 会单独成一次推送。
    stream.lastPushAt = NSDate.date.timeIntervalSince1970;
    _activityStreams[key] = stream;
    [_activityOrder addObject:key];
    while (_activityOrder.count > kCPActivityMaxStreams) {
        NSString *oldest = _activityOrder.firstObject;
        [_activityOrder removeObjectAtIndex:0];
        [_activityStreams removeObjectForKey:oldest];
    }
    return stream;
}

- (void)commitPendingLocked:(CPBridgeActivityStream *)stream {
    CPBridgeActivityItem *pending = stream.pending;
    if (!pending) return;
    stream.pending = nil;
    if (!pending.text.length && !pending.detail.length) return; // 空条目不占 seq
    pending.seq = stream.nextSeq++;
    [stream.entries addObject:pending];
    while (stream.entries.count > kCPActivityMaxEntries) [stream.entries removeObjectAtIndex:0];
    [stream.unsent addObject:pending];
    // 手机长时间断线时不无限攒:超出上限它会发现 seq 对不上,按契约重拉快照对齐。
    while (stream.unsent.count > kCPActivityMaxEntries) [stream.unsent removeObjectAtIndex:0];
}

- (NSDictionary *)activityItemJSON:(CPBridgeActivityItem *)item {
    // 第二层脱敏:driver 折叠时已经做过一遍,这里在推送前再兜一遍。
    // 跨 delta 被劈开的路径(前半条 "/Users/ang" + 后半条 "elmak/x")只有合并后才补得掉。
    NSMutableDictionary *row = [@{
        @"seq": @(item.seq),
        @"kind": CPActivityKindJSON(item.kind),
        @"text": CPBridgeClamp(CPBridgeRedactPaths(item.text), kCPActivityMaxText, NO),
        @"atMs": @((long long)llround(item.at * 1000.0)),
    } mutableCopy];
    if (item.detail.length) {
        row[@"detail"] = CPBridgeClamp(CPBridgeRedactPaths(item.detail), kCPActivityMaxDetail, YES);
    }
    return row;
}

- (NSDictionary *)activityStreamJSONLocked:(NSString *)agentID taskID:(NSString *)taskID {
    CPBridgeActivityStream *stream = [self activityStreamLocked:agentID taskID:taskID create:NO];
    if (!stream) return nil;
    NSMutableArray *rows = NSMutableArray.array;
    for (CPBridgeActivityItem *item in stream.entries) [rows addObject:[self activityItemJSON:item]];
    NSInteger seq = stream.entries.lastObject.seq;
    return @{ @"seq": @(seq), @"live": stream.live ? @YES : @NO, @"entries": rows };
}

- (NSDictionary *)activityStreamJSONForAgentID:(NSString *)agentID taskID:(NSString *)taskID {
    __block NSDictionary *json = nil;
    [self onBridgeQueue:^{ json = [self activityStreamJSONLocked:agentID taskID:taskID]; } wait:YES];
    return json;
}

- (void)broadcastActivityLocked:(CPBridgeActivityStream *)stream
                        entries:(NSArray<CPBridgeActivityItem *> *)batch {
    NSMutableArray *rows = NSMutableArray.array;
    for (CPBridgeActivityItem *item in batch) [rows addObject:[self activityItemJSON:item]];
    // seq 是本批最后一条的 seq;空批(仅 live 翻转)沿用当前尾部,手机的 seq 校验仍成立。
    NSInteger seq = batch.count ? batch.lastObject.seq : stream.entries.lastObject.seq;
    _activityEvents += 1;
    [self broadcastEvent:@"activity" json:@{
        @"agentID": stream.agentID ?: @"",
        @"taskID": stream.taskID ?: @"",
        @"seq": @(seq),
        @"live": stream.live ? @YES : @NO,
        @"entries": rows,
    }];
}

- (void)pushActivityLocked:(CPBridgeActivityStream *)stream allowEmpty:(BOOL)allowEmpty {
    [self commitPendingLocked:stream];
    stream.lastPushAt = NSDate.date.timeIntervalSince1970;
    if (!stream.unsent.count && !allowEmpty) return;
    NSArray<CPBridgeActivityItem *> *batch = [stream.unsent copy];
    [stream.unsent removeAllObjects];
    [self broadcastActivityLocked:stream entries:batch];
}

- (void)scheduleActivityPushLocked:(CPBridgeActivityStream *)stream {
    if (stream.pushScheduled) return;
    NSTimeInterval interval = self.activityFlushInterval > 0 ? self.activityFlushInterval : kCPActivityFlushInterval;
    NSTimeInterval delay = stream.lastPushAt + interval - NSDate.date.timeIntervalSince1970;
    if (delay < 0) delay = 0;
    stream.pushScheduled = YES;
    NSString *key = stream.key;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), _queue, ^{
        CPBridgeServer *strongSelf = weakSelf;
        if (!strongSelf) return;
        CPBridgeActivityStream *live = strongSelf->_activityStreams[key];
        if (live != stream) return; // 已被淘汰
        stream.pushScheduled = NO;
        [strongSelf pushActivityLocked:stream allowEmpty:NO];
    });
}

- (void)ingestActivityLocked:(CPActivityEntry *)entry {
    CPBridgeActivityStream *stream = [self activityStreamLocked:entry.agentID taskID:entry.taskID create:YES];
    if (!stream) return;
    stream.live = YES; // 有条目进来就说明 driver 还活着
    CPBridgeActivityItem *pending = stream.pending;
    BOOL sameItem = (!pending.itemID && !entry.itemID) || [pending.itemID isEqualToString:entry.itemID];
    BOOL mergeable = pending && entry.merge != CPActivityMergeDistinct &&
                     pending.merge == entry.merge && pending.kind == entry.kind && sameItem;
    if (!mergeable) {
        // kind / item / 合并方式一变就把手里那条定稿,顺序才如实。
        [self commitPendingLocked:stream];
        pending = CPBridgeActivityItem.new;
        pending.kind = entry.kind;
        pending.merge = entry.merge;
        pending.itemID = entry.itemID;
        pending.text = [NSMutableString stringWithString:entry.text ?: @""];
        pending.detail = [NSMutableString stringWithString:entry.detail ?: @""];
        stream.pending = pending;
    } else {
        switch (entry.merge) {
            case CPActivityMergeAppendText:
                [pending.text appendString:entry.text ?: @""];
                [pending.detail appendString:entry.detail ?: @""];
                break;
            case CPActivityMergeAppendDetail:
                if (!pending.text.length && entry.text.length) [pending.text appendString:entry.text];
                [pending.detail appendString:entry.detail ?: @""];
                break;
            case CPActivityMergeReplace:
                [pending.text setString:entry.text ?: @""];
                [pending.detail setString:entry.detail ?: @""];
                break;
            case CPActivityMergeDistinct:
                break;
        }
    }
    // 合并期间就把长度压住,不让一个疯狂输出的命令把内存吃光。
    if (pending.text.length > kCPActivityMaxText) {
        [pending.text setString:CPBridgeClamp(pending.text, kCPActivityMaxText, NO)];
    }
    if (pending.detail.length > kCPActivityMaxDetail) {
        [pending.detail setString:CPBridgeClamp(pending.detail, kCPActivityMaxDetail, YES)];
    }
    pending.at = entry.at > 0 ? entry.at : NSDate.date.timeIntervalSince1970;
    [self scheduleActivityPushLocked:stream];
}

- (void)ingestActivityEntry:(CPActivityEntry *)entry {
    if (!entry.agentID.length || !entry.taskID.length) return;
    // 异步:driver 的队列不能被一条慢 SSE 连接堵住。
    [self onBridgeQueue:^{ [self ingestActivityLocked:entry]; } wait:NO];
}

- (void)flushActivityForAgentID:(NSString *)agentID taskID:(NSString *)taskID {
    [self onBridgeQueue:^{
        CPBridgeActivityStream *stream = [self activityStreamLocked:agentID taskID:taskID create:NO];
        // item 结束只是把手里那条定稿,推送仍受 250ms 闸门约束。
        if (stream) [self commitPendingLocked:stream];
    } wait:NO];
}

- (void)setActivityLive:(BOOL)live forAgentID:(NSString *)agentID {
    if (!agentID.length) return;
    [self onBridgeQueue:^{
        for (NSString *key in [self->_activityOrder copy]) {
            CPBridgeActivityStream *stream = self->_activityStreams[key];
            if (![stream.agentID isEqualToString:agentID] || stream.live == live) continue;
            stream.live = live;
            // 降级是状态变化不是吞吐,立刻告诉手机;已有条目一条都不清。
            [self pushActivityLocked:stream allowEmpty:YES];
        }
    } wait:NO];
}

- (NSInteger)activityEventCountForTesting {
    __block NSInteger count = 0;
    [self onBridgeQueue:^{ count = self->_activityEvents; } wait:YES];
    return count;
}

- (void)flushActivityNowForTesting {
    [self onBridgeQueue:^{
        for (NSString *key in [self->_activityOrder copy]) {
            [self pushActivityLocked:self->_activityStreams[key] allowEmpty:NO];
        }
    } wait:YES];
}

- (void)pingSSE {
    static const char ping[] = ":ping\n\n";
    NSArray<CPBridgeSSEClient *> *clients = [_sseClients copy];
    for (CPBridgeSSEClient *client in clients) {
        if (client.fd < 0) continue;
        if (!CPBridgeWriteAll(client.fd, ping, sizeof(ping) - 1)) [self closeSSE:client];
    }
}

- (void)watchAgents {
    NSString *sig = CPAgentsSignature([self currentAgents]) ?: @"";
    if (_lastAgentSignature && [sig isEqualToString:_lastAgentSignature]) return;
    _lastAgentSignature = sig;
    if (_sseClients.count) [self broadcastEvent:@"snapshot" json:[self snapshotDictionary]];
}

- (void)publishSnapshotNow {
    // 白名单和 canControl 不进 agent 签名,watchAgents 看不到;设置变更后由 AppDelegate 主动推一次。
    dispatch_block_t push = ^{
        if (!self->_sseClients.count) return;
        [self broadcastEvent:@"snapshot" json:[self snapshotDictionary]];
    };
    if (dispatch_get_specific(&kBridgeQueueIdent)) push();
    else dispatch_sync(_queue, push);
}

- (void)openSSE:(int)fd {
    NSString *header =
        @"HTTP/1.1 200 OK\r\n"
        @"Content-Type: text/event-stream\r\n"
        @"Cache-Control: no-cache\r\n"
        @"Connection: keep-alive\r\n"
        @"\r\n";
    NSData *headerData = [header dataUsingEncoding:NSUTF8StringEncoding];
    if (!CPBridgeWriteAll(fd, headerData.bytes, headerData.length)) {
        close(fd);
        return;
    }
    CPBridgeSSEClient *client = CPBridgeSSEClient.new;
    client.fd = fd;
    [_sseClients addObject:client];
    _lastAgentSignature = CPAgentsSignature([self currentAgents]) ?: @"";
    NSData *payload = CPBridgeJSONData([self snapshotDictionary]);
    NSString *text = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding] ?: @"{}";
    NSString *frame = [NSString stringWithFormat:@"event: snapshot\ndata: %@\n\n", text];
    NSData *data = [frame dataUsingEncoding:NSUTF8StringEncoding];
    if (!CPBridgeWriteAll(fd, data.bytes, data.length)) [self closeSSE:client];
}

- (void)handlePair:(NSData *)body fd:(int)fd {
    NSDictionary *json = [self parseJSON:body];
    NSString *code = [json[@"code"] isKindOfClass:NSString.class] ? json[@"code"] : nil;
    NSString *deviceName = [json[@"deviceName"] isKindOfClass:NSString.class] ? json[@"deviceName"] : @"手机";
    NSDictionary *result = [self.pairing pairWithCode:code deviceName:deviceName];
    int status = [result[@"status"] intValue];
    if ([result[@"ok"] boolValue]) {
        CPBridgeWriteJSON(fd, 200, @"OK", @{
            @"token": result[@"token"],
            @"deviceId": result[@"deviceId"],
            @"serverName": result[@"serverName"],
        });
        NSString *paired = deviceName.length ? deviceName : @"手机";
        dispatch_async(dispatch_get_main_queue(), ^{
            // 只带设备名,不带 token/deviceId:通知会流到 UI 层,不让凭据离开 Bridge。
            [NSNotificationCenter.defaultCenter postNotificationName:CPBridgeDevicePairedNotification
                                                             object:self
                                                           userInfo:@{@"deviceName": paired}];
        });
        return;
    }
    NSString *reason = status == 429 ? @"Too Many Requests" : @"Forbidden";
    CPBridgeWriteJSON(fd, status, reason, @{@"error": result[@"error"] ?: @"bad_code"});
}

- (void)handleCreateTodo:(NSData *)body fd:(int)fd {
    NSDictionary *json = [self parseJSON:body] ?: @{};
    NSString *opID = [json[@"opID"] isKindOfClass:NSString.class] ? json[@"opID"] : nil;
    NSDictionary *cached = [self replayOp:opID];
    if (cached) { [self writeCached:cached fd:fd]; return; }
    NSString *title = [json[@"title"] isKindOfClass:NSString.class] ? json[@"title"] : @"";
    CPTodo *todo = [self.todoStore addTodoWithTitle:title];
    if (!todo) {
        [self rememberOp:opID status:400 reason:@"Bad Request" json:@{@"error": @"empty_title"}];
        CPBridgeWriteJSON(fd, 400, @"Bad Request", @{@"error": @"empty_title"});
        return;
    }
    id payload = @{@"todo": [self todoJSON:todo]};
    [self rememberOp:opID status:200 reason:@"OK" json:payload];
    CPBridgeWriteJSON(fd, 200, @"OK", payload);
    [self notifyTodosChanged];
}

- (void)handlePatchTodo:(NSInteger)todoID body:(NSData *)body fd:(int)fd {
    NSDictionary *json = [self parseJSON:body] ?: @{};
    NSString *opID = [json[@"opID"] isKindOfClass:NSString.class] ? json[@"opID"] : nil;
    NSDictionary *cached = [self replayOp:opID];
    if (cached) { [self writeCached:cached fd:fd]; return; }
    if (![self.todoStore todoWithID:todoID]) {
        [self rememberOp:opID status:404 reason:@"Not Found" json:@{@"error": @"not_found"}];
        CPBridgeWriteJSON(fd, 404, @"Not Found", @{@"error": @"not_found"});
        return;
    }
    if (json[@"title"] && [json[@"title"] isKindOfClass:NSString.class]) {
        NSString *trimmed = [json[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!trimmed.length) {
            [self rememberOp:opID status:400 reason:@"Bad Request" json:@{@"error": @"empty_title"}];
            CPBridgeWriteJSON(fd, 400, @"Bad Request", @{@"error": @"empty_title"});
            return;
        }
        [self.todoStore updateTodo:todoID title:trimmed];
    }
    if (json[@"completed"] && [json[@"completed"] isKindOfClass:NSNumber.class]) {
        [self.todoStore setTodo:todoID completed:[json[@"completed"] boolValue]];
    }
    CPTodo *todo = [self.todoStore todoWithID:todoID];
    id payload = @{@"todo": [self todoJSON:todo]};
    [self rememberOp:opID status:200 reason:@"OK" json:payload];
    CPBridgeWriteJSON(fd, 200, @"OK", payload);
    [self notifyTodosChanged];
}

- (void)handleDeleteTodo:(NSInteger)todoID body:(NSData *)body fd:(int)fd {
    NSDictionary *json = [self parseJSON:body] ?: @{};
    NSString *opID = [json[@"opID"] isKindOfClass:NSString.class] ? json[@"opID"] : nil;
    NSDictionary *cached = [self replayOp:opID];
    if (cached) { [self writeCached:cached fd:fd]; return; }
    if (![self.todoStore todoWithID:todoID]) {
        [self rememberOp:opID status:404 reason:@"Not Found" json:@{@"error": @"not_found"}];
        CPBridgeWriteJSON(fd, 404, @"Not Found", @{@"error": @"not_found"});
        return;
    }
    [self.todoStore deleteTodo:todoID];
    id payload = @{@"ok": @YES};
    [self rememberOp:opID status:200 reason:@"OK" json:payload];
    CPBridgeWriteJSON(fd, 200, @"OK", payload);
    [self notifyTodosChanged];
}

- (NSInteger)todoIDFromPath:(NSString *)path {
    if (![path hasPrefix:@"/api/todos/"]) return NSNotFound;
    NSString *tail = [path substringFromIndex:11];
    if (!tail.length) return NSNotFound;
    NSCharacterSet *nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    if ([tail rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NSNotFound;
    return tail.integerValue;
}

static NSString *CPCommandActionJSON(CPCommandAction action) {
    switch (action) {
        case CPCommandActionStart: return @"start";
        case CPCommandActionSteer: return @"steer";
        case CPCommandActionInterrupt: return @"interrupt";
    }
}

static NSString *CPCommandStateJSON(CPCommandState state) {
    switch (state) {
        case CPCommandStateAccepted: return @"accepted";
        case CPCommandStateRunning: return @"running";
        case CPCommandStateSucceeded: return @"succeeded";
        case CPCommandStateFailed: return @"failed";
    }
}

- (NSDictionary *)commandJSON:(CPAgentCommand *)command {
    NSMutableDictionary *row = [@{
        @"commandID": command.commandID ?: @"",
        @"state": CPCommandStateJSON(command.state),
        @"action": CPCommandActionJSON(command.action),
        @"agentID": command.agentID ?: @"",
        @"taskID": command.taskID.length ? command.taskID : NSNull.null,
        @"acceptedAtMs": @((long long)llround(command.acceptedAt * 1000.0)),
        @"updatedAtMs": @((long long)llround(command.updatedAt * 1000.0)),
    } mutableCopy];
    if (command.state == CPCommandStateFailed) {
        row[@"errorMessage"] = command.errorMessage ?: @"";
    }
    return row;
}

- (BOOL)snapshotHasAgentID:(NSString *)agentID {
    if (!agentID.length) return NO;
    for (CPAgent *agent in [self currentAgents]) {
        if (agent.placeholder) continue;
        if ([agent.agentID isEqualToString:agentID]) return YES;
    }
    return NO;
}

- (NSString *)commandIDFromPath:(NSString *)path {
    if (![path hasPrefix:@"/api/commands/"]) return nil;
    NSString *tail = [path substringFromIndex:14];
    return tail.length && ![tail containsString:@"/"] ? tail : nil;
}

- (void)pruneCommands {
    while (_commandIDs.count > 100) {
        NSUInteger evict = NSNotFound;
        for (NSUInteger i = 0; i < _commandIDs.count; i++) {
            CPAgentCommand *old = _commands[_commandIDs[i]];
            if (old.state == CPCommandStateAccepted || old.state == CPCommandStateRunning) continue;
            evict = i;
            break;
        }
        if (evict == NSNotFound) break;
        NSString *oldID = _commandIDs[evict];
        [_commandIDs removeObjectAtIndex:evict];
        [_commands removeObjectForKey:oldID];
    }
}

- (void)publishCommand:(CPAgentCommand *)command {
    [self broadcastEvent:@"command" json:@{@"command": [self commandJSON:command]}];
}

- (void)finishCommand:(CPAgentCommand *)command ok:(BOOL)ok errorMessage:(NSString *)errorMessage resultTaskID:(NSString *)resultTaskID {
    if (command.state == CPCommandStateSucceeded || command.state == CPCommandStateFailed) return;
    if (resultTaskID.length) command.taskID = resultTaskID;
    command.updatedAt = NSDate.date.timeIntervalSince1970;
    if (ok) {
        command.state = CPCommandStateSucceeded;
        command.errorMessage = nil;
    } else {
        command.state = CPCommandStateFailed;
        command.errorMessage = errorMessage ?: @"";
    }
    if ([_inflightByAgent[command.agentID] isEqualToString:command.commandID]) {
        [_inflightByAgent removeObjectForKey:command.agentID];
    }
    [self publishCommand:command];
}

- (void)dispatchCommand:(CPAgentCommand *)command driver:(id<CPAgentControlDriver>)driver {
    command.state = CPCommandStateRunning;
    command.updatedAt = NSDate.date.timeIntervalSince1970;
    [self publishCommand:command];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [driver executeCommand:command completion:^(BOOL ok, NSString *errorMessage, NSString *resultTaskID) {
            CPBridgeServer *strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(strongSelf->_queue, ^{
                [strongSelf finishCommand:command ok:ok errorMessage:errorMessage resultTaskID:resultTaskID];
            });
        }];
    });
}

- (void)rejectCommand:(NSString *)opID status:(int)status reason:(NSString *)reason error:(NSString *)error fd:(int)fd {
    id json = @{@"error": error ?: @"bad_request"};
    [self rememberOp:opID status:status reason:reason json:json];
    CPBridgeWriteJSON(fd, status, reason, json);
}

- (void)handleCreateCommand:(NSData *)body headers:(NSDictionary *)headers fd:(int)fd {
    if (![self.pairing deviceCanControlWithToken:[self bearerToken:headers]]) {
        CPBridgeWriteJSON(fd, 403, @"Forbidden", @{@"error": @"control_not_permitted"});
        return;
    }
    NSDictionary *json = [self parseJSON:body] ?: @{};
    NSString *opID = [json[@"opID"] isKindOfClass:NSString.class] ? json[@"opID"] : nil;
    NSDictionary *cached = [self replayOp:opID];
    if (cached) { [self writeCached:cached fd:fd]; return; }

    NSString *actionStr = [json[@"action"] isKindOfClass:NSString.class] ? json[@"action"] : @"";
    CPCommandAction action;
    if ([actionStr isEqualToString:@"start"]) action = CPCommandActionStart;
    else if ([actionStr isEqualToString:@"steer"]) action = CPCommandActionSteer;
    else if ([actionStr isEqualToString:@"interrupt"]) action = CPCommandActionInterrupt;
    else {
        [self rejectCommand:opID status:400 reason:@"Bad Request" error:@"bad_action" fd:fd];
        return;
    }

    NSString *agentID = [json[@"agentID"] isKindOfClass:NSString.class] ? json[@"agentID"] : @"";
    agentID = [agentID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![self snapshotHasAgentID:agentID]) {
        [self rejectCommand:opID status:404 reason:@"Not Found" error:@"agent_not_found" fd:fd];
        return;
    }

    id<CPAgentControlDriver> driver = [self.controlRegistry driverForAgentID:agentID];
    if (!driver || !driver.isHealthy) {
        [self rejectCommand:opID status:503 reason:@"Service Unavailable" error:@"driver_unavailable" fd:fd];
        return;
    }

    NSString *taskID = [json[@"taskID"] isKindOfClass:NSString.class] ? json[@"taskID"] : nil;
    taskID = [taskID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (action != CPCommandActionStart && !taskID.length) {
        [self rejectCommand:opID status:400 reason:@"Bad Request" error:@"missing_task" fd:fd];
        return;
    }

    NSString *text = [json[@"text"] isKindOfClass:NSString.class] ? json[@"text"] : @"";
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (action != CPCommandActionInterrupt && !trimmed.length) {
        [self rejectCommand:opID status:400 reason:@"Bad Request" error:@"empty_text" fd:fd];
        return;
    }

    NSString *resolvedWorkdir = nil;
    NSString *resolvedWorkdirName = nil;
    if (action == CPCommandActionStart) {
        NSString *workdirID = [json[@"workdirID"] isKindOfClass:NSString.class] ? json[@"workdirID"] : nil;
        workdirID = [workdirID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!workdirID.length) {
            [self rejectCommand:opID status:400 reason:@"Bad Request" error:@"missing_workdir" fd:fd];
            return;
        }
        CPWorkdirEntry *entry = [self.workdirStore entryWithID:workdirID];
        resolvedWorkdir = entry.path;
        if (!resolvedWorkdir.length) {
            [self rejectCommand:opID status:400 reason:@"Bad Request" error:@"unknown_workdir" fd:fd];
            return;
        }
        // 项目显示名跟着走:driver 折叠活动流时用它把绝对路径前缀换成项目名。
        resolvedWorkdirName = entry.name;
    }

    NSString *resolvedModelID = nil;
    if (action == CPCommandActionStart) {
        NSString *modelID = [json[@"modelID"] isKindOfClass:NSString.class] ? json[@"modelID"] : nil;
        modelID = [modelID stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (modelID.length) {
            BOOL known = NO;
            for (CPAgentModel *model in driver.availableModels ?: @[]) {
                if ([model.modelID isEqualToString:modelID]) { known = YES; break; }
            }
            if (!known) {
                [self rejectCommand:opID status:400 reason:@"Bad Request" error:@"unknown_model" fd:fd];
                return;
            }
            resolvedModelID = modelID;
        }
    }

    if (action != CPCommandActionStart && ![driver isManagedTaskID:taskID]) {
        [self rejectCommand:opID status:409 reason:@"Conflict" error:@"not_managed" fd:fd];
        return;
    }

    // 打断是急停,不受忙碌闸门约束:被挡住的恰好是最该打断的那种情况(start 正跑着)。
    if (action != CPCommandActionInterrupt && _inflightByAgent[agentID]) {
        [self rejectCommand:opID status:409 reason:@"Conflict" error:@"busy" fd:fd];
        return;
    }

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    CPAgentCommand *command = CPAgentCommand.new;
    command.commandID = NSUUID.UUID.UUIDString.lowercaseString;
    command.action = action;
    command.agentID = agentID;
    command.taskID = action == CPCommandActionStart ? nil : taskID;
    command.text = action == CPCommandActionInterrupt ? nil : trimmed;
    command.workdir = resolvedWorkdir;
    command.workdirName = resolvedWorkdirName;
    command.modelID = resolvedModelID;
    command.state = CPCommandStateAccepted;
    command.acceptedAt = now;
    command.updatedAt = now;
    _commands[command.commandID] = command;
    [_commandIDs addObject:command.commandID];
    // 打断不占在飞槽位,否则会顶掉正跑着那条 start 的记账,start 结束时就清不干净。
    if (action != CPCommandActionInterrupt) _inflightByAgent[agentID] = command.commandID;
    [self pruneCommands];
    id payload = @{@"command": [self commandJSON:command]};
    [self rememberOp:opID status:202 reason:@"Accepted" json:payload];
    [self publishCommand:command];
    CPBridgeWriteJSON(fd, 202, @"Accepted", payload);
    [self dispatchCommand:command driver:driver];
}

- (void)handleGetCommand:(NSString *)commandID fd:(int)fd {
    CPAgentCommand *command = _commands[commandID];
    if (!command) {
        CPBridgeWriteJSON(fd, 404, @"Not Found", @{@"error": @"not_found"});
        return;
    }
    CPBridgeWriteJSON(fd, 200, @"OK", @{@"command": [self commandJSON:command]});
}

- (void)routeMethod:(NSString *)method path:(NSString *)rawPath headers:(NSDictionary *)headers body:(NSData *)body fd:(int)fd {
    NSString *query = nil;
    NSString *path = [self splitPath:rawPath query:&query];
    BOOL isStatic = [method isEqualToString:@"GET"] && ([path isEqualToString:@"/"] || [path hasPrefix:@"/assets/"]);
    BOOL isHealth = [method isEqualToString:@"GET"] && [path isEqualToString:@"/api/health"];
    BOOL isPair = [method isEqualToString:@"POST"] && [path isEqualToString:@"/api/pair"];
    if (isHealth) {
        CPBridgeWriteJSON(fd, 200, @"OK", @{
            @"ok": @YES,
            @"serverName": @"澜台",
            @"appVersion": [self appVersion],
            @"protocol": @1,
        });
        close(fd);
        return;
    }
    if (isStatic) {
        if (![self serveStaticPath:path fd:fd]) {
            CPBridgeWriteResponse(fd, 404, @"Not Found", @"text/plain; charset=utf-8",
                                  [@"not found" dataUsingEncoding:NSUTF8StringEncoding]);
        }
        close(fd);
        return;
    }
    if (isPair) {
        [self handlePair:body fd:fd];
        close(fd);
        return;
    }
    BOOL authed = [self authorized:headers];
    BOOL isEvents = [method isEqualToString:@"GET"] && [path isEqualToString:@"/api/events"];
    if (!authed && isEvents) {
        authed = [self.pairing isTokenValid:[self queryValue:query name:@"token"]];
    }
    if (!authed) {
        CPBridgeWriteJSON(fd, 401, @"Unauthorized", @{@"error": @"unauthorized"});
        close(fd);
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/snapshot"]) {
        CPBridgeWriteJSON(fd, 200, @"OK", [self snapshotDictionary]);
        close(fd);
        return;
    }
    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/api/events"]) {
        [self openSSE:fd];
        return;
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/commands"]) {
        [self handleCreateCommand:body headers:headers fd:fd];
        close(fd);
        return;
    }
    NSString *commandID = [self commandIDFromPath:path];
    if (commandID && [method isEqualToString:@"GET"]) {
        [self handleGetCommand:commandID fd:fd];
        close(fd);
        return;
    }
    if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/api/todos"]) {
        [self handleCreateTodo:body fd:fd];
        close(fd);
        return;
    }
    NSInteger todoID = [self todoIDFromPath:path];
    if (todoID != NSNotFound && [method isEqualToString:@"PATCH"]) {
        [self handlePatchTodo:todoID body:body fd:fd];
        close(fd);
        return;
    }
    if (todoID != NSNotFound && [method isEqualToString:@"DELETE"]) {
        [self handleDeleteTodo:todoID body:body fd:fd];
        close(fd);
        return;
    }
    CPBridgeWriteJSON(fd, 404, @"Not Found", @{@"error": @"not_found"});
    close(fd);
}

- (void)handleConnection:(int)fd {
    NSString *method = nil, *path = nil;
    NSDictionary *headers = nil;
    NSData *body = nil;
    if (!CPBridgeReadRequest(fd, &method, &path, &headers, &body)) {
        close(fd);
        return;
    }
    dispatch_sync(_queue, ^{
        [self routeMethod:method path:path headers:headers body:body fd:fd];
    });
}

- (dispatch_source_t)timerWithInterval:(NSTimeInterval)interval handler:(dispatch_block_t)handler {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
                              (uint64_t)(interval * NSEC_PER_SEC), (uint64_t)(0.1 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(timer, handler);
    dispatch_resume(timer);
    return timer;
}

- (BOOL)start {
    if (_running) return YES;
    int fd = -1;
    NSInteger bound = 0;
    if (self.portMin <= 0) {
        fd = CPBridgeListenSocket(self.loopbackOnly, 0);
        if (fd >= 0) bound = CPBridgeBoundPort(fd);
    } else {
        NSInteger maxPort = self.portMax >= self.portMin ? self.portMax : self.portMin;
        for (NSInteger port = self.portMin; port <= maxPort; port++) {
            fd = CPBridgeListenSocket(self.loopbackOnly, (int)port);
            if (fd >= 0) { bound = port; break; }
        }
    }
    if (fd < 0) {
        NSLog(@"[CPBridge] no free port in %ld–%ld", (long)self.portMin, (long)self.portMax);
        return NO;
    }
    _listenFD = fd;
    _port = bound;
    _running = YES;
    if (self.persistPort) {
        [NSUserDefaults.standardUserDefaults setInteger:bound forKey:CPBridgePortDefaultsKey];
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(_acceptQueue, ^{
        // 阻塞 accept 放在独立队列:主状态队列不能被连接卡住,dispatch_source 在自测无 runloop 时不可靠.
        while (YES) {
            CPBridgeServer *strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_running || strongSelf->_listenFD < 0) break;
            int cfd = accept(strongSelf->_listenFD, NULL, NULL);
            if (cfd < 0) {
                if (errno == EINTR) continue;
                break;
            }
            int yes = 1;
            setsockopt(cfd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
            CPBridgeApplyIOTimeouts(cfd);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                [strongSelf handleConnection:cfd];
            });
        }
    });
    _pingTimer = [self timerWithInterval:20.0 handler:^{ [weakSelf pingSSE]; }];
    _watchTimer = [self timerWithInterval:2.0 handler:^{ [weakSelf watchAgents]; }];
    NSLog(@"[CPBridge] listening on %@:%ld", self.loopbackOnly ? @"127.0.0.1" : @"0.0.0.0", (long)bound);
    return YES;
}

- (void)stop {
    if (!_running && _listenFD < 0) return;
    _running = NO;
    int fd = _listenFD;
    _listenFD = -1;
    if (fd >= 0) {
        shutdown(fd, SHUT_RDWR);
        close(fd);
    }
    dispatch_sync(_acceptQueue, ^{});
    dispatch_block_t tearDown = ^{
        if (self->_pingTimer) { dispatch_source_cancel(self->_pingTimer); self->_pingTimer = nil; }
        if (self->_watchTimer) { dispatch_source_cancel(self->_watchTimer); self->_watchTimer = nil; }
        NSArray<CPBridgeSSEClient *> *clients = [self->_sseClients copy];
        for (CPBridgeSSEClient *client in clients) [self closeSSE:client];
    };
    if (dispatch_get_specific(&kBridgeQueueIdent)) tearDown();
    else dispatch_sync(_queue, tearDown);
}

- (NSInteger)port { return _port; }
- (BOOL)running { return _running; }

- (int)firstSSEFileDescriptorForTesting {
    __block int fd = -1;
    dispatch_block_t readFd = ^{
        CPBridgeSSEClient *client = self->_sseClients.firstObject;
        fd = client ? client.fd : -1;
    };
    if (dispatch_get_specific(&kBridgeQueueIdent)) readFd();
    else dispatch_sync(_queue, readFd);
    return fd;
}

@end
