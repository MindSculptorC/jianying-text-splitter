#import "JianyingController.h"
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <AVFoundation/AVFoundation.h>
#include <sys/stat.h>
#include <math.h>
#include <fcntl.h>
#include <unistd.h>

static NSString * const JYErrorDomain = @"JianyingController";
static id JYAttribute(AXUIElementRef item, CFStringRef key) {
    if (!item) return nil;
    CFTypeRef value = NULL;
    return AXUIElementCopyAttributeValue(item, key, &value) == kAXErrorSuccess ? CFBridgingRelease(value) : nil;
}
static NSString *JYString(AXUIElementRef item, CFStringRef key) {
    id value = JYAttribute(item, key);
    return [value isKindOfClass:NSString.class] ? value : @"";
}
static NSArray *JYTree(AXUIElementRef root) {
    NSMutableArray *queue = [NSMutableArray array];
    if (root) [queue addObject:(__bridge id)root];
    NSMutableArray *all = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSUInteger i = 0; i < queue.count && all.count < 5000; i++) {
        id item = queue[i];
        if ([seen containsObject:item]) continue;
        [seen addObject:item]; [all addObject:item];
        id children = JYAttribute((__bridge AXUIElementRef)item, kAXChildrenAttribute);
        if ([children isKindOfClass:NSArray.class]) [queue addObjectsFromArray:children];
        id sheets = JYAttribute((__bridge AXUIElementRef)item, CFSTR("AXSheets"));
        if ([sheets isKindOfClass:NSArray.class]) [queue addObjectsFromArray:sheets];
    }
    return all;
}
static NSArray *JYMatches(AXUIElementRef root, NSString *identifier) {
    NSMutableArray *result = [NSMutableArray array];
    for (id raw in JYTree(root)) {
        AXUIElementRef item = (__bridge AXUIElementRef)raw;
        if ([JYString(item, kAXIdentifierAttribute) isEqualToString:identifier] ||
            [JYString(item, kAXDescriptionAttribute) isEqualToString:identifier]) [result addObject:raw];
    }
    return result;
}
static BOOL JYFrame(AXUIElementRef element, CGRect *frame) {
    id p = JYAttribute(element, kAXPositionAttribute), s = JYAttribute(element, kAXSizeAttribute);
    if (!p || !s || CFGetTypeID((__bridge CFTypeRef)p) != AXValueGetTypeID() || CFGetTypeID((__bridge CFTypeRef)s) != AXValueGetTypeID()) return NO;
    CGPoint point; CGSize size;
    if (!AXValueGetValue((__bridge AXValueRef)p, kAXValueCGPointType, &point) ||
        !AXValueGetValue((__bridge AXValueRef)s, kAXValueCGSizeType, &size)) return NO;
    if (size.width <= 0 || size.height <= 0) return NO;
    *frame = (CGRect){point, size}; return YES;
}
static void JYControllerLog(NSString *message) {
    NSLog(@"[Jianying AX] %@", message);
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"JianyingSplitter"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *path = [directory stringByAppendingPathComponent:@"controller.log"];
    struct stat prior;
    int flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_APPEND;
    if (stat(path.fileSystemRepresentation, &prior) == 0 && prior.st_size > 2 * 1024 * 1024) flags = O_WRONLY | O_CREAT | O_CLOEXEC | O_TRUNC;
    int fd = open(path.fileSystemRepresentation, flags, 0600);
    if (fd >= 0) {
        NSData *data = [[NSString stringWithFormat:@"%@ %@\n", NSDate.date, message] dataUsingEncoding:NSUTF8StringEncoding];
        (void)write(fd, data.bytes, data.length); close(fd);
    }
}
static NSString *JYDiagnosticText(NSString *text) {
    NSString *line = [[text stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
    return line.length <= 240 ? line : [[line substringToIndex:240] stringByAppendingString:@"…"];
}
static void JYDiagnosticTree(AXUIElementRef root, NSString *stage, BOOL windowsOnly) {
    if (!root) return;
    NSMutableString *report = [NSMutableString stringWithFormat:@"AX SNAPSHOT %@ (metadata only; no AXValue)\n", stage];
    id windows = JYAttribute(root, kAXWindowsAttribute);
    NSMutableArray *queue = [NSMutableArray arrayWithArray:[windows isKindOfClass:NSArray.class] ? windows : @[]];
    if (!queue.count && ![JYString(root, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXApplicationRole]) [queue addObject:(__bridge id)root];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger captured = 0;
    for (NSUInteger i = 0; i < queue.count && captured < 240; i++) {
        id raw = queue[i];
        if ([seen containsObject:raw]) continue;
        [seen addObject:raw]; captured++;
        AXUIElementRef item = (__bridge AXUIElementRef)raw;
        NSString *role = JYString(item, kAXRoleAttribute), *subrole = JYString(item, kAXSubroleAttribute);
        id protected = JYAttribute(item, CFSTR("AXProtectedContent"));
        if ([role localizedCaseInsensitiveContainsString:@"secure"] || [subrole localizedCaseInsensitiveContainsString:@"secure"] ||
            ([protected respondsToSelector:@selector(boolValue)] && [protected boolValue])) {
            [report appendFormat:@"%lu role=%@ [protected metadata omitted]\n", (unsigned long)captured, role];
            continue;
        }
        CGRect frame = CGRectZero;
        BOOL framed = JYFrame(item, &frame);
        [report appendFormat:@"%lu role=%@ title=\"%@\" description=\"%@\" identifier=\"%@\" frame=%@\n",
            (unsigned long)captured, role, JYDiagnosticText(JYString(item, kAXTitleAttribute)),
            JYDiagnosticText(JYString(item, kAXDescriptionAttribute)), JYDiagnosticText(JYString(item, kAXIdentifierAttribute)),
            framed ? [NSString stringWithFormat:@"(%.1f,%.1f %.1fx%.1f)", frame.origin.x, frame.origin.y, frame.size.width, frame.size.height] : @"unavailable"];
        if (!windowsOnly) {
            id children = JYAttribute(item, kAXChildrenAttribute), sheets = JYAttribute(item, CFSTR("AXSheets"));
            if ([children isKindOfClass:NSArray.class]) [queue addObjectsFromArray:children];
            if ([sheets isKindOfClass:NSArray.class]) [queue addObjectsFromArray:sheets];
        }
    }
    if (queue.count > captured) [report appendString:@"[snapshot limit 240 elements]\n"];
    JYControllerLog(report);
}
static BOOL JYLayoutScale(CGRect frame, CGSize reference, CGFloat *scale) {
    if (frame.size.width <= 0 || frame.size.height <= 0) return NO;
    CGFloat candidate = frame.size.width / reference.width;
    CGFloat aspectError = fabs((frame.size.width / frame.size.height) / (reference.width / reference.height) - 1);
    if (candidate < .7 || candidate > 2.5 || aspectError > .01) return NO;
    *scale = candidate; return YES;
}
static BOOL JYTargetIsValid(pid_t pid) {
    NSRunningApplication *target = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    return AXIsProcessTrusted() && pid > 0 && target && !target.terminated && [target.bundleIdentifier isEqualToString:@"com.lemon.lvpro"];
}
static BOOL JYEditorOwnsApplication(pid_t pid, NSRunningApplication *front) {
    if(front.processIdentifier==pid)return YES;
    NSRunningApplication *editor=[NSRunningApplication runningApplicationWithProcessIdentifier:pid];
    NSString *panelHost=[editor.bundleURL.path stringByAppendingPathComponent:@"Contents/Frameworks/VideoFusion-macOS.app"];
    // Jianying presents its native folder chooser from this bundled host.
    return !front.terminated && [front.bundleIdentifier isEqualToString:@"com.lemon.lvpro"] &&
        [front.bundleURL.path.stringByStandardizingPath isEqualToString:panelHost.stringByStandardizingPath];
}
static BOOL JYEditorOwnsForeground(pid_t pid) {
    return JYEditorOwnsApplication(pid,NSWorkspace.sharedWorkspace.frontmostApplication);
}
static BOOL JYPostToEditor(pid_t pid, CGEventRef event) {
    if (!event || !JYTargetIsValid(pid)) return NO;
    // Qt ignores directly routed mouse events. Use the normal event stream
    // only while the exact editor process owns the foreground; refuse input
    // immediately if the user switches to another application.
    if (!JYEditorOwnsForeground(pid)) return NO;
    CGEventPost(kCGSessionEventTap,event);
    return YES;
}
static void JYClick(pid_t pid, CGPoint point, BOOL doubleClick) {
    CGEventRef move = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, point, kCGMouseButtonLeft);
    JYPostToEditor(pid, move); CFRelease(move);
    for (int i = 0; i < (doubleClick ? 2 : 1); i++) {
        CGEventRef down = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, point, kCGMouseButtonLeft);
        CGEventRef up = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, point, kCGMouseButtonLeft);
        CGEventSetIntegerValueField(down, kCGMouseEventClickState, i + 1);
        CGEventSetIntegerValueField(up, kCGMouseEventClickState, i + 1);
        JYPostToEditor(pid, down); [NSThread sleepForTimeInterval:.04]; JYPostToEditor(pid, up);
        CFRelease(down); CFRelease(up);
        if (doubleClick) [NSThread sleepForTimeInterval:.08];
    }
    [NSThread sleepForTimeInterval:.15];
}
static BOOL JYClickElement(pid_t pid, AXUIElementRef element) {
    CGRect rect;
    pid_t owner = 0;
    if (!JYTargetIsValid(pid) || AXUIElementGetPid(element, &owner) != kAXErrorSuccess ||
        !JYEditorOwnsApplication(pid,[NSRunningApplication runningApplicationWithProcessIdentifier:owner]) || !JYFrame(element, &rect)) return NO;
    JYClick(pid, CGPointMake(CGRectGetMidX(rect), CGRectGetMidY(rect)), NO); return YES;
}
static void JYKey(pid_t pid, CGKeyCode key, CGEventFlags flags) {
    CGEventRef down = CGEventCreateKeyboardEvent(NULL, key, true), up = CGEventCreateKeyboardEvent(NULL, key, false);
    CGEventSetFlags(down, flags); CGEventSetFlags(up, flags);
    JYPostToEditor(pid, down); [NSThread sleepForTimeInterval:.04]; JYPostToEditor(pid, up);
    CFRelease(down); CFRelease(up);
    [NSThread sleepForTimeInterval:.12];
}
static void JYType(pid_t pid, NSString *text) {
    // Unicode CGEvents avoid changing the user's clipboard.
    NSUInteger length = text.length;
    unichar *characters = calloc(MAX(length, 1), sizeof(unichar));
    [text getCharacters:characters range:NSMakeRange(0, length)];
    for (NSUInteger i = 0; i < length;) {
        NSUInteger count = CFStringIsSurrogateHighCharacter(characters[i]) && i+1<length ? 2 : 1;
        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true), up = CGEventCreateKeyboardEvent(NULL, 0, false);
        CGEventKeyboardSetUnicodeString(down, count, characters + i); CGEventKeyboardSetUnicodeString(up, count, characters + i);
        JYPostToEditor(pid, down); JYPostToEditor(pid, up);
        CFRelease(down); CFRelease(up);
        i+=count;
        [NSThread sleepForTimeInterval:.01];
    }
    free(characters);
}

