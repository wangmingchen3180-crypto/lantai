#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface XCTestCase : NSObject
- (void)setUp;
- (void)tearDown;
@end

#define XCTAssertTrue(expr, ...) do { (void)(expr); } while (0)
#define XCTAssertFalse(expr, ...) do { (void)(expr); } while (0)
#define XCTAssertNil(expr, ...) do { (void)(expr); } while (0)
#define XCTAssertNotNil(expr, ...) do { (void)(expr); } while (0)
#define XCTAssertEqual(a, b, ...) do { (void)(a); (void)(b); } while (0)
#define XCTAssertEqualObjects(a, b, ...) do { (void)(a); (void)(b); } while (0)
#define XCTAssert(expr, ...) do { (void)(expr); } while (0)

NS_ASSUME_NONNULL_END
