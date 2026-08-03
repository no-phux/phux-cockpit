# Pointer Race

## Decision

Army C keeps Army A's retained, identity-keyed terminal interaction widget and
Ghostty `SelectionGesture`, then brings in Army B's broad libghostty mouse
encoder coverage, frame scale, horizontal wheel support, and adversarial
protocol cases. Capture and lifecycle ownership are replaced rather than taken
unchanged from either branch.

The result routes primary, middle, wheel, and hover edges from native-sdk's
authoritative `canvas_widget_pointer` event. The only raw fallback is button 1:
v0.7.1 reserves its whole stream for native context-menu handling and emits no
routed widget event. A live mouse-reporting TUI gets that raw stream; local and
ended terminals give it exclusively to the native menu. The fallback hit-tests
the retained SDK tree, never app geometry, so every physical edge still has
exactly one terminal path.

## Army A: Overlay

Useful evidence retained from commit `4f5666e`:

- Transparent retained interaction widgets are globally keyed by stable
  `TerminalId`, and their laid-out bounds agree with the independently painted
  terminal frames.
- Primary selection uses libghostty-vt `SelectionGesture` for cell, word, and
  line behavior. Pointer selection remains separate from Cockpit's keyboard
  selection mode, uses the same emulator selection for painting/copy, and is
  cleared by ordinary terminal typing.
- The overlay isolates tab chrome, split headers/divider, gutters, and the
  parked or visible WebKit surface.

Review findings not retained:

- It forwarded the raw event through UiApp, then manually routed and applied
  the same event a second time.
- It held one model-wide pointer drag, did not key ownership by window, and
  dropped captures without consistently releasing a live TUI generation.
- It covered a narrower protocol/wheel surface, did not carry frame scale into
  SGR-Pixels, and advertised the transparent panel as a textbox without an SDK
  text-value contract.

## Army B: Host

Useful evidence retained from commit `506592c`:

- libghostty's encoder supplies X10, UTF-8, SGR, URXVT, and SGR-Pixels across
  modes 9, 1000, 1002, and 1003, including modifiers and motion dedupe.
- Frame scale is required for SGR-Pixels, and wheel reporting needs both axes,
  bounded work, and transition-local accumulators.
- Its adversarial cases covered resized split mapping, Shift selection bypass,
  chrome/divider/Web isolation, reorder, restart, close, and stale generations.

Review findings not retained:

- Host routing recomputed terminal hits from app geometry instead of consuming
  native-sdk's routed widget event.
- One pointer lease was tied to placement/focus checks, so focus or attachment
  movement could revoke identity ownership and unrelated pointers could not be
  represented independently.
- Local drag selection used a hand-built cell range instead of Ghostty's
  single/double/triple selection gesture.

## Army C: Hybrid

- `CockpitHost` consumes `canvas_widget_pointer`, including the SDK target,
  click count, and captured widget ID. Terminal events return before UiApp's
  typed `on_press` dispatch. Button 1 uses the raw event only while a live TUI
  owns mouse reporting; local ownership ignores that echo after the SDK menu
  path. Every other raw pointer echo is ignored for terminal input.
- A bounded capture table is keyed by `window_id + pointer_id` and stores
  `TerminalId + session_generation`. Different pointers coexist; stale edges
  cannot cancel or borrow another capture. Reorder and focus changes do not
  change ownership.
- Web/terminal hiding, detach, close, restart, deactivation, cancel, a second
  down for the same physical pointer, process exit, and generation mismatch all
  retire a capture once. A reporting capture emits a release only while its
  exact active generation and mouse-protocol fingerprint still accept input.
  Motion, wheel, and hover reports require the same generation, visibility, and
  `acceptsInput` gate.
- The current frame's finite positive scale is model state. SGR-Pixels converts
  pane-local canvas points to backing pixels; tests pin scale 1, 1.5, and 2.
