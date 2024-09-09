typedef struct Arguments Arguments;
struct Arguments
{
	simd_float2 size;
	MTLResourceID glyphCacheTexture;
};

typedef struct Sprite Sprite;
struct Sprite
{
	simd_float2 position;
	simd_float2 size;
	simd_float2 textureCoordinatesBlack;
	simd_float2 textureCoordinatesWhite;
	simd_float4 color;
};

@implementation MetalView
{
	NSNotificationCenter *notificationCenter;

	id<MTLDevice> device;
	id<MTLCommandQueue> commandQueue;
	id<MTLRenderPipelineState> pipelineState;

	IOSurfaceRef iosurface;
	id<MTLTexture> texture;

	GlyphCache *glyphCache;

	NSAttributedString *attributedString;
	NSColor *backgroundColor;
}

- (instancetype)initWithNotificationCenter:(NSNotificationCenter *)notificationCenter_
{
	self = [super init];

	notificationCenter = notificationCenter_;

	self.wantsLayer = YES;

	device = MTLCreateSystemDefaultDevice();
	commandQueue = [device newCommandQueue];

	id<MTLLibrary> library = [device newDefaultLibrary];

	MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
	descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	descriptor.vertexFunction = [library newFunctionWithName:@"vertex_main"];
	descriptor.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
	descriptor.colorAttachments[0].blendingEnabled = YES;
	descriptor.colorAttachments[0].destinationRGBBlendFactor =
	        MTLBlendFactorOneMinusSourceAlpha;
	descriptor.colorAttachments[0].destinationAlphaBlendFactor =
	        MTLBlendFactorOneMinusSourceAlpha;
	descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
	descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;

	pipelineState = [device newRenderPipelineStateWithDescriptor:descriptor error:nil];

	return self;
}

- (BOOL)wantsUpdateLayer
{
	return YES;
}

