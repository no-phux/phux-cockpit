// Compare two PNGs over one rectangle and report how many pixels differ.
//
// Build and run:
//   clang -o /tmp/diff-png-region scripts/diff-png-region.m \
//       -framework Foundation -framework CoreGraphics -framework ImageIO
//   /tmp/diff-png-region a.png b.png [x y w h]
//
// Exit status is 0 when the region is byte-identical and 1 when it is not, so
// this reads as an assertion in a script. Anything that is not a comparison -
// a missing file, a size mismatch, an unsupported pixel layout - exits 2, so a
// broken comparison can never be mistaken for "the images match".
//
// WHY THIS EXISTS
// ---------------
// scripts/measure-png-ink.m answers "how much ink", which is the right
// question for a weight regression and the wrong one for "did anything move at
// all": two images can carry identical mean_luma/solid/lit and still differ
// everywhere. Proving an instrument is BLIND to a change needs the stronger
// statement, and proving another instrument SEES it wants the count, not just
// a stat that moved.
//
// THE BASIS, the same one measure-png-ink.m states, so numbers from the two
// tools describe the same pixels:
//   * Pixels are read from each PNG's own decoded bytes via the CGImage data
//     provider. No CGBitmapContext redraw, so no colour conversion is applied
//     to either input.
//   * Both inputs must be 8-bit, 32-bit-per-pixel, alpha-last. Anything else
//     is refused by name rather than measured on a guess.
//   * A pixel "differs" when any of its four channels differs; `max_delta` is
//     the largest single-channel absolute difference over the region.
//
// The rectangle matters more than it looks. A capture of a live app usually
// carries something that legitimately changes between runs (a clock, a frame
// counter, a cursor phase); comparing whole images then reports a difference
// that is content rather than rendering. Crop it off and say so.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

typedef struct {
    CGImageRef image;
    CFDataRef data;
    const uint8_t *bytes;
    size_t width;
    size_t height;
    size_t stride;
} DiffImage;

static BOOL LoadImage(const char *path, DiffImage *out) {
    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) { fprintf(stderr, "cannot open %s\n", path); return NO; }
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) { fprintf(stderr, "cannot decode %s\n", path); return NO; }

    size_t bpp = CGImageGetBitsPerPixel(image);
    size_t bpc = CGImageGetBitsPerComponent(image);
    CGBitmapInfo info = CGImageGetBitmapInfo(image);
    CGImageAlphaInfo alpha = (CGImageAlphaInfo)(info & kCGBitmapAlphaInfoMask);
    if (bpc != 8 || bpp != 32) {
        fprintf(stderr, "%s: unsupported layout bpc=%zu bpp=%zu\n", path, bpc, bpp);
        CGImageRelease(image);
        return NO;
    }
    if (alpha != kCGImageAlphaPremultipliedLast && alpha != kCGImageAlphaLast &&
        alpha != kCGImageAlphaNoneSkipLast && alpha != kCGImageAlphaNone) {
        fprintf(stderr, "%s: unsupported alpha info %d (want alpha-last)\n", path, (int)alpha);
        CGImageRelease(image);
        return NO;
    }

    CGDataProviderRef provider = CGImageGetDataProvider(image);
    CFDataRef data = provider ? CGDataProviderCopyData(provider) : NULL;
    if (!data) { fprintf(stderr, "%s: no pixel data\n", path); CGImageRelease(image); return NO; }

    out->image = image;
    out->data = data;
    out->bytes = CFDataGetBytePtr(data);
    out->width = CGImageGetWidth(image);
    out->height = CGImageGetHeight(image);
    out->stride = CGImageGetBytesPerRow(image);
    return YES;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: diff-png-region <a.png> <b.png> [x y w h]\n");
            return 2;
        }
        DiffImage a = {0};
        DiffImage b = {0};
        if (!LoadImage(argv[1], &a)) return 2;
        if (!LoadImage(argv[2], &b)) return 2;
        if (a.width != b.width || a.height != b.height) {
            fprintf(stderr, "size mismatch: %zux%zu vs %zux%zu\n", a.width, a.height, b.width, b.height);
            return 2;
        }

        size_t rx = 0, ry = 0, rw = a.width, rh = a.height;
        if (argc >= 7) {
            rx = (size_t)atol(argv[3]);
            ry = (size_t)atol(argv[4]);
            rw = (size_t)atol(argv[5]);
            rh = (size_t)atol(argv[6]);
            if (rx > a.width || ry > a.height) { fprintf(stderr, "rect outside image\n"); return 2; }
            if (rx + rw > a.width) rw = a.width - rx;
            if (ry + rh > a.height) rh = a.height - ry;
        }
        if (rw == 0 || rh == 0) { fprintf(stderr, "empty rect\n"); return 2; }

        unsigned long long differing = 0;
        unsigned long long maxDelta = 0;
        size_t firstX = 0, firstY = 0;
        for (size_t y = ry; y < ry + rh; y++) {
            const uint8_t *rowA = a.bytes + y * a.stride;
            const uint8_t *rowB = b.bytes + y * b.stride;
            for (size_t x = rx; x < rx + rw; x++) {
                const uint8_t *pa = rowA + x * 4;
                const uint8_t *pb = rowB + x * 4;
                unsigned long long pixelDelta = 0;
                for (int channel = 0; channel < 4; channel++) {
                    unsigned long long delta = pa[channel] > pb[channel]
                        ? (unsigned long long)(pa[channel] - pb[channel])
                        : (unsigned long long)(pb[channel] - pa[channel]);
                    if (delta > pixelDelta) pixelDelta = delta;
                }
                if (pixelDelta > 0) {
                    if (differing == 0) { firstX = x; firstY = y; }
                    differing++;
                    if (pixelDelta > maxDelta) maxDelta = pixelDelta;
                }
            }
        }

        double total = (double)(rw * rh);
        printf("a=%s b=%s rect=%zu,%zu,%zu,%zu pixels=%.0f diff_pixels=%llu diff_pct=%.4f max_delta=%llu first=(%zu,%zu)\n",
               argv[1], argv[2], rx, ry, rw, rh, total, differing,
               total > 0 ? 100.0 * (double)differing / total : 0.0,
               maxDelta, firstX, firstY);

        CFRelease(a.data);
        CFRelease(b.data);
        CGImageRelease(a.image);
        CGImageRelease(b.image);
        return differing == 0 ? 0 : 1;
    }
}
