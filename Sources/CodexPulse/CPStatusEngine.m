#import "CPStatusEngine.h"
#import "CPReviewStore.h"

#pragma mark - Constants

BOOL CPRunningSelfTests = NO;
BOOL CPTodoUseIsolatedStore = NO; // 仅 --ui-self-test:Todo 用临时库,不读写用户真实待办

// 高对比通道调整：亮通道更亮、暗通道更暗，提高对比度。
CGFloat CPContrastAdjustChannel(CGFloat v) {
    return v >= 0.5 ? MIN(1.0, v + 0.12) : MAX(0.0, v * 0.72);
}

// 动态颜色：按 effectiveAppearance 区分浅色/深色，并在高对比模式下提高对比。
NSColor *CPDyn(CGFloat lr, CGFloat lg, CGFloat lb, CGFloat dr, CGFloat dg, CGFloat db) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        BOOL dark = [match isEqualToString:NSAppearanceNameDarkAqua];
        CGFloat r = dark ? dr : lr, g = dark ? dg : lg, b = dark ? db : lb;
        if (NSWorkspace.sharedWorkspace.accessibilityDisplayShouldIncreaseContrast) {
            r = CPContrastAdjustChannel(r);
            g = CPContrastAdjustChannel(g);
            b = CPContrastAdjustChannel(b);
        }
        return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1.0];
    }];
}

// 主基调为深石墨/深海军蓝：工作台、HUD、Dock 三处窗口始终深色，不随系统浅色外观变白。
// CPDyn 的 light 槽即深色主基调（CGColor 快照与浅色外观下也保持深色），dark 槽为 DarkAqua 下的微调。
NSColor *CPAccent(void) { return CPDyn(0.320, 0.500, 1.000, 0.400, 0.560, 1.000); }
NSColor *CPBg(void) { return CPDyn(0.093, 0.102, 0.133, 0.075, 0.082, 0.110); }
NSColor *CPSurface(void) { return CPDyn(0.145, 0.155, 0.196, 0.125, 0.133, 0.172); }
NSColor *CPBorder(void) { return CPDyn(0.300, 0.315, 0.375, 0.335, 0.350, 0.410); }
NSColor *CPFg(void) { return CPDyn(0.930, 0.930, 0.945, 0.950, 0.950, 0.960); }
NSColor *CPFg2(void) { return CPDyn(0.740, 0.745, 0.775, 0.780, 0.780, 0.810); }
NSColor *CPMuted(void) { return CPDyn(0.580, 0.585, 0.620, 0.620, 0.625, 0.660); }
// 状态色：饱和度调高，在深石墨/深海军蓝底上清晰可见。
NSColor *CPBlue(void) { return CPDyn(0.420, 0.590, 1.000, 0.480, 0.640, 1.000); }
NSColor *CPOrange(void) { return CPDyn(1.000, 0.620, 0.240, 1.000, 0.660, 0.300); }
NSColor *CPRed(void) { return CPDyn(1.000, 0.420, 0.430, 1.000, 0.470, 0.480); }
NSColor *CPGreen(void) { return CPDyn(0.330, 0.860, 0.450, 0.380, 0.890, 0.500); }
// 8% 白色 hairline(对齐原型 --hairline: rgba(255,255,255,.08)):B 版待办卡片、输入框等
// 嵌入式描边专用,比 CPBorder 柔和一档。不改全局 CPBorder,控件描边语义保持不变。
NSColor *CPHairline(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        NSString *match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
        BOOL dark = [match isEqualToString:NSAppearanceNameDarkAqua];
        return [NSColor colorWithSRGBRed:1.0 green:1.0 blue:1.0 alpha:dark ? 0.08 : 0.10];
    }];
}

#pragma mark - Status

NSString *CPStatusTitle(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return @"工作中";
        case CPStatusWaiting: return @"等待中";
        case CPStatusAttention: return @"需关注";
        case CPStatusCompleted: return @"已就绪";
        case CPStatusFailed: return @"失败";
        case CPStatusIdle: return @"空闲";
    }
}

