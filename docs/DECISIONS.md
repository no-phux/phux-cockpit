# Decisions

Settled questions, with the reasoning that settled them. A decision here is not
permanent — it is *closed pending new information*. Reopen one by adding
information, not by re-litigating what is already written down.

---

## Ligatures: NO

**Decided 2026-08-06.** Do not implement programming ligatures.

The packed cell-grid model **permits** them. An N-cell cluster generalizes the
wide/spacer mechanism already in `CellWidth`: the head cell owns the ligature
glyph, continuations ink nothing, positions stay index-derived, and selection
and cursor keep addressing individual cells. The primitive is not the obstacle.

The obstacle is **who decides what ligates**. That requires GSUB `liga`
shaping. CoreText has it; the SDK's own `font_ttf.Face` (`glyphIndex`,
`advance`, `outline`) does not. If the AppKit host shapes and the CPU reference
renderer does not, the two diverge — and because automation screenshots render
through the reference path, that divergence would be **invisible in every
screenshot while being wrong on real glass**. That is the exact failure mode
this whole line of work exists to avoid. It is the same blind spot that hid the
glyph-smoothing defect (see below) for three diagnoses.

Doing it properly means: a GSUB ligature-substitution reader in `font_ttf.zig`
so the ENGINE decides once; cells carrying glyph IDs rather than only cluster
bytes (a ligature is a specific glyph, not a string); then the wire format,
both renderers, and the glyph-atlas key path following. That is a project, not
an increment.

It is also moot today: the app deliberately bundles **JetBrains Mono NL**, the
explicit no-ligature variant.

If ligatures are ever wanted, do it engine-side with explicit glyph IDs. Never
by letting each renderer shape for itself.

---

## Scrollback search matches case-insensitively, everywhere

**Decided 2026-08-10.** One rule for every provider, stated once in
`provider_contract.search_case_sensitive`.

The pinned `vt.search` matcher is ASCII case-insensitive throughout, so the
local side cannot currently be anything else. The remote phux side can do
either, so it is the one that has to be told — it reads the shared constant
rather than taking a caller's bool, which makes the two sides structurally
incapable of drifting apart.

A case **toggle** remains a legitimate feature. It needs case sensitivity in
the ENGINE first, at which point the constant becomes a default. It cannot be
built by letting the providers diverge.

---

## An emptied window closes — including the main one

**Decided 2026-08-10.** When a window's last tab closes, that window goes away.

macOS apps genuinely vary here, and the main window used to stand on its web
surface instead. Closing is the majority behaviour and, more importantly, the
one that keeps a single rule for every window: the thing you emptied is the
thing that goes away. Standing meant the identical gesture — cmd+W on a
window's last tab — closed a secondary window but left the main one on screen
showing something nobody asked for.

The last-window case is unchanged: it closes **and** quits.

---

## Config diagnostics get a dismissible band, never a modal

**Decided 2026-08-12.** A config that produced diagnostics raises one line of
chrome above the terminal, naming the LINE NUMBERS, dismissed by a press
anywhere in it. The startup log keeps every diagnostic in full sentences.

The log alone was the bug. From a bundled `.app` `std.log` lands in the unified
log, so a mistyped key produced a terminal that quietly behaved differently and
a user with no reason to open Console. But the opposite failure is worse and is
the one a dialog would have caused: most diagnostics are **benign** —
`unsupported_key` fires for `font-family` on a config that is otherwise
perfect — and nothing about a setting that did not apply justifies standing
between someone and a prompt. So the band takes no keyboard, holds no chord,
and leaves Escape to the search field, the palette, and the shell.

It NAMES LINE NUMBERS because that is the only part a user can act on; "your
config has a problem" sends them back to the file to hunt. With exactly one
problem there is room to name the problem too, and it does.

It takes its room out of the **content rect**, exactly as the scrollback search
band does, rather than floating like the palette. Painter, hit-test tree, and
PTY sizing pump all derive from `workspaceChromeIn`, and the palette floats only
because it is transient enough that two SIGWINCHes per summon would be the
larger cost. This band appears once per launch at most, so the honest layout is
worth its one resize — and taking room is also what guarantees no press can fall
through it into a grid painted underneath.

Dismissal is **for the launch, not forever**. Persisting "seen it" would need
state on disk that a re-read config file silently invalidates: the file is
parsed fresh every start, so the only honest memory of a notice is one that dies
with the process.

A second finding came out of building it, recorded here because it explains why
`Diagnostic` owns its bytes: the text used to be a slice borrowed from the
source, and `main.readConfig` reads the file into a buffer local to the read and
returns the `Config` **by value** — so every quoted key in the startup log was
read out of a dead stack frame, before the band existed to make it worse. It is
a bounded copy now. See `config_tests.zig`'s "a diagnostic outlives the bytes it
was parsed from".

---

## Glyph rasterization enables macOS font smoothing

**Decided 2026-08-10**, in the SDK fork rather than here.

Every glyph the AppKit host draws lands in a `CGBitmapContext`, and font
smoothing — macOS's stem darkening — is off by default on the transparent
backing those contexts use, so all terminal text rendered systematically thin.

Measured with `scripts/measure-glyph-smoothing.m`, 13pt, bundled JetBrains Mono
NL: fully-solid stem pixels rise **2341 → 3164 (+35.2%)** at scale 2 and
**635 → 940 (+48.0%)** at scale 1, purely from enabling smoothing.

Filling an opaque ground under the cells was **considered and rejected**: on
the same harness it moves solid stem pixels by −0.3% (2341 → 2334), so it buys
no weight while adding a full-screen fill to every frame — which would have
cost real latency against a frame budget that is already over.

The CPU reference renderer never touches CoreText and blends coverage itself,
so it does not share the defect and **no reference screenshot can catch a
regression here**. Re-measure with the harness rather than eyeballing a
screenshot.
