#import "CPScreenPolicy.h"

NSScreen *CPTargetScreen(void) {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count > 0) return screens.firstObject;
    return NSScreen.mainScreen;
}
