// Copyright 2026 AudioHacking
// Minimal Cocoa host app that registers the Jam AUv3 extension.

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Magenta Jam Audio Unit";
    alert.informativeText =
        @"The Magenta Jam AUv3 extension is now registered.\n"
        @"It will appear as an Instrument in Logic Pro, "
        @"Ableton Live, GarageBand, and other AUv3 hosts.";
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender {
    return YES;
}

@end

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
