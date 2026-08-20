#import "CPQuota.h"
#import <sqlite3.h>

#pragma mark - 窗口标题与文案

NSString *CPQuotaTitleForMinutes(NSInteger minutes) {
    if (minutes <= 0) return @"额度";
    if (minutes >= 270 && minutes <= 330) return @"5小时";          // 5h ± 30min
    if (minutes >= 10020 && minutes <= 10140) return @"周";         // 7d ± 1h
    if (minutes >= 40000 && minutes <= 46000) return @"月";
    if (minutes % (24 * 60) == 0) {
        NSInteger days = minutes / (24 * 60);
        return [NSString stringWithFormat:@"%ld天", (long)days];
    }
    if (minutes % 60 == 0) {
        NSInteger hours = minutes / 60;
        return [NSString stringWithFormat:@"%ld小时", (long)hours];
    }
    return [NSString stringWithFormat:@"%ld分钟", (long)minutes];
}

NSString *CPQuotaResetPhrase(NSDate *resetsAt, NSDate *now) {
    if (!resetsAt) return @"";
    NSDate *ref = now ?: NSDate.date;
    NSTimeInterval delta = [resetsAt timeIntervalSinceDate:ref];
    if (delta <= 0) return @"已重置";
    if (delta < 3600) {
        NSInteger minutes = MAX(1, (NSInteger)llround(delta / 60.0));
        return [NSString stringWithFormat:@"%ld分钟后重置", (long)minutes];
    }
    if (delta < 48 * 3600) {
        NSInteger hours = MAX(1, (NSInteger)llround(delta / 3600.0));
        return [NSString stringWithFormat:@"%ld小时后重置", (long)hours];
    }
    NSInteger days = MAX(1, (NSInteger)llround(delta / 86400.0));
    return [NSString stringWithFormat:@"%ld天后重置", (long)days];
}

static NSString *CPQuotaWindowsLine(NSArray<CPQuotaWindow *> *windows, NSDate *now, BOOL includeReset) {
    if (!windows.count) return @"";
    NSMutableArray<NSString *> *parts = NSMutableArray.array;
    for (CPQuotaWindow *window in windows) {
        NSString *title = window.title.length ? window.title : @"额度";
        [parts addObject:[NSString stringWithFormat:@"%@ %.0f%%", title, window.usedPercent]];
    }
    NSString *line = [parts componentsJoinedByString:@" · "];
    if (includeReset && windows.firstObject.resetsAt) {
        NSString *reset = CPQuotaResetPhrase(windows.firstObject.resetsAt, now);
        if (reset.length) line = [line stringByAppendingFormat:@" · %@", reset];
    }
    return line;
}

NSString *CPQuotaCompactLine(CPQuotaSnapshot *snapshot) {
    if (!snapshot) return @"";
    if (snapshot.health == CPAgentHealthMissing) return @"额度不可用";
    return CPQuotaWindowsLine(snapshot.windows, snapshot.updatedAt ?: NSDate.date, YES);
}

NSString *CPQuotaMenuTitle(NSString *agentName, CPQuotaSnapshot *snapshot) {
    if (!snapshot) return nil;
    NSString *name = agentName.length ? agentName : @"Agent";
    if (snapshot.health == CPAgentHealthMissing) {
        return [NSString stringWithFormat:@"%@  额度不可用", name];
    }
    NSString *body = CPQuotaWindowsLine(snapshot.windows, snapshot.updatedAt ?: NSDate.date, YES);
    if (!body.length) return [NSString stringWithFormat:@"%@  额度不可用", name];
    return [NSString stringWithFormat:@"%@  %@", name, body];
}

#pragma mark - 解析辅助

static id CPQuotaValue(NSDictionary *dict, NSString *camel, NSString *snake) {
    if (!dict) return nil;
    id value = dict[camel];
    if (value) return value;
    return snake.length ? dict[snake] : nil;
}

static double CPQuotaDouble(id value, BOOL *ok) {
    if (ok) *ok = NO;
    if ([value isKindOfClass:NSNumber.class]) {
        if (ok) *ok = YES;
        return [(NSNumber *)value doubleValue];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!text.length) return 0;
        if (ok) *ok = YES;
        return text.doubleValue;
    }
    return 0;
}

static NSInteger CPQuotaInteger(id value) {
    if ([value isKindOfClass:NSNumber.class]) return [(NSNumber *)value integerValue];
    if ([value isKindOfClass:NSString.class]) return [(NSString *)value integerValue];
    return 0;
}

static NSDate *CPQuotaDateFromUnix(id value) {
    if (!value || value == NSNull.null) return nil;
    double seconds = CPQuotaDouble(value, NULL);
    if (seconds <= 0) return nil;
    if (seconds > 1e12) seconds /= 1000.0; // 毫秒
    return [NSDate dateWithTimeIntervalSince1970:seconds];
}

