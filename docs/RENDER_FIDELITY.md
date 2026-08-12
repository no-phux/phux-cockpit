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
| eyes on glass / screen capture | everything | nothing | **yes** |

There is no instrument in the middle that captures the app's real frames
without TCC. The evidence for that claim is below; it was checked, not assumed.

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
Nerd Font Mono Regular, 13pt, backing scale 2, 48 columns:

| kind | mean_luma | solid (>127) | lit (>32) |
|---|---|---|---|
| `cell_grid` | 45.7978 | 4179 | 5103 |
| `draw_text` | 36.5460 | 4068 | 5021 |

Deriving command: `./scripts/host-raster-check.sh`

`--min-solid 4000` is the floor to assert in CI: roughly 4% under the measured
value, and well clear of the 3081 a smoothing regression produces. Re-derive it,
do not adjust it by feel, if the font, the size or the sample row changes.

### What it cannot see

It proves the rasterizer, not the frame. It cannot see a layout mistake, a
colour chosen wrongly upstream, a command that was never emitted, or a defect in
compositing between commands. Reference screenshots remain the right instrument
for those, and they are trustworthy for exactly that.

---

## 4. Rules that follow

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
  that: it needs a human to grant Screen Recording once. See section 5.

---

## 5. What a human would have to do once

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
