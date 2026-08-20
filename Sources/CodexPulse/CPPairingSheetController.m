#import "CPPairingSheetController.h"
#import "CPStatusEngine.h"
#import "CPControls.h"
#import <CoreImage/CoreImage.h>

static const CGFloat CPPairSheetWidth = 340.0;
static const CGFloat CPPairQRSide = 168.0;

NSImage *CPQRCodeImage(NSString *text, CGFloat side) {
    NSData *payload = [text dataUsingEncoding:NSUTF8StringEncoding];
    if (!payload.length) return nil;
    CIFilter *filter = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    if (!filter) return nil;
    [filter setValue:payload forKey:@"inputMessage"];
    [filter setValue:@"M" forKey:@"inputCorrectionLevel"];
    CIImage *output = filter.outputImage;
    if (!output) return nil;

    // 二维码原生只有几十像素,只能按整数倍放大:任何插值都会糊掉码眼导致扫不出。
    // 因此返回的图尺寸是「不超过 side 的最大整数倍」,而不是恰好 side——
    // 宿主必须原尺寸显示(NSImageScaleNone),再缩放就白费这一步。
    CGFloat native = MAX(output.extent.size.width, 1.0);
    CGFloat scale = MAX(1.0, floor(side / native));
    CIImage *scaled = [output imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    NSCIImageRep *rep = [NSCIImageRep imageRepWithCIImage:scaled];
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(scaled.extent.size.width, scaled.extent.size.height)];
    [image addRepresentation:rep];
    return image;
}

@interface CPPairingSheetController ()
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSTextField *codeLabel;
@property (nonatomic, strong) NSTextField *hint;
@property (nonatomic, strong) NSImageView *qr;
@property (nonatomic, strong) NSTextField *addressLabel;
@property (nonatomic, strong) NSTimer *countdownTimer;
@property (nonatomic) NSTimeInterval issuedAt;
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *url;
@end

@implementation CPPairingSheetController

- (instancetype)init {
    self = [super init];
    if (self) _codeTTL = 180.0;
    return self;
}

- (NSPanel *)window { return self.panel; }
- (BOOL)isVisible { return self.panel.isVisible; }
- (NSString *)displayedCode { return self.code; }
- (NSString *)encodedURL { return self.url; }
- (NSTextField *)hintLabel { return self.hint; }
- (NSImageView *)qrView { return self.qr; }

#pragma mark - Build

// 系统 bezel 按钮在深色面板里会画成浅灰底 + 白字,等于看不见。
// 跟工作台一致:自绘 CPSurface 底 + hairline 描边 + hover wash。
- (NSButton *)actionButton:(NSString *)title action:(SEL)action {
    CPHoverButton *button = (CPHoverButton *)[CPHoverButton buttonWithTitle:title target:self action:action];
    button.bordered = NO;
    button.attributedTitle = [[NSAttributedString alloc]
        initWithString:title
            attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                         NSForegroundColorAttributeName: CPFg()}];
    button.wantsLayer = YES;
    button.cpBaseBackground = CPSurface();
    button.layer.backgroundColor = CPSurface().CGColor;
    button.layer.cornerRadius = 8.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = CPHairline().CGColor;
    [button.heightAnchor constraintEqualToConstant:32].active = YES;
    return button;
}

