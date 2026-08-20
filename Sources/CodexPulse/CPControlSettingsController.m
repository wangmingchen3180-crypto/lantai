#import "CPControlSettingsController.h"
#import "CPStatusEngine.h"
#import "CPControls.h"

static const CGFloat CPControlSheetWidth = 400.0;
static const CGFloat CPControlListHeight = 148.0;

@interface CPControlDeviceRow : NSView
@property (copy) NSString *deviceId;
@property (strong) NSButton *toggle;
@property (strong) NSButton *revoke;
@end
@implementation CPControlDeviceRow
@end

@interface CPControlProjectRow : NSView
@property (copy) NSString *workdirID;
@property (strong) NSTextField *nameLabel;
@property (strong) NSTextField *pathLabel;
@property (strong) NSButton *nameButton;
@property (strong) NSButton *removeButton;
@end
@implementation CPControlProjectRow
@end

@interface CPControlFlippedView : NSView
@end
@implementation CPControlFlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface CPControlSettingsController () <NSWindowDelegate, NSTextFieldDelegate>
@property (nonatomic, strong) NSPanel *panel;
@property (nonatomic, strong) NSStackView *deviceStack;
@property (nonatomic, strong) NSStackView *projectStack;
@property (nonatomic, strong) NSTextField *devicesEmpty;
@property (nonatomic, strong) NSTextField *projectsEmpty;
@property (nonatomic, copy) NSArray<NSString *> *deviceIDs;
@property (nonatomic, copy) NSArray<NSButton *> *switches;
@property (nonatomic, copy) NSArray<NSString *> *workdirIDs;
@property (nonatomic, copy) NSArray<NSTextField *> *nameLabels;
@property (nonatomic, copy) NSArray<NSTextField *> *pathLabels;
@property (nonatomic, copy) NSString *editingWorkdirID;
@property (nonatomic, strong) NSTextField *editField;
@property (nonatomic, strong) id clickMonitor;
@property (nonatomic, strong) id keyMonitor;
@end

@implementation CPControlSettingsController

- (NSPanel *)window { return self.panel; }
- (BOOL)isVisible { return self.panel.isVisible; }
- (NSTextField *)devicesEmptyLabel { return self.devicesEmpty; }
- (NSTextField *)projectsEmptyLabel { return self.projectsEmpty; }
- (NSArray<NSString *> *)displayedDeviceIDs { return self.deviceIDs ?: @[]; }
- (NSArray<NSButton *> *)controlSwitches { return self.switches ?: @[]; }
- (NSArray<NSString *> *)displayedWorkdirIDs { return self.workdirIDs ?: @[]; }
- (NSArray<NSTextField *> *)projectNameLabels { return self.nameLabels ?: @[]; }
- (NSArray<NSTextField *> *)projectPathLabels { return self.pathLabels ?: @[]; }

- (CPWorkdirStore *)effectiveStore {
    if (!self.workdirStore) self.workdirStore = [[CPWorkdirStore alloc] initWithSuiteName:nil];
    return self.workdirStore;
}

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

- (NSScrollView *)listScrollHosting:(NSStackView *)stack {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.drawsBackground = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.borderType = NSNoBorder;
    scroll.scrollerStyle = NSScrollerStyleOverlay;

    // documentView 默认 translatesAutoresizingMaskIntoConstraints == YES,配合 NSZeroRect
    // 会带着一组「锁死在 0×0」的约束,跟里面 stack 的四边对齐打架,整个滚动区画不出东西。
    // 又必须翻转:非翻转视图原点在左下,内容比可视区矮时会被压到底部。
    NSView *doc = [[CPControlFlippedView alloc] initWithFrame:NSZeroRect];
    doc.translatesAutoresizingMaskIntoConstraints = NO;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [doc addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:doc.topAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:doc.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:doc.trailingAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:doc.bottomAnchor],
    ]];
    scroll.documentView = doc;
    [doc.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor].active = YES;
    [scroll.heightAnchor constraintEqualToConstant:CPControlListHeight].active = YES;
    return scroll;
}

