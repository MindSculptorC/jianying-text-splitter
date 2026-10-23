// Command-line integration test for the exact backend runner compiled into App.m.
// It never creates NSApplication, opens windows, or sends UI events.
#define main JYGUIEntryPoint
#import "App.m"
#undef main

static void Check(BOOL good, NSString *message) {
    if (!good) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        NSError *error = nil;
        if (argc >= 3) {
            AppDelegate *app = [AppDelegate new]; app.resources = @(argv[1]);
            NSMutableArray *arguments = [NSMutableArray array];
            for (int i = 3; i < argc; i++) [arguments addObject:@(argv[i])];
            NSDictionary *result = [app run:@(argv[2]) args:arguments error:&error];
            if (!result) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
            NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:&error];
            fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
            return 0;
        }
        NSDictionary *large = JYRunProcess(@[@"/usr/bin/python3", @"-c",
            @"import json,sys; sys.stderr.write('e'*2000000); print(json.dumps({'ok':True,'payload':'x'*2000000}))"], 10, &error);
        Check(large && [large[@"exit_code"] intValue] == 0 && [large[@"stdout"] length] > 2000000 && [large[@"stderr"] length] == 2000000,
            [NSString stringWithFormat:@"large dual output: %@", error]);
        NSDictionary *orphan = JYRunProcess(@[@"/usr/bin/python3", @"-c",
            @"import os,time,json; child=os.fork(); time.sleep(1) if child==0 else print(json.dumps({'ok':True})); os._exit(0) if child==0 else None"], 10, &error);
        Check(orphan && [orphan[@"elapsed"] doubleValue] < .8, @"must not wait for inherited output descriptor EOF");
        NSDictionary *timeout = JYRunProcess(@[@"/usr/bin/python3", @"-c", @"import time; time.sleep(20)"], .15, &error);
        Check(timeout && [timeout[@"timed_out"] boolValue] && [timeout[@"elapsed"] doubleValue] < 4.5, @"timeout returns within deadline");
        NSDictionary *missing = JYRunProcess(@[@"/nonexistent-python-test"], 1, &error);
        Check(!missing && error, @"missing executable reports NSError");
        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"JYAppRunnerTest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:nil error:&error];
        AppDelegate *app = [AppDelegate new]; app.resources = directory;
        NSDictionary *scripts = @{@"ok.py":@"import json; print(json.dumps({'ok':True,'count':19}))",
            @"badjson.py":@"print('not json')", @"error.py":@"import json; print(json.dumps({'ok':False,'error':'test failure'}))",
            @"exit.py":@"import sys; print('explicit stderr',file=sys.stderr); sys.exit(4)"};
        for (NSString *name in scripts) [scripts[name] writeToFile:[directory stringByAppendingPathComponent:name] atomically:YES encoding:NSUTF8StringEncoding error:&error];
        NSDictionary *good = [app run:@"ok.py" args:@[] error:&error];
        Check([good[@"count"] intValue] == 19, @"run parses valid JSON dictionary");
        for (NSString *name in @[@"badjson.py", @"error.py", @"exit.py"]) {
            error = nil;
            Check(![app run:name args:@[] error:&error] && error.localizedDescription.length > 0, [@"run returns error for " stringByAppendingString:name]);
        }
        error = nil;
        Check(![app run:@"ok.py" args:@[@42] error:&error] && error, @"non-string argument reports exception without escaping");
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        printf("PASS: large dual output, inherited descriptor, timeout, missing executable, valid/malformed/error JSON, nonzero exit, invalid argument\n");
        return 0;
    }
}
