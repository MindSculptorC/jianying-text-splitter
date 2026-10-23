#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <AudioToolbox/AudioToolbox.h>
#include <math.h>
#include <unistd.h>

static void Require(BOOL valid, NSString *message) {
    if (!valid) @throw [NSException exceptionWithName:@"fixture" reason:message userInfo:nil];
}
static CMSampleBufferRef AudioFrame(int frame) {
    float samples[1600];
    for (int i = 0; i < 1600; i++) samples[i] = sin((frame * 1600.0 + i) * 2 * M_PI * 440 / 48000) * .15;
    CMBlockBufferRef block = NULL;
    Require(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, sizeof(samples), kCFAllocatorDefault,
        NULL, 0, sizeof(samples), 0, &block) == noErr, @"audio block");
    Require(CMBlockBufferReplaceDataBytes(samples, block, 0, sizeof(samples)) == noErr, @"audio copy");
    AudioStreamBasicDescription desc = { .mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, .mBytesPerPacket = 4,
        .mFramesPerPacket = 1, .mBytesPerFrame = 4, .mChannelsPerFrame = 1, .mBitsPerChannel = 32 };
    CMAudioFormatDescriptionRef format = NULL;
    Require(CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &desc, 0, NULL, 0, NULL, NULL, &format) == noErr, @"audio format");
    CMSampleTimingInfo timing = {CMTimeMake(1, 48000), CMTimeMake(frame * 1600, 48000), kCMTimeInvalid};
    size_t sampleSize = 4;
    CMSampleBufferRef sample = NULL;
    Require(CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1600, 1, &timing, 1, &sampleSize, &sample) == noErr, @"audio sample");
    CFRelease(block); CFRelease(format);
    return sample;
}
static void Create(NSURL *output) {
    NSError *error = nil;
    AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:output fileType:AVFileTypeMPEG4 error:&error];
    Require(writer != nil, error.localizedDescription);
    AVAssetWriterInput *video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:@{
        AVVideoCodecKey: AVVideoCodecTypeH264, AVVideoWidthKey: @640, AVVideoHeightKey: @360,
        AVVideoCompressionPropertiesKey: @{AVVideoAverageBitRateKey: @2000000}}];
    video.transform = CGAffineTransformMake(0, 1, -1, 0, 360, 0);
    AVAssetWriterInput *audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:@{
        AVFormatIDKey: @(kAudioFormatMPEG4AAC), AVSampleRateKey: @48000, AVNumberOfChannelsKey: @1, AVEncoderBitRateKey: @128000}];
    AVAssetWriterInputPixelBufferAdaptor *adaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:video sourcePixelBufferAttributes:@{
        (__bridge NSString *)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA),
        (__bridge NSString *)kCVPixelBufferWidthKey: @640, (__bridge NSString *)kCVPixelBufferHeightKey: @360}];
    [writer addInput:video]; [writer addInput:audio];
    Require([writer startWriting], writer.error.localizedDescription);
    [writer startSessionAtSourceTime:kCMTimeZero];
    // Drain the two inputs independently: encoder backpressure can otherwise
    // deadlock when one input needs the other to advance (notably on CI VMs).
    int frame = 0, audioFrame = 0;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:45];
    while (frame < 90 || audioFrame < 90) {
        Require(writer.status == AVAssetWriterStatusWriting, writer.error.localizedDescription);
        Require(deadline.timeIntervalSinceNow > 0, @"fixture encoder timed out");
        BOOL advanced = NO;
        if (frame < 90 && video.readyForMoreMediaData) {
        CVPixelBufferRef pixel = NULL;
        Require(CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, adaptor.pixelBufferPool, &pixel) == kCVReturnSuccess, @"pixel creation");
        CVPixelBufferLockBaseAddress(pixel, 0);
        uint8_t *base = CVPixelBufferGetBaseAddress(pixel);
        size_t stride = CVPixelBufferGetBytesPerRow(pixel);
        for (int y = 0; y < 360; y++) for (int x = 0; x < 640; x++) {
            size_t i = y * stride + x * 4;
            base[i] = frame >= 60 ? 240 : 0;
            base[i + 1] = frame >= 30 && frame < 60 ? 240 : 0;
            base[i + 2] = frame < 30 ? 240 : 0;
            base[i + 3] = 255;
        }
        CVPixelBufferUnlockBaseAddress(pixel, 0);
        Require([adaptor appendPixelBuffer:pixel withPresentationTime:CMTimeMake(frame, 30)], writer.error.localizedDescription);
        CVPixelBufferRelease(pixel);
            frame++;
            advanced = YES;
            if (frame == 90) [video markAsFinished];
        }
        if (audioFrame < 90 && audio.readyForMoreMediaData) {
            CMSampleBufferRef audioSample = AudioFrame(audioFrame);
            Require([audio appendSampleBuffer:audioSample], writer.error.localizedDescription);
            CFRelease(audioSample);
            audioFrame++;
            advanced = YES;
            if (audioFrame == 90) [audio markAsFinished];
        }
        if (!advanced) usleep(2000);
    }
    [writer endSessionAtSourceTime:CMTimeMake(3, 1)];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [writer finishWritingWithCompletionHandler:^{ dispatch_semaphore_signal(done); }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    Require(writer.status == AVAssetWriterStatusCompleted, writer.error.localizedDescription);
    puts(output.path.UTF8String);
}
static void Inspect(NSURL *input) {
    AVAssetImageGenerator *generator = [AVAssetImageGenerator assetImageGeneratorWithAsset:[AVURLAsset URLAssetWithURL:input options:nil]];
    generator.appliesPreferredTrackTransform = YES;
    generator.requestedTimeToleranceBefore = kCMTimeZero;
    generator.requestedTimeToleranceAfter = kCMTimeZero;
    NSMutableArray *output = [NSMutableArray array];
    for (NSNumber *seconds in @[@.1, @.75]) {
        NSError *error = nil;
        CMTime actual;
        CGImageRef image = [generator copyCGImageAtTime:CMTimeMakeWithSeconds(seconds.doubleValue, 600) actualTime:&actual error:&error];
        Require(image != NULL, error.localizedDescription);
        uint8_t rgba[4] = {0};
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(rgba, 1, 1, 8, 4, space, kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image);
        [output addObject:@{@"time": @(CMTimeGetSeconds(actual)), @"width": @(CGImageGetWidth(image)), @"height": @(CGImageGetHeight(image)),
            @"rgba": @[@(rgba[0]), @(rgba[1]), @(rgba[2]), @(rgba[3])]}];
        CGContextRelease(context); CGColorSpaceRelease(space); CGImageRelease(image);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:output options:NSJSONWritingSortedKeys error:nil];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
}
int main(int argc, char **argv) {
    @autoreleasepool { @try {
        Require(argc == 3, @"media-fixture create|inspect file.mp4");
        NSURL *url = [NSURL fileURLWithPath:@(argv[2])];
        if (!strcmp(argv[1], "create")) Create(url);
        else if (!strcmp(argv[1], "inspect")) Inspect(url);
        else Require(NO, @"unknown fixture command");
        return 0;
    } @catch (NSException *error) { fprintf(stderr, "%s\n", error.reason.UTF8String); return 1; } }
}