- (void)buildIfNeeded {
    if (self.panel) return;

    self.panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, CPControlSheetWidth, 520)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
    self.panel.title = @"手机指挥设置";
    self.panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.panel.titlebarAppearsTransparent = YES;
    self.panel.backgroundColor = CPBg();
    self.panel.level = NSFloatingWindowLevel;
    self.panel.hidesOnDeactivate = NO;
    self.panel.releasedWhenClosed = NO;
    self.panel.delegate = self;

    NSView *root = [[NSView alloc] initWithFrame:self.panel.contentView.bounds];
    root.wantsLayer = YES;
    root.layer.backgroundColor = CPBg().CGColor;
    self.panel.contentView = root;

    NSTextField *title = CPLabel(@"手机指挥设置", 15, NSFontWeightSemibold, CPFg());

    NSTextField *deviceHead = CPLabel(@"已配对设备", 12, NSFontWeightSemibold, CPFg());
    NSTextField *risk = CPLabel(@"打开「允许指挥」后，这台手机可以让 Codex 在下面列出的项目里执行任务。",
                               11, NSFontWeightRegular, CPMuted());
    risk.lineBreakMode = NSLineBreakByWordWrapping;
    risk.maximumNumberOfLines = 2;
    [risk setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.devicesEmpty = CPLabel(@"还没有已配对的手机。先在菜单栏打开「连接手机…」。",
                                11, NSFontWeightRegular, CPMuted());
    self.devicesEmpty.lineBreakMode = NSLineBreakByWordWrapping;
    self.devicesEmpty.maximumNumberOfLines = 2;
    [self.devicesEmpty setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                forOrientation:NSLayoutConstraintOrientationHorizontal];
    // stack.alignment = Width 对有固有尺寸的标签不生效,它会按自然宽度浮到尾部(实测 x=129
    // 而非 0,文字看着右偏)。显式钉宽度,自然对齐才会把文字放到左边。
    [self.devicesEmpty.widthAnchor constraintEqualToConstant:CPControlSheetWidth - 44].active = YES;

    self.deviceStack = [NSStackView stackViewWithViews:@[]];
    self.deviceStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.deviceStack.alignment = NSLayoutAttributeWidth;
    self.deviceStack.spacing = 8;
    NSScrollView *deviceScroll = [self listScrollHosting:self.deviceStack];

    NSTextField *projectHead = CPLabel(@"可指挥的项目", 12, NSFontWeightSemibold, CPFg());
    self.projectsEmpty = CPLabel(@"还没有项目。没有项目时，手机无法新建任务。",
                                 11, NSFontWeightRegular, CPMuted());
    self.projectsEmpty.lineBreakMode = NSLineBreakByWordWrapping;
    self.projectsEmpty.maximumNumberOfLines = 2;
    [self.projectsEmpty setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                                 forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.projectsEmpty.widthAnchor constraintEqualToConstant:CPControlSheetWidth - 44].active = YES;

    self.projectStack = [NSStackView stackViewWithViews:@[]];
    self.projectStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.projectStack.alignment = NSLayoutAttributeWidth;
    self.projectStack.spacing = 8;
    NSScrollView *projectScroll = [self listScrollHosting:self.projectStack];

    NSButton *addProject = [self actionButton:@"添加项目" action:@selector(addProject:)];

    NSStackView *column = [NSStackView stackViewWithViews:@[title, deviceHead, risk, deviceScroll,
                                                            projectHead, projectScroll, addProject]];
    column.orientation = NSUserInterfaceLayoutOrientationVertical;
    column.alignment = NSLayoutAttributeLeading;
    column.spacing = 10;
    column.translatesAutoresizingMaskIntoConstraints = NO;
    [column setCustomSpacing:16 afterView:title];
    [column setCustomSpacing:4 afterView:deviceHead];
    [column setCustomSpacing:8 afterView:risk];
    [column setCustomSpacing:16 afterView:deviceScroll];
    [column setCustomSpacing:8 afterView:projectHead];
    [column setCustomSpacing:14 afterView:projectScroll];
    [root addSubview:column];

    // 宽度必须显式钉住。窗口 styleMask 没有 Resizable,AppKit 会按约束反推窗口尺寸;
    // 只绑左右两边到 root 是循环可满足的,加上 risk 那行横向抗压被降低,
    // 整扇窗会塌成最宽标签的宽度(实测是一条黑竖条)。
    // 配对面板用的是同一套写法,只因为里面二维码写死了边长才没塌,别照那个抄。
    [NSLayoutConstraint activateConstraints:@[
        [column.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:22],
        [column.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-22],
        [column.topAnchor constraintEqualToAnchor:root.topAnchor constant:14],
        [column.widthAnchor constraintEqualToConstant:CPControlSheetWidth - 44],
        [deviceScroll.widthAnchor constraintEqualToAnchor:column.widthAnchor],
        [projectScroll.widthAnchor constraintEqualToAnchor:column.widthAnchor],
        [addProject.widthAnchor constraintEqualToAnchor:column.widthAnchor],
    ]];
    NSLayoutConstraint *bottom = [column.bottomAnchor constraintLessThanOrEqualToAnchor:root.bottomAnchor
                                                                              constant:-14];
    bottom.priority = NSLayoutPriorityDefaultHigh;
    bottom.active = YES;
}