- (void)buildIfNeeded {
    if (self.panel) return;

    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, CPPairSheetWidth, 430)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"连接手机";
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.titlebarAppearsTransparent = YES;
    self.panel.backgroundColor = CPBg();
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;

    // 自绘深色底:不依赖 window.backgroundColor,否则 contentView 不画底色,
    // 浅色系统外观和截图流程里都会露出白底,把白字衬没了。
    NSView *root = [[NSView alloc] initWithFrame:self.panel.contentView.bounds];
    root.wantsLayer = YES;
    root.layer.backgroundColor = CPBg().CGColor;
    self.panel.contentView = root;

    NSTextField *title = CPLabel(@"用手机连上这台 Mac", 15, NSFontWeightSemibold, CPFg());
    NSTextField *desc = CPLabel(@"手机扫下面的二维码，或在浏览器里打开该地址后手输六位码。",
                               12, NSFontWeightRegular, CPFg2());
    desc.lineBreakMode = NSLineBreakByWordWrapping;
    desc.maximumNumberOfLines = 2;
    [desc setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    // 二维码底必须是白色:深色底上的二维码多数手机相机识别率明显下降。
    NSView *qrPlate = [[NSView alloc] initWithFrame:NSZeroRect];
    qrPlate.wantsLayer = YES;
    qrPlate.layer.backgroundColor = NSColor.whiteColor.CGColor;
    qrPlate.layer.cornerRadius = 10.0;
    qrPlate.translatesAutoresizingMaskIntoConstraints = NO;

    self.qr = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.qr.imageScaling = NSImageScaleNone; // 保持整数倍像素,见 CPQRCodeImage 注释
    self.qr.translatesAutoresizingMaskIntoConstraints = NO;
    [qrPlate addSubview:self.qr];

    self.codeLabel = CPLabel(@"------", 30, NSFontWeightBold, CPFg());
    self.codeLabel.alignment = NSTextAlignmentCenter;
    // 等宽数字:倒计时刷新时六位码不会左右跳动。
    self.codeLabel.font = [NSFont monospacedDigitSystemFontOfSize:30 weight:NSFontWeightBold];

    self.hint = CPLabel(@"", 11, NSFontWeightRegular, CPMuted());
    self.hint.alignment = NSTextAlignmentCenter;

    self.addressLabel = CPLabel(@"", 11, NSFontWeightRegular, CPFg2());
    self.addressLabel.alignment = NSTextAlignmentCenter;
    self.addressLabel.selectable = YES;

    NSButton *regenerate = [self actionButton:@"重新生成" action:@selector(regenerate:)];
    NSButton *copyURL = [self actionButton:@"复制地址" action:@selector(copyAddress:)];

    NSStackView *buttons = [NSStackView stackViewWithViews:@[copyURL, regenerate]];
    buttons.distribution = NSStackViewDistributionFillEqually;
    buttons.spacing = 8;

    NSStackView *column = [NSStackView stackViewWithViews:@[title, desc, qrPlate, self.codeLabel,
                                                            self.hint, self.addressLabel, buttons]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeCenterX;
    column.spacing = 10;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [column setCustomSpacing:16 afterView:desc];
    [column setCustomSpacing:14 afterView:qrPlate];
    [column setCustomSpacing:4 afterView:self.codeLabel];
    [column setCustomSpacing:14 afterView:self.addressLabel];
    [root addSubview:column];

    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:22],
        [column.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-22],
        [column.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [qrPlate.widthAnchor constraintEqualToConstant:CPPairQRSide + 16],
        [qrPlate.heightAnchor constraintEqualToConstant:CPPairQRSide + 16],
        [self.qr.centerXAnchor constraintEqualToAnchor:qrPlate.centerXAnchor],
        [self.qr.centerYAnchor constraintEqualToAnchor:qrPlate.centerYAnchor],
        [self.qr.widthAnchor constraintEqualToConstant:CPPairQRSide],
        [self.qr.heightAnchor constraintEqualToConstant:CPPairQRSide],
        [buttons.widthAnchor constraintEqualToAnchor:column.widthAnchor]
    ]];
}

#pragma mark - Show / refresh

- (void)show {
    [self buildIfNeeded];
    [self loadCode:NO];
    [self.panel center];
    [self.panel makeKeyAndOrderFront:nil];
    // 自测/截图流程里不抢前台,否则会打断用户正在做的事。
    if (!CPRunningSelfTests) [NSApp activateIgnoringOtherApps:YES];
    [self startCountdown];
}

