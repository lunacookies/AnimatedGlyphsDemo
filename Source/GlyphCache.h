typedef struct CachedGlyph CachedGlyph;
struct CachedGlyph
{
	simd_float2 positionBlack;
	simd_float2 positionWhite;
	simd_float2 size;
	simd_float2 offset;
};

@interface GlyphCache : NSObject

- (instancetype)initWithDevice:(id<MTLDevice>)device scaleFactor:(float)scaleFactor;

- (CachedGlyph)cachedGlyph:(CGGlyph)glyph
                      font:(CTFontRef)font
            subpixelOffset:(simd_float2)subpixelOffset;

@property(readonly) id<MTLTexture> texture;

@end