#pragma mark - Rows

- (NSString *)pairedDateText:(NSTimeInterval)createdAt {
    if (createdAt <= 0) return @"—";
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"M月d日";
    return [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:createdAt]];
}

- (CPControlDeviceRow *)deviceRow:(NSDictionary *)row {
    CPControlDeviceRow *view = [[CPControlDeviceRow alloc] initWithFrame:NSZeroRect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.wantsLayer = YES;
    view.layer.backgroundColor = CPSurface().CGColor;
    view.layer.cornerRadius = 8.0;
    view.deviceId = [row[@"deviceId"] isKindOfClass:NSString.class] ? row[@"deviceId"] : @"";

    NSString *name = [row[@"deviceName"] isKindOfClass:NSString.class] ? row[@"deviceName"] : @"手机";
    NSTimeInterval createdAt = [row[@"createdAt"] isKindOfClass:NSNumber.class] ? [row[@"createdAt"] doubleValue] : 0;
    BOOL canControl = [row[@"canControl"] respondsToSelector:@selector(boolValue)] ? [row[@"canControl"] boolValue] : NO;

    NSTextField *nameLabel = CPLabel(name.length ? name : @"手机", 12, NSFontWeightMedium, CPFg());
    NSTextField *dateLabel = CPLabel([self pairedDateText:createdAt], 11, NSFontWeightRegular, CPMuted());

    NSButton *revoke = [self actionButton:@"撤销" action:@selector(revokeClicked:)];
    revoke.identifier = view.deviceId;
    [revoke.widthAnchor constraintEqualToConstant:64].active = YES;
    view.revoke = revoke;

    NSButton *toggle = [NSButton checkboxWithTitle:@"允许指挥" target:self action:@selector(toggleControl:)];
    toggle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
    toggle.contentTintColor = CPFg();
    toggle.state = canControl ? NSControlStateValueOn : NSControlStateValueOff;
    toggle.identifier = view.deviceId;
    toggle.translatesAutoresizingMaskIntoConstraints = NO;
    view.toggle = toggle;

    nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    revoke.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:nameLabel];
    [view addSubview:dateLabel];
    [view addSubview:revoke];
    [view addSubview:toggle];

    [NSLayoutConstraint activateConstraints:@[
        [view.heightAnchor constraintEqualToConstant:72],
        [nameLabel.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:10],
        [nameLabel.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],
        [nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:revoke.leadingAnchor constant:-8],
        [revoke.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-10],
        [revoke.centerYAnchor constraintEqualToAnchor:nameLabel.centerYAnchor],
        [dateLabel.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [dateLabel.topAnchor constraintEqualToAnchor:nameLabel.bottomAnchor constant:2],
        [toggle.leadingAnchor constraintEqualToAnchor:nameLabel.leadingAnchor],
        [toggle.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-8],
    ]];
    return view;
}

- (CPControlProjectRow *)projectRow:(CPWorkdirEntry *)entry {
    CPControlProjectRow *view = [[CPControlProjectRow alloc] initWithFrame:NSZeroRect];
    view.translatesAutoresizingMaskIntoConstraints = NO;
    view.wantsLayer = YES;
    view.layer.backgroundColor = CPSurface().CGColor;
    view.layer.cornerRadius = 8.0;
    view.workdirID = entry.workdirID;

    NSButton *remove = [self actionButton:@"删除" action:@selector(removeProjectClicked:)];
    remove.identifier = entry.workdirID;
    [remove.widthAnchor constraintEqualToConstant:64].active = YES;
    view.removeButton = remove;

    NSTextField *pathLabel = CPLabel(entry.path ?: @"", 11, NSFontWeightRegular, CPMuted());
    pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    pathLabel.maximumNumberOfLines = 1;
    [pathLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                        forOrientation:NSLayoutConstraintOrientationHorizontal];
    view.pathLabel = pathLabel;

    NSView *nameView;
    if ([self.editingWorkdirID isEqualToString:entry.workdirID]) {
        NSTextField *edit = [[NSTextField alloc] initWithFrame:NSZeroRect];
        edit.bordered = NO;
        edit.bezeled = NO;
        edit.drawsBackground = YES;
        edit.backgroundColor = [CPAccent() colorWithAlphaComponent:0.10];
        edit.wantsLayer = YES;
        edit.layer.cornerRadius = 4.0;
        edit.focusRingType = NSFocusRingTypeNone;
        edit.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        edit.textColor = CPFg();
        edit.stringValue = entry.name ?: @"";
        edit.target = self;
        edit.action = @selector(commitProjectEdit:);
        edit.delegate = self;
        edit.identifier = entry.workdirID;
        self.editField = edit;
        nameView = edit;
        view.nameLabel = edit;
    } else {
        NSButton *nameButton = [CPHoverButton buttonWithTitle:@"" target:self action:@selector(startProjectEdit:)];
        nameButton.bordered = NO;
        [nameButton setButtonType:NSButtonTypeMomentaryChange];
        nameButton.identifier = entry.workdirID;
        nameButton.toolTip = @"点击改显示名";
        nameButton.attributedTitle = [[NSAttributedString alloc]
            initWithString:entry.name ?: @""
                attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium],
                             NSForegroundColorAttributeName: CPFg()}];
        nameButton.alignment = NSTextAlignmentLeft;
        nameButton.lineBreakMode = NSLineBreakByTruncatingTail;
        view.nameButton = nameButton;
        // 按钮才是可见标题;标签不进视图,只给自测读显示名。
        view.nameLabel = CPLabel(entry.name ?: @"", 12, NSFontWeightMedium, CPFg());
        nameView = nameButton;
    }
    nameView.translatesAutoresizingMaskIntoConstraints = NO;
    pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    remove.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:nameView];
    [view addSubview:pathLabel];
    [view addSubview:remove];

    [NSLayoutConstraint activateConstraints:@[
        [view.heightAnchor constraintEqualToConstant:56],
        [nameView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:10],
        [nameView.topAnchor constraintEqualToAnchor:view.topAnchor constant:8],
        [nameView.trailingAnchor constraintLessThanOrEqualToAnchor:remove.leadingAnchor constant:-8],
        [remove.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-10],
        [remove.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
        [pathLabel.leadingAnchor constraintEqualToAnchor:nameView.leadingAnchor],
        [pathLabel.trailingAnchor constraintLessThanOrEqualToAnchor:remove.leadingAnchor constant:-8],
        [pathLabel.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-8],
    ]];
    return view;
}

