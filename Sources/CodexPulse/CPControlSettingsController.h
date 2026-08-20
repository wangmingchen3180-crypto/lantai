#import <Cocoa/Cocoa.h>
#import "CPWorkdirStore.h"

// 「手机指挥设置」卡片:已配对设备授权 + 项目白名单。
// 不 import Bridge;设备能力由宿主注入,白名单走数据层 CPWorkdirStore。
@interface CPControlSettingsController : NSObject

@property (copy) NSArray<NSDictionary *> *(^devicesProvider)(void);
// 每项形如 @{@"deviceId":…, @"deviceName":…, @"createdAt":@(…), @"canControl":@(YES/NO)}
// 注意:不要把 token 放进来,凭据不得离开 Bridge。
@property (copy) BOOL (^setControlHandler)(NSString *deviceId, BOOL canControl);
@property (copy) BOOL (^revokeHandler)(NSString *deviceId);
@property (copy) void (^settingsDidChange)(void); // 授权或白名单变更后通知宿主重推快照

@property (strong) CPWorkdirStore *workdirStore; // 自测注入独立 suite;生产默认 standardUserDefaults

@property (nonatomic, readonly) NSPanel *window;
@property (nonatomic, readonly) BOOL isVisible;

- (void)show;
- (void)close;
- (void)reload; // 按当前 provider / store 重绘;自测可只 reload 不 show

// 自测断言用
@property (nonatomic, readonly) NSTextField *devicesEmptyLabel;
@property (nonatomic, readonly) NSTextField *projectsEmptyLabel;
@property (nonatomic, readonly, copy) NSArray<NSString *> *displayedDeviceIDs;
@property (nonatomic, readonly, copy) NSArray<NSButton *> *controlSwitches;
@property (nonatomic, readonly, copy) NSArray<NSString *> *displayedWorkdirIDs;
@property (nonatomic, readonly, copy) NSArray<NSTextField *> *projectNameLabels;
@property (nonatomic, readonly, copy) NSArray<NSTextField *> *projectPathLabels;

// 点面板外面就收起,但挂着 sheet 时不许收——文件对话框比本面板宽一倍多,
// 大半个（含「添加」按钮）都在 panel.frame 外面。抽出来是为了能在自测里断言。
- (BOOL)shouldDismissForClickAt:(NSPoint)screenPoint;

- (void)addPathForTesting:(NSString *)path;
- (void)removeProjectAtIndex:(NSInteger)index;
- (void)renameProjectAtIndex:(NSInteger)index to:(NSString *)name;
- (void)revokeAtIndex:(NSInteger)index; // 跳过 NSAlert,自测用
@end
