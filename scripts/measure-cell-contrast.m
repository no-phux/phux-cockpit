// Rasterize a terminal row IN A GIVEN FOREGROUND, through the SDK host's own
// rasterizer, and measure how much ink reaches the bitmap.
//
// Sibling of scripts/measure-host-raster.m and built the same way: it
// `#include`s the pinned SDK's `src/platform/macos/appkit_host.m`, so the
// CGBitmapContext configuration, the CoreText draw, the face resolution and
// the colour space are the host's own. The difference is the QUESTION.
// measure-host-raster asks "how thickly does this rasterizer ink a glyph",
// holding the colour fixed at the app's foreground. This asks "how much of
// that ink survives THIS foreground on THIS background", holding the
// rasterizer fixed and varying the colour — which is the half a
// minimum-contrast floor moves.
//
// It takes its colours on the command line rather than declaring them,
// because the caller (scripts/contrast-floor-check.sh) reads them out of the
// running Zig projection. A colour typed into this file would be a
// counterfactual; a colour the build printed is evidence. See
// phux-cockpit-wmi.
//
//   measure-cell-contrast <font.ttf> <label>:<fgHex>:<bgHex> [...]
//
// Both hex values are #rrggbb or rrggbb. Each triple prints one line.
//
// THE BASIS is measure-host-raster.m's, unchanged and deliberately so: the
// same cell box, the same font size, the same 2x scale, the same opaque
// background so luminance is a direct read of coverage, and the same two
// thresholds (`solid` counts luma > 127, `lit` counts luma > 32).

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

#ifndef NATIVE_SDK_APPKIT_HOST
#error "define NATIVE_SDK_APPKIT_HOST to the pinned SDK's appkit_host.m path"
#endif

#include NATIVE_SDK_APPKIT_HOST

@interface NativeSdkMetalSurfaceView (PhuxCockpitCellContrast)
- (NativeSdkPacketCommandRaster *)rasterCacheBuildEntryForCommand:(NSDictionary *)command
                                                             kind:(NSString *)kind
                                                            scale:(CGFloat)scale
                                                       pixelWidth:(NSUInteger)pixelWidth
                                                      pixelHeight:(NSUInteger)pixelHeight;
@end

static NSString *const kSampleText = @"the quick brown fox jumps over the lazy dog $ ls";

static const CGFloat kFontSize = 13.0;
static const CGFloat kCellWidth = 8.0;
static const CGFloat kCellHeight = 18.0;
static const CGFloat kBaseline = 14.0;
static const CGFloat kScale = 2.0;

static BOOL ParseHex(const char *text, double out[3]) {
    if (!text) return NO;
    if (text[0] == '#') text++;
    if (strlen(text) != 6) return NO;
    for (int channel = 0; channel < 3; channel++) {
        char pair[3] = {text[channel * 2], text[channel * 2 + 1], 0};
        char *end = NULL;
        long value = strtol(pair, &end, 16);
        if (!end || *end != 0) return NO;
        out[channel] = (double)value / 255.0;
    }
    return YES;
}

static NSArray *ColorArray(const double rgb[3]) {
    return @[ @(rgb[0]), @(rgb[1]), @(rgb[2]), @(1.0) ];
}

static NSDictionary *CellGridCommand(NSUInteger cols, NSArray *fg, NSArray *bg) {
    NSMutableArray *cells = [NSMutableArray arrayWithCapacity:cols];
    for (NSUInteger column = 0; column < cols; column++) {
        NSMutableDictionary *cell = [NSMutableDictionary dictionary];
        cell[@"fg"] = fg;
        cell[@"bg"] = bg;
        cell[@"ul"] = fg;
        cell[@"flags"] = @(NativeSdkCellFlagHasBackground);
        if (column < kSampleText.length) {
            cell[@"text"] = [kSampleText substringWithRange:NSMakeRange(column, 1)];
        }
        [cells addObject:cell];
    }
    return @{
        @"kind" : @"cell_grid",
        @"bounds" : @[ @(0), @(0), @(cols * kCellWidth), @(kCellHeight) ],
        @"opacity" : @(1.0),
        @"cellGrid" : @{
            @"font" : @(1),
            @"boldFont" : @(0),
            @"italicFont" : @(0),
            @"boldItalicFont" : @(0),
            @"size" : @(kFontSize),
            @"origin" : @[ @(0), @(0) ],
            @"cellWidth" : @(kCellWidth),
            @"cellHeight" : @(kCellHeight),
            @"baseline" : @(kBaseline),
            @"cols" : @(cols),
            @"rows" : @(1),
            @"cells" : cells,
        },
    };
}

typedef struct {
    double mean;
    unsigned long long solid;
    unsigned long long lit;
    // Pixels whose luminance differs from the row's own background by more
    // than one 8-bit step. This is the statistic the contrast floor moves and
    // `solid`/`lit` do not: dark ink on a dark ground is real ink that no
    // absolute threshold counts, so a row of invisible text and a row of
    // BLANK both score solid=0, lit=0. `distinct` tells them apart.
    unsigned long long distinct;
    // The largest per-pixel luminance distance from the background anywhere in
    // the row: how far the most-inked pixel actually gets from the ground.
    double peak_delta;
} Ink;

