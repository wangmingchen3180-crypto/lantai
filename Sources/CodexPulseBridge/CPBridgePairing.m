#import "CPBridgePairing.h"
#import <Security/Security.h>

static NSString * const CPBridgeKeychainService = @"com.codexpulse.bridge.devices";
static NSString * const CPBridgeKeychainAccount = @"paired-devices-v1";

@implementation CPBridgeDevice
@end

@implementation CPBridgePairing {
    NSString *_pairingCode;
    NSDate *_pairingIssuedAt;
    NSInteger _failedAttempts;
    NSDate *_lockoutUntil;
    NSMutableArray<CPBridgeDevice *> *_devices;
    BOOL _loaded;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _pairingCodeTTL = 180;
    _lockoutDuration = 600;
    _maxFailedAttempts = 5;
    _devices = NSMutableArray.array;
    return self;
}

- (void)ensureLoaded {
    if (_loaded) return;
    _loaded = YES;
    if (self.inMemoryOnly) return;
    [_devices addObjectsFromArray:[self devicesFromKeychain]];
}

- (NSArray<CPBridgeDevice *> *)devicesFromKeychain {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CPBridgeKeychainService,
        (__bridge id)kSecAttrAccount: CPBridgeKeychainAccount,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (st != errSecSuccess || !result) return @[];
    NSData *data = (__bridge_transfer NSData *)result;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<CPBridgeDevice *> *devices = NSMutableArray.array;
    for (id item in (NSArray *)json) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = item;
        NSString *deviceId = [row[@"deviceId"] isKindOfClass:NSString.class] ? row[@"deviceId"] : nil;
        NSString *token = [row[@"token"] isKindOfClass:NSString.class] ? row[@"token"] : nil;
        if (!deviceId.length || !token.length) continue;
        CPBridgeDevice *device = CPBridgeDevice.new;
        device.deviceId = deviceId;
        device.deviceName = [row[@"deviceName"] isKindOfClass:NSString.class] ? row[@"deviceName"] : @"手机";
        device.token = token;
        device.createdAt = [row[@"createdAt"] isKindOfClass:NSNumber.class] ? [row[@"createdAt"] doubleValue] : 0;
        // 旧记录没有 canControl 字段时视为 NO,绝不能默认成 YES。
        device.canControl = [row[@"canControl"] isKindOfClass:NSNumber.class] ? [row[@"canControl"] boolValue] : NO;
        [devices addObject:device];
    }
    return devices;
}

- (void)persistDevices {
    if (self.inMemoryOnly) return;
    NSMutableArray *rows = NSMutableArray.array;
    for (CPBridgeDevice *device in _devices) {
        [rows addObject:@{
            @"deviceId": device.deviceId ?: @"",
            @"deviceName": device.deviceName ?: @"",
            @"token": device.token ?: @"",
            @"createdAt": @(device.createdAt),
            @"canControl": device.canControl ? @YES : @NO,
        }];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil] ?: [NSData data];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: CPBridgeKeychainService,
        (__bridge id)kSecAttrAccount: CPBridgeKeychainAccount,
    };
    NSDictionary *attrs = @{
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
    };
    OSStatus st = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attrs);
    if (st == errSecItemNotFound) {
        NSMutableDictionary *add = [query mutableCopy];
        [add addEntriesFromDictionary:attrs];
        SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    }
}

