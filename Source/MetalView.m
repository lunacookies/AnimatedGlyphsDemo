typedef struct Arguments Arguments;
struct Arguments
{
	simd_float2 size;
	MTLResourceID glyphCacheTexture;
	uint64 sprites;
};

typedef struct LoupeArguments LoupeArguments;
struct LoupeArguments
{
	MTLResourceID src;
	MTLResourceID dst;
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

typedef struct Atom Atom;
struct Atom
{
	uint16 codeUnit;
	simd_float2 position;
	simd_float2 positionTarget;
	simd_float4 color;
	simd_float4 colorTarget;
};

@implementation MetalView
{
	id<MTLDevice> device;
	id<MTLCommandQueue> commandQueue;
	id<MTLRenderPipelineState> pipelineState;
	id<MTLComputePipelineState> loupePipelineState;
	CADisplayLink *displayLink;

	IOSurfaceRef iosurface;
	id<MTLTexture> texture;
	id<MTLTexture> offscreenTexture;

	GlyphCache *glyphCache;
	id<MTLBuffer> sprites;
	imm spriteCapacity;

	Atom *atoms;
	imm atomCapacity;
	imm atomCount;

	float scrollOffset;
}

- (instancetype)initWithFrame:(NSRect)frame
{
	self = [super initWithFrame:frame];

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

	loupePipelineState = [device
	        newComputePipelineStateWithFunction:[library newFunctionWithName:@"loupe_main"]
	                                      error:nil];

	displayLink = [self displayLinkWithTarget:self selector:@selector(displayLinkDidFire)];
	[displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];

	atomCapacity = 8;
	atoms = calloc((umm)atomCapacity, sizeof(Atom));

	return self;
}

- (void)displayLinkDidFire
{
	self.needsDisplay = YES;
}

- (BOOL)wantsUpdateLayer
{
	return YES;
}

- (void)updateLayer
{
	uint16 *codeUnits = calloc((umm)atomCount, sizeof(uint16));
	for (imm i = 0; i < atomCount; i++)
	{
		codeUnits[i] = atoms[i].codeUnit;
	}
	NSString *string = [NSString stringWithCharacters:codeUnits length:(umm)atomCount];
	free(codeUnits);

	NSAttributedString *attributedString = [[NSAttributedString alloc]
	        initWithString:string
	            attributes:@{
		            NSFontAttributeName : [NSFont systemFontOfSize:13],
		            NSForegroundColorAttributeName : NSColor.labelColor,
	            }];

	CFDictionaryRef typesetterOptions = (__bridge CFDictionaryRef) @{
		(__bridge NSString *)
		kCTTypesetterOptionAllowUnboundedLayout : (__bridge NSNumber *)kCFBooleanTrue
	};
	CTTypesetterRef typesetter = CTTypesetterCreateWithAttributedStringAndOptions(
	        (__bridge CFAttributedStringRef)attributedString, typesetterOptions);
	CTFramesetterRef framesetter = CTFramesetterCreateWithTypesetter(typesetter);

	CGSize frameSizeConstraints = self.bounds.size;
	frameSizeConstraints.height = CGFLOAT_MAX;

	CGSize frameSize = CTFramesetterSuggestFrameSizeWithConstraints(
	        framesetter, (CFRange){0}, NULL, frameSizeConstraints, NULL);

	if (self.bounds.size.height > frameSize.height)
	{
		scrollOffset = 0;
	}
	else
	{
		scrollOffset = simd_clamp(
		        scrollOffset, 0, (float)(frameSize.height - self.bounds.size.height));
	}

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

	if (frameGlyphCount > spriteCapacity)
	{
		do
		{
			if (spriteCapacity == 0)
			{
				spriteCapacity = 1024;
			}
			else
			{
				spriteCapacity *= 2;
			}
		} while (frameGlyphCount > spriteCapacity);
		sprites = [device newBufferWithLength:(umm)spriteCapacity * sizeof(Sprite)
		                              options:MTLResourceStorageModeShared];
		sprites.label = @"Sprites";
	}

	imm spriteCount = 0;

	NSColorSpace *colorSpace = self.window.colorSpace;
	Assert(colorSpace != nil);

	for (imm lineIndex = 0; lineIndex < lineCount; lineIndex++)
	{
		CTLineRef line = CFArrayGetValueAtIndex(lines, lineIndex);
		simd_float2 lineOrigin = 0;
		lineOrigin.x = (float)(lineOrigins[lineIndex].x + frameRect.origin.x);
		lineOrigin.y = (float)(lineOrigins[lineIndex].y + frameRect.origin.y);

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

			CFIndex *stringIndices = calloc((umm)runGlyphCount, sizeof(CFIndex));
			CTRunGetStringIndices(run, (CFRange){0}, stringIndices);

			for (imm glyphIndex = 0; glyphIndex < runGlyphCount; glyphIndex++)
			{
				CGGlyph glyph = glyphs[glyphIndex];

				simd_float2 glyphPosition = 0;
				glyphPosition.x = (float)glyphPositions[glyphIndex].x;
				glyphPosition.y = (float)glyphPositions[glyphIndex].y;

				simd_float2 rawPosition = lineOrigin + glyphPosition;
				rawPosition *= scaleFactor;

				imm atomsStart = stringIndices[glyphIndex];
				imm atomsEnd = atomsStart + 1;
				if (glyphIndex < runGlyphCount - 1)
				{
					atomsEnd = stringIndices[glyphIndex + 1];
				}
				Assert(atomsStart < atomsEnd);

				for (imm atomIndex = atomsStart; atomIndex < atomsEnd; atomIndex++)
				{
					Atom *atom = atoms + atomIndex;

					simd_float2 positionTargetOld = atom->positionTarget;
					simd_float2 positionTargetNew = rawPosition;
					positionTargetNew.y =
					        (float)texture.height - positionTargetNew.y;

					atom->positionTarget = positionTargetNew;
					atom->colorTarget = simdColor;

					if (simd_all(positionTargetOld != positionTargetNew))
					{
						atom->position = atom->positionTarget;
						atom->color.a = 0;
					}
					else
					{
						atom->position = simd_mix(
						        atom->position, atom->positionTarget, 0.1f);
						atom->color = simd_mix(
						        atom->color, atom->colorTarget, 0.05f);
					}
				}

				rawPosition = atoms[atomsStart].position;
				rawPosition.y = (float)texture.height - rawPosition.y;

				simd_float2 integralComponent = floor(rawPosition);
				simd_float2 fractionalComponent = rawPosition - integralComponent;

				CachedGlyph cachedGlyph =
				        [glyphCache cachedGlyph:glyph
				                           font:runFont
				                 subpixelOffset:fractionalComponent];

				Sprite *sprite = (Sprite *)sprites.contents + spriteCount;
				spriteCount++;
				sprite->position = integralComponent - cachedGlyph.offset;
				sprite->position.y += scrollOffset * scaleFactor;
				sprite->size = cachedGlyph.size;
				sprite->textureCoordinatesBlack =
				        cachedGlyph.textureCoordinatesBlack;
				sprite->textureCoordinatesWhite =
				        cachedGlyph.textureCoordinatesWhite;
				sprite->color = atoms[atomsStart].color;
			}

			free(glyphs);
			free(glyphPositions);
			free(stringIndices);
		}
	}

