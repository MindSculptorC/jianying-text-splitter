#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <sys/stat.h>
#include <unistd.h>
#include <sys/stdio.h>
#include <errno.h>
#include <math.h>

// Objective-C AVFoundation backend, avoiding the host's mismatched Swift SDK.
static void Fail(NSString *code, NSString *message) {
    @throw [NSException exceptionWithName:code reason:message userInfo:nil];
}
static void PrintJSON(NSDictionary *value, FILE *stream) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:nil];
    fwrite(data.bytes, 1, data.length, stream);
    fputc('\n', stream);
}
static NSURL *InputURL(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path].URLByStandardizingPath;
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&directory] || directory)
        Fail(@"input_not_found", [@"找不到输入视频：" stringByAppendingString:url.path]);
    if (![[NSFileManager defaultManager] isReadableFileAtPath:url.path])
        Fail(@"input_not_readable", @"没有权限读取输入视频。");
    return url;
}
static AVURLAsset *Asset(NSURL *url) {
    return [AVURLAsset URLAssetWithURL:url options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
}
static NSDictionary *Probe(AVAsset *asset) {
    double duration = CMTimeGetSeconds(asset.duration);
    if (!isfinite(duration) || duration <= 0) Fail(@"invalid_duration", @"视频时长无效。");
    AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!video) Fail(@"no_video", @"输入文件没有视频轨道。");
    CGRect rect = CGRectApplyAffineTransform((CGRect){CGPointZero, video.naturalSize}, video.preferredTransform);
    return @{@"duration_us": @(llround(duration * 1000000)), @"width": @(llround(fabs(rect.size.width))),
        @"height": @(llround(fabs(rect.size.height))), @"fps": @(video.nominalFrameRate),
        @"has_audio": [asset tracksWithMediaType:AVMediaTypeAudio].count > 0 ? @YES : @NO};
}
static int64_t Integer(NSString *value) {
    NSScanner *scanner = [NSScanner scannerWithString:value];
    long long parsed;
    if (![scanner scanLongLong:&parsed] || !scanner.isAtEnd) Fail(@"invalid_range", @"时间参数必须为整数微秒。");
    return parsed;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        __block NSString *temporary = nil;
        int result = 0;
        @try {
            NSArray<NSString *> *args = [[NSProcessInfo processInfo] arguments];
            if (argc == 3 && [args[1] isEqualToString:@"probe"]) {
                PrintJSON(Probe(Asset(InputURL(args[2]))), stdout);
            } else if (argc == 6 && [args[1] isEqualToString:@"cut"]) {
                int64_t start = Integer(args[4]), duration = Integer(args[5]);
                if (start < 0 || duration <= 0 || start > INT64_MAX - duration)
                    Fail(@"invalid_range", @"开始时间须为非负整数，时长须为正整数（单位微秒）。");
                NSURL *input = InputURL(args[2]);
                NSURL *output = [NSURL fileURLWithPath:args[3]].URLByStandardizingPath;
                if (![output.pathExtension.lowercaseString isEqualToString:@"mp4"])
                    Fail(@"invalid_output_type", @"输出文件扩展名必须为 .mp4。");
                struct stat fileStatus;
                if (lstat(output.path.fileSystemRepresentation, &fileStatus) == 0)
                    Fail(@"output_exists", [@"目标文件已经存在，未覆盖：" stringByAppendingString:output.path]);
                if (errno != ENOENT) Fail(@"output_unavailable", @"不能检查目标路径。");
                NSURL *parent = output.URLByDeletingLastPathComponent;
                BOOL directory = NO;
                if (![[NSFileManager defaultManager] fileExistsAtPath:parent.path isDirectory:&directory] || !directory)
                    Fail(@"output_directory_missing", [@"目标文件夹不存在：" stringByAppendingString:parent.path]);
                AVURLAsset *asset = Asset(input);
                NSDictionary *source = Probe(asset);
                int64_t sourceDuration = [source[@"duration_us"] longLongValue];
                if (start >= sourceDuration || start + duration > sourceDuration + 1000)
                    Fail(@"range_outside_video", @"切段范围超出母版视频时长。");
                int64_t actualDuration = MIN(duration, sourceDuration - start);
                temporary = [parent.path stringByAppendingPathComponent:[NSString stringWithFormat:@".media-export-%@.mp4", NSUUID.UUID.UUIDString]];
                AVAssetExportSession *session = [[AVAssetExportSession alloc] initWithAsset:asset presetName:AVAssetExportPresetHighestQuality];
                if (!session) Fail(@"export_unavailable", @"系统无法为这个视频创建导出会话。");
                if (![session.supportedFileTypes containsObject:AVFileTypeMPEG4])
                    Fail(@"mp4_unsupported", @"该视频无法用系统导出器重新编码为 MP4。");
                session.outputURL = [NSURL fileURLWithPath:temporary];
                session.outputFileType = AVFileTypeMPEG4;
                session.shouldOptimizeForNetworkUse = YES;
                session.timeRange = CMTimeRangeMake(CMTimeMake(start, 1000000), CMTimeMake(actualDuration, 1000000));
                dispatch_semaphore_t finished = dispatch_semaphore_create(0);
                [session exportAsynchronouslyWithCompletionHandler:^{ dispatch_semaphore_signal(finished); }];
                dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);
                if (session.status != AVAssetExportSessionStatusCompleted)
                    Fail(@"export_failed", session.error.localizedDescription ?: @"系统视频导出失败。");
                NSDictionary *exported = Probe(Asset([NSURL fileURLWithPath:temporary]));
                int64_t tolerance = (int64_t)ceil(MAX(20000.0, 2000000.0 / MAX([source[@"fps"] doubleValue], 1.0)));
                if (llabs([exported[@"duration_us"] longLongValue] - actualDuration) > tolerance)
                    Fail(@"duration_mismatch", [NSString stringWithFormat:@"导出时长校验失败：期望 %lld 微秒，实际 %@ 微秒。", actualDuration, exported[@"duration_us"]]);
                if (![exported[@"width"] isEqual:source[@"width"]] || ![exported[@"height"] isEqual:source[@"height"]])
                    Fail(@"orientation_mismatch", @"导出视频的尺寸或方向与母版不一致。");
                // Atomic no-overwrite publication; supports volumes without hardlinks.
                if (renamex_np(temporary.fileSystemRepresentation, output.path.fileSystemRepresentation, RENAME_EXCL) != 0) {
                    int errorNumber = errno;
                    Fail(errorNumber == EEXIST ? @"output_exists" : @"publish_failed",
                        [NSString stringWithFormat:@"无法保存输出（已有文件不会被覆盖）：%s", strerror(errorNumber)]);
                }
                NSMutableDictionary *data = exported.mutableCopy;
                data[@"output"] = output.path;
                data[@"start_us"] = @(start);
                data[@"requested_duration_us"] = @(duration);
                PrintJSON(data, stdout);
            } else {
                Fail(@"usage", @"用法：media-export probe 输入视频；media-export cut 输入视频 输出.mp4 开始微秒 时长微秒");
            }
        } @catch (NSException *exception) {
            PrintJSON(@{@"error": exception.name, @"message": exception.reason ?: @"系统媒体处理失败。"}, stderr);
            result = 1;
        } @finally {
            if (temporary) [[NSFileManager defaultManager] removeItemAtPath:temporary error:nil];
        }
        return result;
    }
}