- (void)updateLayer
{
	CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString(
	        (__bridge CFAttributedStringRef)attributedString);

	CGSize frameSizeConstraints = self.bounds.size;
	frameSizeConstraints.height = CGFLOAT_MAX;

	CGSize frameSize = CTFramesetterSuggestFrameSizeWithConstraints(
	        framesetter, (CFRange){0}, NULL, frameSizeConstraints, NULL);

	CGRect frameRect = self.bounds;
	frameRect.origin.y = self.bounds.size.height - frameSize.height;
	frameRect.size.height = frameSize.height;

	CGPathRef path = CGPathCreateWithRect(frameRect, NULL);
	CTFrameRef frame = CTFramesetterCreateFrame(framesetter, (CFRange){0}, path, NULL);

	CFArrayRef lines = CTFrameGetLines(frame);
	imm lineCount = CFArrayGetCount(lines);

	CGPoint *lineOrigins = calloc((umm)lineCount, sizeof(CGPoint));
	CTFrameGetLineOrigins(frame, (CFRange){0}, lineOrigins);

	imm frameGlyphCount = 0;
	for (imm lineIndex = 0; lineIndex < lineCount; lineIndex++)
	{
		CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
		frameGlyphCount += CTLineGetGlyphCount(line);
	}

	float scaleFactor = (float)self.window.backingScaleFactor;

	Sprite *sprites = calloc((umm)frameGlyphCount, sizeof(Sprite));
	imm spriteCount = 0;

	NSColorSpace *colorSpace = self.window.colorSpace;
	Assert(colorSpace != nil);

	for (imm lineIndex = 0; lineIndex < lineCount; lineIndex++)
	{
		CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
		CGPoint lineOrigin = lineOrigins[lineIndex];
		lineOrigin.x += frameRect.origin.x;
		lineOrigin.y += frameRect.origin.y;

		CFArrayRef runs = CTLineGetGlyphRuns(line);
		imm runCount = CFArrayGetCount(runs);

		for (imm runIndex = 0; runIndex < runCount; runIndex++)
		{
			CTRunRef run = CFArrayGetValueAtIndex(runs, runIndex);

			CFDictionaryRef runAttributes = CTRunGetAttributes(run);

			const void *runFontRaw =
			        CFDictionaryGetValue(runAttributes, kCTFontAttributeName);
			Assert(CFGetTypeID(runFontRaw) == CTFontGetTypeID());
			CTFontRef runFont = runFontRaw;

			const void *unmatchedColorRaw = CFDictionaryGetValue(runAttributes,
			        (__bridge CFStringRef)NSForegroundColorAttributeName);
			NSColor *unmatchedColor = (__bridge NSColor *)unmatchedColorRaw;
			NSColor *color = [unmatchedColor colorUsingColorSpace:colorSpace];

			simd_float4 simdColor = 0;
			simdColor.r = (float)color.redComponent;
			simdColor.g = (float)color.greenComponent;
			simdColor.b = (float)color.blueComponent;
			simdColor.a = (float)color.alphaComponent;

			imm runGlyphCount = CTRunGetGlyphCount(run);

			CGGlyph *glyphs = calloc((umm)runGlyphCount, sizeof(CGGlyph));
			CTRunGetGlyphs(run, (CFRange){0}, glyphs);

			CGPoint *glyphPositions = calloc((umm)runGlyphCount, sizeof(CGPoint));
			CTRunGetPositions(run, (CFRange){0}, glyphPositions);

			CGRect *glyphBoundingRects = calloc((umm)runGlyphCount, sizeof(CGRect));
			CTFontGetBoundingRectsForGlyphs(runFont, kCTFontOrientationDefault, glyphs,
			        glyphBoundingRects, runGlyphCount);

			for (imm glyphIndex = 0; glyphIndex < runGlyphCount; glyphIndex++)
			{
				CGGlyph glyph = glyphs[glyphIndex];
				CGPoint glyphPosition = glyphPositions[glyphIndex];
				CGRect glyphBoundingRect = glyphBoundingRects[glyphIndex];

				if (glyphBoundingRect.size.width == 0 ||
				        glyphBoundingRect.size.height == 0)
				{
					continue;
				}

				CGPoint rawPosition = {0};
				rawPosition.x =
				        lineOrigin.x + glyphPosition.x + glyphBoundingRect.origin.x;
				rawPosition.y =
				        lineOrigin.y + glyphPosition.y + glyphBoundingRect.origin.y;

				rawPosition.x *= scaleFactor;
				rawPosition.y *= scaleFactor;

				CGPoint roundedPosition = {0};
				roundedPosition.x = floor(rawPosition.x);
				roundedPosition.y = floor(rawPosition.y);

				CGPoint fractionalPosition = {0};
				fractionalPosition.x = rawPosition.x - roundedPosition.x;
				fractionalPosition.y = rawPosition.y - roundedPosition.y;

				CachedGlyph cachedGlyph =
				        [glyphCache cachedGlyph:glyph
				                           font:runFont
				                 subpixelOffset:fractionalPosition];

				Sprite *sprite = sprites + spriteCount;
				spriteCount++;

				sprite->position.x = (float)roundedPosition.x;
				sprite->position.y = (float)roundedPosition.y;
				sprite->position -= cachedGlyph.offset;

				sprite->size = cachedGlyph.size;
				sprite->textureCoordinatesBlack = cachedGlyph.positionBlack;
				sprite->textureCoordinatesWhite = cachedGlyph.positionWhite;

				sprite->color = simdColor;
			}

			free(glyphs);
			free(glyphPositions);
			free(glyphBoundingRects);
		}
	}

	id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

	NSColor *convertedBackgroundColor = [backgroundColor colorUsingColorSpace:colorSpace];
	MTLClearColor clearColor = {0};
	clearColor.red = convertedBackgroundColor.redComponent;
	clearColor.green = convertedBackgroundColor.greenComponent;
	clearColor.blue = convertedBackgroundColor.blueComponent;
	clearColor.alpha = convertedBackgroundColor.alphaComponent;

	MTLRenderPassDescriptor *descriptor = [[MTLRenderPassDescriptor alloc] init];
	descriptor.colorAttachments[0].texture = texture;
	descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
	descriptor.colorAttachments[0].clearColor = clearColor;

	id<MTLRenderCommandEncoder> encoder =
	        [commandBuffer renderCommandEncoderWithDescriptor:descriptor];

	NSSize size = [self convertSizeToBacking:self.bounds.size];
	Arguments arguments = {0};
	arguments.size.x = (float)size.width;
	arguments.size.y = (float)size.height;
	arguments.glyphCacheTexture = glyphCache.texture.gpuResourceID;

	[encoder setRenderPipelineState:pipelineState];
	[encoder useResource:glyphCache.texture
	               usage:MTLResourceUsageRead
	              stages:MTLRenderStageFragment];

	[encoder setVertexBytes:&arguments length:sizeof(arguments) atIndex:0];
	[encoder setFragmentBytes:&arguments length:sizeof(arguments) atIndex:0];

	[encoder setVertexBytes:sprites length:sizeof(*sprites) * (umm)spriteCount atIndex:1];
	[encoder setFragmentBytes:sprites length:sizeof(*sprites) * (umm)spriteCount atIndex:1];

	[encoder drawPrimitives:MTLPrimitiveTypeTriangle
	            vertexStart:0
	            vertexCount:6
	          instanceCount:(umm)spriteCount];

	[encoder endEncoding];

	[commandBuffer commit];
	[commandBuffer waitUntilCompleted];
	[self.layer setContentsChanged];

	[notificationCenter postNotificationName:UpdatedTextureBNotificationName object:texture];

	free(lineOrigins);
	free(sprites);
	CFRelease(frame);
	CFRelease(framesetter);
	CFRelease(path);
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];

	glyphCache = [[GlyphCache alloc] initWithDevice:device
	                                    scaleFactor:self.window.backingScaleFactor];

	self.layer.contentsScale = self.window.backingScaleFactor;
	[self updateIOSurface];
	self.needsDisplay = YES;
}

