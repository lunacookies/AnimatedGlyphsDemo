@implementation AppDelegate
{
	NSWindow *window;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	window = [NSWindow windowWithContentViewController:[[MainViewController alloc] init]];
	[window center];
	[window makeKeyAndOrderFront:nil];
	[NSApp activate];
}

@end
