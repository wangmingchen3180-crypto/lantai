#import <Cocoa/Cocoa.h>

// 「连接手机」配对卡:菜单栏菜单唤出,显示二维码 + 六位配对码。
// 配对是一次性动作(token 存下后手机直接连),所以入口放菜单里,不占工作台标题栏。
// 本控制器只负责显示与倒计时,不持有配对逻辑:码与地址由宿主通过 block 提供。
@interface CPPairingSheetController : NSObject

// 返回当前六位码;返回 nil 视为「Bridge 未启动」。regenerate 为 YES 时应签发新码。
@property (nonatomic, copy) NSString * (^codeProvider)(BOOL regenerate);
// 形如 http://192.168.1.7:8787 ;返回 nil 视为「拿不到局域网地址」。
@property (nonatomic, copy) NSString * (^baseURLProvider)(void);
@property (nonatomic) NSTimeInterval codeTTL; // 默认 180s,与 CPBridgePairing.pairingCodeTTL 对齐

@property (nonatomic, readonly) NSPanel *window;
@property (nonatomic, readonly) BOOL isVisible;

- (void)show;
- (void)close;
- (void)regenerate:(id)sender; // 「重新生成」按钮动作;自测直接调用
// 手机配对成功:显示确认后自动关闭,不需要用户手动关。
- (void)showPairedWithDeviceName:(NSString *)deviceName;

// 自测断言用:当前展示的码、二维码承载的 URL、以及剩余秒数文案。
@property (nonatomic, readonly, copy) NSString *displayedCode;
@property (nonatomic, readonly, copy) NSString *encodedURL;
@property (nonatomic, readonly) NSTextField *hintLabel;
@property (nonatomic, readonly) NSImageView *qrView;
@end

// 把 URL 编成二维码图像;失败返回 nil。CoreImage 内置滤镜,不引第三方依赖。
// 返回尺寸是「不超过 side 的最大整数倍」,不是恰好 side;调用方必须原尺寸显示。
NSImage *CPQRCodeImage(NSString *text, CGFloat side);
