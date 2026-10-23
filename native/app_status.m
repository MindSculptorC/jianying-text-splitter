#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>

// Read-only process presence check; never activates, quits or edits an app.
int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSMutableSet *pids = [NSMutableSet set];
    NSMutableSet *mainPids = [NSMutableSet set];
    NSMutableArray *processes = [NSMutableArray array];
    for (int i = 1; i < argc; ++i) {
      NSString *identifier = [NSString stringWithUTF8String:argv[i]];
      if (!identifier.length) return 2;
      NSArray *apps = [NSRunningApplication runningApplicationsWithBundleIdentifier:identifier];
      if (!apps) return 3;
      for (NSRunningApplication *app in apps) {
        if (!app.terminated && ![pids containsObject:@(app.processIdentifier)]) {
          [pids addObject:@(app.processIdentifier)];
          NSString *bundle = app.bundleURL.path ?: @"";
          NSString *lower = bundle.lowercaseString;
          // Jianying's TrayHelper reuses the main bundle identifier and stays
          // alive after the editor quits. Ignore only clearly embedded helper
          // bundles, never a main app merely because it is an accessory app.
          BOOL embedded = [lower containsString:@".app/contents/frameworks/"] ||
                          [lower containsString:@".app/contents/helpers/"];
          BOOL helperName = [lower.lastPathComponent containsString:@"helper"];
          BOOL helper = embedded && helperName && [lower.pathExtension isEqualToString:@"app"];
          if (!helper) [mainPids addObject:@(app.processIdentifier)];
          [processes addObject:@{ @"pid": @(app.processIdentifier),
                                 @"bundle_path": bundle,
                                 @"executable_path": app.executableURL.path ?: @"",
                                 @"activation_policy": @(app.activationPolicy),
                                 @"ignored_helper": @(helper) }];
        }
      }
    }
    if (argc < 2) return 2;
    NSDictionary *result = @{ @"running": @(mainPids.count > 0), @"pids": mainPids.allObjects,
                              @"all_pids": pids.allObjects, @"processes": processes };
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if (!json) return 3;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    return 0;
  }
}
