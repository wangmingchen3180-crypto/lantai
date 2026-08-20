#import "CodexPulse.h"
#import "CPAppDelegate.h"
#import "CPSelfTests.h"
#import <string.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc > 1 && strcmp(argv[1], "--ui-self-test") == 0) {
            return CPRunUISelfTests(argc, argv);
        }
        if (argc > 1 && strcmp(argv[1], "--self-test") == 0) {
            return CPRunSelfTests(argc, argv);
        }
        if (argc > 1 && strcmp(argv[1], "--kimi-probe") == 0) {
            return CPRunKimiProbe();
        }
        BOOL demo = NO;
        NSString *shotDir = nil;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--demo") == 0) demo = YES;
            else if (strcmp(argv[i], "--shot") == 0) {
                // --shot 必然是虚构数据:截图不能泄露本机真实任务。
                demo = YES;
                shotDir = (i + 1 < argc && argv[i + 1][0] != '-')
                        ? @(argv[++i]) : @"docs/images";
            }
        }
        // demo 用虚构数据,和正在运行的真实实例互不干扰,所以不受单实例限制。
        // 单实例:再次双击 .app 只会激活旧进程并直接退出——旧进程内存里的菜单不会自动更新。
        if (!demo && CPAnotherInstanceIsRunning()) {
            NSAlert *alert = [[NSAlert alloc] init];
            alert.messageText = @"澜台已在运行";
            alert.informativeText = @"若刚更新过却看不到新功能,请先在菜单栏点「退出澜台」,再重新打开 Lantai.app。";
            [alert addButtonWithTitle:@"好"];
            [alert runModal];
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        delegate.demoMode = demo;
        delegate.shotOutputDir = shotDir;
        if (shotDir) CPRunningSelfTests = YES; // 截图期间禁止真的深链打开 Agent
        delegate.hudVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-hud") == 0;
        delegate.detailVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-detail") == 0;
        delegate.kimiVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-kimi") == 0;
        CPRunningSelfTests = CPRunningSelfTests || delegate.detailVisualTest || delegate.kimiVisualTest;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
