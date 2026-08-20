#import "CPScreenshots.h"
#import "CPAppDelegate.h"
#import "CodexPulse.h"

static NSString *gOutputDir = nil;

static void CPShotWrite(NSView *view, NSString *name) {
    if (!view) { NSLog(@"[shot] %@: 视图为空,跳过", name); return; }
    NSRect bounds = view.bounds;
    if (NSIsEmptyRect(bounds)) { NSLog(@"[shot] %@: 尺寸为空,跳过", name); return; }

    // bitmapImageRepForCachingDisplayInRect: 会按窗口 backingScaleFactor 给出 2x rep,
    // 所以 Retina 上直接得到 @2x 位图,不需要额外缩放。
    NSBitmapImageRep *rep = [view bitmapImageRepForCachingDisplayInRect:bounds];
    if (!rep) { NSLog(@"[shot] %@: 无法创建位图,跳过", name); return; }
    [view cacheDisplayInRect:bounds toBitmapImageRep:rep];

    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    NSString *path = [gOutputDir stringByAppendingPathComponent:
                      [name stringByAppendingPathExtension:@"png"]];
    NSError *error = nil;
    if ([png writeToFile:path options:NSDataWritingAtomic error:&error]) {
        NSLog(@"[shot] %@  %.0fx%.0f pt / %ldx%ld px",
              path, bounds.size.width, bounds.size.height,
              (long)rep.pixelsWide, (long)rep.pixelsHigh);
    } else {
        NSLog(@"[shot] %@ 写入失败: %@", path, error.localizedDescription);
    }
}

// 各步之间留一拍 runloop,让展开动画和自动布局落定后再取图。
static void CPShotStep(NSTimeInterval delay, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), block);
}

void CPCaptureScreenshots(AppDelegate *delegate, NSString *outputDir) {
    gOutputDir = outputDir.stringByStandardizingPath;
    [NSFileManager.defaultManager createDirectoryAtPath:gOutputDir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:NULL];
    NSLog(@"[shot] 输出目录 %@", gOutputDir);

    // 同步灌入 demo 数据,后面每一步都基于同一份任务列表。
    [delegate applyAgents:[delegate.reader readAgents] signature:nil];

    __weak AppDelegate *weakDelegate = delegate;

    CPShotStep(0.8, ^{
        AppDelegate *d = weakDelegate; if (!d) return;
        CPShotWrite(d.dock.window.contentView, @"orb");

        d.hud.stickyExpanded = YES;
        [d.hud expand];
    });

    CPShotStep(1.8, ^{
        AppDelegate *d = weakDelegate; if (!d) return;
        CPShotWrite(d.hud.window.contentView, @"hud");

        [d showCard];
    });

    CPShotStep(2.8, ^{
        AppDelegate *d = weakDelegate; if (!d) return;
        CPShotWrite(d.card.window.contentView, @"workbench");

        // 打开第一条任务的详情。走和 --visual-test-detail 相同的注入方式:
        // 只切详情视图,不触发深链(CPRunningSelfTests 已置位)。
        CPAgent *agent = d.card.selectedAgent;
        if (agent.tasks.count) {
            CPWorkbenchTaskRowButton *row =
                [CPWorkbenchTaskRowButton buttonWithTitle:@"" target:nil action:nil];
            row.agentID = agent.agentID;
            row.taskID = agent.tasks.firstObject.taskID;
            [d.card taskClicked:row];
        }
    });

    CPShotStep(3.8, ^{
        AppDelegate *d = weakDelegate; if (!d) return;
        CPShotWrite(d.card.window.contentView, @"workbench-detail");
        [d connectPhoneFromMenu:nil];
    });

    CPShotStep(4.8, ^{
        AppDelegate *d = weakDelegate; if (!d) return;
        CPShotWrite(d.pairingSheet.window.contentView, @"pairing");
        NSLog(@"[shot] 完成");
        [NSApp terminate:nil];
    });
}
