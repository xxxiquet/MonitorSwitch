#import <Cocoa/Cocoa.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/IOKitLib.h>
#import <Security/Security.h>
#import <ifaddrs.h>
#import <arpa/inet.h>

// Only HID++ service reports from this keyboard are used. Ordinary key reports
// are neither interpreted, recorded, nor forwarded.
static const int KeyboardVID = 0x046d, KeyboardPID = 0xb36e;


static NSInteger targetFromReport(const uint8_t *bytes, CFIndex length, uint32_t reportID, uint8_t feature) {
    if (!feature || length < 6 || (reportID != 0x10 && reportID != 0x11)) return NSNotFound;
    if (bytes[0] != reportID || bytes[1] != 0xff || bytes[2] != feature) return NSNotFound;
    // Software id 0 means a device notification, not a reply to our query.
    if ((bytes[3] & 0x0f) != 0 || bytes[5] >= 3) return NSNotFound;
    return bytes[5] + 1;
}

@interface MonitorSwitch : NSObject <NSApplicationDelegate>
@property NSStatusItem *statusItem;
@property NSMenuItem *infoItem, *autoItem;
@property NSUserDefaults *prefs;
@property NSArray<NSString *> *names;
@property NSArray<NSNumber *> *inputs;
@property IOHIDManagerRef manager;
@property IOHIDDeviceRef keyboard;
@property uint8_t feature;
@property uint8_t stage;
@property uint8_t deviceHost;
@property BOOL automatic, observeOnly, busy, suspended;
@property double lastTick, suppressUntil;
@property double lastHostQuery;
@property NSInteger pendingChannel;
@property NSInteger requestedChannel;
@property NSMutableData *reportBuffer;
@property NSTimer *timer;
@property NSString *lastLog;
@property NSString *statusText;
@property NSString *displayUUID;
@property NSArray<NSString *> *deviceTypes;
@property NSInteger macChannel;
@property NSString *logPath;
@property NSString *lastServiceReport;
@property NSTask *networkTask;
@property NSPipe *networkPipe;
@property NSMutableData *networkBuffer;
@property NSMutableSet<NSNumber *> *networkHostsSeen;
@property double networkRetryAt;
- (void)received:(const uint8_t *)bytes length:(CFIndex)length reportID:(uint32_t)reportID;
- (void)startNetworkListener;
- (void)stopNetworkListener;
- (void)networkOutput:(NSData *)data;
- (void)tick;
- (void)deviceArrived:(IOHIDDeviceRef)device;
- (void)deviceRemoved:(IOHIDDeviceRef)device;
@end

static void hidReport(void *context, IOReturn result, void *sender, IOHIDReportType type,
                      uint32_t reportID, uint8_t *bytes, CFIndex length) {
    if (result == kIOReturnSuccess)
        [(__bridge MonitorSwitch *)context received:bytes length:length reportID:reportID];
}

static void hidArrived(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    if (result == kIOReturnSuccess) [(__bridge MonitorSwitch *)context deviceArrived:device];
}
static void hidRemoved(void *context, IOReturn result, void *sender, IOHIDDeviceRef device) {
    [(__bridge MonitorSwitch *)context deviceRemoved:device];
}

