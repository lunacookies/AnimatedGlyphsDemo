typedef struct GlyphCacheEntry GlyphCacheEntry;
struct GlyphCacheEntry
{
	CGGlyph glyph;
	CTFontRef font;
	simd_float2 subpixelOffset;
	CachedGlyph cachedGlyph;
};

static const float padding = 2;

@implementation GlyphCache
{
	imm diameter;
	float scaleFactor;
	id<MTLTexture> texture;
	CGContextRef context;
	simd_float2 cursor;
	float largestGlyphHeight;

	GlyphCacheEntry *entries;
	imm entryCapacity;
	imm entryCount;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device scaleFactor:(float)scaleFactor_
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
            subpixelOffset:(simd_float2)subpixelOffset
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

	simd_float2 boundingRectOrigin = 0;
	simd_float2 boundingRectSize = 0;
	{
		CGRect boundingRect = {0};
		CTFontGetBoundingRectsForGlyphs(
		        font, kCTFontOrientationDefault, &glyph, &boundingRect, 1);
		boundingRectOrigin.x = (float)boundingRect.origin.x;
		boundingRectOrigin.y = (float)boundingRect.origin.y;
		boundingRectSize.x = (float)boundingRect.size.width;
		boundingRectSize.y = (float)boundingRect.size.height;
		boundingRectOrigin *= scaleFactor;
		boundingRectSize *= scaleFactor;
	}

	cachedGlyph->size = ceil(boundingRectSize);
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

		if (cursor.x + boundingRectSize.x + 2 * padding >= diameter)
		{
			cursor.x = 0;
			cursor.y += ceil(largestGlyphHeight) + 2 * padding;
			largestGlyphHeight = 0;
		}

		simd_float2 position = cursor;

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

		position -= boundingRectOrigin;
		position += subpixelOffset;
		position += padding;

		{
			CGPoint drawPosition = {0};
			drawPosition.x = position.x / scaleFactor;
			drawPosition.y = position.y / scaleFactor;
			CTFontDrawGlyphs(font, &glyph, &drawPosition, 1, context);
		}

		[texture replaceRegion:MTLRegionMake2D(0, 0, (umm)diameter, (umm)diameter)
		           mipmapLevel:0
		             withBytes:CGBitmapContextGetData(context)
		           bytesPerRow:(umm)diameter];

		largestGlyphHeight = Max(largestGlyphHeight, boundingRectSize.y);
		cursor.x += ceil(boundingRectSize.x) + 2 * padding;
	}

	return *cachedGlyph;
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