static NSDate *CPQuotaDateFromISO(NSString *value) {
    if (!value.length) return nil;
    static NSISO8601DateFormatter *fractional;
    static NSISO8601DateFormatter *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = NSISO8601DateFormatter.new;
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = NSISO8601DateFormatter.new;
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [fractional dateFromString:value] ?: [plain dateFromString:value];
}

static CPQuotaWindow *CPQuotaWindowMake(NSString *windowID, NSInteger minutes, double usedPercent, NSDate *resetsAt) {
    CPQuotaWindow *window = CPQuotaWindow.new;
    window.windowID = windowID;
    window.windowMinutes = minutes;
    window.usedPercent = MAX(0.0, MIN(100.0, usedPercent));
    window.resetsAt = resetsAt;
    window.title = CPQuotaTitleForMinutes(minutes);
    return window;
}

static NSInteger CPQuotaMinutesFromKimiWindow(NSDictionary *window) {
    if (![window isKindOfClass:NSDictionary.class]) return 0;
    NSInteger duration = CPQuotaInteger(window[@"duration"]);
    NSString *unit = [window[@"timeUnit"] isKindOfClass:NSString.class] ? window[@"timeUnit"] : @"";
    if (duration <= 0) return 0;
    if ([unit isEqualToString:@"TIME_UNIT_MINUTE"]) return duration;
    if ([unit isEqualToString:@"TIME_UNIT_HOUR"]) return duration * 60;
    if ([unit isEqualToString:@"TIME_UNIT_DAY"]) return duration * 24 * 60;
    return 0;
}

static double CPQuotaPercentFromDetail(NSDictionary *detail, double fallbackRatio, BOOL *ok) {
    if (ok) *ok = NO;
    // ratio 优先:0.1524 比 used=15/limit=100 更准。负数表示没有 ratio。
    if (fallbackRatio >= 0 && fallbackRatio <= 1.0001) {
        if (ok) *ok = YES;
        return fallbackRatio * 100.0;
    }
    if (![detail isKindOfClass:NSDictionary.class]) return 0;
    BOOL limitOK = NO, usedOK = NO;
    double limit = CPQuotaDouble(detail[@"limit"], &limitOK);
    double used = CPQuotaDouble(detail[@"used"], &usedOK);
    if (limitOK && usedOK && limit > 0) {
        if (ok) *ok = YES;
        return used / limit * 100.0;
    }
    BOOL remainOK = NO;
    double remaining = CPQuotaDouble(detail[@"remaining"], &remainOK);
    if (limitOK && remainOK && limit > 0) {
        if (ok) *ok = YES;
        return (limit - remaining) / limit * 100.0;
    }
    return 0;
}

#pragma mark - Codex

