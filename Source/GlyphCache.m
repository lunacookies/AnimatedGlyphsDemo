typedef struct GlyphCacheEntry GlyphCacheEntry;
struct GlyphCacheEntry
{
	CGGlyph glyph;
	CTFontRef font;
	simd_float2 offset;
	simd_float2 size;
	simd_float2 textureCoordinatesBlack;
	simd_float2 textureCoordinatesWhite;
	simd_float2 subpixelOffset;
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

	MTLPixelFormat pixelFormat = MTLPixelFormatR8Unorm;
	imm align = (imm)[device minimumLinearTextureAlignmentForPixelFormat:pixelFormat];
	imm bytesPerRow = (imm)AlignPow2((umm)diameter, align);
	imm bytesNeeded = bytesPerRow * diameter;
	id<MTLBuffer> buffer = [device newBufferWithLength:(umm)bytesNeeded
	                                           options:MTLResourceStorageModeShared];
	buffer.label = @"Glyph Cache Backing Store";

	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.width = (umm)diameter;
	descriptor.height = (umm)diameter;
	descriptor.pixelFormat = pixelFormat;
	descriptor.storageMode = buffer.storageMode;
	texture = [buffer newTextureWithDescriptor:descriptor
	                                    offset:0
	                               bytesPerRow:(umm)bytesPerRow];
	texture.label = @"Glyph Cache";

	context = CGBitmapContextCreate(buffer.contents, (umm)diameter, (umm)diameter, 8,
	        (umm)bytesPerRow, CGColorSpaceCreateWithName(kCGColorSpaceLinearGray),
	        kCGImageAlphaOnly);
	CGContextScaleCTM(context, scaleFactor, scaleFactor);

	// Disable Core Graphics’s built-in subpixel quantization because we perform our own.
	// Ideally we’d just use the built-in subpixel quantization, but no API is exposed for it.
	CGContextSetAllowsFontSubpixelQuantization(context, false);

	entryCapacity = 1024;
	entries = malloc((umm)entryCapacity * sizeof(GlyphCacheEntry));

	return self;
}

- (CachedGlyph)cachedGlyph:(CGGlyph)glyph
                      font:(CTFontRef)font
            subpixelOffset:(simd_float2)subpixelOffset
{
	Assert(simd_all(subpixelOffset < 1));
	Assert(simd_all(subpixelOffset >= 0));

	{
		float subpixelOffsetResolution = 4;
		subpixelOffset =
		        floor(subpixelOffset * subpixelOffsetResolution) / subpixelOffsetResolution;
		Assert(simd_all(subpixelOffset < 1));
		Assert(simd_all(subpixelOffset >= 0));
	}

	GlyphCacheEntry *entry = NULL;

	for (imm entryIndex = 0; entryIndex < entryCount; entryIndex++)
	{
		GlyphCacheEntry *candidate = entries + entryIndex;
		if (candidate->glyph == glyph && CFEqual(candidate->font, font) &&
		        simd_all(candidate->subpixelOffset == subpixelOffset))
		{
			entry = candidate;
			break;
		}
	}

	if (entry == NULL)
	{
		if (entryCount == entryCapacity)
		{
			entryCapacity *= 2;
			entries = realloc(entries, (umm)entryCapacity * sizeof(GlyphCacheEntry));
		}
		entry = entries + entryCount;
		entryCount++;

		CFRetain(font);
		memset(entry, 0, sizeof(*entry));
		entry->glyph = glyph;
		entry->font = font;
		entry->subpixelOffset = subpixelOffset;

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

		entry->offset = padding - floor(boundingRectOrigin);
		entry->size = ceil(boundingRectSize);
		entry->size += 2 * padding;

		float xStep = ceil(boundingRectSize.x) + 2 * padding;

		for (bool32 black = 0; black <= 1; black++)
		{
			if (cursor.x + xStep >= diameter)
			{
				cursor.x = 0;
				cursor.y += ceil(largestGlyphHeight) + 2 * padding;
				largestGlyphHeight = 0;
			}

			if (black)
			{
				entry->textureCoordinatesBlack = cursor;
			}
			else
			{
				entry->textureCoordinatesWhite = cursor;
			}

			{
				simd_float2 drawPosition = cursor;
				drawPosition -= floor(boundingRectOrigin);
				drawPosition += padding;

				// The draw position (baseline, left side) should be on a pixel
				// boundary, up until we add in the subpixel offset.
				Assert(simd_all(drawPosition == floor(drawPosition)));
				drawPosition += subpixelOffset;

				drawPosition /= scaleFactor;
				CGPoint drawPositionCG = {drawPosition.x, drawPosition.y};

				CFStringRef colorName = black ? kCGColorBlack : kCGColorWhite;
				CGContextSetFillColorWithColor(
				        context, CGColorGetConstantColor(colorName));
				CTFontDrawGlyphs(font, &glyph, &drawPositionCG, 1, context);
			}

			largestGlyphHeight = Max(largestGlyphHeight, boundingRectSize.y);
			cursor.x += xStep;
		}
	}

	CachedGlyph result = {0};
	result.offset = entry->offset;
	result.size = entry->size;
	result.textureCoordinatesBlack = entry->textureCoordinatesBlack;
	result.textureCoordinatesWhite = entry->textureCoordinatesWhite;

	Assert(simd_all(result.offset == floor(result.offset)));
	Assert(simd_all(result.size == floor(result.size)));
	Assert(simd_all(result.textureCoordinatesBlack == floor(result.textureCoordinatesBlack)));
	Assert(simd_all(result.textureCoordinatesWhite == floor(result.textureCoordinatesWhite)));

	return result;
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