@implementation MonitorSwitch
- (void)log:(NSString *)message {
    if ([message isEqualToString:self.lastLog]) return;
    self.lastLog = message;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], message];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:self.logPath];
    if (file) { [file seekToEndOfFile]; [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile]; }
    fprintf(stderr, "%s", line.UTF8String);
}
- (void)status:(NSString *)text {
    self.statusText = text;
    self.infoItem.title = text;
    self.statusItem.button.toolTip = text;
    [self log:text];
}
- (NSMenuItem *)item:(NSString *)title action:(SEL)action tag:(NSInteger)tag {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    item.target = self; item.tag = tag;
    return item;
}
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // The standard domain already uses CFBundleIdentifier. A suite with the
    // same identifier can return nil on macOS, silently dropping preferences.
    self.prefs = NSUserDefaults.standardUserDefaults;
    self.names = [self.prefs arrayForKey:@"names"] ?: @[@"Device 1", @"Device 2", @"Device 3"];
    if ([self.names isEqualToArray:@[@"HP1", @"MacBook", @"HP2"]]) self.names = @[@"Device 1", @"Device 2", @"Device 3"];
    NSString *configPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MonitorSwitch/network-config.json"];
    NSDictionary *config = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:configPath] ?: NSData.data options:0 error:nil];
    self.macChannel = [config[@"macChannel"] integerValue] ?: 2;
    if (self.macChannel < 1 || self.macChannel > 3) self.macChannel = 2;
    self.deviceTypes = config[@"deviceTypes"] ?: @[@"Windows", @"macOS", @"Windows"];
    self.displayUUID = [self.prefs stringForKey:@"displayUUID"] ?: config[@"displayUUID"] ?: @"";
    // 16 was read from this MSI while the Mac was using its USB-C connection.
    // Channel 3 is the second HP connected to HDMI 2.
    self.inputs = config[@"inputs"] ?: [self.prefs arrayForKey:@"inputs"] ?: @[@17, @16, @18];
    if (self.names.count != 3 || self.inputs.count != 3) { self.names = @[@"Device 1", @"Device 2", @"Device 3"]; self.inputs = @[@17, @16, @18]; }
    NSString *logDir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MonitorSwitch"];
    [[NSFileManager defaultManager] createDirectoryAtPath:logDir withIntermediateDirectories:YES attributes:nil error:nil];
    self.logPath = [logDir stringByAppendingPathComponent:@"monitor.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:self.logPath]) [@"" writeToFile:self.logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    [self.prefs registerDefaults:@{@"automatic": @YES, @"observeOnly": @NO}];
    self.automatic = [self.prefs boolForKey:@"automatic"];
    self.observeOnly = [self.prefs boolForKey:@"observeOnly"];
    self.networkHostsSeen = NSMutableSet.set;
    self.pendingChannel = NSNotFound;
    self.requestedChannel = NSNotFound;
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = [NSImage imageWithSystemSymbolName:@"display.2" accessibilityDescription:@"MonitorSwitch"];
    self.statusItem.button.image.template = YES;
    self.statusItem.button.accessibilityLabel = @"MonitorSwitch";
    [self rebuildMenu];
    // Track additions/removals on the manager while scheduling the opened
    // keyboard independently. An unscheduled manager keeps a stale device set.
    self.manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDManagerOptionIndependentDevices);
    IOHIDManagerSetDeviceMatching(self.manager, (__bridge CFDictionaryRef)@{ @kIOHIDVendorIDKey: @(KeyboardVID), @kIOHIDProductIDKey: @(KeyboardPID) });
    IOHIDManagerRegisterDeviceMatchingCallback(self.manager, hidArrived, (__bridge void *)self);
    IOHIDManagerRegisterDeviceRemovalCallback(self.manager, hidRemoved, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(wake:) name:NSWorkspaceDidWakeNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(sleep:) name:NSWorkspaceScreensDidSleepNotification object:nil];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(wake:) name:NSWorkspaceScreensDidWakeNotification object:nil];
    [self status:self.observeOnly ? @"Diagnostic mode · monitor unchanged" : @"Easy-Switch enabled · waiting for device events"];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self startNetworkListener];
    if (!config[@"keys"] || !config[@"macChannel"] || [NSProcessInfo.processInfo.arguments containsObject:@"--setup"]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self settings:nil]; });
    }
}
- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)visible {
    if (!visible) [self settings:nil];
    return YES;
}
- (void)rebuildMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"MonitorSwitch"];
    NSMenuItem *header = [self item:@"MonitorSwitch" action:nil tag:0];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 62)];
    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(16, 14, 36, 36)];
    icon.image = NSApp.applicationIconImage; [view addSubview:icon];
    NSTextField *title = [NSTextField labelWithString:@"MonitorSwitch"];
    title.font = [NSFont boldSystemFontOfSize:14]; title.frame = NSMakeRect(64, 32, 218, 20); [view addSubview:title];
    NSTextField *subtitle = [NSTextField labelWithString:@"One keyboard. One display. Three devices."];
    subtitle.font = [NSFont systemFontOfSize:11]; subtitle.textColor = NSColor.secondaryLabelColor;
    subtitle.frame = NSMakeRect(64, 13, 225, 17); [view addSubview:subtitle];
    header.view = view; [menu addItem:header];
    self.infoItem = [self item:self.statusText ?: @"Ready" action:nil tag:0]; [menu addItem:self.infoItem];
    [menu addItem:NSMenuItem.separatorItem];
    for (NSInteger i = 0; i < 3; i++) {
        NSString *port = self.inputs[i].intValue == 17 ? @"HDMI 1" : self.inputs[i].intValue == 18 ? @"HDMI 2" : self.inputs[i].intValue == 16 ? @"USB-C / DP 2" : self.inputs[i].intValue == 15 ? @"DisplayPort 1" : @"Not configured";
        NSMenuItem *item = [self item:[NSString stringWithFormat:@"%@  ·  %@", self.names[i], port] action:@selector(manual:) tag:i + 1];
        item.image = [NSImage imageWithSystemSymbolName:@"desktopcomputer" accessibilityDescription:nil];
        item.state = self.requestedChannel == i + 1 ? NSControlStateValueOn : NSControlStateValueOff;
        [menu addItem:item];
    }
    [menu addItem:NSMenuItem.separatorItem];
    self.autoItem = [self item:@"Follow Easy-Switch" action:@selector(toggleAuto:) tag:0];
    self.autoItem.state = self.automatic ? NSControlStateValueOn : NSControlStateValueOff; [menu addItem:self.autoItem];
    [menu addItem:[self item:@"Setup devices…" action:@selector(settings:) tag:0]];
    [menu addItem:[self item:@"Export Windows profiles…" action:@selector(exportProfiles:) tag:0]];
    NSMenuItem *diagnostics = [self item:@"Diagnostics" action:nil tag:0];
    diagnostics.image = [NSImage imageWithSystemSymbolName:@"waveform.path.ecg" accessibilityDescription:nil];
    NSMenu *details = [[NSMenu alloc] initWithTitle:@"Diagnostics"];
    for (NSNumber *channel in @[@1, @2, @3]) {
        if (channel.integerValue == self.macChannel) continue;
        NSString *state = [self.networkHostsSeen containsObject:channel] ? @"event received" : @"waiting for helper";
        [details addItem:[self item:[NSString stringWithFormat:@"Device %@: %@", channel, state] action:nil tag:0]];
    }
    [details addItem:NSMenuItem.separatorItem];
    NSMenuItem *test = [self item:@"Observe only" action:@selector(toggleTest:) tag:0];
    test.state = self.observeOnly ? NSControlStateValueOn : NSControlStateValueOff; [details addItem:test];
    [details addItem:[self item:@"Read current input" action:@selector(readCurrent:) tag:0]];
    [details addItem:[self item:@"Open logs folder" action:@selector(openLog:) tag:0]];
    diagnostics.submenu = details; [menu addItem:diagnostics];
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self item:@"About MonitorSwitch" action:@selector(about:) tag:0]];
    NSMenuItem *quit = [self item:@"Quit MonitorSwitch" action:@selector(quit:) tag:0]; quit.keyEquivalent = @"q"; [menu addItem:quit];
    self.statusItem.menu = menu;
}
- (void)startNetworkListener {
    if (!self.automatic || self.suspended || self.networkTask.running) return;
    if (NSDate.timeIntervalSinceReferenceDate < self.networkRetryAt) return;
    self.networkRetryAt = NSDate.timeIntervalSinceReferenceDate + 30;
    NSString *config = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MonitorSwitch/network-config.json"];
    NSString *script = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"network_follow.py"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:config] || ![[NSFileManager defaultManager] fileExistsAtPath:script]) {
        [self log:@"Windows helpers not configured · open Setup devices"];
        return;
    }
    [self stopNetworkListener];
    self.networkBuffer = NSMutableData.data;
    self.networkPipe = NSPipe.pipe;
    NSTask *task = NSTask.new;
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/python3"];
    task.arguments = @[@"-u", script, @"--config", config, @"--emit-events", @"--return-input", [self.inputs[self.macChannel - 1] stringValue]];
    task.standardOutput = self.networkPipe;
    NSString *errorPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/MonitorSwitch/network-errors.log"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:errorPath]) [@"" writeToFile:errorPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSFileHandle *errors = [NSFileHandle fileHandleForWritingAtPath:errorPath];
    [errors seekToEndOfFile]; task.standardError = errors;
    __weak MonitorSwitch *weakSelf = self;
    self.networkPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf networkOutput:data]; });
    };
    NSError *error = nil;
    self.networkTask = task;
    if (![task launchAndReturnError:&error]) {
        [self log:[NSString stringWithFormat:@"Windows listener failed: %@", error.localizedDescription]];
        [self stopNetworkListener];
    } else [self log:@"Windows listener ready · waiting for helpers"];
}
- (void)stopNetworkListener {
    self.networkPipe.fileHandleForReading.readabilityHandler = nil;
    if (self.networkTask.running) [self.networkTask terminate];
    self.networkTask = nil; self.networkPipe = nil; self.networkBuffer = nil;
}
- (void)networkOutput:(NSData *)data {
    if (!self.networkBuffer || !self.automatic || self.suspended) return;
    [self.networkBuffer appendData:data];
    const uint8_t newline = '\n';
    NSData *delimiter = [NSData dataWithBytes:&newline length:1];
    while (self.networkBuffer.length) {
        NSRange end = [self.networkBuffer rangeOfData:delimiter options:0 range:NSMakeRange(0, self.networkBuffer.length)];
        if (end.location == NSNotFound) break;
        NSString *line = [[NSString alloc] initWithData:[self.networkBuffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
        [self.networkBuffer replaceBytesInRange:NSMakeRange(0, end.location + 1) withBytes:NULL length:0];
        NSInteger channel = [line hasPrefix:@"MONITORSWITCH_CHANNEL:"] ? [[line substringFromIndex:[@"MONITORSWITCH_CHANNEL:" length]] integerValue] : NSNotFound;
        if (channel < 1 || channel > 3 || channel == self.macChannel) continue;
        if (channel == NSNotFound) continue;
        [self.networkHostsSeen addObject:@(channel)]; [self rebuildMenu];
        [self log:[NSString stringWithFormat:@"Easy-Switch → %ld · %@ (confirmed by Windows helper)", channel, self.names[channel - 1]]];
        [self selectChannel:channel manual:NO];
    }
    if (self.networkBuffer.length > 65536) [self.networkBuffer setLength:0];
}
- (void)closeKeyboard {
    if (!self.keyboard) return;
    IOHIDDeviceUnscheduleFromRunLoop(self.keyboard, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDDeviceClose(self.keyboard, kIOHIDOptionsTypeNone);
    CFRelease(self.keyboard); self.keyboard = NULL; self.feature = 0; self.stage = 0;
    self.reportBuffer = nil; self.lastServiceReport = nil; self.lastHostQuery = 0;
}
- (void)deviceArrived:(IOHIDDeviceRef)device {
    NSString *transport = (__bridge NSString *)IOHIDDeviceGetProperty(device, CFSTR(kIOHIDTransportKey));
    [self log:[NSString stringWithFormat:@"HID: keyboard connected · %@", transport ?: @"unknown transport"]];
    [self tick];
}
- (void)deviceRemoved:(IOHIDDeviceRef)device {
    if (self.requestedChannel == self.macChannel) self.requestedChannel = NSNotFound;
    if (self.keyboard == device) [self closeKeyboard];
    [self status:@"HID: keyboard disconnected; destination unknown"];
}
- (void)sendFeature:(uint8_t)feature function:(uint8_t)function first:(uint8_t)first second:(uint8_t)second {
    if (!self.keyboard) return;
    uint8_t packet[20] = {0x11, 0xff, feature, (uint8_t)((function << 4) | 0x0a), first, second};
    IOReturn result = IOHIDDeviceSetReport(self.keyboard, kIOHIDReportTypeOutput, 0x11, packet, sizeof(packet));
    if (result != kIOReturnSuccess) [self status:[NSString stringWithFormat:@"Channel query failed (0x%08x)", result]];
}
- (void)tick {
    double now = NSDate.timeIntervalSinceReferenceDate;
    if (self.lastTick && now - self.lastTick > 5) { [self closeKeyboard]; self.pendingChannel = NSNotFound; self.suppressUntil = now + 5; }
    self.lastTick = now;
    if (!self.automatic || self.suspended || now < self.suppressUntil) return;
    [self startNetworkListener];
    CFSetRef devices = IOHIDManagerCopyDevices(self.manager);
    if (!devices) { [self closeKeyboard]; return; }
    NSSet *set = (__bridge NSSet *)devices;
    if (self.keyboard && ![set containsObject:(__bridge id)self.keyboard]) {
        [self closeKeyboard];
        // Absence does not identify the destination: channel 1, channel 3,
        // power off, and sleep can all look identical. Never guess an input.
        [self status:@"Keyboard disconnected; destination not confirmed"];
    }
    if (!self.keyboard && set.count) {
        IOHIDDeviceRef candidate = (__bridge IOHIDDeviceRef)set.anyObject;
        IOReturn result = IOHIDDeviceOpen(candidate, kIOHIDOptionsTypeNone);
        if (result == kIOReturnSuccess) {
            self.keyboard = (IOHIDDeviceRef)CFRetain(candidate);
            self.reportBuffer = [NSMutableData dataWithLength:128];
            IOHIDDeviceRegisterInputReportCallback(self.keyboard, self.reportBuffer.mutableBytes, self.reportBuffer.length, hidReport, (__bridge void *)self);
            IOHIDDeviceScheduleWithRunLoop(self.keyboard, CFRunLoopGetMain(), kCFRunLoopCommonModes);
            self.stage = 1;
            [self status:@"Reading keyboard channel…"];
            [self sendFeature:0 function:0 first:0x18 second:0x14];
        } else {
            [self status:[NSString stringWithFormat:@"Keyboard service access denied (0x%08x)", result]];
        }
    } else if (self.keyboard && self.stage == 1) {
        [self sendFeature:0 function:0 first:0x18 second:0x14];
    } else if (self.keyboard && self.stage == 2) {
        [self sendFeature:self.feature function:0 first:0 second:0];
    } else if (self.keyboard && self.stage == 3 && now - self.lastHostQuery >= 2) {
        self.lastHostQuery = now;
        [self sendFeature:self.feature function:0 first:0 second:0];
    }
    CFRelease(devices);
}
- (void)received:(const uint8_t *)bytes length:(CFIndex)length reportID:(uint32_t)reportID {
    if (length < 6 || (reportID != 0x10 && reportID != 0x11) || bytes[0] != reportID || bytes[1] != 0xff) return;
    // Diagnostic capture is restricted to HID++ service packets. Never log
    // ordinary keyboard reports. Repeated identical polls are suppressed.
    NSMutableString *service = [NSMutableString stringWithFormat:@"HID++ id=%02x len=%ld", reportID, (long)length];
    for (CFIndex i = 0; i < MIN(length, 20); i++) [service appendFormat:@" %02x", bytes[i]];
    if (![service isEqualToString:self.lastServiceReport]) {
        self.lastServiceReport = service; [self log:service];
    }
    if (self.stage == 1 && bytes[2] == 0 && bytes[3] == 0x0a) {
        self.feature = bytes[4];
        if (!self.feature) { [self status:@"Keyboard did not expose ChangeHost"]; return; }
        self.stage = 2;
        [self sendFeature:self.feature function:0 first:0 second:0];
        return;
    }
    if (self.stage >= 2 && bytes[2] == self.feature && bytes[3] == 0x0a && bytes[4] > 0 && bytes[4] <= 3 && bytes[5] < bytes[4]) {
        BOOL changed = self.stage != 3 || self.deviceHost != bytes[5];
        self.stage = 3; self.deviceHost = bytes[5];
        if (!changed) return;
        NSInteger channel = self.deviceHost + 1;
        [self status:[NSString stringWithFormat:@"Keyboard on channel %ld · %@", channel, self.names[channel - 1]]];
        // Returning to this computer is positively identified by the device.
        // In test mode only log it; do not write any monitor values.
        if (channel == self.macChannel) [self selectChannel:channel manual:NO];
        return;
    }
    NSInteger channel = targetFromReport(bytes, length, reportID, self.feature);
    if (channel == NSNotFound) return;
    [self status:[NSString stringWithFormat:@"Easy-Switch → %ld · %@", channel, self.names[channel - 1]]];
    [self selectChannel:channel manual:NO];
}
- (void)selectChannel:(NSInteger)channel manual:(BOOL)manual {
    if (channel < 1 || channel > 3) return;
    if (!self.displayUUID.length) { [self status:@"Select your monitor in Setup devices first"]; return; }
    int input = self.inputs[channel - 1].intValue;
    if (!input) { [self status:[NSString stringWithFormat:@"No input configured for %@", self.names[channel - 1]]]; return; }
    if (!manual && self.observeOnly) { [self log:[NSString stringWithFormat:@"TEST: channel=%ld input=%d, monitor unchanged", channel, input]]; return; }
    if (!manual && self.requestedChannel == channel) return;
    self.requestedChannel = channel;
    [self rebuildMenu];
    if (self.busy) { self.pendingChannel = channel; self.requestedChannel = NSNotFound; return; }
    [self status:[NSString stringWithFormat:@"Switching to %@…", self.names[channel - 1]]];
    [self runDDC:@[@"display", self.displayUUID, @"set", @"input", [@(input) stringValue]] completion:^(int result, NSString *output) {
        if (result != 0) { self.requestedChannel = NSNotFound; [self status:[NSString stringWithFormat:@"Command for %@ failed: %@", self.names[channel - 1], output]]; return; }
        // MSI may stop replying on DDC after leaving the Mac's USB-C input.
        // A successful write is therefore reported as sent, not as read-back verified.
        [self status:[NSString stringWithFormat:@"Input command sent to %@", self.names[channel - 1]]];
    }];
}
- (void)runDDC:(NSArray<NSString *> *)arguments completion:(void (^)(int, NSString *))completion {
    if (self.busy) return;
    self.busy = YES;
    NSString *binary = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"m1ddc"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:binary]; task.arguments = arguments;
        NSPipe *pipe = NSPipe.pipe; task.standardOutput = pipe; task.standardError = pipe;
        NSError *error = nil; int result = -1; NSString *output = @"";
        if ([task launchAndReturnError:&error]) {
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
            while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.05];
            if (task.running) { [task terminate]; output = @"Monitor did not respond within 5 seconds"; }
            else { result = task.terminationStatus; output = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @""; }
        } else output = error.localizedDescription ?: @"Could not start display control";
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            completion(result, [output stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]);
            if (!self.busy && self.pendingChannel != NSNotFound) { NSInteger channel = self.pendingChannel; self.pendingChannel = NSNotFound; [self selectChannel:channel manual:NO]; }
        });
    });
}
- (void)manual:(NSMenuItem *)item { [self selectChannel:item.tag manual:YES]; }
- (void)toggleAuto:(id)sender {
    self.automatic = !self.automatic;
    [self.prefs setBool:self.automatic forKey:@"automatic"];
    if (!self.automatic) { [self closeKeyboard]; [self stopNetworkListener]; [self status:@"Automatic switching paused"]; }
    [self rebuildMenu]; [self tick];
}
- (void)toggleTest:(id)sender { self.observeOnly = !self.observeOnly; [self.prefs setBool:self.observeOnly forKey:@"observeOnly"]; [self rebuildMenu]; [self status:self.observeOnly ? @"Diagnostic mode · monitor unchanged" : @"Automatic switching enabled"]; }
- (void)sleep:(id)sender { self.requestedChannel = NSNotFound; self.suspended = YES; self.pendingChannel = NSNotFound; [self closeKeyboard]; [self stopNetworkListener]; }
- (void)wake:(id)sender { self.suspended = NO; self.suppressUntil = NSDate.timeIntervalSinceReferenceDate + 5; }
- (void)readCurrent:(id)sender {
    if (!self.displayUUID.length) { [self status:@"Select your monitor in Setup devices first"]; return; }
    [self runDDC:@[@"display", self.displayUUID, @"get", @"input"] completion:^(int result, NSString *output) {
        [self status:result == 0 ? [NSString stringWithFormat:@"Current input code: %@", output] : [NSString stringWithFormat:@"Monitor unavailable: %@", output]];
    }];
}
- (NSString *)configurationPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MonitorSwitch/network-config.json"];
}
- (NSDictionary *)configuration {
    NSData *data = [NSData dataWithContentsOfFile:[self configurationPath]];
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] ?: @{} : @{};
}
- (NSArray<NSDictionary *> *)connectedDisplays {
    NSTask *task = NSTask.new;
    task.executableURL = [NSURL fileURLWithPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"m1ddc"]];
    task.arguments = @[@"display", @"list"];
    NSPipe *pipe = NSPipe.pipe; task.standardOutput = pipe; task.standardError = pipe;
    if (![task launchAndReturnError:nil]) return @[];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (task.running && deadline.timeIntervalSinceNow > 0) [NSThread sleepForTimeInterval:0.02];
    if (task.running) { [task terminate]; return @[]; }
    NSString *text = [[NSString alloc] initWithData:[pipe.fileHandleForReading readDataToEndOfFile] encoding:NSUTF8StringEncoding] ?: @"";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\[\\d+\\] (.+) \\(([A-Fa-f0-9-]{36})\\)" options:0 error:nil];
    NSMutableArray *result = NSMutableArray.array;
    for (NSTextCheckingResult *match in [regex matchesInString:text options:0 range:NSMakeRange(0,text.length)])
        [result addObject:@{@"name": [text substringWithRange:[match rangeAtIndex:1]], @"uuid": [text substringWithRange:[match rangeAtIndex:2]]}];
    return result;
}
- (NSArray<NSString *> *)localAddresses {
    NSMutableArray *addresses = NSMutableArray.array;
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) == 0) {
        for (struct ifaddrs *item = list; item; item = item->ifa_next) {
            if (!item->ifa_addr || item->ifa_addr->sa_family != AF_INET) continue;
            char buffer[INET_ADDRSTRLEN];
            inet_ntop(AF_INET, &((struct sockaddr_in *)item->ifa_addr)->sin_addr, buffer, sizeof(buffer));
            NSString *address = [NSString stringWithUTF8String:buffer];
            if (![address hasPrefix:@"127."] && ![address hasPrefix:@"169.254."] && ![addresses containsObject:address]) [addresses addObject:address];
        }
        freeifaddrs(list);
    }
    return addresses;
}
- (void)settings:(id)sender {
    NSDictionary *oldConfig = [self configuration];
    NSAlert *alert = NSAlert.new; alert.messageText = @"Set up your devices";
    alert.informativeText = @"Match each row to its physical Easy-Switch button. Choose macOS for this computer and Windows for the others. Your existing pairing keys are preserved.";
    [alert addButtonWithTitle:@"Save setup"]; [alert addButtonWithTitle:@"Cancel"];
    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0,0,560,340)];
    NSArray *headings = @[@"Device", @"Name", @"System", @"Monitor input"];
    NSArray *positions = @[@0,@66,@240,@390];
    for (NSInteger i=0;i<4;i++) {
        NSTextField *label = [NSTextField labelWithString:headings[i]];
        label.font = [NSFont boldSystemFontOfSize:11]; label.textColor = NSColor.secondaryLabelColor;
        label.frame = NSMakeRect([positions[i] doubleValue],308,160,18); [view addSubview:label];
    }
    NSMutableArray *names = NSMutableArray.array, *types = NSMutableArray.array, *ports = NSMutableArray.array;
    NSArray *inputCodes = @[@17,@18,@15,@16];
    for (NSInteger i=0;i<3;i++) {
        CGFloat y = 268 - i*40;
        NSTextField *number = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld",i+1]];
        number.frame = NSMakeRect(14,y+4,32,22); [view addSubview:number];
        NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(66,y,164,26)];
        name.stringValue=self.names[i]; [view addSubview:name]; [names addObject:name];
        NSPopUpButton *type = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(240,y,140,26)];
        [type addItemsWithTitles:@[@"macOS",@"Windows"]]; [type selectItemAtIndex:i+1==self.macChannel ? 0 : 1];
        [view addSubview:type]; [types addObject:type];
        NSComboBox *port = [[NSComboBox alloc] initWithFrame:NSMakeRect(390,y,166,26)];
        [port addItemsWithObjectValues:@[@"HDMI 1 (17)",@"HDMI 2 (18)",@"DisplayPort 1 (15)",@"USB-C / DP 2 (16)"]];
        NSUInteger index = [inputCodes indexOfObject:self.inputs[i]];
        if (index != NSNotFound) [port selectItemAtIndex:index]; else port.stringValue=[self.inputs[i] stringValue];
        [view addSubview:port]; [ports addObject:port];
    }
    NSTextField *monitorLabel = [NSTextField labelWithString:@"Connected monitor"];
    monitorLabel.frame=NSMakeRect(0,145,180,22); [view addSubview:monitorLabel];
    NSPopUpButton *monitor = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(185,142,370,26)];
    NSArray *displays = [self connectedDisplays];
    for (NSDictionary *display in displays) { [monitor addItemWithTitle:display[@"name"]]; monitor.lastItem.representedObject=display[@"uuid"]; if ([self.displayUUID isEqualToString:display[@"uuid"]]) [monitor selectItem:monitor.lastItem]; }
    if (!monitor.numberOfItems || (self.displayUUID.length && ![displays filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"uuid == %@",self.displayUUID]].count)) {
        [monitor addItemWithTitle:self.displayUUID.length ? @"Previously configured monitor" : @"No DDC monitor detected"];
        monitor.lastItem.representedObject=self.displayUUID; [monitor selectItem:monitor.lastItem];
    }
    [view addSubview:monitor];
    NSTextField *modelLabel=[NSTextField labelWithString:@"Windows monitor name"];
    modelLabel.frame=NSMakeRect(0,106,185,22);[view addSubview:modelLabel];
    NSTextField *model=[[NSTextField alloc] initWithFrame:NSMakeRect(185,103,370,26)];
    model.stringValue=oldConfig[@"monitorModel"] ?: @"G274QPF";[view addSubview:model];
    NSTextField *addressLabel=[NSTextField labelWithString:@"This computer's LAN address"];
    addressLabel.frame=NSMakeRect(0,66,185,22);[view addSubview:addressLabel];
    NSComboBox *address=[[NSComboBox alloc] initWithFrame:NSMakeRect(185,63,370,26)];
    NSArray *addresses=[self localAddresses];[address addItemsWithObjectValues:addresses];
    address.stringValue=oldConfig[@"macIP"] ?: addresses.firstObject ?: @"";[view addSubview:address];
    NSTextField *error=[NSTextField wrappingLabelWithString:@"Use standard inputs above, or enter a DDC input code from 1 to 255."];
    error.textColor=NSColor.secondaryLabelColor;error.font=[NSFont systemFontOfSize:11];error.frame=NSMakeRect(0,5,555,42);[view addSubview:error];
    alert.accessoryView=view;[NSApp activateIgnoringOtherApps:YES];
    while ([alert runModal] == NSAlertFirstButtonReturn) {
        NSMutableArray *nextNames=NSMutableArray.array,*nextInputs=NSMutableArray.array,*nextTypes=NSMutableArray.array;
        NSInteger local=0,count=0;BOOL valid=YES;
        for (NSInteger i=0;i<3;i++) {
            NSString *name=[[names[i] stringValue] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            [nextNames addObject:name.length ? name : [NSString stringWithFormat:@"Device %ld",i+1]];
            BOOL isMac=[types[i] indexOfSelectedItem]==0;[nextTypes addObject:isMac ? @"macOS" : @"Windows"];if(isMac){local=i+1;count++;}
            NSString *text=[ports[i] stringValue];NSRange open=[text rangeOfString:@"(" options:NSBackwardsSearch];
            NSString *code=open.location==NSNotFound ? text : [[text substringFromIndex:open.location+1] stringByReplacingOccurrencesOfString:@")" withString:@""];
            NSScanner *scanner=[NSScanner scannerWithString:code];NSInteger input=0;
            if (![scanner scanInteger:&input] || !scanner.isAtEnd || input<1 || input>255) valid=NO;
            [nextInputs addObject:@(input)];
        }
        struct in_addr ipv4;
        NSString *ip=[address.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (count!=1 || !valid || inet_pton(AF_INET,ip.UTF8String,&ipv4)!=1 || ![monitor.selectedItem.representedObject length] || !model.stringValue.length) {
            error.stringValue=@"Choose exactly one macOS device, a monitor, its Windows name, a valid IPv4 address and input codes 1–255.";error.textColor=NSColor.systemRedColor;continue;
        }
        NSMutableDictionary *config=[oldConfig mutableCopy];NSMutableDictionary *keys=[(oldConfig[@"keys"] ?: @{}) mutableCopy];
        [keys removeObjectForKey:[@(local) stringValue]];
        for(NSInteger channel=1;channel<=3;channel++) {
            if(channel==local)continue;NSString *key=[@(channel) stringValue];
            if(!keys[key]) {
                uint8_t bytes[32];if(SecRandomCopyBytes(kSecRandomDefault,sizeof(bytes),bytes)!=errSecSuccess){valid=NO;break;}
                NSMutableString *secret=NSMutableString.string;for(NSInteger n=0;n<32;n++)[secret appendFormat:@"%02x",bytes[n]];keys[key]=secret;
            }
        }
        if(!valid){error.stringValue=@"Could not create pairing keys. Setup was not saved.";continue;}
        config[@"keys"]=keys;config[@"macChannel"]=@(local);config[@"macIP"]=ip;config[@"port"]=oldConfig[@"port"] ?: @25347;
        config[@"displayUUID"]=monitor.selectedItem.representedObject;config[@"deviceTypes"]=nextTypes;config[@"names"]=nextNames;config[@"inputs"]=nextInputs;config[@"monitorModel"]=model.stringValue;
        NSString *path=[self configurationPath];[[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *failure=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:&failure];
        if(!data || ![data writeToFile:path options:NSDataWritingAtomic error:&failure]){error.stringValue=failure.localizedDescription ?: @"Could not save setup.";continue;}
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:nil];
        self.names=nextNames;self.inputs=nextInputs;self.deviceTypes=nextTypes;self.macChannel=local;self.displayUUID=config[@"displayUUID"];
        [self.prefs setObject:self.names forKey:@"names"];[self.prefs setObject:self.inputs forKey:@"inputs"];[self.prefs setObject:self.displayUUID forKey:@"displayUUID"];
        [self stopNetworkListener];self.networkRetryAt=0;self.requestedChannel=NSNotFound;[self closeKeyboard];[self startNetworkListener];[self tick];[self rebuildMenu];[self status:@"Setup saved · export profiles for your Windows devices"];break;
    }
}
- (void)exportProfiles:(id)sender {
    NSDictionary *config=[self configuration];
    if(![config[@"keys"] count]){[self settings:nil];config=[self configuration];if(![config[@"keys"] count])return;}
    NSOpenPanel *panel=NSOpenPanel.openPanel;panel.canChooseDirectories=YES;panel.canChooseFiles=NO;panel.canCreateDirectories=YES;
    panel.prompt=@"Export profiles";panel.message=@"These private files pair your devices. Transfer each profile to its matching Windows computer; do not publish them.";
    [NSApp activateIgnoringOtherApps:YES];if([panel runModal]!=NSModalResponseOK)return;
    NSInteger local=[config[@"macChannel"] integerValue] ?: 2;
    for(NSInteger channel=1;channel<=3;channel++) {
        if(channel==local)continue;
        NSDictionary *profile=@{@"deviceType":@"Windows",@"channel":@(channel),@"macChannel":@(local),@"macIP":config[@"macIP"],@"port":config[@"port"],@"key":config[@"keys"][[ @(channel) stringValue]],@"returnInput":self.inputs[local-1],@"monitorModel":config[@"monitorModel"] ?: @"G274QPF"};
        NSURL *url=[panel.URL URLByAppendingPathComponent:[NSString stringWithFormat:@"MonitorSwitch-Device%ld-%@.json",channel,NSUUID.UUID.UUIDString]];
        NSError *error=nil;NSData *data=[NSJSONSerialization dataWithJSONObject:profile options:NSJSONWritingPrettyPrinted error:&error];
        if(![data writeToURL:url options:NSDataWritingAtomic error:&error]){[self status:@"Profile export failed"];return;}
        [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:url.path error:nil];
    }
    [self status:@"Private Windows profiles exported"];[[NSWorkspace sharedWorkspace] openURL:panel.URL];
}
- (void)openLog:(id)sender { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:self.logPath.stringByDeletingLastPathComponent]]; }
- (void)about:(id)sender {
    NSAlert *alert = NSAlert.new; alert.messageText = @"MonitorSwitch";
    alert.informativeText = @"MonitorSwitch 0.9.1\n\nLocal Easy-Switch display control. No subscription, account or cloud.\n\nConfigure one macOS device and up to two Windows devices. Windows helpers confirm their channels over your local network. Only Logitech service reports are used; typed keys are not recorded.\n\nIncludes m1ddc (MIT).";
    [NSApp activateIgnoringOtherApps:YES]; [alert runModal];
}
- (void)quit:(id)sender { [NSApp terminate:nil]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.timer invalidate]; [self closeKeyboard]; [self stopNetworkListener];
    if (self.manager) {
        IOHIDManagerUnscheduleFromRunLoop(self.manager, CFRunLoopGetMain(), kCFRunLoopCommonModes);
        CFRelease(self.manager);
    }
}
@end