CPQuotaSnapshot *CPQuotaFromCodexRateLimits(NSDictionary *payload, NSString *agentID, NSDate *now) {
    if (![payload isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *root = payload[@"rateLimits"];
    if (![root isKindOfClass:NSDictionary.class]) root = payload[@"rate_limits"];
    if (![root isKindOfClass:NSDictionary.class]) root = payload;
    NSDictionary *primary = CPQuotaValue(root, @"primary", @"primary");
    if (![primary isKindOfClass:NSDictionary.class]) {
        primary = CPQuotaValue(root, @"primaryWindow", @"primary_window");
    }
    NSDictionary *secondary = CPQuotaValue(root, @"secondary", @"secondary");
    if (![secondary isKindOfClass:NSDictionary.class]) {
        secondary = CPQuotaValue(root, @"secondaryWindow", @"secondary_window");
    }

    NSMutableArray<CPQuotaWindow *> *windows = NSMutableArray.array;
    void (^addWindow)(NSDictionary *, NSString *) = ^(NSDictionary *src, NSString *fallbackID) {
        if (![src isKindOfClass:NSDictionary.class]) return;
        BOOL percentOK = NO;
        double percent = CPQuotaDouble(CPQuotaValue(src, @"usedPercent", @"used_percent"), &percentOK);
        NSInteger minutes = CPQuotaInteger(CPQuotaValue(src, @"windowDurationMins", @"window_minutes"));
        if (minutes <= 0) {
            NSInteger seconds = CPQuotaInteger(CPQuotaValue(src, @"limitWindowSeconds", @"limit_window_seconds"));
            if (seconds > 0) minutes = seconds / 60;
        }
        NSDate *resets = CPQuotaDateFromUnix(CPQuotaValue(src, @"resetsAt", @"resets_at"));
        if (!resets) resets = CPQuotaDateFromUnix(CPQuotaValue(src, @"resetAt", @"reset_at"));
        if (!percentOK && minutes <= 0) return;
        NSString *windowID = minutes >= 10020 && minutes <= 10140 ? @"weekly" :
                             (minutes >= 270 && minutes <= 330 ? @"session" : fallbackID);
        [windows addObject:CPQuotaWindowMake(windowID, minutes > 0 ? minutes : 0, percentOK ? percent : 0, resets)];
    };
    addWindow(primary, @"primary");
    addWindow(secondary, @"session");
    if (!windows.count) return nil;

    CPQuotaSnapshot *snapshot = CPQuotaSnapshot.new;
    snapshot.agentID = agentID.length ? agentID : @"codex";
    snapshot.health = CPAgentHealthOK;
    snapshot.windows = windows;
    snapshot.updatedAt = now ?: NSDate.date;
    return snapshot;
}

#pragma mark - Kimi

CPQuotaSnapshot *CPQuotaFromKimiResponses(NSDictionary *usages, NSDictionary *stats, NSString *agentID, NSDate *now) {
    NSMutableArray<CPQuotaWindow *> *windows = NSMutableArray.array;
    NSDictionary *coding = nil;
    NSArray *usageList = usages[@"usages"];
    if ([usageList isKindOfClass:NSArray.class]) {
        for (NSDictionary *item in usageList) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            if ([item[@"scope"] isEqualToString:@"FEATURE_CODING"]) { coding = item; break; }
        }
        if (!coding && usageList.count) {
            id first = usageList.firstObject;
            if ([first isKindOfClass:NSDictionary.class]) coding = first;
        }
    }

    NSDictionary *weeklyLimit = nil;
    if ([stats isKindOfClass:NSDictionary.class]) {
        id value = stats[@"ratelimitCode7d"];
        if ([value isKindOfClass:NSDictionary.class]) weeklyLimit = value;
    }

    NSDictionary *detail = [coding[@"detail"] isKindOfClass:NSDictionary.class] ? coding[@"detail"] : nil;
    BOOL weeklyOK = NO;
    double weeklyRatio = -1;
    if (weeklyLimit) {
        BOOL ratioOK = NO;
        double ratio = CPQuotaDouble(weeklyLimit[@"ratio"], &ratioOK);
        if (ratioOK) weeklyRatio = ratio;
    }
    double weeklyPercent = CPQuotaPercentFromDetail(detail, weeklyRatio, &weeklyOK);
    NSDate *weeklyReset = CPQuotaDateFromISO(detail[@"resetTime"]);
    if (!weeklyReset && weeklyLimit) weeklyReset = CPQuotaDateFromISO(weeklyLimit[@"resetTime"]);
    if (weeklyOK) {
        [windows addObject:CPQuotaWindowMake(@"weekly", 10080, weeklyPercent, weeklyReset)];
    }

    NSArray *limits = coding[@"limits"];
    if ([limits isKindOfClass:NSArray.class] && limits.count) {
        NSDictionary *rate = [limits.firstObject isKindOfClass:NSDictionary.class] ? limits.firstObject : nil;
        NSDictionary *rateDetail = [rate[@"detail"] isKindOfClass:NSDictionary.class] ? rate[@"detail"] : nil;
        NSInteger minutes = CPQuotaMinutesFromKimiWindow(rate[@"window"]);
        if (minutes <= 0) minutes = 300;
        BOOL rateOK = NO;
        double ratePercent = CPQuotaPercentFromDetail(rateDetail, -1, &rateOK);
        if (rateOK) {
            NSDate *rateReset = CPQuotaDateFromISO(rateDetail[@"resetTime"]);
            [windows insertObject:CPQuotaWindowMake(@"session", minutes, ratePercent, rateReset) atIndex:0];
        }
    }

    if ([stats isKindOfClass:NSDictionary.class]) {
        NSDictionary *balance = stats[@"subscriptionBalance"];
        if ([balance isKindOfClass:NSDictionary.class]) {
            BOOL ratioOK = NO;
            double ratio = CPQuotaDouble(balance[@"amountUsedRatio"], &ratioOK);
            if (ratioOK) {
                NSDate *expire = CPQuotaDateFromISO(balance[@"expireTime"]);
                [windows addObject:CPQuotaWindowMake(@"monthly", 43200, ratio * 100.0, expire)];
            }
        }
    }

    CPQuotaSnapshot *snapshot = CPQuotaSnapshot.new;
    snapshot.agentID = agentID.length ? agentID : @"kimi";
    snapshot.updatedAt = now ?: NSDate.date;
    snapshot.windows = windows;
    snapshot.health = windows.count ? CPAgentHealthOK : CPAgentHealthMissing;
    return snapshot;
}

#pragma mark - Kimi 取数

static NSString *CPKimiCookiesPath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"CP_KIMI_COOKIES"];
    if (override.length) return override;
    return [NSHomeDirectory() stringByAppendingPathComponent:
            @"Library/Application Support/kimi-desktop/Cookies"];
}