static BOOL MeasureImage(CGImageRef image, double bgLuma, Ink *out) {
    if (!image) return NO;
    if (CGImageGetBitsPerComponent(image) != 8 || CGImageGetBitsPerPixel(image) != 32) return NO;
    CGDataProviderRef provider = CGImageGetDataProvider(image);
    CFDataRef data = provider ? CGDataProviderCopyData(provider) : NULL;
    if (!data) return NO;
    const uint8_t *px = CFDataGetBytePtr(data);
    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    const size_t stride = CGImageGetBytesPerRow(image);
    double sum = 0, peak = 0;
    unsigned long long solid = 0, lit = 0, distinct = 0;
    for (size_t y = 0; y < height; y++) {
        const uint8_t *row = px + y * stride;
        for (size_t x = 0; x < width; x++) {
            const uint8_t *p = row + x * 4;
            const double luma = 0.2126 * p[0] + 0.7152 * p[1] + 0.0722 * p[2];
            sum += luma;
            if (luma > 127.0) solid++;
            if (luma > 32.0) lit++;
            const double delta = fabs(luma - bgLuma);
            if (delta > 1.0) distinct++;
            if (delta > peak) peak = delta;
        }
    }
    CFRelease(data);
    const double count = (double)(width * height);
    out->mean = count > 0 ? sum / count : 0.0;
    out->solid = solid;
    out->lit = lit;
    out->distinct = distinct;
    out->peak_delta = peak;
    return YES;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: measure-cell-contrast <font.ttf> <label>:<fgHex>:<bgHex> [...]\n");
            return 2;
        }
        NSString *fontPath = [NSString stringWithUTF8String:argv[1]];
        NSData *fontData = [NSData dataWithContentsOfFile:fontPath];
        if (!fontData) {
            fprintf(stderr, "cannot read font %s\n", argv[1]);
            return 1;
        }
        uint64_t token = 0;
        if (native_sdk_appkit_register_font(1, fontData.bytes, fontData.length, &token) != 1) {
            fprintf(stderr, "the host refused to register %s\n", argv[1]);
            return 1;
        }

        NativeSdkMetalSurfaceView *view =
            [[NativeSdkMetalSurfaceView alloc] initWithFrame:NSMakeRect(0, 0, 640, 64)];
        if (!view) {
            fprintf(stderr, "could not create the host surface view\n");
            return 1;
        }
        [view stopDisplayTimer];
        if (!view.canvasColorSpace) view.canvasColorSpace = CGColorSpaceCreateDeviceRGB();

        const NSUInteger cols = kSampleText.length;
        const NSUInteger pixelWidth = (NSUInteger)(cols * kCellWidth * kScale);
        const NSUInteger pixelHeight = (NSUInteger)(kCellHeight * kScale);

        printf("sdk=%s\n", NATIVE_SDK_APPKIT_HOST);
        printf("font=%s size=%.1f scale=%.1f cols=%lu\n",
               argv[1], (double)kFontSize, (double)kScale, (unsigned long)cols);

        for (int index = 2; index < argc; index++) {
            char spec[256];
            strncpy(spec, argv[index], sizeof(spec) - 1);
            spec[sizeof(spec) - 1] = 0;
            char *label = strtok(spec, ":");
            char *fgText = strtok(NULL, ":");
            char *bgText = strtok(NULL, ":");
            double fg[3], bg[3];
            if (!label || !ParseHex(fgText, fg) || !ParseHex(bgText, bg)) {
                fprintf(stderr, "bad spec %s (want label:#rrggbb:#rrggbb)\n", argv[index]);
                return 2;
            }
            // The background's own luminance in the SAME 0..255 byte space the
            // measured pixels live in, so `distinct` compares like with like.
            const double bgLuma = 255.0 * (0.2126 * bg[0] + 0.7152 * bg[1] + 0.0722 * bg[2]);

            NativeSdkPacketCommandRaster *entry =
                [view rasterCacheBuildEntryForCommand:CellGridCommand(cols, ColorArray(fg), ColorArray(bg))
                                                 kind:@"cell_grid"
                                                scale:kScale
                                           pixelWidth:pixelWidth
                                          pixelHeight:pixelHeight];
            if (!entry || !entry.image) {
                fprintf(stderr, "the host rasterizer returned nothing for %s\n", label);
                return 1;
            }
            Ink ink;
            if (!MeasureImage(entry.image, bgLuma, &ink)) {
                fprintf(stderr, "unexpected raster layout for %s\n", label);
                return 1;
            }
            printf("label=%-22s fg=%s bg=%s mean_luma=%8.4f solid=%6llu lit=%6llu distinct=%6llu peak_delta=%7.2f\n",
                   label, fgText, bgText, ink.mean, ink.solid, ink.lit, ink.distinct, ink.peak_delta);
        }
        return 0;
    }
}
