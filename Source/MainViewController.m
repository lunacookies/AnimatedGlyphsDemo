@implementation MainViewController

- (instancetype)init
{
	self = [super init];
	self.title = @"MetalTextRendering";
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	NSAttributedString *attributedString = [[NSAttributedString alloc]
	        initWithString:@"Sphinx of black quartz, judge my vow."
	            attributes:@{
		            NSFontAttributeName : [NSFont systemFontOfSize:13],
		            NSForegroundColorAttributeName : NSColor.labelColor,
	            }];

	NSColor *backgroundColor = NSColor.textBackgroundColor;

	MetalView *metalView = [[MetalView alloc] init];
	metalView.attributedString = attributedString;
	metalView.backgroundColor = backgroundColor;

	[self.view addSubview:metalView];
	metalView.translatesAutoresizingMaskIntoConstraints = NO;
	[NSLayoutConstraint activateConstraints:@[
		[metalView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
		[metalView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
		[metalView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
		[metalView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
	]];
}

@end