NSString *CPKimiDesktopAuthToken(void) {
    NSString *path = CPKimiCookiesPath();
    sqlite3 *db = NULL;
    NSString *uri = [NSString stringWithFormat:@"file:%@?mode=ro", path];
    if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
        if (db) sqlite3_close(db);
        return nil;
    }
    sqlite3_busy_timeout(db, 150);
    const char *sql =
        "SELECT value FROM cookies "
        "WHERE name='kimi-auth' AND host_key IN ('www.kimi.com','.www.kimi.com','.kimi.com','kimi.com') "
        "AND length(value) > 0 "
        "ORDER BY last_access_utc DESC LIMIT 1";
    sqlite3_stmt *stmt = NULL;
    NSString *token = nil;
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK &&
        sqlite3_step(stmt) == SQLITE_ROW &&
        sqlite3_column_text(stmt, 0)) {
        token = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(stmt, 0)];
        token = [token stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!token.length) token = nil;
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return token;
}

static NSDictionary *CPKimiJWTPayload(NSString *token) {
    NSArray<NSString *> *parts = [token componentsSeparatedByString:@"."];
    if (parts.count < 2) return nil;
    NSString *payload = parts[1];
    payload = [[payload stringByReplacingOccurrencesOfString:@"-" withString:@"+"]
               stringByReplacingOccurrencesOfString:@"_" withString:@"/"];
    while (payload.length % 4 != 0) payload = [payload stringByAppendingString:@"="];
    NSData *data = [[NSData alloc] initWithBase64EncodedString:payload options:0];
    if (!data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static NSDictionary *CPKimiPOST(NSString *urlString, NSDictionary *body, NSString *token, NSDictionary *claims) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !token.length) return nil;
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = @"POST";
    req.timeoutInterval = 10;
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:nil];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", token] forHTTPHeaderField:@"Authorization"];
    [req setValue:[NSString stringWithFormat:@"kimi-auth=%@", token] forHTTPHeaderField:@"Cookie"];
    [req setValue:@"https://www.kimi.com" forHTTPHeaderField:@"Origin"];
    [req setValue:@"https://www.kimi.com/code/console" forHTTPHeaderField:@"Referer"];
    [req setValue:@"1" forHTTPHeaderField:@"connect-protocol-version"];
    [req setValue:@"zh-CN" forHTTPHeaderField:@"x-language"];
    [req setValue:@"web" forHTTPHeaderField:@"x-msh-platform"];
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36" forHTTPHeaderField:@"User-Agent"];
    NSString *device = [claims[@"device_id"] isKindOfClass:NSString.class] ? claims[@"device_id"] : nil;
    NSString *ssid = [claims[@"ssid"] isKindOfClass:NSString.class] ? claims[@"ssid"] : nil;
    NSString *sub = [claims[@"sub"] isKindOfClass:NSString.class] ? claims[@"sub"] : nil;
    if (device.length) [req setValue:device forHTTPHeaderField:@"x-msh-device-id"];
    if (ssid.length) [req setValue:ssid forHTTPHeaderField:@"x-msh-session-id"];
    if (sub.length) [req setValue:sub forHTTPHeaderField:@"x-traffic-id"];

    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    __block NSData *data = nil;
    __block NSInteger status = 0;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        (void)e;
        data = d;
        status = [r isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)r).statusCode : 0;
        dispatch_semaphore_signal(sem);
    }] resume];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC));
    if (status != 200 || !data.length) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

static CPQuotaSnapshot *CPKimiMissingSnapshot(void) {
    CPQuotaSnapshot *snapshot = CPQuotaSnapshot.new;
    snapshot.agentID = @"kimi";
    snapshot.health = CPAgentHealthMissing;
    snapshot.windows = NSMutableArray.array;
    snapshot.updatedAt = NSDate.date;
    return snapshot;
}

CPQuotaSnapshot *CPKimiFetchQuotaSnapshot(void) {
    NSString *token = CPKimiDesktopAuthToken();
    if (!token.length) return CPKimiMissingSnapshot();
    NSDictionary *claims = CPKimiJWTPayload(token);
    NSDictionary *usages = CPKimiPOST(
        @"https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages",
        @{ @"scope": @[ @"FEATURE_CODING" ] }, token, claims);
    NSDictionary *stats = CPKimiPOST(
        @"https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats",
        @{}, token, claims);
    CPQuotaSnapshot *snapshot = CPQuotaFromKimiResponses(usages, stats, @"kimi", NSDate.date);
    return snapshot ?: CPKimiMissingSnapshot();
}