- libghostty owns format/mode encoding. Cockpit supplies vertical and horizontal
  wheel buttons, modifier state, active-button state, and bounded coordinates.
  NaN/infinite values are rejected; finite hostile deltas are clamped to a
  64-report total event budget, fairly interleaved across axes, without making
  either accumulator non-finite. Local scrollback keeps a separate remainder.
- Mouse mode/format fingerprints reset motion dedupe and reporting-wheel
  accumulators on every observed transition, including disable and re-enable;
  a transition also retires captures minted under the old protocol.
- Ghostty's gesture owns edge-drag autoscroll. One 15 ms host timer ticks every
  active local capture by exactly one row and stops when no gesture requests it.
- Local and ended panes use a transparent unbound `.terminal` interaction
  widget, supplying the native I-beam, a stable textbox name, and the real
  viewport as `text_value`. A live mouse-reporting pane switches to a transparent
  `.panel`, because SDK v0.7.1 gives `.terminal` an unavoidable default menu.
  The app-owned Ghostty painter remains the sole pixel and selection owner.
- Right/control-click presents native pane-addressed Copy/Paste actions only
  under local ownership. While a live TUI reports mouse input, the native menu
  is intentionally absent and secondary down/up go exclusively to the child.
  Shift local selection remains copyable through Cmd+C in that mode, and copy
  keeps the range highlighted after clipboard confirmation.

## SDK Seam

native-sdk v0.7.1 already publishes the authoritative routed
`CanvasWidgetPointerEvent`, but an unbound terminal cannot bind an app-defined
continuous pointer message. Its capture register is also one
`canvas_widget_pressed_id` per canvas, not per `(window, pointer)`.

The remaining adapter is deliberately narrow:

1. Keep an inert `on_press` on the transparent interaction widget so the SDK
   establishes its normal retained-widget press/capture target. Use `.terminal`
   for local ownership and `.panel` for live TUI mouse reporting.
2. Intercept the SDK's already-routed `canvas_widget_pointer` event in
   `CockpitHost`; do not route the raw event again for buttons the SDK routes.
3. Resolve active motion/up/cancel through Cockpit's identity/generation capture
   table. If v0.7.1's canvas-global captured target belongs to another pointer,
   perform only an ID lookup for the owner's current retained bounds, never a
   coordinate hit test.
4. Route button 1 from its raw echo only while the target's live generation has
   mouse reporting active. Resolve its down against the retained SDK panel and
   its continuation against Cockpit capture; otherwise leave the whole gesture
   to the native menu.
5. Do not forward a consumed terminal widget event into UiApp's `on_press`
   handler. Accessibility activation still uses that handler normally.

This adapter can disappear when the SDK offers custom continuous-pointer
handlers plus per-window/per-pointer retained capture. Until then, removing it
would either duplicate routing or make multi-pointer generation ownership
untruthful.

## Verification

The null-platform suite covers routed single application, Ghostty cell/word/
line selection, selection-copy-type, protocols and modes, modifiers, both wheel
axes and fairness, scaled pixels, transition reset and capture fencing, hostile
numeric input, independent pointers, autoscroll, native context actions,
mode-exclusive secondary ownership, retained Shift selection, I-beam/text-value
accessibility, persistent copy selection, all lifecycle fences, strict surface
isolation, and stale post-close query output. The default run passes 142
runnable tests with four expected screenshot skips;
`COCKPIT_SHOTS=1` passes all 146 tests. The four
inspected PNGs retain the one-terminal, tabs, split, and four-terminal product
proofs without overlay artifacts. `zig build` separately passes and links the
ReleaseFast native macOS executable.

## Residual Limitations

- Native SDK v0.7.1's canvas-global pressed-widget register cannot itself
  represent concurrent pointers; Cockpit's bounded eight-capture adapter is the
  authority after each pointer's routed down.
- Protocol transitions are observed at emulator output-batch boundaries. A
  child that disables and re-enables the identical mode and format inside one
  indivisible output batch leaves the same final fingerprint, so no consumer of
  terminal flags alone can observe that transient transition.
- Deterministic screenshots cover the retained native canvas, not WebKit
  pixels, and do not replace a live AppKit/Metal pointer exercise.