	free(lineOrigins);
	CFRelease(frame);
	CFRelease(path);
	CFRelease(framesetter);
	CFRelease(typesetter);

	Assert(spriteCount <= spriteCapacity);
	Assert(spriteCount == frameGlyphCount);

	id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

	{
		NSColor *convertedBackgroundColor =
		        [NSColor.textBackgroundColor colorUsingColorSpace:colorSpace];
		MTLClearColor clearColor = {0};
		clearColor.red = convertedBackgroundColor.redComponent;
		clearColor.green = convertedBackgroundColor.greenComponent;
		clearColor.blue = convertedBackgroundColor.blueComponent;
		clearColor.alpha = convertedBackgroundColor.alphaComponent;

		MTLRenderPassDescriptor *descriptor = [[MTLRenderPassDescriptor alloc] init];
		descriptor.colorAttachments[0].texture = offscreenTexture;
		descriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
		descriptor.colorAttachments[0].clearColor = clearColor;

		id<MTLRenderCommandEncoder> encoder =
		        [commandBuffer renderCommandEncoderWithDescriptor:descriptor];

		NSSize size = [self convertSizeToBacking:self.bounds.size];
		Arguments arguments = {0};
		arguments.size.x = (float)size.width;
		arguments.size.y = (float)size.height;
		arguments.glyphCacheTexture = glyphCache.texture.gpuResourceID;
		arguments.sprites = sprites.gpuAddress;

		if (spriteCount > 0)
		{
			[encoder setRenderPipelineState:pipelineState];
			[encoder useResource:glyphCache.texture
			               usage:MTLResourceUsageRead
			              stages:MTLRenderStageVertex | MTLRenderStageFragment];
			[encoder useResource:sprites
			               usage:MTLResourceUsageRead
			              stages:MTLRenderStageVertex | MTLRenderStageFragment];

			[encoder setVertexBytes:&arguments length:sizeof(arguments) atIndex:0];
			[encoder setFragmentBytes:&arguments length:sizeof(arguments) atIndex:0];

			[encoder drawPrimitives:MTLPrimitiveTypeTriangle
			            vertexStart:0
			            vertexCount:6
			          instanceCount:(umm)spriteCount];
		}

		[encoder endEncoding];
	}

