# Render fidelity: what each instrument can and cannot see

`phux-cockpit-2ml.3`. Written after establishing, with measurements rather than
argument, exactly which defect classes the automated screenshot path is blind
to and what can be done about it without a Screen Recording permission.

Read this before trusting a screenshot, and before writing a test that claims
to check what the terminal looks like.

---

## The short version

| Instrument | Sees | Blind to | Needs TCC |
|---|---|---|---|
| `native automate screenshot` | display list, layout, colour choices, which commands were emitted | everything the real macOS rasterizer does: CoreText outlines, hinting, font smoothing, CG blend arithmetic, device colour space | no |
| `scripts/host-raster-check.sh` | the real host rasterizer's output for a fixed row | layout, what the app actually emitted, anything outside one command | no |
| `scripts/drive-backing-scale.sh` | the real frame the live app uploads to the Metal texture, at any backing scale | the Metal upload itself, compositing by the window server, scanout | no, but it needs a diagnostic SDK build |
| eyes on glass / screen capture | everything | nothing | **yes** |

No instrument in the middle captures the app's real frames **through a
shipping build** without TCC; that claim is checked in section 2. Section 4
adds the one that does it through a diagnostic build, and the reason it had
to exist: everything in sections 1-3 was measured at one backing scale, and
the backing scale moves the numbers.

---

## 1. Why the reference screenshot cannot see a rasterizer defect

`native automate screenshot <label>` does not photograph anything and does not
read the GPU. The verb lands in `runtime/flow.zig:944`, is served by
`publishAutomationScreenshot` (`runtime/flow.zig:1043`), and the pixels come
from `renderCanvasScreenshot` (`runtime/canvas_frame.zig:801`, body at `:819`).
That function re-plans the view's retained display list as a full repaint and
rasterizes it with `canvas.ReferenceRenderSurface`
(`runtime/canvas_frame.zig:843-849`) — a pure-Zig CPU renderer.

Its glyphs come from `primitives/canvas/font_ttf.zig`, a std-only TrueType
outline parser, filled by a vector rasterizer held in per-thread scratch
(`primitives/canvas/reference.zig:61-79`). CoreText is never called on this
path. The PNG carries no colour-space chunk (`primitives/canvas/png.zig:55-77`).

The app's real frames take an entirely different route. Cockpit presents on the
**packet** path (`gpu_present_path=packet` in the automation snapshot, now asserted
by `scripts/automate-smoke.sh`), where the AppKit host decodes the packet
and rasterizes each command with CoreText into a `CGBitmapContext`
(`platform/macos/appkit_host.m:5256` for the cached raster, `:5473` for the
direct full-surface draw, `:4569` for the composite scratch). All three set
`CGContextSetShouldSmoothFonts`, added for `phux-cockpit-aht`. That call does
NOT fix anything: see "The smoothing calls are a no-op" below, where the two
shipping SDK commits are measured against each other and come out identical.

So: two renderers, two glyph rasterizers, and the screenshot only ever shows
the one that is not on screen.

### Proven, not asserted

Reintroducing the `aht` defect (`CGContextSetShouldSmoothFonts(..., true)` →
`false` at the three call sites above, in a local copy of the pinned SDK) and
building the app against it:

```
binary                                     reference screenshot sha256
8ed94141881ba893…  fixed SDK               6b4f3b582a7bbf926d0605f44bf9b7af1f07c84c86b61c6f84c4acba66fcd3d2
57ba94b9290ad790…  smoothing disabled      6b4f3b582a7bbf926d0605f44bf9b7af1f07c84c86b61c6f84c4acba66fcd3d2
```

Two different binaries, one byte-identical screenshot. The screenshots were
taken twice per run one second apart and matched within each run, so the
comparison is not measuring capture jitter. Same numbers on the same basis
(`scripts/measure-png-ink.m`, whole image): `mean_luma=21.6076 solid=132410
lit=177883` for both.

That result stands. It proves the screenshot is blind to the rasterizer. It
does NOT prove the smoothing change fixed anything, and the next section is
why.

### The smoothing calls are a no-op

`CGContextSetShouldSmoothFonts(ctx, false)` really does thin the glyphs, and the
harness really does see it. But no build was ever in that state. The state
before the fix was the calls being ABSENT, and absent is not false — on this
`CGBitmapContext` the default is smoothing ENABLED.

Three measurements, one harness, one basis, `scripts/host-raster-check.sh`:

| SDK | smoothing calls | mean_luma | solid | lit |
|---|---|---|---|---|
| `e8bd84886` (0.7.1 and 0.8.0 shipped this) | absent | 45.7978 | 4179 | 5103 |
| `f3678832f` (the current pin) | set `true` | 45.7978 | 4179 | 5103 |
| `f3678832f`, locally edited | set `false` | 37.1124 | 3081 | 4272 |