@implementation JianyingController {
    AXUIElementRef _app;
    NSRunningApplication *_running;
    NSMutableSet<NSString *> *_reportedLookupFailures;
    BOOL _loggedBackgroundRouting;
}
- (instancetype)init { if ((self = [super init])) _exportTimeout = 20 * 60; return self; }
- (void)dealloc { if (_app) CFRelease(_app); }
- (void)cancel { self.cancelled = YES; }
- (void)progress:(NSString *)message {
    void (^callback)(NSString *) = self.progressHandler;
    if (callback) dispatch_async(dispatch_get_main_queue(), ^{ callback(message); });
}
- (BOOL)fail:(NSError **)error code:(NSInteger)code message:(NSString *)message {
    JYControllerLog([NSString stringWithFormat:@"FAIL code=%ld %@", (long)code, message]);
    if (_app && code != 1 && AXIsProcessTrusted()) JYDiagnosticTree(_app, [NSString stringWithFormat:@"failure %ld", (long)code], NO);
    if (error) *error = [NSError errorWithDomain:JYErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}
- (BOOL)connect:(NSError **)error {
    if (!AXIsProcessTrusted()) return [self fail:error code:1 message:@"请在系统设置 → 隐私与安全性 → 辅助功能中允许本工具控制电脑，然后重试。"];
    _running = nil;
    NSRunningApplication *onlyCandidate = nil;
    NSUInteger candidateCount = 0, visibleCount = 0;
    for (NSRunningApplication *candidate in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.lemon.lvpro"]) {
        NSString *path = candidate.bundleURL.path.lowercaseString ?: @"";
        BOOL embedded = [path containsString:@".app/contents/frameworks/"] || [path containsString:@".app/contents/helpers/"];
        BOOL helper = embedded && [path.lastPathComponent containsString:@"helper"] && [path.pathExtension isEqualToString:@"app"];
        if (candidate.terminated || helper) continue;
        candidateCount++; onlyCandidate = candidate;
        AXUIElementRef candidateApp = AXUIElementCreateApplication(candidate.processIdentifier);
        AXUIElementSetMessagingTimeout(candidateApp, 2.0);
        id candidateWindows = JYAttribute(candidateApp, kAXWindowsAttribute);
        CFRelease(candidateApp);
        if ([candidateWindows isKindOfClass:NSArray.class] && [candidateWindows count]) {
            visibleCount++;
            if (!_running || candidate.active) _running = candidate;
        }
    }
    if (visibleCount > 1 && !_running.active)
        return [self fail:error code:2 message:@"检测到多个剪映主窗口，请先将要操作的剪映切到前台。"];
    if (!_running && candidateCount == 1) _running = onlyCandidate;
    if (!_running) return [self fail:error code:2 message:@"请先打开当前 Mac 上的剪映专业版。"]; 
    if (_app) CFRelease(_app);
    _app = AXUIElementCreateApplication(_running.processIdentifier);
    _reportedLookupFailures = [NSMutableSet set];
    _loggedBackgroundRouting = NO;
    AXUIElementSetMessagingTimeout(_app, 2.0);
    AXUIElementSetAttributeValue(_app,kAXFrontmostAttribute,kCFBooleanTrue);
    __block BOOL activationAccepted = NO;
    void (^requestActivation)(void) = ^{
        activationAccepted = [self->_running activateWithOptions:NSApplicationActivateIgnoringOtherApps | NSApplicationActivateAllWindows];
        if (@available(macOS 14.0, *)) {
            [NSApp yieldActivationToApplication:self->_running];
            activationAccepted = [self->_running activateFromApplication:NSRunningApplication.currentApplication options:NSApplicationActivateAllWindows] || activationAccepted;
        } else {
            activationAccepted = [self->_running activateWithOptions:NSApplicationActivateIgnoringOtherApps];
        }
    };
    if (NSThread.isMainThread) requestActivation(); else dispatch_sync(dispatch_get_main_queue(), requestActivation);
    NSTimeInterval activationDeadline = NSProcessInfo.processInfo.systemUptime + 2;
    while (NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier != _running.processIdentifier && NSProcessInfo.processInfo.systemUptime < activationDeadline && !self.cancelled) {
        if (NSThread.isMainThread) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
        else [NSThread sleepForTimeInterval:.05];
    }
    JYControllerLog([NSString stringWithFormat:@"Cooperative activation accepted=%d foreground=%d target=%d; input requires exact foreground PID", activationAccepted,
        NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier, _running.processIdentifier]);
    JYControllerLog([NSString stringWithFormat:@"Connected editor pid=%d", _running.processIdentifier]);
    JYDiagnosticTree(_app, @"connected windows", YES);
    return YES;
}
- (NSArray *)windows {
    id windows = JYAttribute(_app, kAXWindowsAttribute);
    return [windows isKindOfClass:NSArray.class] ? windows : @[];
}
- (id)uniqueElement:(NSString *)identifier inRoot:(AXUIElementRef)root {
    NSArray *matches = JYMatches(root, identifier);
    // Qt can expose one visual control through nested accessibility nodes.
    // Collapse only nodes with the exact same nonempty screen rectangle;
    // distinct controls still count as ambiguous and stop the operation.
    if (matches.count > 1) {
        CGRect first = CGRectZero;
        BOOL same = JYFrame((__bridge AXUIElementRef)matches.firstObject, &first);
        for (id raw in matches) {
            CGRect current = CGRectZero;
            if (!JYFrame((__bridge AXUIElementRef)raw, &current) || !CGRectEqualToRect(first, current)) { same = NO; break; }
        }
        if (same) return matches.firstObject;
    }
    if (matches.count != 1) {
        NSString *key = [NSString stringWithFormat:@"%@|%@|%lu", identifier, JYString(root, kAXRoleAttribute), (unsigned long)matches.count];
        if (![_reportedLookupFailures containsObject:key]) {
            if (!_reportedLookupFailures) _reportedLookupFailures = [NSMutableSet set];
            [_reportedLookupFailures addObject:key];
            NSMutableString *report = [NSMutableString stringWithFormat:@"LOOKUP %@ exact identifier/description candidates=%lu\n", identifier, (unsigned long)matches.count];
            NSUInteger candidates = 0;
            for (id raw in JYTree(root)) {
                AXUIElementRef item = (__bridge AXUIElementRef)raw;
                NSString *role = JYString(item, kAXRoleAttribute), *subrole = JYString(item, kAXSubroleAttribute);
                if ([role localizedCaseInsensitiveContainsString:@"secure"] || [subrole localizedCaseInsensitiveContainsString:@"secure"]) continue;
                id protected = JYAttribute(item, CFSTR("AXProtectedContent"));
                if ([protected respondsToSelector:@selector(boolValue)] && [protected boolValue]) continue;
                NSString *title = JYString(item, kAXTitleAttribute), *description = JYString(item, kAXDescriptionAttribute), *identity = JYString(item, kAXIdentifierAttribute);
                BOOL candidate = [title containsString:identifier] || [description containsString:identifier] || [identity containsString:identifier];
                if (!candidate) continue;
                candidates++;
                CGRect rect = CGRectZero; BOOL framed = JYFrame(item, &rect);
                [report appendFormat:@"candidate %lu role=%@ title=\"%@\" description=\"%@\" identifier=\"%@\" frame=%@\n", (unsigned long)candidates, role,
                    JYDiagnosticText(title), JYDiagnosticText(description), JYDiagnosticText(identity), framed ? NSStringFromRect(NSRectFromCGRect(rect)) : @"unavailable"];
            }
            if (!candidates) [report appendString:@"No metadata candidates; bounded subtree follows.\n"];
            JYControllerLog(report);
            JYDiagnosticTree(root, [@"lookup " stringByAppendingString:identifier], NO);
        }
    }
    return matches.count == 1 ? matches.firstObject : nil;
}
- (BOOL)waitSeconds:(NSTimeInterval)seconds until:(BOOL (^)(void))condition {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:seconds];
    do {
        if (self.cancelled) return NO;
        if (condition()) return YES;
        [NSThread sleepForTimeInterval:.2];
    } while ([limit timeIntervalSinceNow] > 0);
    return NO;
}
- (BOOL)checkCancelled:(NSError **)error {
    return !self.cancelled || [self fail:error code:3 message:@"已停止自动操作。如果剪映已开始导出，请在剪映中手动取消；已生成文件保留供检查。"];
}
- (BOOL)foreground:(NSError **)error {
    if (![self checkCancelled:error]) return NO;
    pid_t owner = 0;
    if (!_app || !_running || !JYTargetIsValid(_running.processIdentifier) || AXUIElementGetPid(_app, &owner) != kAXErrorSuccess || owner != _running.processIdentifier)
        return [self fail:error code:4 message:@"原先确认的剪映进程已退出或控制权限已失效，已停止发送按键。请重新打开剪映后重试。"];
    if (!JYEditorOwnsForeground(_running.processIdentifier))
        return [self fail:error code:4 message:@"剪映未能获得前台，已停止输入。请将剪映窗口切到前台后继续导出。"];
    return YES;
}
- (BOOL)prepareHome:(NSError **)error {
    self.cancelled = NO;
    if (![self connect:error]) return NO;
    if ([self uniqueElement:@"HomePageStartProjectDesp" inRoot:_app]) return YES;
    if (![self uniqueElement:@"MainWindowTitleBarExportBtn" inRoot:_app])
        return [self fail:error code:10 message:@"没有确认当前窗口是剪映编辑界面，未发送关闭快捷键。请手动返回剪映首页后重试。"];
    if (![self foreground:error]) return NO;
    JYKey(_running.processIdentifier, 13, kCGEventFlagMaskCommand); // Command-W: return from draft to home.
    if ([self waitSeconds:10 until:^BOOL{ return [self uniqueElement:@"HomePageStartProjectDesp" inRoot:self->_app] != nil; }]) return YES;
    if (![self checkCancelled:error]) return NO;
    return [self fail:error code:10 message:@"没有确认剪映已返回首页。请手动保存草稿并返回首页，再重试。"];
}
- (BOOL)openPreparedDraft:(NSString *)expectedName error:(NSError **)error {
    self.cancelled = NO;
    if (expectedName.length == 0) return [self fail:error code:11 message:@"副本草稿名不能为空。"];
    if (![self connect:error]) return NO;
    if (![self uniqueElement:@"HomePageStartProjectDesp" inRoot:_app])
        return [self fail:error code:12 message:@"请先在剪映返回首页，或手动打开指定的无文本副本。"];
    NSArray *windows = [self windows];
    id home = nil;
    for (id window in windows) if ([self uniqueElement:@"HomePageStartProjectDesp" inRoot:(__bridge AXUIElementRef)window]) home = window;
    CGRect frame = CGRectZero;
    CGFloat homeScale = 0;
    if (!home) return [self fail:error code:13 message:@"无法唯一识别剪映首页窗口，请手动打开指定副本后继续。"];
    BOOL homeHasFrame = JYFrame((__bridge AXUIElementRef)home, &frame);
    BOOL homeCanFallback = homeHasFrame && JYLayoutScale(frame, CGSizeMake(1372, 768), &homeScale);
    JYControllerLog([NSString stringWithFormat:@"Home layout %.1fx%.1f coordinateFallback=%d scale=%.4f (primary: exact title AXFrame)", frame.size.width, frame.size.height, homeCanFallback, homeScale]);
    NSMutableArray *fields = [NSMutableArray array];
    for (id raw in JYTree((__bridge AXUIElementRef)home)) if ([JYString((__bridge AXUIElementRef)raw, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXTextFieldRole]) [fields addObject:raw];
    if (fields.count != 1) return [self fail:error code:14 message:@"未能唯一识别首页搜索框，请手动打开指定副本后继续。"];
    if (![self foreground:error]) return NO;
    AXUIElementRef searchField = (__bridge AXUIElementRef)fields.firstObject;
    AXError focused = AXUIElementSetAttributeValue(searchField, kAXFocusedAttribute, kCFBooleanTrue);
    if (focused != kAXErrorSuccess && !JYClickElement(_running.processIdentifier, searchField)) return [self fail:error code:15 message:@"无法聚焦剪映搜索框。"];
    AXError setValue = AXUIElementSetAttributeValue(searchField, kAXValueAttribute, (__bridge CFStringRef)expectedName);
    [NSThread sleepForTimeInterval:.15];
    BOOL searchMatches = [JYString(searchField, kAXValueAttribute) isEqualToString:expectedName];
    JYControllerLog([NSString stringWithFormat:@"Search AXSetValue status=%d verified=%d", setValue, searchMatches]);
    if (setValue != kAXErrorSuccess || !searchMatches) {
        if (![self foreground:error] || !JYClickElement(_running.processIdentifier, searchField)) return [self fail:error code:15 message:@"无法聚焦剪映搜索框。"];
        JYKey(_running.processIdentifier, 0, kCGEventFlagMaskCommand); JYType(_running.processIdentifier, expectedName);
        [NSThread sleepForTimeInterval:.2];
        searchMatches = [JYString(searchField, kAXValueAttribute) isEqualToString:expectedName];
        JYControllerLog([NSString stringWithFormat:@"Search typing fallback verified=%d", searchMatches]);
    }
    if (!searchMatches) return [self fail:error code:15 message:@"剪映搜索框没有接收完整副本名称，请手动打开指定副本后继续。"];
    if (![self foreground:error]) return NO;
    JYKey(_running.processIdentifier, 36, 0); // The verified native search field submits with Return.
    NSString *identifier = [@"HomePageDraftTitle:" stringByAppendingString:expectedName];
    __block id match = nil;
    if (![self waitSeconds:10 until:^BOOL{
        match = [self uniqueElement:identifier inRoot:self->_app];
        if (!match) return NO;
        NSUInteger titles = 0;
        for (id raw in JYTree(self->_app)) {
            AXUIElementRef item = (__bridge AXUIElementRef)raw;
            if ([JYString(item, kAXDescriptionAttribute) hasPrefix:@"HomePageDraftTitle:"] ||
                [JYString(item, kAXIdentifierAttribute) hasPrefix:@"HomePageDraftTitle:"]) titles++;
        }
        return titles == 1;
    }])
        return [self fail:error code:16 message:[NSString stringWithFormat:@"没有找到唯一同名副本“%@”。请手动打开该副本后继续。", expectedName]];
    if (![self foreground:error]) return NO;
    CGRect titleFrame = CGRectZero;
    AXUIElementRef titleElement = (__bridge AXUIElementRef)match;
    BOOL hasTitleFrame = JYFrame(titleElement, &titleFrame);
    // Draft titles can enter rename mode; click the exact matched draft card.
    for(id raw in JYTree((__bridge AXUIElementRef)home)) {
        AXUIElementRef candidate=(__bridge AXUIElementRef)raw;
        CGRect card=CGRectZero;
        if([JYString(candidate,kAXDescriptionAttribute) isEqualToString:@"HomePageDraft"] && JYFrame(candidate,&card) &&
           hasTitleFrame && CGRectContainsRect(card,titleFrame)) {titleFrame=card;break;}
    }
    if (!hasTitleFrame) {
        id parent = JYAttribute(titleElement, kAXParentAttribute);
        AXUIElementRef parentElement = parent ? (__bridge AXUIElementRef)parent : NULL;
        NSString *parentRole = JYString(parentElement, kAXRoleAttribute);
        if (parentElement && ![parentRole isEqualToString:(__bridge NSString *)kAXWindowRole] &&
            ![parentRole isEqualToString:(__bridge NSString *)kAXApplicationRole]) hasTitleFrame = JYFrame(parentElement, &titleFrame);
    }
    if (hasTitleFrame) {
        JYControllerLog([NSString stringWithFormat:@"Opening unique exact draft title via AXFrame %@", NSStringFromRect(NSRectFromCGRect(titleFrame))]);
        JYClick(_running.processIdentifier, CGPointMake(CGRectGetMidX(titleFrame), CGRectGetMidY(titleFrame)), YES);
    } else if (homeCanFallback) {
        JYControllerLog([NSString stringWithFormat:@"Draft title has no AXFrame; using verified layout fallback scale=%.4f", homeScale]);
        JYClick(_running.processIdentifier, CGPointMake(frame.origin.x + 281 * homeScale, frame.origin.y + 581 * homeScale), YES);
    } else {
        return [self fail:error code:13 message:[NSString stringWithFormat:@"副本标题没有可点击位置，首页 %.1f×%.1f 也不符合已验证布局。请手动打开副本“%@”，再点击继续导出。", frame.size.width, frame.size.height, expectedName]];
    }
    if (![self waitSeconds:25 until:^BOOL{ return [self uniqueElement:@"MainWindowTitleBarExportBtn" inRoot:self->_app] != nil; }]) {
        if (![self checkCancelled:error]) return NO;
        return [self fail:error code:17 message:@"副本尚未进入编辑界面，请手动打开后重试导出。"];
    }
    if(![self waitSeconds:30 until:^BOOL{
        for(id raw in JYTree(self->_app)){
            NSString *description=JYString((__bridge AXUIElementRef)raw,kAXDescriptionAttribute);
            if([description hasPrefix:@"totalProgress|"] && ![description hasSuffix:@"00:00:00:00"])return YES;
        }
        return NO;
    }])return [self fail:error code:17 message:@"剪映尚未加载完整时间轴，请等待加载结束后继续导出。"];
    [NSThread sleepForTimeInterval:1.5];
    return YES;
}
- (id)folderConfirmButton {
    NSSet *labels = [NSSet setWithArray:@[@"选择", @"打开", @"选取", @"Choose", @"Open"]];
    NSMutableArray *matches = [NSMutableArray array];
    for (id raw in JYTree(_app)) {
        AXUIElementRef item = (__bridge AXUIElementRef)raw;
        if (![JYString(item, kAXRoleAttribute) isEqualToString:(__bridge NSString *)kAXButtonRole]) continue;
        if ([labels containsObject:JYString(item, kAXTitleAttribute)] || [labels containsObject:JYString(item, kAXDescriptionAttribute)])
            [matches addObject:raw];
    }
    return matches.count == 1 ? matches.firstObject : nil;
}
- (BOOL)exportOpenDraft:(NSString *)expectedName outputPath:(NSString *)outputPath error:(NSError **)error {
    self.cancelled = NO;
    if (!expectedName.length || !outputPath.isAbsolutePath || ![outputPath.pathExtension.lowercaseString isEqualToString:@"mp4"])
        return [self fail:error code:20 message:@"导出需要副本名称及绝对路径的 .mp4 输出文件。"];
    NSString *finalOutput = outputPath.stringByStandardizingPath;
    if(![expectedName.lastPathComponent isEqualToString:expectedName])return [self fail:error code:20 message:@"副本名称不能包含路径分隔符。"];
    NSString *normalizedOutput = [finalOutput.stringByDeletingLastPathComponent stringByAppendingPathComponent:[expectedName stringByAppendingPathExtension:@"mp4"]];
    struct stat existing;
    if (lstat(normalizedOutput.fileSystemRepresentation, &existing) == 0 || lstat(finalOutput.fileSystemRepresentation, &existing) == 0)
        return [self fail:error code:21 message:@"目标母版文件已经存在，未覆盖。请使用新的输出文件名。"];
    BOOL directory = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:normalizedOutput.stringByDeletingLastPathComponent isDirectory:&directory] || !directory)
        return [self fail:error code:22 message:@"母版输出文件夹不存在。"];
    if (![self connect:error]) return NO;
    [self progress:@"正在打开剪映导出窗口…"];
    id exportButton = [self uniqueElement:@"MainWindowTitleBarExportBtn" inRoot:_app];
    if (![self foreground:error]) return NO;
    if (!exportButton || !JYClickElement(_running.processIdentifier, (__bridge AXUIElementRef)exportButton))
        return [self fail:error code:23 message:@"没有唯一识别当前编辑界面的导出按钮。请打开无文本副本后重试。"];
    NSString *expectedTitle = [@"导出-" stringByAppendingString:expectedName];
    __block id dialog = nil;
    BOOL found = [self waitSeconds:15 until:^BOOL{
        for (id window in [self windows]) if ([JYString((__bridge AXUIElementRef)window, kAXTitleAttribute) isEqualToString:expectedTitle]) { dialog = window; return YES; }
        return NO;
    }];
    if (!found) {
        if (![self checkCancelled:error]) return NO;
        return [self fail:error code:24 message:[NSString stringWithFormat:@"没有确认导出窗口属于副本“%@”，已停止。请检查打开的草稿名称。", expectedName]];
    }
    CGRect rect = CGRectZero;
    CGFloat exportScale = 0;
    if (!JYFrame((__bridge AXUIElementRef)dialog, &rect) || !JYLayoutScale(rect, CGSizeMake(640, 720), &exportScale))
        return [self fail:error code:25 message:[NSString stringWithFormat:@"剪映导出面板尺寸 %.1f×%.1f 与已验证布局比例不同（参考 640×720），请手动将无文本母版导出到指定路径后继续。", rect.size.width, rect.size.height]];
    JYControllerLog([NSString stringWithFormat:@"Export layout %.1fx%.1f scale=%.4f", rect.size.width, rect.size.height, exportScale]);
    // The AX window is published before Qt finishes its opening animation.
    [NSThread sleepForTimeInterval:1.0];
    if (![self foreground:error]) return NO;
    // Keep the default exact draft title; relocate the completed master only
    // after verification. This avoids typing into Qt's non-AX title field.
    id folderButton = [self uniqueElement:@"ExportFileNameInputBtn" inRoot:(__bridge AXUIElementRef)dialog];
    if (!folderButton || ![self foreground:error] || !JYClickElement(_running.processIdentifier, (__bridge AXUIElementRef)folderButton))
        return [self fail:error code:26 message:@"未识别导出文件夹选择按钮，已停止。"];
    if (![self waitSeconds:8 until:^BOOL{ return [self folderConfirmButton] != nil; }])
        return [self fail:error code:27 message:@"系统文件夹选择窗口未就绪，请手动选择母版输出文件夹。"];
    if (![self foreground:error]) return NO;
    JYKey(_running.processIdentifier, 5, kCGEventFlagMaskCommand | kCGEventFlagMaskShift); // Command-Shift-G
    __block id pathField=nil;
    [self waitSeconds:5 until:^BOOL{
        pathField=[self uniqueElement:@"PathTextField" inRoot:self->_app];
        if(!pathField){
            for(NSRunningApplication *candidate in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.lemon.lvpro"]){
                if(!JYEditorOwnsApplication(self->_running.processIdentifier,candidate))continue;
                AXUIElementRef host=AXUIElementCreateApplication(candidate.processIdentifier);
                pathField=[self uniqueElement:@"PathTextField" inRoot:host];CFRelease(host);
                if(pathField)break;
            }
        }
        return pathField!=nil;
    }];
    if(!pathField)return [self fail:error code:28 message:@"系统没有打开前往文件夹输入框，未输入路径。请手动选择母版输出文件夹。"]; 
    NSString *directoryPath=normalizedOutput.stringByDeletingLastPathComponent;
    BOOL pathSet=pathField && AXUIElementSetAttributeValue((__bridge AXUIElementRef)pathField,kAXValueAttribute,(__bridge CFStringRef)directoryPath)==kAXErrorSuccess &&
        [JYString((__bridge AXUIElementRef)pathField,kAXValueAttribute) isEqualToString:directoryPath];
    if(!pathSet){JYKey(_running.processIdentifier, 0, kCGEventFlagMaskCommand); JYType(_running.processIdentifier, directoryPath);}
    JYKey(_running.processIdentifier, 36, 0);
    [NSThread sleepForTimeInterval:.5];
    id choose = [self folderConfirmButton];
    // Returning to an already selected directory can submit the native panel
    // directly. The exact export path below remains the final condition.
    if (![self foreground:error])return NO;
    if (choose && !JYClickElement(_running.processIdentifier, (__bridge AXUIElementRef)choose))
        return [self fail:error code:28 message:@"无法确认系统文件夹选择，请手动选定导出文件夹后重试。"];
    __block NSString *observedPath = nil;
    BOOL pathMatches = [self waitSeconds:8 until:^BOOL{
        if(JYMatches(self->_app,@"open-panel").count || JYMatches(self->_app,@"GoToWindow").count)return NO;
        id pathElement = [self uniqueElement:@"ExportPathInput" inRoot:(__bridge AXUIElementRef)dialog];
        if(!pathElement)pathElement=[self uniqueElement:@"ExportFileNameInput" inRoot:(__bridge AXUIElementRef)dialog];
        if (!pathElement) return NO;
        observedPath = JYString((__bridge AXUIElementRef)pathElement, kAXValueAttribute);
        NSMutableSet *paths=[NSMutableSet set];
        for(id raw in JYTree((__bridge AXUIElementRef)dialog)){
            for(NSString *candidate in @[JYString((__bridge AXUIElementRef)raw,kAXValueAttribute),JYString((__bridge AXUIElementRef)raw,kAXDescriptionAttribute)])
                if(candidate.isAbsolutePath && [candidate.pathExtension.lowercaseString isEqualToString:@"mp4"])[paths addObject:candidate.stringByStandardizingPath];
        }
        if(paths.count==1)observedPath=paths.anyObject;
        else if(paths.count>1)return NO;
        return [observedPath.stringByStandardizingPath isEqualToString:normalizedOutput];
    }];
    if (!pathMatches) return [self fail:error code:29 message:[NSString stringWithFormat:@"导出路径校验失败，未开始导出。预期：%@；剪映显示：%@", normalizedOutput, observedPath ?: @"无法读取"]];
    if (lstat(normalizedOutput.fileSystemRepresentation, &existing) == 0)
        return [self fail:error code:30 message:@"导出前发现目标文件已存在，未点击导出。"];
    id confirm = [self uniqueElement:@"ExportOkBtn" inRoot:(__bridge AXUIElementRef)dialog];
    if (!confirm || ![self foreground:error] || !JYClickElement(_running.processIdentifier, (__bridge AXUIElementRef)confirm))
        return [self fail:error code:31 message:@"没有识别导出确认按钮，已停止。"];
    [self progress:@"剪映正在渲染无文本母版，请保持剪映运行…"];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MAX(self.exportTimeout, 1)];
    unsigned long long previousSize = 0;
    NSUInteger stableCount = 0;
    while ([deadline timeIntervalSinceNow] > 0) {
        if (![self checkCancelled:error]) return NO;
        if (_running.terminated) return [self fail:error code:32 message:@"剪映已退出，母版导出未完成。"];
        NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:normalizedOutput error:nil];
        unsigned long long size = attributes.fileSize;
        if (size > 0 && size == previousSize) stableCount++; else stableCount = 0;
        previousSize = size;
        if (stableCount >= 3) {
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:normalizedOutput] options:@{AVURLAssetPreferPreciseDurationAndTimingKey: @YES}];
            double seconds = CMTimeGetSeconds(asset.duration);
            AVAssetTrack *video = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
            if (isfinite(seconds) && seconds > 0 && video) {
                int64_t observedDuration = llround(seconds * 1000000);
                int64_t tolerance = (int64_t)ceil(MAX(20000., 2000000. / MAX(video.nominalFrameRate, 1.)));
                if (self.expectedDurationUS > 0 && llabs(observedDuration - self.expectedDurationUS) > tolerance)
                    return [self fail:error code:33 message:[NSString stringWithFormat:@"母版时长校验失败：预期 %lld 微秒，实际 %lld 微秒。文件已保留，请检查是否导出了完整时间轴。", self.expectedDurationUS, observedDuration]];
                if(![normalizedOutput isEqualToString:finalOutput]) {
                    if(link(normalizedOutput.fileSystemRepresentation,finalOutput.fileSystemRepresentation)!=0)
                        return [self fail:error code:35 message:@"母版已导出，但无法归入任务路径；文件已保留，已有目标不会覆盖。"];
                    unlink(normalizedOutput.fileSystemRepresentation);
                }
                [self progress:@"无文本母版已完成并通过视频时长检查。"];
                return YES;
            }
        }
        [NSThread sleepForTimeInterval:1];
    }
    return [self fail:error code:34 message:@"等待剪映导出超过 20 分钟。已停止等待，剪映可能仍在渲染；请查看剪映导出窗口后重试。"];
}
@end
