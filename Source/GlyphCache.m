typedef struct GlyphCacheEntry GlyphCacheEntry;
struct GlyphCacheEntry
{
	CGGlyph glyph;
	CTFontRef font;
	CGPoint subpixelOffset;
	CachedGlyph cachedGlyph;
};

static const CGFloat padding = 2;

@implementation GlyphCache
{
	imm diameter;
	CGFloat scaleFactor;
	id<MTLTexture> texture;
	CGContextRef context;
	CGPoint cursor;
	CGFloat largestGlyphHeight;

	GlyphCacheEntry *entries;
	imm entryCapacity;
	imm entryCount;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device scaleFactor:(CGFloat)scaleFactor_
{
	self = [super init];
	scaleFactor = scaleFactor_;

	diameter = 1024;

	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.width = (umm)diameter;
	descriptor.height = (umm)diameter;
	descriptor.pixelFormat = MTLPixelFormatR8Unorm;
	descriptor.storageMode = MTLStorageModeShared;
	texture = [device newTextureWithDescriptor:descriptor];
	texture.label = @"Glyph Cache";

	context = CGBitmapContextCreate(NULL, (umm)diameter, (umm)diameter, 8, (umm)diameter,
	        CGColorSpaceCreateWithName(kCGColorSpaceLinearGray), kCGImageAlphaOnly);
	CGContextScaleCTM(context, scaleFactor, scaleFactor);

	entryCapacity = 1024;
	entries = malloc((umm)entryCapacity * sizeof(GlyphCacheEntry));

	return self;
}

- (CachedGlyph)cachedGlyph:(CGGlyph)glyph
                      font:(CTFontRef)font
            subpixelOffset:(CGPoint)subpixelOffset
{
	for (imm entryIndex = 0; entryIndex < entryCount; entryIndex++)
	{
		GlyphCacheEntry *entry = entries + entryIndex;
		if (entry->glyph == glyph && CFEqual(entry->font, font) &&
		        entry->subpixelOffset.x == subpixelOffset.x &&
		        entry->subpixelOffset.y == subpixelOffset.y)
		{
			return entry->cachedGlyph;
		}
	}

	if (entryCount == entryCapacity)
	{
		entryCapacity *= 2;
		entries = realloc(entries, (umm)entryCapacity * sizeof(GlyphCacheEntry));
	}

	GlyphCacheEntry *entry = entries + entryCount;
	entryCount++;

	CFRetain(font);
	memset(entry, 0, sizeof(*entry));
	entry->glyph = glyph;
	entry->font = font;
	entry->subpixelOffset = subpixelOffset;

	CachedGlyph *cachedGlyph = &entry->cachedGlyph;
	cachedGlyph->offset = padding;

	CGRect boundingRect = [self boundingRectForGlyph:glyph fromFont:font];
	cachedGlyph->size.x = (float)ceil(boundingRect.size.width);
	cachedGlyph->size.y = (float)ceil(boundingRect.size.height);
	cachedGlyph->size += 2 * padding;

	for (bool32 black = 0; black <= 1; black++)
	{
		CFStringRef colorName = NULL;
		if (black)
		{
			colorName = kCGColorBlack;
		}
		else
		{
			colorName = kCGColorWhite;
		}
		CGContextSetFillColorWithColor(context, CGColorGetConstantColor(colorName));

		if (cursor.x + boundingRect.size.width + 2 * padding >= diameter)
		{
			cursor.x = 0;
			cursor.y += ceil(largestGlyphHeight) + 2 * padding;
			largestGlyphHeight = 0;
		}

		CGPoint position = cursor;

		if (black)
		{
			cachedGlyph->positionBlack.x = (float)position.x;
			cachedGlyph->positionBlack.y = (float)position.y;
		}
		else
		{
			cachedGlyph->positionWhite.x = (float)position.x;
			cachedGlyph->positionWhite.y = (float)position.y;
		}

		position.x -= boundingRect.origin.x;
		position.y -= boundingRect.origin.y;

		position.x += subpixelOffset.x;
		position.y += subpixelOffset.y;

		position.x += padding;
		position.y += padding;

		largestGlyphHeight = Max(largestGlyphHeight, boundingRect.size.height);

		[self drawGlyph:glyph fromFont:font atPosition:position];

		cursor.x += ceil(boundingRect.size.width) + 2 * padding;
	}

	return *cachedGlyph;
}

- (void)drawGlyph:(CGGlyph)glyph fromFont:(CTFontRef)font atPosition:(CGPoint)position
{
	position.x /= scaleFactor;
	position.y /= scaleFactor;

	CTFontDrawGlyphs(font, &glyph, &position, 1, context);
	[texture replaceRegion:MTLRegionMake2D(0, 0, (umm)diameter, (umm)diameter)
	           mipmapLevel:0
	             withBytes:CGBitmapContextGetData(context)
	           bytesPerRow:(umm)diameter];
}

- (CGRect)boundingRectForGlyph:(CGGlyph)glyph fromFont:(CTFontRef)font
{
	CGRect boundingRect = {0};
	CTFontGetBoundingRectsForGlyphs(font, kCTFontOrientationDefault, &glyph, &boundingRect, 1);

	boundingRect.origin.x *= scaleFactor;
	boundingRect.origin.y *= scaleFactor;
	boundingRect.size.width *= scaleFactor;
	boundingRect.size.height *= scaleFactor;

	return boundingRect;
}

- (void)dealloc
{
	for (imm entryIndex = 0; entryIndex < entryCount; entryIndex++)
	{
		GlyphCacheEntry *entry = entries + entryIndex;
		CFRelease(entry->font);
	}

	free(entries);

	CFRelease(context);
}

- (id<MTLTexture>)texture
{
	return texture;
}

@end
