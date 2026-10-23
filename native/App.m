#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import "JianyingController.h"
#include <spawn.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <signal.h>
#include <errno.h>
#include <crt_externs.h>

static NSString *const Domain = @"Local.JianyingSplitter";

static void JYProcessLog(NSString *message) {
    NSLog(@"[backend] %@", message);
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"JianyingSplitter"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:nil];
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", NSDate.date, message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    int fd = open([directory stringByAppendingPathComponent:@"process.log"].fileSystemRepresentation,
                  O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600);
    if (fd >= 0) { (void)write(fd, data.bytes, data.length); close(fd); }
}

// Output is redirected to private files instead of NSPipes: a helper or its
// descendant retaining a pipe's write end can never strand the GUI on EOF.
// waitpid observes the process directly and all waits have a monotonic deadline.
static NSDictionary *JYRunProcess(NSArray<NSString *> *arguments, NSTimeInterval timeout, NSError **error) {
    NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"JYProcess-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    int stdoutFD = -1, stderrFD = -1;
    pid_t pid = -1;
    BOOL childReaped = NO, actionsReady = NO, attributesReady = NO;
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    char **argv = NULL;
    NSDictionary *result = nil;
    double started = NSProcessInfo.processInfo.systemUptime;
    @try {
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:error]) return nil;
        NSString *stdoutPath = [directory stringByAppendingPathComponent:@"stdout"], *stderrPath = [directory stringByAppendingPathComponent:@"stderr"];
        stdoutFD = open(stdoutPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        stderrFD = open(stderrPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0600);
        if (stdoutFD < 0 || stderrFD < 0) @throw [NSException exceptionWithName:@"ProcessIO" reason:@"无法建立后端临时日志。" userInfo:nil];
        int setupError = posix_spawn_file_actions_init(&actions);
        if (setupError) @throw [NSException exceptionWithName:@"ProcessSpawn" reason:@(strerror(setupError)) userInfo:nil];
        actionsReady = YES;
        setupError = posix_spawnattr_init(&attributes);
        if (setupError) @throw [NSException exceptionWithName:@"ProcessSpawn" reason:@(strerror(setupError)) userInfo:nil];
        attributesReady = YES;
        setupError = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
        setupError = setupError ?: posix_spawn_file_actions_adddup2(&actions, stdoutFD, STDOUT_FILENO);
        setupError = setupError ?: posix_spawn_file_actions_adddup2(&actions, stderrFD, STDERR_FILENO);
        setupError = setupError ?: posix_spawn_file_actions_addclose(&actions, stdoutFD);
        setupError = setupError ?: posix_spawn_file_actions_addclose(&actions, stderrFD);
        setupError = setupError ?: posix_spawnattr_setflags(&attributes, POSIX_SPAWN_SETPGROUP);
        setupError = setupError ?: posix_spawnattr_setpgroup(&attributes, 0);
        if (setupError) @throw [NSException exceptionWithName:@"ProcessSpawn" reason:@(strerror(setupError)) userInfo:nil];
        argv = calloc(arguments.count + 1, sizeof(char *));
        if (!argv) @throw [NSException exceptionWithName:@"ProcessMemory" reason:@"后端启动内存分配失败。" userInfo:nil];
        for (NSUInteger i = 0; i < arguments.count; i++) {
            if (![arguments[i] isKindOfClass:NSString.class]) @throw [NSException exceptionWithName:@"ProcessArguments" reason:@"后端参数包含非文本值。" userInfo:nil];
            argv[i] = (char *)arguments[i].UTF8String;
        }
        int spawnError = posix_spawn(&pid, argv[0], &actions, &attributes, argv, *_NSGetEnviron());
        if (spawnError) {
            pid = -1;
            @throw [NSException exceptionWithName:@"ProcessSpawn" reason:[NSString stringWithFormat:@"无法启动后端：%s", strerror(spawnError)] userInfo:nil];
        }
        close(stdoutFD); stdoutFD = -1; close(stderrFD); stderrFD = -1;
        int status = 0;
        BOOL timedOut = NO;
        for (;;) {
            pid_t observed = waitpid(pid, &status, WNOHANG);
            if (observed == pid) { childReaped = YES; break; }
            if (observed < 0 && errno != EINTR) {
                if (errno == ECHILD) childReaped = YES;
                @throw [NSException exceptionWithName:@"ProcessWait" reason:[NSString stringWithFormat:@"无法读取后端退出状态：%s", strerror(errno)] userInfo:nil];
            }
            if (NSProcessInfo.processInfo.systemUptime - started >= MAX(timeout, .05)) {
                timedOut = YES;
                kill(-pid, SIGTERM); // Own process group only, including encoder children.
                double stopDeadline = NSProcessInfo.processInfo.systemUptime + 2;
                while (NSProcessInfo.processInfo.systemUptime < stopDeadline) {
                    if (waitpid(pid, &status, WNOHANG) == pid) { childReaped = YES; break; }
                    usleep(20000);
                }
                if (!childReaped) {
                    kill(-pid, SIGKILL);
                    // Even a failed kill cannot make the UI wait forever.
                    stopDeadline = NSProcessInfo.processInfo.systemUptime + 2;
                    while (NSProcessInfo.processInfo.systemUptime < stopDeadline) {
                        if (waitpid(pid, &status, WNOHANG) == pid) { childReaped = YES; break; }
                        usleep(20000);
                    }
                }
                // The parent may exit promptly while a descendant ignores TERM.
                // Finish stopping the dedicated group even if the parent is reaped.
                kill(-pid, SIGKILL);
                break;
            }
            usleep(20000);
        }
        NSData *stdoutData = [NSData dataWithContentsOfFile:stdoutPath options:NSDataReadingMappedIfSafe error:nil] ?: [NSData data];
        NSData *stderrData = [NSData dataWithContentsOfFile:stderrPath options:NSDataReadingMappedIfSafe error:nil] ?: [NSData data];
        if (stdoutData.length > 64 * 1024 * 1024) @throw [NSException exceptionWithName:@"ProcessOutput" reason:@"后端返回内容超过 64 MB，请缩小处理范围。" userInfo:nil];
        NSInteger exitCode = WIFEXITED(status) ? WEXITSTATUS(status) : WIFSIGNALED(status) ? 128 + WTERMSIG(status) : -1;
        result = @{@"stdout":stdoutData, @"stderr":stderrData, @"exit_code":@(exitCode), @"timed_out":@(timedOut),
            @"elapsed":@(NSProcessInfo.processInfo.systemUptime - started)};
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"后端执行异常（%@）：%@", exception.name, exception.reason ?: @"未知异常"];
        if (error) *error = [NSError errorWithDomain:Domain code:101 userInfo:@{NSLocalizedDescriptionKey:message}];
        JYProcessLog(message);
    } @finally {
        if (pid > 0 && !childReaped) {
            kill(-pid, SIGKILL);
            // Nonblocking reap; never introduce a new unbounded failure path.
            (void)waitpid(pid, NULL, WNOHANG);
        }
        if (stdoutFD >= 0) close(stdoutFD);
        if (stderrFD >= 0) close(stderrFD);
        if (actionsReady) posix_spawn_file_actions_destroy(&actions);
        if (attributesReady) posix_spawnattr_destroy(&attributes);
        free(argv);
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
    }
    return result;
}
@interface AppDelegate : NSObject <NSApplicationDelegate,WKScriptMessageHandler,WKNavigationDelegate>
@property NSWindow *window;
@property WKWebView *web;
@property NSString *resources;
@property NSString *rootPath;
@property NSString *editorPath;
@property NSString *pythonPath;
@property NSMutableDictionary *aliases;
@property NSMutableDictionary *folderOverrides;
@property NSDictionary *currentPlan;
@property NSDictionary *job;
@property JianyingController *controller;
@property BOOL busy;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.resources=NSBundle.mainBundle.resourcePath;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    self.rootPath=[defaults stringForKey:@"outputRoot"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
    self.editorPath=[defaults stringForKey:@"editorPath"] ?: @"/Applications/VideoFusion-macOS.app";
    self.aliases=[[defaults dictionaryForKey:@"aliases"] mutableCopy] ?: [NSMutableDictionary dictionary];
    self.folderOverrides=[[defaults dictionaryForKey:@"folderOverrides"] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *lastJob=[defaults stringForKey:@"lastJob"];
    if (lastJob && [[NSFileManager defaultManager] fileExistsAtPath:lastJob]) {
        NSDictionary *j=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:lastJob] options:0 error:nil];
        if ([j isKindOfClass:NSDictionary.class]) {
            NSString *parent=lastJob.stringByDeletingLastPathComponent;
            NSDictionary *prepared=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[parent stringByAppendingPathComponent:@"prepared.json"]]?:[NSData data] options:0 error:nil];
            NSDictionary *plan=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:[parent stringByAppendingPathComponent:@"plan.json"]]?:[NSData data] options:0 error:nil];
            self.job=@{@"job_path":lastJob,@"master_path":j[@"master_path"]?:@"",@"prepared":prepared?:@{},@"plan":plan?:@{}};
        }
    }
    NSMenu *menu=[NSMenu new],*appMenu=[NSMenu new];NSMenuItem *appItem=[NSMenuItem new];[menu addItem:appItem];[appItem setSubmenu:appMenu];
    [appMenu addItemWithTitle:@"关于剪映文本切段助手" action:@selector(orderFrontStandardAboutPanel:) keyEquivalent:@""];
    [appMenu addItem:NSMenuItem.separatorItem];[appMenu addItemWithTitle:@"退出" action:@selector(terminate:) keyEquivalent:@"q"];
    NSMenuItem *editItem=[[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];NSMenu *edit=[NSMenu new];editItem.submenu=edit;[menu addItem:editItem];
    for(NSArray *item in @[@[@"复制",@"copy:",@"c"],@[@"粘贴",@"paste:",@"v"],@[@"全选",@"selectAll:",@"a"]]) [edit addItemWithTitle:item[0] action:NSSelectorFromString(item[1]) keyEquivalent:item[2]];
    NSApp.mainMenu=menu;
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1120,790) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    self.window.title=@"剪映文本切段助手";self.window.minSize=NSMakeSize(930,720);[self.window center];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];[config.userContentController addScriptMessageHandler:self name:@"native"];
    self.web=[[WKWebView alloc] initWithFrame:self.window.contentView.bounds configuration:config];self.web.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;self.web.navigationDelegate=self;
    [self.window.contentView addSubview:self.web];
    NSURL *page=[NSURL fileURLWithPath:[self.resources stringByAppendingPathComponent:@"ui/index.html"]];
    [self.web loadFileURL:page allowingReadAccessToURL:[page URLByDeletingLastPathComponent]];
    [self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {return !self.busy;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    if (!self.busy)return NSTerminateNow;
    NSAlert *a=[NSAlert new];a.messageText=@"当前导出还在进行";a.informativeText=@"请等待本轮完成。关闭工具不会自动取消剪映中的渲染。";[a addButtonWithTitle:@"继续等待"];[a runModal];return NSTerminateCancel;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSURL *u=action.request.URL;
    BOOL local=u.isFileURL && [u.path hasPrefix:[self.resources stringByAppendingPathComponent:@"ui/"]];
    handler(local?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)emit:(NSDictionary *)value {
    dispatch_async(dispatch_get_main_queue(), ^{NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];if(data){NSString *js=[NSString stringWithFormat:@"window.receive(%@)",[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];[self.web evaluateJavaScript:js completionHandler:nil];}});
}
- (void)status:(NSString *)text error:(BOOL)error {[self emit:@{@"type":@"status",@"text":text?:@"",@"error":@(error)}];}
- (void)setWorking:(BOOL)value {self.busy=value;[self emit:@{@"type":@"busy",@"value":@(value)}];}
- (NSError *)problem:(NSString *)text {return [NSError errorWithDomain:Domain code:1 userInfo:@{NSLocalizedDescriptionKey:text?:@"操作失败"}];}
- (NSString *)findPython:(NSError **)error {
    if(self.pythonPath.length)return self.pythonPath;
    NSFileManager *fm=NSFileManager.defaultManager;
    NSMutableArray *paths=[NSMutableArray array];
    NSString *saved=[NSUserDefaults.standardUserDefaults stringForKey:@"pythonPath"];
    if(saved.length)[paths addObject:saved];
    [paths addObjectsFromArray:@[@"/opt/homebrew/bin/python3",@"/usr/local/bin/python3"]];
    NSString *versions=@"/Library/Frameworks/Python.framework/Versions";
    for(NSString *v in [[fm contentsOfDirectoryAtPath:versions error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)].reverseObjectEnumerator){
        [paths addObject:[[versions stringByAppendingPathComponent:v] stringByAppendingPathComponent:@"bin/python3"]];
    }
    // Avoid invoking Apple's developer-tools installation shim on a fresh Mac.
    if([fm fileExistsAtPath:@"/Library/Developer/CommandLineTools/usr/bin/python3"] || [fm fileExistsAtPath:@"/Applications/Xcode.app"])
        [paths addObject:@"/usr/bin/python3"];
    for(NSString *path in paths){
        if(![fm isExecutableFileAtPath:path])continue;
        NSDictionary *probe=JYRunProcess(@[path,@"-I",@"-c",@"import sys; print('JY_PYTHON_OK' if sys.version_info >= (3,9) else 'OLD')"],8,nil);
        NSString *result=[[NSString alloc] initWithData:probe[@"stdout"]?:[NSData data] encoding:NSUTF8StringEncoding];
        if(probe && [probe[@"exit_code"] intValue]==0 && [result containsString:@"JY_PYTHON_OK"]){self.pythonPath=path;return path;}
    }
    if(error)*error=[self problem:@"没有找到 Python 3.9 或更新版本。请从 python.org 安装适用于 macOS 的 Python 3，重新打开助手；已有其他位置的 Python 可点击底部「Python 位置」选择。无需安装 pip 依赖。"];
    return nil;
}
- (NSDictionary *)run:(NSString *)script args:(NSArray *)args error:(NSError **)error {
    @try {
        NSString *command = [args.firstObject isKindOfClass:NSString.class] ? args.firstObject : @"";
        NSTimeInterval timeout = [command isEqualToString:@"split"] ? 7200 : [command isEqualToString:@"prepare"] ? 300 : 120;
        NSString *label = [NSString stringWithFormat:@"%@ %@", script, command];
        JYProcessLog([NSString stringWithFormat:@"START %@ (timeout %.0fs)", label, timeout]);
        NSString *python=[self findPython:error]; if(!python)return nil;
        NSArray *arguments = [@[python, [self.resources stringByAppendingPathComponent:script]] arrayByAddingObjectsFromArray:args];
        NSDictionary *process = JYRunProcess(arguments, timeout, error);
        if (!process) return nil;
        JYProcessLog([NSString stringWithFormat:@"END %@ code=%@ duration=%.3fs stdout=%lu stderr=%lu timeout=%@", label,
            process[@"exit_code"], [process[@"elapsed"] doubleValue], (unsigned long)[process[@"stdout"] length],
            (unsigned long)[process[@"stderr"] length], process[@"timed_out"]]);
        if ([process[@"timed_out"] boolValue]) {
            NSString *message = [NSString stringWithFormat:@"后端操作“%@”超过 %.0f 秒，已停止该操作。已完成的文件会保留，可重新读取或继续切分。", command, timeout];
            if (error) *error = [self problem:message];
            [self status:message error:YES];
            return nil;
        }
        NSError *jsonError = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:process[@"stdout"] options:0 error:&jsonError];
        NSDictionary *result = [parsed isKindOfClass:NSDictionary.class] ? parsed : nil;
        if ([process[@"exit_code"] integerValue] != 0 || !result || [result[@"ok"] isEqual:@NO]) {
            id detail = result[@"error"];
            NSString *message = [detail isKindOfClass:NSString.class] ? detail : nil;
            if (!message.length) message = [[NSString alloc] initWithData:process[@"stderr"] encoding:NSUTF8StringEncoding];
            if (!message.length) message = jsonError ? [@"后端没有返回有效 JSON：" stringByAppendingString:jsonError.localizedDescription] : @"后端没有返回有效结果。";
            for (NSString *key in @[@"job_path",@"recovery_path"]) if([result[key] isKindOfClass:NSString.class]) message=[message stringByAppendingFormat:@"\n%@: %@",key,result[key]];
            if (message.length > 4000) message = [[message substringToIndex:4000] stringByAppendingString:@"…"];
            JYProcessLog([NSString stringWithFormat:@"FAIL %@ %@", label, message]);
            if (error) *error = [self problem:message];
            return nil;
        }
        return result;
    } @catch (NSException *exception) {
        NSString *message = [NSString stringWithFormat:@"后端调用异常（%@）：%@", exception.name, exception.reason ?: @"未知异常"];
        JYProcessLog(message);
        if (error) *error = [self problem:message];
        [self status:message error:YES];
        return nil;
    }
}
- (NSString *)aliasesFileForRoot:(NSString *)root {
    NSString *dir=[NSTemporaryDirectory() stringByAppendingPathComponent:@"JianyingSplitter"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
    NSString *path=[dir stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".json"]];
    NSData *data=[NSJSONSerialization dataWithJSONObject:self.aliases[root]?:@{} options:0 error:nil];[data writeToFile:path atomically:YES];return path;
}
- (NSString *)jsonFile:(NSDictionary *)value {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".json"]];
    [[NSJSONSerialization dataWithJSONObject:value options:0 error:nil] writeToFile:path atomically:YES];return path;
}
- (NSString *)overrideKey:(NSDictionary *)m {
    return [NSString stringWithFormat:@"%@\n%@",m[@"draft"]?:@"",self.rootPath];
}
- (NSDictionary *)optionsForMessage:(NSDictionary *)m {
    NSDictionary *settings=@{@"match_mode":m[@"matchMode"]?:@"exact",@"output_mode":m[@"outputMode"]?:@"matched",@"incremental":m[@"incremental"]?:@YES};
    [NSUserDefaults.standardUserDefaults setObject:settings forKey:@"exportSettings"];
    NSMutableDictionary *options=[settings mutableCopy];
    options[@"folder_overrides"]=self.folderOverrides[[self overrideKey:m]]?:@{};
    return options;
}
- (void)refresh {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{NSError *e=nil;NSDictionary *r=[self run:@"core.py" args:@[@"list"] error:&e];
        if(!r){[self status:e.localizedDescription error:YES];return;}
        NSMutableArray *drafts=[NSMutableArray array];for(NSDictionary *d in r[@"drafts"]?:@[]){if(![d[@"name"] hasPrefix:@"切段助手_"])[drafts addObject:d];}
        [self emit:@{@"type":@"init",@"root":self.rootPath,@"app":self.editorPath,@"drafts":drafts,@"settings":[NSUserDefaults.standardUserDefaults dictionaryForKey:@"exportSettings"]?:@{}}];
        if(self.job)[self emit:@{@"type":@"job",@"job":self.job}];
    });
}
- (NSMutableArray *)planArgs:(NSDictionary *)m aliases:(NSString *)aliases {
    NSMutableArray *args=[@[@"plan",@"--draft",m[@"draft"]?:@"",@"--output",m[@"root"]?:self.rootPath,@"--app",self.editorPath,@"--aliases",aliases] mutableCopy];
    if([m[@"track"] length])[args addObjectsFromArray:@[@"--track",m[@"track"]]];return args;
}
- (void)scan:(NSDictionary *)m {
    self.currentPlan=nil;[self setWorking:YES];[self status:@"正在读取草稿与分类文件夹…" error:NO];NSString *aliases=[self aliasesFileForRoot:self.rootPath];
    NSString *options=[self jsonFile:[self optionsForMessage:m]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{NSError *e=nil;NSMutableArray *args=[self planArgs:m aliases:aliases];[args addObjectsFromArray:@[@"--options",options]];NSDictionary *r=[self run:@"core.py" args:args error:&e];
        [[NSFileManager defaultManager] removeItemAtPath:options error:nil];[[NSFileManager defaultManager] removeItemAtPath:aliases error:nil];
        if(r){self.currentPlan=r;[self emit:@{@"type":@"plan",@"plan":r}];}else [self status:e.localizedDescription error:YES];[self setWorking:NO];
    });
}
- (void)chooseDirectory:(NSString *)title completion:(void (^)(NSString *))callback {
    NSOpenPanel *p=[NSOpenPanel openPanel];p.title=title;p.canChooseDirectories=YES;p.canChooseFiles=NO;p.canCreateDirectories=YES;p.allowsMultipleSelection=NO;
    if(self.rootPath)p.directoryURL=[NSURL fileURLWithPath:self.rootPath];
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){if(response==NSModalResponseOK)callback(p.URL.path.stringByStandardizingPath.stringByResolvingSymlinksInPath);}];
}
- (void)permission {
    NSAlert *a=[NSAlert new];a.messageText=@"允许本工具控制剪映";a.informativeText=@"系统的“辅助功能”权限用于点击剪映导出按钮、输入保存路径。请在系统设置 → 隐私与安全性 → 辅助功能中启用“剪映文本切段助手”，然后回到这里继续。";[a addButtonWithTitle:@"打开设置"];[a addButtonWithTitle:@"稍后"];
    if([a runModal]==NSAlertFirstButtonReturn){NSDictionary *opts=@{(__bridge NSString *)kAXTrustedCheckOptionPrompt:@YES};AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);[[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];}
}
- (JianyingController *)newController {
    JianyingController *c=[JianyingController new];__weak AppDelegate *weakSelf=self;c.progressHandler=^(NSString *message){[weakSelf status:message error:NO];};self.controller=c;return c;
}
- (BOOL)launchEditor:(NSError **)error {
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);__block NSError *launchError=nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        NSWorkspaceOpenConfiguration *cfg=[NSWorkspaceOpenConfiguration configuration];cfg.activates=YES;
        BOOL mainRunning=NO;
        for(NSRunningApplication *candidate in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.lemon.lvpro"]){
            if(!candidate.terminated&&[candidate.bundleURL.path.stringByStandardizingPath isEqualToString:self.editorPath.stringByStandardizingPath])mainRunning=YES;
        }
        // The tray helper shares the editor's bundle ID. Without a fresh launch,
        // LaunchServices can activate only that helper after the editor exits.
        cfg.createsNewApplicationInstance=!mainRunning;
        [[NSWorkspace sharedWorkspace] openApplicationAtURL:[NSURL fileURLWithPath:self.editorPath] configuration:cfg completionHandler:^(NSRunningApplication *app,NSError *e){launchError=e;dispatch_semaphore_signal(sem);}];
    });
    if(dispatch_semaphore_wait(sem,dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC))){if(error)*error=[self problem:@"打开剪映超时。请手动打开剪映，再继续。"];return NO;}
    if(launchError){if(error)*error=launchError;return NO;}
    // LaunchServices may finish before the main editor process has registered
    // its windows (or may initially return the embedded tray helper).
    for(int attempt=0;attempt<150;attempt++) {
        for(NSRunningApplication *candidate in [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.lemon.lvpro"]) {
            NSString *path=candidate.bundleURL.path.lowercaseString?:@"";
            BOOL embedded=[path containsString:@".app/contents/frameworks/"]||[path containsString:@".app/contents/helpers/"];
            if(candidate.terminated||(embedded&&[path.lastPathComponent containsString:@"helper"]))continue;
            AXUIElementRef element=AXUIElementCreateApplication(candidate.processIdentifier);
            AXUIElementSetMessagingTimeout(element,1);
            CFTypeRef windows=NULL;
            AXError result=AXUIElementCopyAttributeValue(element,kAXWindowsAttribute,&windows);
            BOOL ready=result==kAXErrorSuccess&&windows&&CFGetTypeID(windows)==CFArrayGetTypeID()&&CFArrayGetCount(windows)>0;
            if(windows)CFRelease(windows);CFRelease(element);
            if(ready)return YES;
        }
        [NSThread sleepForTimeInterval:.2];
    }
    if(error)*error=[self problem:@"剪映启动后尚未显示主窗口，请等首页出现后继续。"];return NO;
}
- (BOOL)closeEditor:(NSError **)error {
    BOOL (^isMainEditor)(NSRunningApplication *) = ^BOOL(NSRunningApplication *app) {
        NSString *path=app.bundleURL.path.lowercaseString?:@"";
        BOOL embedded=[path containsString:@".app/contents/frameworks/"]||[path containsString:@".app/contents/helpers/"];
        BOOL helper=embedded&&[path.lastPathComponent containsString:@"helper"]&&[path.pathExtension isEqualToString:@"app"];
        return !app.terminated&&!helper;
    };
    NSPredicate *mainOnly=[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary *bindings){return isMainEditor(object);}];
    NSArray *running=[[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.lemon.lvpro"] filteredArrayUsingPredicate:mainOnly];
    if(!running.count)return YES;
    if(![[self newController] prepareHome:error])return NO;
    for(NSRunningApplication *a in running)[a terminate];
    for(int i=0;i<100;i++){if(![[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.lemon.lvpro"] filteredArrayUsingPredicate:mainOnly].count)return YES;[NSThread sleepForTimeInterval:.15];}
    if(error)*error=[self problem:@"剪映尚未正常退出。请保存并退出剪映，再重新开始；工具没有强制结束进程。"];return NO;
}
- (void)saveJob:(NSDictionary *)r {
    self.job=r;[NSUserDefaults.standardUserDefaults setObject:r[@"job_path"] forKey:@"lastJob"];[self emit:@{@"type":@"job",@"job":r}];
}
- (BOOL)splitJobWithMaster:(NSString *)master error:(NSError **)error {
    [self status:@"正在精确切分并归档；完成的片段会逐个写入导出清单…" error:NO];
    NSMutableArray *args=[@[@"split",@"--job",self.job[@"job_path"]] mutableCopy];if(master.length)[args addObjectsFromArray:@[@"--master",master]];
    NSDictionary *r=[self run:@"workflow.py" args:args error:error];if(!r)return NO;
    [self emit:@{@"type":@"done",@"count":r[@"completed_count"]?:@0,@"skipped":r[@"skipped_count"]?:@0,@"exported":r[@"exported_count"]?:r[@"completed_count"]?:@0,@"manifest":r[@"manifest_path"]?:@""}];return YES;
}
- (void)exportPreparedAutomatically:(BOOL)openDraft {
    NSError *e=nil;JianyingController *c=[self newController];c.expectedDurationUS=[self.job[@"plan"][@"duration_us"] longLongValue];
    NSString *name=self.job[@"prepared"][@"draft_name"];
    if(!name.length||![self.job[@"master_path"] length]){[self status:@"恢复任务信息不完整，请重新读取草稿。" error:YES];return;}
    NSString *preparedPath=self.job[@"prepared"][@"draft_path"];
    if(!preparedPath.length){[self status:@"恢复任务没有副本路径，请重新准备无文本副本。" error:YES];return;}
    [self status:@"正在复核副本的全部时间轴均无可编辑文本…" error:NO];
    NSDictionary *clean=[self run:@"core.py" args:@[@"verify-clean",@"--draft",preparedPath,@"--app",self.editorPath] error:&e];
    if(!clean||![clean[@"clean"] boolValue]){[self status:e.localizedDescription?:@"副本没有通过无文本校验，未开始导出。" error:YES];return;}
    if([clean[@"duration_us"] longLongValue]!=c.expectedDurationUS){[self status:@"副本时间轴时长已经变化，请重新读取原草稿并生成导出任务。" error:YES];return;}
    if(openDraft){if(![self launchEditor:&e]||![c openPreparedDraft:name error:&e]){[self status:[NSString stringWithFormat:@"无文本副本已保留：%@\n%@\n请在剪映首页打开这个副本，再点“副本已打开，继续导出”。",name,e.localizedDescription] error:YES];return;}}
    if(![c exportOpenDraft:name outputPath:self.job[@"master_path"] error:&e]){[self status:[NSString stringWithFormat:@"%@\n可在剪映中将“%@”导出为完整无文本视频，再点“选择已导出的无文本整片”继续。",e.localizedDescription,name] error:YES];return;}
    if(![self splitJobWithMaster:nil error:&e])[self status:e.localizedDescription error:YES];
}
- (void)startExport:(NSDictionary *)m {
    if(!self.currentPlan||![self.currentPlan[@"can_export"] boolValue]){[self status:@"请先处理所有匹配问题并重新读取时间轴。" error:YES];return;}
    BOOL needsRender=[self.currentPlan[@"export_count"] integerValue]>0&&!self.currentPlan[@"reusable_master"];
    if(needsRender&&!AXIsProcessTrusted()){[self permission];return;}
    NSDictionary *plan=self.currentPlan;NSString *aliases=[self aliasesFileForRoot:self.rootPath];NSString *options=[self jsonFile:plan[@"options"]?:@{}];[self setWorking:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSError *e=nil;[self status:needsRender?@"正在保存并关闭剪映，随后建立去文本副本…":@"正在校验增量记录与可复用的无文本母版…" error:NO];
        if(needsRender&&![self closeEditor:&e]){[self status:e.localizedDescription error:YES];[self setWorking:NO];return;}
        NSMutableArray *args=[@[@"prepare",@"--draft",plan[@"draft_path"],@"--output",plan[@"output_root"],@"--app",self.editorPath,@"--aliases",aliases,@"--expected-sha",plan[@"source_sha256"]?:@"",@"--expected-fingerprint",plan[@"source_fingerprint"]?:@""] mutableCopy];
        if([m[@"track"] length])[args addObjectsFromArray:@[@"--track",m[@"track"]]];
        [args addObjectsFromArray:@[@"--options",options]];
        NSDictionary *r=[self run:@"workflow.py" args:args error:&e];
        [[NSFileManager defaultManager] removeItemAtPath:options error:nil];[[NSFileManager defaultManager] removeItemAtPath:aliases error:nil];
        if(!r){[self status:[NSString stringWithFormat:@"%@\n若刚才退出剪映触发了保存，请刷新后重新读取时间轴。",e.localizedDescription] error:YES];[self launchEditor:nil];[self setWorking:NO];return;}
        if([r[@"status"] isEqual:@"up_to_date"]){self.currentPlan=nil;[self emit:@{@"type":@"done",@"count":r[@"completed_count"],@"skipped":r[@"skipped_count"],@"exported":@0,@"manifest":@""}];[self setWorking:NO];return;}
        [self saveJob:r];if([r[@"reused_master"] boolValue]){if(![self splitJobWithMaster:nil error:&e])[self status:e.localizedDescription error:YES];}else [self exportPreparedAutomatically:YES];[self setWorking:NO];
    });
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if(![message.body isKindOfClass:NSDictionary.class])return;NSDictionary *m=message.body;NSString *action=m[@"action"];
    if(![action isKindOfClass:NSString.class])return;
    if(self.busy&&![@[@"openOutput",@"init"] containsObject:action])return;
    if([action isEqual:@"init"]||[action isEqual:@"refresh"]){[self refresh];return;}
    if([action isEqual:@"pickRoot"]){[self chooseDirectory:@"选择导出总文件夹" completion:^(NSString *path){self.rootPath=path;self.currentPlan=nil;[NSUserDefaults.standardUserDefaults setObject:path forKey:@"outputRoot"];[self emit:@{@"type":@"root",@"path":path}];}];return;}
    if([action isEqual:@"pickDraft"]){[self chooseDirectory:@"选择剪映草稿文件夹" completion:^(NSString *path){self.currentPlan=nil;[self emit:@{@"type":@"draft",@"path":path,@"name":path.lastPathComponent}];}];return;}
    if([action isEqual:@"pickSegmentFolder"]){NSString *key=m[@"segmentKey"];if(!key.length)return;[self chooseDirectory:[NSString stringWithFormat:@"为这一段“%@”选择任意输出文件夹",m[@"text"]?:@""] completion:^(NSString *path){NSString *scope=[self overrideKey:m];NSMutableDictionary *a=[self.folderOverrides[scope] mutableCopy]?:[NSMutableDictionary dictionary];a[key]=path;self.folderOverrides[scope]=a;[NSUserDefaults.standardUserDefaults setObject:self.folderOverrides forKey:@"folderOverrides"];[self scan:m];}];return;}
    if([action isEqual:@"resetSegmentFolder"]){NSString *scope=[self overrideKey:m];NSMutableDictionary *a=[self.folderOverrides[scope] mutableCopy]?:[NSMutableDictionary dictionary];[a removeObjectForKey:m[@"segmentKey"]?:@""];self.folderOverrides[scope]=a;[NSUserDefaults.standardUserDefaults setObject:self.folderOverrides forKey:@"folderOverrides"];[self scan:m];return;}
    if([action isEqual:@"pickPython"]){NSOpenPanel *p=[NSOpenPanel openPanel];p.title=@"选择 Python 3 可执行文件（python3）";p.canChooseDirectories=NO;p.canChooseFiles=YES;p.directoryURL=[NSURL fileURLWithPath:@"/usr/local/bin"];[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result){if(result==NSModalResponseOK){[NSUserDefaults.standardUserDefaults setObject:p.URL.path forKey:@"pythonPath"];self.pythonPath=nil;self.currentPlan=nil;[self refresh];}}];return;}
    if([action isEqual:@"pickApp"]){NSOpenPanel *p=[NSOpenPanel openPanel];p.allowedFileTypes=@[@"app"];p.directoryURL=[NSURL fileURLWithPath:@"/Applications"];[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK){self.editorPath=p.URL.path;self.currentPlan=nil;[NSUserDefaults.standardUserDefaults setObject:self.editorPath forKey:@"editorPath"];[self emit:@{@"type":@"app",@"path":self.editorPath}];}}];return;}
    if([action isEqual:@"pickAlias"]){NSString *text=m[@"text"];[self chooseDirectory:[NSString stringWithFormat:@"为“%@”指定文件夹",text] completion:^(NSString *path){NSString *root=[self.rootPath stringByResolvingSymlinksInPath],*target=[path stringByResolvingSymlinksInPath],*prefix=[root stringByAppendingString:@"/"];if(![target hasPrefix:prefix]){[self status:@"请选择导出总文件夹之内的分类子文件夹。" error:YES];return;}NSMutableDictionary *a=[self.aliases[self.rootPath] mutableCopy]?:[NSMutableDictionary dictionary];a[text]=[target substringFromIndex:prefix.length];self.aliases[self.rootPath]=a;[NSUserDefaults.standardUserDefaults setObject:self.aliases forKey:@"aliases"];[self scan:m];}];return;}
    if([action isEqual:@"scan"]){[self scan:m];return;}
    if([action isEqual:@"permission"]){[self permission];return;}
    if([action isEqual:@"openOutput"]){[[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:self.rootPath]];return;}
    if([action isEqual:@"openEditor"]){dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{NSError *e=nil;if(![self launchEditor:&e])[self status:e.localizedDescription error:YES];});return;}
    if([action isEqual:@"export"]){[self startExport:m];return;}
    if([action isEqual:@"continueExport"]){if(!self.job)return;if(!AXIsProcessTrusted()){[self permission];return;}[self setWorking:YES];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{[self exportPreparedAutomatically:NO];[self setWorking:NO];});return;}
    if([action isEqual:@"resumeSplit"]){if(!self.job)return;[self setWorking:YES];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *e=nil;if(![self splitJobWithMaster:nil error:&e])[self status:e.localizedDescription error:YES];[self setWorking:NO];});return;}
    if([action isEqual:@"pickMaster"]){if(!self.job)return;NSOpenPanel *p=[NSOpenPanel openPanel];p.title=@"选择从无文本副本导出的完整视频";p.allowedFileTypes=@[@"mp4",@"mov",@"m4v"];[p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r){if(r==NSModalResponseOK){NSAlert *a=[NSAlert new];a.messageText=@"确认视频来自无文本副本";a.informativeText=@"请选择工具生成的无文本副本所导出的完整视频，从时间轴 00:00 开始。工具会校验总时长，但无法自动判断视频画面是否仍有文本轨道。";[a addButtonWithTitle:@"确认并切分"];[a addButtonWithTitle:@"取消"];if([a runModal]!=NSAlertFirstButtonReturn)return;NSString *path=p.URL.path;[self setWorking:YES];dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{NSError *e=nil;if(![self splitJobWithMaster:path error:&e])[self status:e.localizedDescription error:YES];[self setWorking:NO];});}}];}
}
@end

int main(int argc,const char **argv){@autoreleasepool{NSApplication *app=[NSApplication sharedApplication];app.activationPolicy=NSApplicationActivationPolicyRegular;AppDelegate *delegate=[AppDelegate new];app.delegate=delegate;[app run];}return 0;}