	{
		id<MTLComputeCommandEncoder> encoder = [commandBuffer computeCommandEncoder];

		LoupeArguments arguments = {0};
		arguments.src = offscreenTexture.gpuResourceID;
		arguments.dst = texture.gpuResourceID;

		[encoder setComputePipelineState:loupePipelineState];
		[encoder useResource:offscreenTexture usage:MTLResourceUsageRead];
		[encoder useResource:texture usage:MTLResourceUsageWrite];
		[encoder setBytes:&arguments length:sizeof(arguments) atIndex:0];
		[encoder dispatchThreads:MTLSizeMake(texture.width, texture.height, 1)
		        threadsPerThreadgroup:MTLSizeMake(32, 32, 1)];

		[encoder endEncoding];
	}


	[commandBuffer commit];
	[commandBuffer waitUntilCompleted];
	[self.layer setContentsChanged];
}

- (void)viewDidChangeBackingProperties
{
	[super viewDidChangeBackingProperties];

	glyphCache = [[GlyphCache alloc] initWithDevice:device
	                                    scaleFactor:(float)self.window.backingScaleFactor];

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
	descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
	                   MTLTextureUsageShaderWrite;
	descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;

	if (iosurface != NULL)
	{
		CFRelease(iosurface);
	}

	iosurface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
	texture = [device newTextureWithDescriptor:descriptor iosurface:iosurface plane:0];
	offscreenTexture = [device newTextureWithDescriptor:descriptor];
	texture.label = @"Layer Contents";

	self.layer.contents = (__bridge id)iosurface;
}

- (BOOL)acceptsFirstResponder
{
	return YES;
}

- (void)keyDown:(NSEvent *)event
{
	[self interpretKeyEvents:@[ event ]];
}

- (void)insertText:(id)idString
{
	NSString *string = idString;
	imm length = (imm)string.length;

	if (atomCount + length > atomCapacity)
	{
		do
		{
			atomCapacity *= 2;
		} while (atomCount + length > atomCapacity);
		atoms = realloc(atoms, sizeof(Atom) * (umm)atomCapacity);
	}

	uint16 *codeUnits = calloc((umm)length, sizeof(uint16));
	[string getCharacters:codeUnits range:(NSRange){0, (umm)length}];

	for (imm i = 0; i < length; i++)
	{
		Atom *atom = atoms + atomCount + i;
		memset(atom, 0, sizeof(*atom));
		atom->codeUnit = codeUnits[i];
	}
	atomCount += length;

	free(codeUnits);

	self.needsDisplay = YES;
}

- (void)insertNewline:(id)sender
{
	[self insertText:@"\n"];
}

- (void)deleteBackward:(id)sender
{
	if (atomCount > 0)
	{
		atomCount--;
		self.needsDisplay = YES;
	}
}

- (void)scrollWheel:(NSEvent *)event
{
	scrollOffset -= (float)event.scrollingDeltaY;
	self.needsDisplay = YES;
}

@end