NSString *CPStatusSymbol(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return @"sparkles";
        case CPStatusWaiting: return @"pause.fill";
        case CPStatusAttention: return @"exclamationmark.bubble.fill";
        case CPStatusCompleted: return @"checkmark.circle.fill";
        case CPStatusFailed: return @"xmark.octagon.fill";
        case CPStatusIdle: return @"moon.zzz.fill";
    }
}

NSColor *CPStatusColor(CPStatus s) {
    switch (s) {
        case CPStatusWorking: return CPBlue();
        case CPStatusWaiting: return CPOrange();
        case CPStatusAttention: return CPDyn(1.000, 0.560, 0.220, 1.000, 0.600, 0.270);
        case CPStatusCompleted: return CPGreen();
        case CPStatusFailed: return CPRed();
        case CPStatusIdle: return CPMuted();
    }
}

NSImage *CPDotImage(CGFloat size, NSColor *color) {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(size, size)];
    [img lockFocus];
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(0, 0, size, size)] fill];
    [img unlockFocus];
    return img;
}

NSImage *CPStatusDot(CGFloat size, CPStatus status) { return CPDotImage(size, CPStatusColor(status)); }

NSDate *CPDateFromMillis(sqlite3_int64 v) { return v <= 0 ? NSDate.date : [NSDate dateWithTimeIntervalSince1970:v / 1000.0]; }
NSDate *CPDateFromSeconds(NSTimeInterval v) { return v <= 0 ? nil : [NSDate dateWithTimeIntervalSince1970:v]; }

// 用 Codex rollout 的真实生命周期判断，而不是在调试日志正文里做关键词搜索。
// task_complete 持续为已完成，直到下一次 task_started；黄色只来自尚未返回的审批/输入调用。
CPStatus CPInferTaskStatus(NSDate *lastLog, NSDate *lastStarted, NSDate *lastComplete,
                                  BOOL attentionPending, NSDate *lastError, NSDate *now) {
    if (attentionPending) return CPStatusAttention;
    BOOL activeTurn = lastStarted && (!lastComplete || [lastStarted compare:lastComplete] == NSOrderedDescending);
    if (activeTurn) {
        BOOL unresolvedError = lastError && [lastError compare:lastStarted] != NSOrderedAscending &&
                               (!lastLog || [lastError compare:lastLog] != NSOrderedAscending);
        if (unresolvedError) return CPStatusFailed;
        return CPStatusWorking;
    }
    if (lastComplete && (!lastStarted || [lastComplete compare:lastStarted] != NSOrderedAscending)) return CPStatusCompleted;
    if (lastLog && [now timeIntervalSinceDate:lastLog] < 12) return CPStatusWorking;
    return CPStatusIdle;
}

NSInteger CPStatusTiePriority(CPStatus status) {
    switch (status) {
        case CPStatusFailed: return 5;
        case CPStatusAttention: return 4;
        case CPStatusWaiting: return 3;
        case CPStatusCompleted: return 2;
        case CPStatusWorking: return 1;
        case CPStatusIdle: return 0;
    }
}