- (void)close {
    [self stopCountdown];
    // 关窗即让码作废在语义上更安全,但作废由宿主决定;这里只停止展示。
    [self.panel orderOut:nil];
}

- (void)regenerate:(id)sender {
    (void)sender;
    [self loadCode:YES];
}

- (void)showPairedWithDeviceName:(NSString *)deviceName {
    if (!self.panel.isVisible) return;
    [self stopCountdown];
    // 码已在服务端一次性作废,界面同步撤掉二维码,避免留一个已失效的码让人再扫。
    self.code = nil;
    self.url = nil;
    self.qr.image = nil;
    self.codeLabel.stringValue = @"✓";
    self.hint.stringValue = [NSString stringWithFormat:@"%@ 已连接。可在菜单栏「手机指挥设置」中允许它下达指令",
                              deviceName.length ? deviceName : @"手机"];
    self.hint.lineBreakMode = NSLineBreakByWordWrapping;
    self.hint.maximumNumberOfLines = 2;
    self.hint.textColor = CPGreen();
    if (CPRunningSelfTests) return; // 自测不排延迟关闭,断言直接看当前状态
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf close]; });
}

- (void)copyAddress:(id)sender {
    (void)sender;
    if (!self.url.length) return;
    NSPasteboard *board = NSPasteboard.generalPasteboard;
    [board clearContents];
    // 只复制基地址,不带 code:剪贴板可能被其他应用读取,配对码不进剪贴板。
    NSString *base = self.baseURLProvider ? self.baseURLProvider() : nil;
    [board setString:base ?: @"" forType:NSPasteboardTypeString];
}

- (void)loadCode:(BOOL)regenerate {
    NSString *code = self.codeProvider ? self.codeProvider(regenerate) : nil;
    NSString *base = self.baseURLProvider ? self.baseURLProvider() : nil;

    if (!code.length || !base.length) {
        self.code = nil;
        self.url = nil;
        self.codeLabel.stringValue = @"——";
        self.qr.image = nil;
        // 起不来就明说,不画一个扫不通的空二维码。
        self.hint.stringValue = !base.length ? @"拿不到局域网地址，确认 Mac 已连上 Wi-Fi。"
                                            : @"Bridge 未启动，无法生成配对码。";
        self.hint.textColor = CPOrange();
        self.addressLabel.stringValue = @"";
        return;
    }

    self.code = code;
    self.url = [NSString stringWithFormat:@"%@/?code=%@", base, code];
    self.issuedAt = NSDate.date.timeIntervalSince1970;

    // 六位码分成两组更易读，但内部值不变。
    self.codeLabel.stringValue = [NSString stringWithFormat:@"%@ %@",
                                  [code substringToIndex:3], [code substringFromIndex:3]];
    self.qr.image = CPQRCodeImage(self.url, CPPairQRSide);
    self.hint.textColor = CPMuted();
    self.addressLabel.stringValue = base;
    [self updateCountdown];
}

- (void)startCountdown {
    [self stopCountdown];
    self.countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                          target:self
                                                        selector:@selector(updateCountdown)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)stopCountdown {
    [self.countdownTimer invalidate];
    self.countdownTimer = nil;
}

- (void)updateCountdown {
    if (!self.code.length) return;
    NSInteger left = (NSInteger)ceil(self.codeTTL - (NSDate.date.timeIntervalSince1970 - self.issuedAt));
    if (left <= 0) {
        self.hint.stringValue = @"配对码已过期，点「重新生成」。";
        self.hint.textColor = CPOrange();
        self.qr.image = nil;
        self.codeLabel.stringValue = @"——";
        self.code = nil;
        self.url = nil;
        return;
    }
    self.hint.stringValue = [NSString stringWithFormat:@"%ld 秒后失效 · 只在同一网络内有效", (long)left];
    self.hint.textColor = CPMuted();
}

- (void)dealloc {
    [self stopCountdown];
}

@end
