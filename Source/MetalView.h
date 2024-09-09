@interface MetalView : NSView
- (instancetype)initWithNotificationCenter:(NSNotificationCenter *)notificationCenter;
@property NSAttributedString *attributedString;
@property NSColor *backgroundColor;
@end