- (void)setFrameSize:(NSSize)size
{
	[super setFrameSize:size];
	[self updateIOSurface];
	self.needsDisplay = YES;
}

- (void)updateIOSurface
{
	NSSize size = [self convertSizeToBacking:self.layer.frame.size];

	if (size.width == 0 || size.height == 0)
	{
		return;
	}

	NSDictionary *properties = @{
		(__bridge NSString *)kIOSurfaceWidth : @(size.width),
		(__bridge NSString *)kIOSurfaceHeight : @(size.height),
		(__bridge NSString *)kIOSurfaceBytesPerElement : @4,
		(__bridge NSString *)kIOSurfacePixelFormat : @(kCVPixelFormatType_32BGRA),
	};

	MTLTextureDescriptor *descriptor = [[MTLTextureDescriptor alloc] init];
	descriptor.width = (umm)size.width;
	descriptor.height = (umm)size.height;
	descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;

	if (iosurface != NULL)
	{
		CFRelease(iosurface);
	}

	iosurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
	texture = [device newTextureWithDescriptor:descriptor iosurface:iosurface plane:0];
	texture.label = @"Layer Contents";

	self.layer.contents = (__bridge id)iosurface;
}

- (NSAttributedString *)attributedString
{
	return attributedString;
}

- (void)setAttributedString:(NSAttributedString *)attributedString_
{
	attributedString = attributedString_;
	self.needsDisplay = YES;
}

- (NSColor *)backgroundColor
{
	return backgroundColor;
}

- (void)setBackgroundColor:(NSColor *)backgroundColor_
{
	backgroundColor = backgroundColor_;
	self.needsDisplay = YES;
}

@end
