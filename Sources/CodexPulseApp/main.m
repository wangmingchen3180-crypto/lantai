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
        if (!demo && CPAnotherInstanceIsRunning()) return 0;
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
