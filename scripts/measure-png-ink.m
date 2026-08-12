// Measure ink statistics of a PNG, on ONE stated basis, with no colour
// management in the way.
//
// Build and run:
//   clang -o /tmp/measure-png-ink scripts/measure-png-ink.m \
//       -framework Foundation -framework CoreGraphics -framework ImageIO
//   /tmp/measure-png-ink shot.png [x y w h]
//
// This exists for phux-cockpit-2ml.3. `native automate screenshot` renders
// through the SDK's deterministic CPU reference renderer, which rasterizes
// glyphs from its own TrueType outline filler and never touches CoreText. A
// defect in the REAL rasterizer - macOS font smoothing off, a wrong blend, a
// wrong colour space - cannot appear in a reference screenshot by
// construction. This tool turns a PNG into numbers that can be compared
// without arguing about eyes.
//
// It used to name a companion, scripts/capture-gpu-ink.sh, that would capture
// the real composited Metal texture. That script does not exist and was never
// written: docs/RENDER_FIDELITY.md section 2 records why, having evaluated
// every capture path the SDK offers and found each one either TCC-gated or,
// in the case of NATIVE_SDK_GPU_SHOT_DIR, silently replacing the rasterizer it
// was supposed to photograph. So the only inputs here are reference
// screenshots, and the reference-vs-GPU comparison the paragraph below warns
// about cannot currently be made at all.
//
// THE BASIS, stated once so both sides of any comparison keep it:
//   * Pixels are read from the PNG's own decoded bytes via the CGImage data
//     provider. No CGBitmapContext redraw, so no colour conversion is applied
//     to either input.
//   * Both inputs are opaque RGBA8: the reference screenshot is composited
//     over the view's clear colour, and the GPU readback is premultiplied over
//     the same opaque terminal background. With alpha = 255 the premultiplied
//     and straight forms are equal, so luminance is directly comparable.
//   * luma = 0.2126*R + 0.7152*G + 0.0722*B on the raw 0..255 samples.
//   * `solid` counts luma > 127 and `lit` counts luma > 32 - the same two
//     thresholds scripts/measure-glyph-smoothing.m reports, so the numbers
//     from the two tools describe the same thing.
//
// Absolute values are only comparable between images of the same size drawn by
// the same renderer. Compare a renderer against ITSELF across two builds; do
// not read across the reference/GPU column boundary.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: measure-png-ink <file.png> [x y w h]\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSURL *url = [NSURL fileURLWithPath:path];
        CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        if (!source) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
        CFRelease(source);
        if (!image) { fprintf(stderr, "cannot decode %s\n", argv[1]); return 1; }

        size_t width = CGImageGetWidth(image);
        size_t height = CGImageGetHeight(image);
        size_t bpp = CGImageGetBitsPerPixel(image);
        size_t bpc = CGImageGetBitsPerComponent(image);
        size_t stride = CGImageGetBytesPerRow(image);
        CGBitmapInfo info = CGImageGetBitmapInfo(image);
        CGImageAlphaInfo alpha = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);

        // Refuse anything that is not the 8-bit, 4-channel, big-endian byte
        // order both producers emit, rather than silently measuring a layout
        // this tool guessed at.
        if (bpc != 8 || bpp != 32) {
            fprintf(stderr, "%s: unsupported layout bpc=%zu bpp=%zu\n", argv[1], bpc, bpp);
            CGImageRelease(image);
            return 1;
        }
        // Channel order: RGBA (alpha last) is what both producers write. A
        // BGRA or alpha-first PNG would put luminance on the wrong channels,
        // so name it and stop.
        if (alpha != kCGImageAlphaPremultipliedLast && alpha != kCGImageAlphaLast &&
            alpha != kCGImageAlphaNoneSkipLast && alpha != kCGImageAlphaNone) {
            fprintf(stderr, "%s: unsupported alpha info %d (want alpha-last)\n", argv[1], (int)alpha);
            CGImageRelease(image);
            return 1;
        }

        CGDataProviderRef provider = CGImageGetDataProvider(image);
        CFDataRef data = provider ? CGDataProviderCopyData(provider) : NULL;
        if (!data) { fprintf(stderr, "%s: no pixel data\n", argv[1]); CGImageRelease(image); return 1; }
        const uint8_t *px = CFDataGetBytePtr(data);

        size_t rx = 0, ry = 0, rw = width, rh = height;
        if (argc >= 6) {
            rx = (size_t)atol(argv[2]);
            ry = (size_t)atol(argv[3]);
            rw = (size_t)atol(argv[4]);
            rh = (size_t)atol(argv[5]);
            if (rx > width || ry > height) { fprintf(stderr, "rect outside image\n"); return 1; }
            if (rx + rw > width) rw = width - rx;
            if (ry + rh > height) rh = height - ry;
        }

        double sum = 0;
        unsigned long long solid = 0, lit = 0;
        for (size_t y = ry; y < ry + rh; y++) {
            const uint8_t *row = px + y * stride;
            for (size_t x = rx; x < rx + rw; x++) {
                const uint8_t *p = row + x * 4;
                double luma = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
                sum += luma;
                if (luma > 127.0) solid++;
                if (luma > 32.0) lit++;
            }
        }
        double count = (double)(rw * rh);
        printf("file=%s width=%zu height=%zu rect=%zu,%zu,%zu,%zu pixels=%.0f mean_luma=%.4f solid=%llu lit=%llu\n",
               argv[1], width, height, rx, ry, rw, rh, count, count > 0 ? sum / count : 0.0, solid, lit);

        CFRelease(data);
        CGImageRelease(image);
        return 0;
    }
}
