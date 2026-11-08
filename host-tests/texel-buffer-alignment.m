#import <Metal/Metal.h>
#include <stdio.h>
int main(void) {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    struct { MTLPixelFormat f; const char *n; unsigned texel; } fs[] = {
        { MTLPixelFormatR8Unorm, "R8Unorm", 1 }, { MTLPixelFormatR8Uint, "R8Uint", 1 }, { MTLPixelFormatRG8Unorm, "RG8Unorm", 2 },
        { MTLPixelFormatR16Uint, "R16Uint", 2 }, { MTLPixelFormatR16Float, "R16Float", 2 }, { MTLPixelFormatRGBA8Unorm, "RGBA8Unorm", 4 },
        { MTLPixelFormatR32Uint, "R32Uint", 4 }, { MTLPixelFormatR32Float, "R32Float", 4 }, { MTLPixelFormatRG32Float, "RG32Float", 8 },
        { MTLPixelFormatRGBA16Float, "RGBA16Float", 8 }, { MTLPixelFormatRGBA32Float, "RGBA32Float", 16 }, { MTLPixelFormatRGBA32Uint, "RGBA32Uint", 16 },
    };
    int ok = 1;
    for (unsigned i = 0; i < sizeof fs / sizeof fs[0]; i++) {
        NSUInteger a = [d minimumTextureBufferAlignmentForPixelFormat:fs[i].f];
        printf("%-12s texel %2u B, Metal texture buffer offset alignment %3lu B %s\n", fs[i].n, fs[i].texel, (unsigned long)a,
               a <= fs[i].texel ? "ok" : "LARGER");
        ok &= a <= fs[i].texel;
    }
    printf("%s (%s)\n", ok ? "single-texel alignment holds" : "single-texel alignment does NOT hold", [d.name UTF8String]);
    return 0;
}