static int selfTest(void) {
    uint8_t report[20] = {0x11, 0xff, 9, 0, 3, 0};
    int count = 0;
    for (int channel = 0; channel < 3; channel++) { report[5] = channel; NSCAssert(targetFromReport(report, 20, 0x11, 9) == channel + 1, @"valid channel"); count++; }
    report[3] = 0x0a; NSCAssert(targetFromReport(report, 20, 0x11, 9) == NSNotFound, @"query reply is not a switch"); count++;
    report[3] = 0; report[5] = 3; NSCAssert(targetFromReport(report, 20, 0x11, 9) == NSNotFound, @"invalid host"); count++;
    report[5] = 1; NSCAssert(targetFromReport(report, 5, 0x11, 9) == NSNotFound, @"truncated input"); count++;
    report[4] = 0; report[5] = 2; NSCAssert(targetFromReport(report, 20, 0x11, 9) == 3, @"notification with an unused host-count byte"); count++;
    NSCAssert(targetFromReport(report, 20, 0x11, 10) == NSNotFound, @"unrelated feature"); count++;
    NSCAssert(targetFromReport(report, 20, 0x11, 0) == NSNotFound, @"unresolved feature"); count++;
    NSCAssert(targetFromReport(report, 20, 1, 9) == NSNotFound, @"ordinary keys are ignored"); count++;
    report[1] = 1; NSCAssert(targetFromReport(report, 20, 0x11, 9) == NSNotFound, @"wrong device"); count++;
    printf("%d parser checks passed. Hardware compatibility requires a real-device check.\n", count);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return selfTest();
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        MonitorSwitch *delegate = [MonitorSwitch new]; app.delegate = delegate;
        [app run];
    }
    return 0;
}
