@implementation MainViewController

- (instancetype)init
{
	self = [super init];
	self.title = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"];
	return self;
}

- (void)viewDidLoad
{
	[super viewDidLoad];

	MetalView *metalView = [[MetalView alloc] init];
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