- (void)clearStack:(NSStackView *)stack {
    for (NSView *view in [stack.arrangedSubviews copy]) {
        [stack removeArrangedSubview:view];
        [view removeFromSuperview];
    }
}

- (void)reload {
    [self buildIfNeeded];
    [self clearStack:self.deviceStack];
    [self clearStack:self.projectStack];

    NSArray<NSDictionary *> *devices = self.devicesProvider ? self.devicesProvider() : @[];
    NSMutableArray<NSString *> *deviceIDs = NSMutableArray.array;
    NSMutableArray<NSButton *> *switches = NSMutableArray.array;
    if (!devices.count) {
        [self.deviceStack addArrangedSubview:self.devicesEmpty];
    } else {
        for (NSDictionary *row in devices) {
            if (![row isKindOfClass:NSDictionary.class]) continue;
            CPControlDeviceRow *deviceRow = [self deviceRow:row];
            [self.deviceStack addArrangedSubview:deviceRow];
            if (deviceRow.deviceId.length) [deviceIDs addObject:deviceRow.deviceId];
            if (deviceRow.toggle) [switches addObject:deviceRow.toggle];
        }
    }
    self.deviceIDs = deviceIDs;
    self.switches = switches;

    NSArray<CPWorkdirEntry *> *entries = [self.effectiveStore allEntries];
    NSMutableArray<NSString *> *workdirIDs = NSMutableArray.array;
    NSMutableArray<NSTextField *> *names = NSMutableArray.array;
    NSMutableArray<NSTextField *> *paths = NSMutableArray.array;
    if (!entries.count) {
        [self.projectStack addArrangedSubview:self.projectsEmpty];
    } else {
        for (CPWorkdirEntry *entry in entries) {
            CPControlProjectRow *projectRow = [self projectRow:entry];
            [self.projectStack addArrangedSubview:projectRow];
            if (entry.workdirID.length) [workdirIDs addObject:entry.workdirID];
            if (projectRow.nameLabel) [names addObject:projectRow.nameLabel];
            if (projectRow.pathLabel) [paths addObject:projectRow.pathLabel];
        }
    }
    self.workdirIDs = workdirIDs;
    self.nameLabels = names;
    self.pathLabels = paths;

    if (self.editField && self.panel.isVisible) {
        [self.panel makeFirstResponder:self.editField];
    }
}

