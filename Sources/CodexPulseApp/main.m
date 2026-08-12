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
        if (CPAnotherInstanceIsRunning()) return 0;
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = AppDelegate.new;
        delegate.hudVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-hud") == 0;
        delegate.detailVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-detail") == 0;
        delegate.kimiVisualTest = argc > 1 && strcmp(argv[1], "--visual-test-kimi") == 0;
        CPRunningSelfTests = delegate.detailVisualTest || delegate.kimiVisualTest;
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
