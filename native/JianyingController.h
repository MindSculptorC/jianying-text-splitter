#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Synchronous methods: call on a background queue so the AppKit UI can stay
// responsive. Progress callbacks are delivered on the main queue.
@interface JianyingController : NSObject
@property (atomic) BOOL cancelled;
@property (nonatomic) int64_t expectedDurationUS; // 0 disables whole-master duration comparison.
@property (nonatomic) NSTimeInterval exportTimeout; // Default: 20 minutes.
@property (nonatomic, copy, nullable) void (^progressHandler)(NSString *message);
- (void)cancel;
- (BOOL)prepareHome:(NSError **)error;
- (BOOL)openPreparedDraft:(NSString *)expectedName error:(NSError **)error;
- (BOOL)exportOpenDraft:(NSString *)expectedName outputPath:(NSString *)outputPath error:(NSError **)error;
@end

NS_ASSUME_NONNULL_END
