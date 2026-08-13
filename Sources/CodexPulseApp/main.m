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
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--demo") == 0) { demo = YES; break; }
        }
        // demo 用虚构数据,和正在运行的真实实例互不干扰,所以不受单实例限制。
        if (!demo && CPAnotherInstanceIsRunning()) return 0;
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        delegate.demoMode = demo;
        delegate.hudVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-hud") == 0;
        delegate.detailVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-detail") == 0;
        delegate.kimiVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-kimi") == 0;
        CPRunningSelfTests = delegate.detailVisualTest || delegate.kimiVisualTest;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
