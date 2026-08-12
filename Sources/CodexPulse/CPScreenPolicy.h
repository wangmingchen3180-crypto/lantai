#import <Cocoa/Cocoa.h>

/// 主显示器策略：优先 `NSScreen.screens.firstObject`（排列中的主屏），
/// 否则回退 `NSScreen.mainScreen`。不跟随鼠标 / key window。
FOUNDATION_EXPORT NSScreen *CPTargetScreen(void);