#pragma mark - Show / close

- (void)show {
    [self buildIfNeeded];
    self.editingWorkdirID = nil;
    self.editField = nil;
    [self reload];
    [self.panel center];
    [self.panel makeKeyAndOrderFront:nil];
    if (!CPRunningSelfTests) [NSApp activateIgnoringOtherApps:YES];
    [self installMonitors];
}

- (void)close {
    [self removeMonitors];
    self.editingWorkdirID = nil;
    self.editField = nil;
    [self.panel orderOut:nil];
}

- (void)windowWillClose:(NSNotification *)notification {
    (void)notification;
    [self removeMonitors];
}

- (void)installMonitors {
    [self removeMonitors];
    __weak typeof(self) weakSelf = self;
    self.keyMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode != 53 || !weakSelf.panel.isKeyWindow) return event;
        if ([weakSelf cancelEditingIfNeeded]) return nil;
        [weakSelf close];
        return nil;
    }];
    if (CPRunningSelfTests) return;
    self.clickMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^(NSEvent *event) {
        (void)event;
        if ([weakSelf shouldDismissForClickAt:[NSEvent mouseLocation]]) [weakSelf close];
    }];
}

- (BOOL)shouldDismissForClickAt:(NSPoint)screenPoint {
    if (!self.panel.isVisible) return NO;
    // 挂着 sheet 就一律不收。NSOpenPanel 的 sheet 实测 880pt 宽,本面板只有 400pt,
    // 只有 45% 落在 panel.frame 里;侧边栏和右下角的「添加」按钮都在外面。
    // 又因为文件对话框由 openAndSavePanelService 另一个进程画,它的点击对本进程算「别的应用」,
    // 全局监听收得到——于是点「添加」反而先把面板关掉,项目永远加不上。
    if (self.panel.attachedSheet) return NO;
    return !NSPointInRect(screenPoint, self.panel.frame);
}

- (void)removeMonitors {
    if (self.keyMonitor) { [NSEvent removeMonitor:self.keyMonitor]; self.keyMonitor = nil; }
    if (self.clickMonitor) { [NSEvent removeMonitor:self.clickMonitor]; self.clickMonitor = nil; }
}

- (BOOL)cancelEditingIfNeeded {
    if (!self.editingWorkdirID.length) return NO;
    self.editingWorkdirID = nil;
    self.editField = nil;
    [self reload];
    return YES;
}

- (void)notifyChange {
    if (self.settingsDidChange) self.settingsDidChange();
}

#pragma mark - Device actions

- (void)toggleControl:(NSButton *)sender {
    NSString *deviceId = sender.identifier;
    BOOL on = sender.state == NSControlStateValueOn;
    BOOL ok = self.setControlHandler ? self.setControlHandler(deviceId, on) : NO;
    if (ok) [self notifyChange];
    [self reload];
}