NSString *CPCleanTitle(const unsigned char *text) {
    if (!text) return @"未命名任务";
    NSString *value = [NSString stringWithUTF8String:(const char *)text] ?: @"未命名任务";

    // 1) 移除成对的 XML 块(如 <in-app-browser-context>…</in-app-browser-context>),含跨行内容。
    NSRegularExpression *blockRe = [NSRegularExpression regularExpressionWithPattern:@"<([A-Za-z][\\w-]*)[^>]*>.*?</\\1>"
                                                                           options:NSRegularExpressionDotMatchesLineSeparators
                                                                             error:nil];
    value = [blockRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@" "];
    // 2) 移除不成对的残留标签。
    NSRegularExpression *tagRe = [NSRegularExpression regularExpressionWithPattern:@"</?[A-Za-z][^>]*>" options:0 error:nil];
    value = [tagRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@" "];
    // 2.5) Markdown 链接 [label](url) / [label](url "title") 只保留可读 label;裸 chatgpt-conversation:// URI 直接移除。
    NSRegularExpression *mdLinkRe = [NSRegularExpression regularExpressionWithPattern:@"\\[([^\\]]*)\\]\\([^)\\s]+(?:\\s+\"[^\"]*\")?\\)" options:0 error:nil];
    value = [mdLinkRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@"$1"];
    NSRegularExpression *uriRe = [NSRegularExpression regularExpressionWithPattern:@"chatgpt-conversation://\\S+" options:0 error:nil];
    value = [uriRe stringByReplacingMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@""];
    // 3) 逐行挑选首个简洁非空行;去掉 "[11] user:" 之类前缀,跳过 TRANSCRIPT 包装与审查样板文本。
    NSRegularExpression *anywherePrefixRe = [NSRegularExpression regularExpressionWithPattern:@"\\[\\d+\\]\\s*(user|assistant|system)\\s*:\\s*"
                                                                                      options:NSRegularExpressionCaseInsensitive
                                                                                        error:nil];
    NSRegularExpression *headPrefixRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(user|assistant|system)\\s*:\\s*"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil];
    NSString *picked = nil;
    for (NSString *rawLine in [value componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [anywherePrefixRe stringByReplacingMatchesInString:rawLine options:0 range:NSMakeRange(0, rawLine.length) withTemplate:@" "];
        line = [headPrefixRe stringByReplacingMatchesInString:line options:0 range:NSMakeRange(0, line.length) withTemplate:@""];
        line = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!line.length) continue;
        // 去掉行首行尾的 ">" 与空白后判断 transcript 标记(大小写不敏感):
        // "TRANSCRIPT", ">>> TRANSCRIPT START", "transcript end >" 等都跳过。
        NSString *marker = [line stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"> \t"]].lowercaseString;
        if ([marker isEqualToString:@"transcript"] ||
            [marker isEqualToString:@"transcript start"] ||
            [marker isEqualToString:@"transcript end"]) continue;
        NSString *lower = line.lowercaseString;
        if ([lower hasPrefix:@"the following is"]) continue; // "The following is the Codex agent history…" 样板
        picked = line;
        break;
    }
    value = picked.length ? picked : @"未命名任务";
    // 4) 清洗完成后再做最终截断。
    return value.length > 58 ? [[value substringToIndex:58] stringByAppendingString:@"…"] : value;
}

// Tokens 紧凑格式(全 app 统一):2.63M / 12.4k。
NSString *CPFormatTokens(NSInteger tokens) {
    if (tokens >= 1000000) return [NSString stringWithFormat:@"%.2fM", tokens / 1000000.0];
    if (tokens >= 1000) return [NSString stringWithFormat:@"%.1fk", tokens / 1000.0];
    return [NSString stringWithFormat:@"%ld", (long)tokens];
}

// 中文本地时间格式(全 app 统一):7月8日 15:14。
NSString *CPFormatDateCN(NSDate *date) {
    if (!date) return @"—";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"M月d日 HH:mm";
    return [fmt stringFromDate:date];
}

CPDisplayStatus CPDisplayStatusForTask(CPTask *task, NSString *agentID, CPReviewStore *reviewStore) {
    (void)agentID;
    (void)reviewStore;
    switch (task.status) {
        case CPStatusFailed: return CPDisplayStatusFailed;
        case CPStatusAttention:
        case CPStatusWaiting: return CPDisplayStatusWaiting;
        case CPStatusCompleted: return CPDisplayStatusCompletedPendingReview;
        case CPStatusWorking: return CPDisplayStatusWorking;
        case CPStatusIdle: return CPDisplayStatusIdle;
    }
}