Reproduce the first two rows with

```
./scripts/host-raster-compare.sh e8bd84886
```

The two shipping commits are identical to four decimal places on every
statistic. The +35%/-26.3% that justified the fix was measured against the
third row: a state that exists only in a local edit made to demonstrate the
knob. **Cockpit's glyph weight has not changed since 0.7.1.** Any report that
the text still looks the same after the fix is correct, and is not a second
defect.

The comment in `build.zig.zon` claiming macOS font smoothing "is off by default
on a transparent backing" is false as measured here; the row above is the
refutation.

This is the general trap, and it is what `scripts/host-raster-compare.sh`
exists to close: a control you constructed tells you the knob is wired up. It
cannot tell you the knob was ever in the other position. Compare two commits
that shipped.

Meanwhile the same defect, measured through the host's own rasterizer, is
large — see section 3.

---

## 2. Capture paths evaluated, and why each one is or is not viable

The goal was a capture of the app's REAL pixels that runs without the macOS
Screen Recording permission, since TCC is unavailable in CI.

**`CGWindowListCreateImage`, `CGDisplayCreateImage`, `ScreenCaptureKit`,
`screencapture(1)`** — all TCC-gated since macOS 10.15. Not usable in CI. The
SDK does create an `SCStream` (`appkit_host.m:7856-7928`) but configures it 2x2
and drops every non-audio buffer at `:7931`; it is the audio capture service and
yields no image.

**`NSView cacheDisplayInRect:` / `CALayer renderInContext:`** — no TCC, but the
canvas is a `CAMetalLayer` and neither reads a Metal drawable. Not present in
the SDK either, so it would need in-process code the app cannot inject.

**`gpu_sample` in the automation snapshot** — this one IS a real GPU readback,
blitted from the presented drawable (`appkit_host.m:6337-6344`) and published as
`gpu_sample=0xff090b0f`. It is one pixel at the surface centre. Real, TCC-free,
automation-reachable, and far too coarse to measure glyph weight. Worth knowing
it exists; not an instrument.

**`NATIVE_SDK_GPU_SHOT_DIR`** — the SDK's only real-pixel-to-PNG path
(`appkit_host.m:5132-5155`): it reads the composited canvas texture back with
`getBytes` and writes a PNG. No TCC, no focus, no window required. This looked
like the answer.

It is not available to Cockpit. The dump only fires from the GPU composite pass
(`appkit_host.m:5030`), which is gated on `NATIVE_SDK_GPU_COMPOSITE=1`, and that
pass refuses any command whose kind is not in its known-kind list at
`appkit_host.m:4714-4716`:

```objc
const BOOL knownKind = [kind hasPrefix:@"fill_rect"] || … || [kind isEqualToString:@"draw_image"];
if (!knownKind) return 0;
```

`cell_grid` is not in that list, and a Cockpit terminal frame is nothing but
`cell_grid` commands. Measured consequence, from the automation snapshot with
the app running the same pane both times:

```
NATIVE_SDK_GPU_COMPOSITE unset   gpu_present_path=packet
NATIVE_SDK_GPU_COMPOSITE=1       gpu_present_path=pixels  present_fallback=missing_service
                                 present_fallback_frames=147   shots written: 0
```

Every packet present is refused and the runtime falls back to the CPU **pixels**
path — which is the reference renderer. So turning composite mode on does not
capture the real rasterizer; it *replaces* it. That is a real SDK bug, filed as
`phux-cockpit-2ml.7`.

**Conclusion.** No SDK affordance captures Cockpit's real frames without TCC
today. A negative result, with the code that makes it negative named above.

---

## 3. What was built instead: `scripts/host-raster-check.sh`

If the app's frames cannot be captured, the rasterizer can still be exercised
directly — which is where the whole `aht` defect class lives.

`scripts/measure-host-raster.m` `#include`s the **pinned SDK's own**
`src/platform/macos/appkit_host.m` and calls its real
`rasterCacheBuildEntryForCommand:` with a `cell_grid` command built the way the
packet decoder builds one (`appkit_host.m:3613-3690`), plus a `draw_text`
command for contrast. It registers the app's own JetBrains Mono face through the
host's `native_sdk_appkit_register_font`, and compiles with the same flags
`build/app.zig:1157` uses.

This is not a replica. The context creation, the smoothing calls, the CoreText
draw, the face resolution, the two-pass cell order and the colour space are the
host's own code. A future SDK bump that changes any of them moves these numbers
without this repo being touched. `scripts/host-raster-check.sh` refuses to run
against a checkout at any commit other than the one `build.zig.zon` pins.

It needs no window, no focus, no Screen Recording permission, and no running
app, so it runs in CI.

### It catches the defect the screenshot misses

Same harness, same font, same row, only the SDK's three smoothing calls differ:

```
$ ./scripts/host-raster-check.sh --min-solid 4000                       # pinned SDK
kind=cell_grid width=768 height=36 mean_luma=45.7978 solid=4179 lit=5103
kind=draw_text width=768 height=36 mean_luma=36.5460 solid=4068 lit=5021
ok: cell_grid solid=4179 >= 4000
exit=0

$ PHUX_COCKPIT_SDK_SRC=<copy with smoothing disabled> \
      ./scripts/host-raster-check.sh --min-solid 4000
kind=cell_grid width=768 height=36 mean_luma=37.1124 solid=3081 lit=4272
kind=draw_text width=768 height=36 mean_luma=27.4578 solid=3026 lit=4117
FAIL: cell_grid solid=3081 is below the pinned floor 4000.
exit=1
```

`solid` falls 4179 → 3081, a 26.3% loss of fully-inked pixels, while the
reference screenshot of the same two builds is byte-identical. The assertion was
watched failing and watched passing; a floor that has only ever been seen to
pass is not evidence.

### Pinned baseline

Measured on this machine at the pinned SDK `f3678832f`, JetBrains Mono NL
Nerd Font Mono Regular, 13pt, **backing scale 2**, 48 columns:

| kind | mean_luma | solid (>127) | lit (>32) |
|---|---|---|---|
| `cell_grid` | 45.7978 | 4179 | 5103 |
| `draw_text` | 36.5460 | 4068 | 5021 |

Deriving command: `./scripts/host-raster-check.sh`

Backing scale 2 is the harness default and must stay the default, because
these numbers are only comparable within one scale — see section 4. `--scale`
overrides it for a deliberate cross-scale reading; it is not a knob to turn
while chasing a regression against the floor above.

`--min-solid 4000` is the floor to assert in CI: roughly 4% under the measured
value, and well clear of the 3081 a smoothing regression produces. Re-derive it,
do not adjust it by feel, if the font, the size or the sample row changes.

### What it cannot see

It proves the rasterizer, not the frame. It cannot see a layout mistake, a
colour chosen wrongly upstream, a command that was never emitted, or a defect in
compositing between commands. Reference screenshots remain the right instrument
for those, and they are trustworthy for exactly that.

---

## 4. The backing scale is a measurement axis, and it had never been moved

`phux-cockpit-aht`, round 6. Every number in sections 1-3 was taken on this
machine, which drives one 1920x1080 panel at `backingScaleFactor` 1.00. The
owner reporting "I can't see the text" is on a Retina display, at 2. So the
2x path — a 2x drawable, a raster cache keyed on a 2x scale, CoreText asked
for glyphs on a 2x grid, a 4x-larger upload — had never been executed once,
and "could not reproduce" meant "could not reproduce on the wrong path".

### The panel cannot be made Retina, and that was measured

`CGDisplayCopyAllDisplayModes` on the only display, called **with**
`kCGDisplayShowDuplicateLowResolutionModes` (the option whose entire purpose
is to reveal HiDPI modes the Displays pane hides), returns 31 modes. Every one
of them reports `CGDisplayModeGetPixelWidth == CGDisplayModeGetWidth`. There
is no 2x mode on this hardware to switch into, so `CGDisplaySetDisplayMode`
has nothing to aim at. Exposing one would need
`defaults write /Library/Preferences/com.apple.windowserver
DisplayResolutionEnabled -bool true` as root plus a logout, and even then only
for modes the panel can actually drive.

`native automate resize <w> <h> <scale>` does not help, and this was checked
rather than repeated: with the pattern asserted absent first, `resize 900 600
2` left `gpu_scale=1` (and `gpu_size` unchanged at `1100x640`). The scale
argument does not reach the backing scale, because the backing scale is not an
input — `appkit_host.m:4111` reads it off `self.window.backingScaleFactor`.

### The seam that does work

That read is the ONE place the host learns the device scale. Everything
downstream takes the value that lands in that local: `contentsScale`,
`drawableSize`, the `GPU_SURFACE_RESIZE` event the runtime stores as
`gpu_scale_factor` and publishes as `gpu_scale`, and therefore the `scale`
argument every packet present is drawn with. `docs/sdk-patches/scale-probe.patch`
overrides it from `NATIVE_SDK_FORCE_BACKING_SCALE` and dumps the exact
premultiplied bytes handed to the texture upload;
`scripts/drive-backing-scale.sh` applies it to a scratch worktree of the
pinned SDK, builds, drives the live app, and measures.

What that reproduces: every line of code a Retina window runs, at the same
pixel dimensions, with the same CoreText rasterization. What it does not:
the window server's 2x scanout, since the 2x layer is downsampled on its way
to a 1x panel. The numbers below are read upstream of scanout, so that gap
does not touch them — but a defect living only in scanout is still out of
reach here.

### The finding: the same text inks LESS as the scale rises

Two independent instruments, one direction, on `5bccbd2`.

