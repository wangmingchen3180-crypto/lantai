#import <Cocoa/Cocoa.h>

@class AppDelegate;

// --shot [dir]:用 demo 数据把界面摆到几个代表状态,逐个渲染成 PNG 后退出。
//
// 走 -cacheDisplayInRect:toBitmapImageRep:,即应用重绘自己的视图树,不经过
// CGWindowList / screencapture,因此不需要「屏幕录制」权限,也不会把桌面上
// 其他窗口拍进来。截图随 UI 改动可重跑,不用手工对齐。
void CPCaptureScreenshots(AppDelegate *delegate, NSString *outputDir);