// Agent 灯代表最近更新的任务；仅在更新时间完全相同时才用严重度打破平局。
// 这样历史等待项不会长期压住一个已经重新运行的任务，也能真实呈现五种灯色。
CPDisplayStatus CPDisplayStatusForTasks(NSArray<CPTask *> *tasks, NSString *agentID, CPReviewStore *reviewStore) {
    CPTask *latestTask = nil;
    CPDisplayStatus latestStatus = CPDisplayStatusIdle;
    for (CPTask *t in tasks) {
        CPDisplayStatus status = CPDisplayStatusForTask(t, agentID, reviewStore);
        NSComparisonResult order = latestTask ? [t.updatedAt compare:latestTask.updatedAt] : NSOrderedDescending;
        if (!latestTask || order == NSOrderedDescending || (order == NSOrderedSame && status > latestStatus)) {
            latestTask = t;
            latestStatus = status;
        }
    }
    return latestStatus;
}

CPDisplayStatus CPDisplayStatusForAgents(NSArray<CPAgent *> *agents, CPReviewStore *reviewStore) {
    CPDisplayStatus overall = CPDisplayStatusIdle;
    for (CPAgent *a in agents) {
        if (a.placeholder) continue;
        CPDisplayStatus s = CPDisplayStatusForTasks(a.tasks, a.agentID, reviewStore);
        if (s > overall) overall = s;
    }
    return overall;
}

// CPRippleView:统一水波组件(定稿规范)。
// - 固定中心:自身只承载描边圆环 layer,中心图标由宿主提供且永不缩放;
// - 固定基础环 baseRingLayer:固定半径、固定线宽,始终静止显示状态色;
// - 8 层明暗成对涟漪 rippleLayers(白峰)/rippleTroughLayers(黑谷):scale 1.0 → 1.55,
//   透明度 0→峰值→长尾巴衰减→0,lineWidth 2.0 → 0.5,缓入缓出(0.45,0.08,0.35,1),
//   repeat forever,层间 timeOffset = duration/8(基准 12s 即 1.5s)错拍;
// - 波层在组件内先于基础环加入,宿主把组件放在图标之下,波从图标边缘水面露出;
// - reduce motion:停止所有 CAAnimation,只留固定状态环(实色),不缩放不闪烁;
// - 组件按 1.55 倍扩散预留自身 frame,不改变父视图尺寸,也不改变宿主按钮 frame。

NSString *CPDisplayStatusTitle(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return @"失败";
        case CPDisplayStatusWaiting: return @"需关注";
        case CPDisplayStatusCompletedPendingReview: return @"已就绪"; // 完成事件的底层语义不变，界面统一显示「已就绪」
        case CPDisplayStatusWorking: return @"工作中";
        case CPDisplayStatusIdle: return @"空闲";
    }
}

NSColor *CPDisplayStatusColor(CPDisplayStatus s) {
    switch (s) {
        case CPDisplayStatusFailed: return CPRed();
        case CPDisplayStatusWaiting: return CPOrange();
        case CPDisplayStatusCompletedPendingReview: return CPBlue();
        case CPDisplayStatusWorking: return CPGreen();
        case CPDisplayStatusIdle: return CPDyn(0.300, 0.850, 0.900, 0.350, 0.900, 0.950);
    }
}

// 角标计数:需要用户处理且尚未查看的条目。
// 打开详情会记录当前 updatedAt 签名；任务再次更新后会自动重新出现。
NSInteger CPBadgeCountForAgents(NSArray<CPAgent *> *agents, CPReviewStore *reviewStore) {
    NSInteger count = 0;
    for (CPAgent *a in agents) {
        if (a.placeholder) continue;
        for (CPTask *t in a.tasks) {
            switch (t.status) {
                case CPStatusFailed:
                case CPStatusAttention:
                case CPStatusWaiting:
                    if (![reviewStore isTaskReviewed:t agentID:a.agentID]) count++;
                    break;
                case CPStatusCompleted:
                    if (![reviewStore isTaskReviewed:t agentID:a.agentID]) count++;
                    break;
                case CPStatusWorking:
                case CPStatusIdle:
                    break;
            }
        }
    }
    return count;
}

// 首启动豁免:新安装 defaults 为空时,历史 Completed 会全部算未读并撑爆徽标。
// 首次拿到真实数据时把当刻 Completed 批量标为已读;Waiting/Failed/Attention 仍提醒。