Live app, the bytes uploaded to the Metal texture, one fixed 380x60 **point**
rectangle of terminal text (`./scripts/drive-backing-scale.sh 1.5 2 3`):

| forced | `gpu_scale` | raster px | mean_luma | solid_frac | lit_frac |
|---|---|---|---|---|---|
| none (control) | 1 | 1100x640 | 52.8903 | 18.70% | 26.11% |
| 1.5 | 1.5 | 1650x960 | 52.6717 | 17.78% | 24.09% |
| 2 | 2 | 2200x1280 | 49.2482 | 16.46% | 20.67% |
| 3 | 3 | 3300x1920 | 46.1627 | 14.89% | 18.00% |

Headless, the host rasterizer alone, the fixed sample row
(`./scripts/host-raster-check.sh --scale N`):

| scale | mean_luma | solid_frac | lit_frac |
|---|---|---|---|
| 1 | 49.4425 | 0.1816 | 0.2289 |
| 2 | 45.7978 | 0.1512 | 0.1846 |
| 3 | 42.9154 | 0.1351 | 0.1631 |

1x → 2x is −6.9% mean luminance and −12.0% solid fraction in the live app,
−7.4% and −16.7% headless. Both monotone, both agreeing on sign and rough
size, from completely different code paths.

Read it correctly. Over a fixed area of the same glyphs, mean luminance is
conserved by an *ideal* area-coverage rasterizer, and edge pixels become a
smaller share of a glyph as resolution rises, so the naive prediction is that
`solid_frac` goes **up**. It goes down. The same text emits measurably less
light per unit area on a 2x window than on a 1x one. That is the signature of
a rasterizer with no stem darkening: whatever fattening the smoothing pass
applies is roughly a fixed sub-pixel amount, so it is worth proportionally
less as the pixels get smaller. It is exactly why Ghostty ships `font-thicken`
and `minimum-contrast`, and it is what this bead's original DESCRIPTION said
before four rounds went looking elsewhere.

### And the headline non-finding

**See-through or black terminal text does not reproduce at 2x.** The dumped
2x frames are crisp, bright, correctly positioned text on the terminal ground,
with `gpu_present_path=packet`, `gpu_status=ready`, `dispatch_errors=0` and
`gpu_nonblank=true`. The 2x defect that would explain "I can't see it" is not
there. What is there is ~7% less light, which makes an already-thin render
thinner, not invisible.

### The apparatus is not blind, and here is the proof

A measurement that has only ever returned "fine" is worth nothing until it has
been seen to return "broken". Forcing scale 8 on the same 1100x640 window asks
for 8800x5120 device pixels, past the `pixelWidth > 8192` refusal at
`appkit_host.m:5599`. The run fails, and fails in the right place:

```
$ ./scripts/drive-backing-scale.sh 8
none   1          1100x640    1100x640    52.8903    4264     18.70%      26.11%
error: automate assert failed after 30000ms
  missing: gpu_present_path=packet
exit=1
```

The snapshot of that instance reads `gpu_scale=8 ... gpu_present_path=pixels`:
every packet present is refused and the runtime falls back to the CPU
reference renderer. So the harness does distinguish a working 2x path from a
broken one — and separately, that cliff sits at a 4096-**point** window at 2x,
which no shipping Mac display can produce. It is a bound worth knowing, not a
bug the owner can hit.

---

## 5. Rules that follow

- **Never** conclude "the text renders correctly" from a reference screenshot.
  It cannot support that claim about anything CoreText does.
- When comparing two images, state the metric and keep the basis identical on
  both sides. `scripts/measure-png-ink.m` states its basis in its header and
  reads raw decoded bytes so no colour management moves the numbers.
- Compare a renderer against ITSELF across two builds. The gap between the
  reference renderer and the host rasterizer is legitimate — different outlines,
  different hinting, different stem darkening — and reading a defect out of it is
  how `aht` was misdiagnosed twice.
- `phux-cockpit-aht`'s fix is still unconfirmed ON GLASS. Nothing here changes
  that: it needs a human to grant Screen Recording once. See section 6.

---

## 6. What a human would have to do once

To close the last gap — confirming the app's actual presented frames, including
compositing and display colour conversion — someone has to grant Screen
Recording to the capturing binary once, in System Settings > Privacy & Security
> Screen Recording. TCC is per-binary and survives rebuilds only if the code
signature identity is stable, so grant it to a stable helper (for example
`/usr/sbin/screencapture` invoked from a fixed terminal app), not to a freshly
built app bundle each time.

Once granted, a `screencapture -l<windowid> -o -x` of the Cockpit window, fed
through `scripts/measure-png-ink.m` over a fixed crop, would be automatable on a
developer machine — but not in CI, and not on a fresh machine without a human
click. That is the honest boundary. Everything above it is automated now.
