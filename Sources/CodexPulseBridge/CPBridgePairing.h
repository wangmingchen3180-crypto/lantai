#import <Foundation/Foundation.h>

@interface CPBridgeDevice : NSObject
@property (copy) NSString *deviceId;
@property (copy) NSString *deviceName;
@property (copy) NSString *token;
@property NSTimeInterval createdAt;
@property BOOL canControl;                 // 默认 NO;新配对不能下指令
@end

@interface CPBridgePairing : NSObject
@property NSTimeInterval pairingCodeTTL;   // 默认 180s
@property NSTimeInterval lockoutDuration;  // 默认 600s
@property NSInteger maxFailedAttempts;     // 默认 5
@property BOOL inMemoryOnly;               // 自测:token 不进用户 Keychain
- (NSString *)issuePairingCode;        // 6 位数字,只留内存
- (NSString *)currentPairingCode;      // 过期返回 nil;调用方不得写日志
- (NSDictionary *)pairWithCode:(NSString *)code deviceName:(NSString *)deviceName;
- (BOOL)isTokenValid:(NSString *)token;
- (BOOL)deviceCanControlWithToken:(NSString *)token;
- (BOOL)setDevice:(NSString *)deviceId canControl:(BOOL)canControl;
- (NSArray<CPBridgeDevice *> *)pairedDevices; // 不含 token,给 Mac 界面列出
- (BOOL)revokeDevice:(NSString *)deviceId;
- (void)clearAllDevices;               // 自测收尾
@end