- (NSString *)randomToken {
    uint8_t bytes[32];
    if (SecRandomCopyBytes(kSecRandomDefault, sizeof(bytes), bytes) != errSecSuccess) {
        arc4random_buf(bytes, sizeof(bytes));
    }
    static const char table[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    NSMutableString *token = [NSMutableString stringWithCapacity:43];
    // 32 字节 → base64url 无填充,不透明随机串。
    int val = 0, valb = -6;
    for (int i = 0; i < 32; i++) {
        val = (val << 8) + bytes[i];
        valb += 8;
        while (valb >= 0) {
            [token appendFormat:@"%c", table[(val >> valb) & 0x3F]];
            valb -= 6;
        }
    }
    if (valb > -6) [token appendFormat:@"%c", table[((val << 8) >> (valb + 8)) & 0x3F]];
    return token;
}

- (NSString *)issuePairingCode {
    @synchronized (self) {
        uint32_t n = arc4random_uniform(1000000);
        _pairingCode = [NSString stringWithFormat:@"%06u", n];
        _pairingIssuedAt = NSDate.date;
        return _pairingCode;
    }
}

- (NSString *)currentPairingCode {
    @synchronized (self) {
        if (!_pairingCode.length || !_pairingIssuedAt) return nil;
        if ([[NSDate date] timeIntervalSinceDate:_pairingIssuedAt] > self.pairingCodeTTL) {
            _pairingCode = nil;
            _pairingIssuedAt = nil;
            return nil;
        }
        return _pairingCode;
    }
}

- (BOOL)isLockedOut {
    if (!_lockoutUntil) return NO;
    if ([_lockoutUntil timeIntervalSinceNow] > 0) return YES;
    _lockoutUntil = nil;
    _failedAttempts = 0;
    return NO;
}

- (void)registerFailure {
    _failedAttempts += 1;
    if (_failedAttempts >= self.maxFailedAttempts) {
        _lockoutUntil = [NSDate dateWithTimeIntervalSinceNow:self.lockoutDuration];
    }
}

- (NSDictionary *)pairWithCode:(NSString *)code deviceName:(NSString *)deviceName {
    @synchronized (self) {
        [self ensureLoaded];
        if ([self isLockedOut]) {
            return @{@"ok": @NO, @"status": @429, @"error": @"too_many_attempts"};
        }
        NSString *trimmed = [code stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *live = [self currentPairingCode];
        BOOL matches = live.length && trimmed.length && [live isEqualToString:trimmed];
        if (!matches) {
            [self registerFailure];
            if ([self isLockedOut]) {
                return @{@"ok": @NO, @"status": @429, @"error": @"too_many_attempts"};
            }
            return @{@"ok": @NO, @"status": @403, @"error": @"bad_code"};
        }
        _failedAttempts = 0;
        _lockoutUntil = nil;
        _pairingCode = nil;
        _pairingIssuedAt = nil;
        CPBridgeDevice *device = CPBridgeDevice.new;
        device.deviceId = NSUUID.UUID.UUIDString.lowercaseString;
        NSString *name = [deviceName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        device.deviceName = name.length ? name : @"手机";
        device.token = [self randomToken];
        device.createdAt = NSDate.date.timeIntervalSince1970;
        device.canControl = NO;
        [_devices addObject:device];
        [self persistDevices];
        return @{
            @"ok": @YES,
            @"status": @200,
            @"token": device.token,
            @"deviceId": device.deviceId,
            @"serverName": @"澜台",
        };
    }
}

- (BOOL)isTokenValid:(NSString *)token {
    if (!token.length) return NO;
    @synchronized (self) {
        [self ensureLoaded];
        for (CPBridgeDevice *device in _devices) {
            if ([device.token isEqualToString:token]) return YES;
        }
        return NO;
    }
}

- (CPBridgeDevice *)deviceForToken:(NSString *)token {
    if (!token.length) return nil;
    for (CPBridgeDevice *device in _devices) {
        if ([device.token isEqualToString:token]) return device;
    }
    return nil;
}

- (BOOL)deviceCanControlWithToken:(NSString *)token {
    @synchronized (self) {
        [self ensureLoaded];
        CPBridgeDevice *device = [self deviceForToken:token];
        return device ? device.canControl : NO;
    }
}

- (BOOL)setDevice:(NSString *)deviceId canControl:(BOOL)canControl {
    if (!deviceId.length) return NO;
    @synchronized (self) {
        [self ensureLoaded];
        for (CPBridgeDevice *device in _devices) {
            if (![device.deviceId isEqualToString:deviceId]) continue;
            device.canControl = canControl;
            [self persistDevices];
            return YES;
        }
        return NO;
    }
}

- (NSArray<CPBridgeDevice *> *)pairedDevices {
    @synchronized (self) {
        [self ensureLoaded];
        NSMutableArray<CPBridgeDevice *> *copy = NSMutableArray.array;
        for (CPBridgeDevice *device in _devices) {
            CPBridgeDevice *safe = CPBridgeDevice.new;
            safe.deviceId = device.deviceId;
            safe.deviceName = device.deviceName;
            safe.createdAt = device.createdAt;
            safe.canControl = device.canControl;
            [copy addObject:safe];
        }
        return copy;
    }
}

- (BOOL)revokeDevice:(NSString *)deviceId {
    if (!deviceId.length) return NO;
    @synchronized (self) {
        [self ensureLoaded];
        NSUInteger idx = [_devices indexOfObjectPassingTest:^BOOL(CPBridgeDevice *device, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop;
            return [device.deviceId isEqualToString:deviceId];
        }];
        if (idx == NSNotFound) return NO;
        [_devices removeObjectAtIndex:idx];
        [self persistDevices];
        return YES;
    }
}

- (void)clearAllDevices {
    @synchronized (self) {
        [_devices removeAllObjects];
        if (self.inMemoryOnly) return;
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: CPBridgeKeychainService,
            (__bridge id)kSecAttrAccount: CPBridgeKeychainAccount,
        };
        SecItemDelete((__bridge CFDictionaryRef)query);
    }
}

@end