- (void)revokeClicked:(NSButton *)sender {
    [self revokeDeviceID:sender.identifier skipConfirm:CPRunningSelfTests];
}

- (void)revokeAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.deviceIDs.count) return;
    [self revokeDeviceID:self.deviceIDs[(NSUInteger)index] skipConfirm:YES];
}

- (void)revokeDeviceID:(NSString *)deviceId skipConfirm:(BOOL)skip {
    if (!deviceId.length) return;
    if (!skip) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"撤销这台手机？";
        alert.informativeText = @"撤销后它立刻无法再连上这台 Mac，需要重新扫码配对。";
        alert.alertStyle = NSAlertStyleWarning;
        [alert addButtonWithTitle:@"撤销"];
        [alert addButtonWithTitle:@"取消"];
        if (self.panel) alert.window.appearance = self.panel.appearance;
        if ([alert runModal] != NSAlertFirstButtonReturn) return;
    }
    BOOL ok = self.revokeHandler ? self.revokeHandler(deviceId) : NO;
    if (ok) [self notifyChange];
    [self reload];
}

#pragma mark - Project actions

- (void)addProject:(id)sender {
    (void)sender;
    if (CPRunningSelfTests) return;
    NSOpenPanel *open = [NSOpenPanel openPanel];
    open.canChooseDirectories = YES;
    open.canChooseFiles = NO;
    open.allowsMultipleSelection = NO;
    open.canCreateDirectories = NO;
    open.prompt = @"添加";
    open.message = @"选择允许手机指挥的项目目录";
    // 对话框开着期间直接把监听摘掉,不依赖 attachedSheet 在点击那一刻的时序。
    // 它比本面板宽一倍多,点里面任何一处(文件夹、侧边栏、「添加」)都落在 panel.frame 外,
    // 而对话框由另一个进程绘制,全局监听收得到——不摘就会「点完文件夹面板自己关了」。
    [self removeMonitors];
    __weak typeof(self) weakSelf = self;
    [open beginSheetModalForWindow:self.panel completionHandler:^(NSModalResponse result) {
        CPControlSettingsController *self2 = weakSelf;
        if (self2.panel.isVisible) [self2 installMonitors];
        if (result != NSModalResponseOK) return;
        NSURL *url = open.URLs.firstObject;
        if (!url.isFileURL) return;
        [weakSelf addPath:url.path name:nil];
    }];
}

- (void)addPath:(NSString *)path name:(NSString *)name {
    CPWorkdirEntry *entry = [self.effectiveStore addPath:path name:name];
    if (!entry) return;
    [self notifyChange];
    [self reload];
}

- (void)addPathForTesting:(NSString *)path {
    [self addPath:path name:nil];
}

- (void)removeProjectClicked:(NSButton *)sender {
    [self removeWorkdirID:sender.identifier];
}

- (void)removeProjectAtIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.workdirIDs.count) return;
    [self removeWorkdirID:self.workdirIDs[(NSUInteger)index]];
}

- (void)removeWorkdirID:(NSString *)workdirID {
    if (![self.effectiveStore removeEntry:workdirID]) return;
    if ([self.editingWorkdirID isEqualToString:workdirID]) {
        self.editingWorkdirID = nil;
        self.editField = nil;
    }
    [self notifyChange];
    [self reload];
}

- (void)startProjectEdit:(NSButton *)sender {
    self.editingWorkdirID = sender.identifier;
    [self reload];
}

- (void)commitProjectEdit:(NSTextField *)sender {
    NSString *workdirID = sender.identifier ?: self.editingWorkdirID;
    NSString *name = [sender.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.editingWorkdirID = nil;
    self.editField = nil;
    if (name.length && [self.effectiveStore renameEntry:workdirID to:name]) [self notifyChange];
    [self reload];
}

- (void)renameProjectAtIndex:(NSInteger)index to:(NSString *)name {
    if (index < 0 || index >= (NSInteger)self.workdirIDs.count) return;
    if (![self.effectiveStore renameEntry:self.workdirIDs[(NSUInteger)index] to:name]) return;
    [self notifyChange];
    [self reload];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSTextField *field = notification.object;
    if (field == self.editField) [self commitProjectEdit:field];
}

- (void)dealloc {
    [self removeMonitors];
}

@end
