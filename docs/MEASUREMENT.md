# What makes a measurement first-class here

`phux-cockpit-2ml.6`. Written after `scripts/` reached nine measurement scripts
authored by different people at different hours, three of which carried their
own copy of the same defect.

Start at `./scripts/measure.sh`. This file is the argument for why the things it
lists are shaped the way they are.

---

## The rule

**A magic number without a re-runnable derivation is a guess wearing a
constant's clothes.**

Everything below is that rule made operational. Each property was adopted
because of a specific failure this month, and each failure is named, because a
property adopted on taste is the one that gets dropped when it becomes
inconvenient.

---

## Adopted

### 1. One entry point that lists what can be measured

`./scripts/measure.sh` greps every script in `scripts/` for a `# measures:`
line in its own header and prints the result. It runs one on request and
otherwise gets out of the way: every script keeps its own flags, its own output
and its own exit code, and invoking it directly is still correct.

**The failure it addresses.** `phux-cockpit-wah` set an incremental-search
slice size to 64 and 256 on intuition. Measurement later put one engine tick at
~285 rows, which means 64 completes a 4000-row search inline — the exact stall
the change existed to remove — and 256 would have finished a 500k-row history
in a single frame. The final 4 and 32 are derived. The harness that derives
them already existed when the guess was made. It was one of nine scripts with
no index, and guessing was cheaper than finding it.

A measurement nobody can find is not available, whatever its file permissions
say.

**What it deliberately is not.** It is a directory, not a driver. It does not
normalise flags, capture output, or add a run wrapper, because a driver becomes
a second place for behaviour to live — and behaviour living in nine places at
once is the problem this whole bead is about.

**The listing has no table in it.** Descriptions come from the scripts. A
hand-maintained index is exactly the failure `scripts/check-sdk-pin.sh` exists
to catch: README documented one SDK pin while `build.zig.zon` shipped another,
for days.

### 2. The refusals live in one place

`scripts/lib/measure.sh` holds the parts where two scripts disagreeing would be
a correctness problem: reading the SDK pin, resolving the pinned checkout,
`expect_change`, the serial-automation refusal, the publisher-pid assertion,
the sample floor. Formatting and prose stay in the scripts.

**The failure it addresses.** `phux-cockpit-yo5`. Three scripts each carried

```sh
awk '/\.native_sdk = \.\{/ { found = 1 } found && /\.url = / { print; exit }'
```

which latches on the dependency and then takes the first `.url` *anywhere*
after it. While `native_sdk` is a local `.path` override — which is precisely
what `docs/sdk-patches/` tells you to do while validating an SDK patch — that
block has no `.url`, so the scan walks into the next dependency and returns
ghostty's tarball. `build-automation-cli.sh` then fetches ghostty's sha into
the SDK clone. Nothing fails; it fetches the wrong thing.

A fourth script, `check-sdk-pin.sh`, had the block-scoped version all along.
The bug and its fix coexisted in the same directory. That is what per-script
copies buy you, and it is why this consolidation is a correctness change rather
than a cleanup.

The same duplication had already produced a second, quieter gap:
`drive-shell-ceiling.sh` refuses to run while another bundle holds the
automation dropbox and asserts `publisher_pid` is the pid it launched
(`phux-cockpit-2ml.10`); `automate-smoke.sh` did neither, and would happily
have reported a spotless transcript about a sibling agent's binary. Both now
call the same two library functions.

### 3. Every measurement states its basis and its deriving command

`measure_basis` prints one line before the numbers:

```
MEASURED-BASIS frame_profile host=arm64-26.0 when=2026-08-12T18:40:11Z \
    basis="4 panes, 45-row full-screen repaint loop, font-size 13, 214 host_draw samples" \
    derive="./scripts/automate-smoke.sh --profile"
```

**The failure it addresses.** `phux-cockpit-aht` carried an invalid comparison
for days: an *alpha* measurement set against a *luminance* measurement,
yielding a +61% that justified a full-screen per-cell fill actually worth
-0.3%. Both numbers were real. Neither recorded what it was a number *of*, so
nothing about the pair looked wrong until someone re-ran the harness.

The existing `MEASURED ...` lines are unchanged, deliberately — `MEASURED
shells=1 rss_kib=153952 threads=23 fds=63` is quoted verbatim in
`docs/sdk-patches/README.md`, and a format change would break the citations it
exists to support. The basis is an additional line, not a new schema.

### 4. A refusal below a sample floor, generalised

`measure_require_sample_floor` refuses to print a statistic computed over too
few samples, and names both numbers when it does.

**The failure it addresses.** `phux-cockpit-jw4`. The first profiling run
waited on `assert 'present_n=[0-9]'`, which matches `present_n=0` on the first
poll and returns instantly — an always-true wait. Every host-side stage was
then reported as 0, describing an app that had not drawn anything yet.

It refuses rather than annotating, because a number printed with a caveat gets
copied into an issue without the caveat.

### 5. The harness has tests, and they were watched failing

`scripts/lib/measure_test.sh` is hermetic, offline and sub-second, and runs in
CI beside `check-sdk-pin.sh`. It reproduces `yo5` against a synthetic
`build.zig.zon` containing a `.path` override, so the defect can be re-created
on demand rather than accidentally by the next person who validates an SDK
patch.

**The failure it addresses.** `phux-cockpit-2ml.5`: a confident, merged,
publicly-retracted finding that automation input was silently broken. It was
not. The assertion "proving" it counted `role=textbox name="Terminal`, which
only matches the SELECTED tab's rendered pane, so `cmd+t` creating a second
TAB could not move it however perfectly the key was delivered.

An assertion never seen to distinguish the two states is not evidence — and a
harness is nothing but assertions, so the same standard applies to it.

---

## Rejected, and why

### Stored baselines, compared automatically against a prior run

The proposal: keep the last measured numbers in a checked-in file and diff
against them.

Rejected. A stored baseline is a remembered number with a filename, and
remembered numbers are the `aht` failure exactly: the +61% came from setting a
recorded value against a differently-derived one. Institutionalising the
recorded value does not make the two derivations agree; it makes the
disagreement harder to see, because a file looks more authoritative than a
memory.

There is also a cost nobody pays up front. These numbers are machine-dependent
— the pinned raster table in `docs/RENDER_FIDELITY.md` is one Mac, one font,
one backing scale. A baseline file needs a regeneration ritual, a story for the
second machine, and a policy for who may update it. The first time it fails on
different hardware someone will refresh it, and from then on the floor is
decorative.

What is used instead, and is strictly stronger:

- `scripts/host-raster-compare.sh` compares two SDK commits **that both
  shipped**. Not a stored number, and not a counterfactual: the four-round
  `aht` misdiagnosis happened because a fix was validated against a hand-edited
  SDK state no build was ever in. Against the real prior commit it moved zero
  pixels.
- An explicit floor passed as an argument (`--min-solid 4000`), whose value and
  derivation are written down next to the measurement they came from, with the
  deriving command beside them.

### One machine-readable output format for every measurement

Rejected for now. The current `MEASURED` lines are quoted verbatim in issues,
PR descriptions and `docs/sdk-patches/README.md`; a schema change invalidates
those citations and buys nothing until something consumes the schema. Nothing
does. `MEASURED-BASIS` was added alongside rather than instead, so the existing
citations still resolve.

Revisit when there is a consumer, not before.

### Running the driven measurements in CI

Rejected on cost. `automate-smoke.sh` and `drive-shell-ceiling.sh` need a
packaged bundle and are serial-only — the automation dropbox is per-user, so
two of them on one runner corrupt each other rather than queueing.
`host-raster-check.sh` needs a full SDK build. Only the hermetic library test
is wired into CI, where it costs under a second.

### A driver that wraps each script behind uniform flags

Rejected. See "what it deliberately is not" above: a wrapper is a second place
for behaviour to live, and every script already has flags shaped by what it
measures. `--want 8` and `--min-solid 4000` are not the same kind of argument
and should not be forced to look like one.

---

## Adding a measurement

1. Put it in `scripts/`, with a `# measures: <one line>` in its header. That
   line, and nothing else, is what puts it in `./scripts/measure.sh`.
2. Source `scripts/lib/measure.sh` and use the shared refusals. If you find
   yourself copying one, that is the signal to move it into the library — the
   copy is how `yo5` happened.
3. Print `measure_basis` before the numbers.
4. If it computes a statistic, give it a floor and refuse below it.
5. If it asserts, give the assertion its ABSENT half. An assertion you have
   never seen fail is not evidence.

---

## Still not first-class

Recorded rather than quietly fixed, because a known gap is cheaper than a
surprise:

- `scripts/measure-png-ink.m` and `scripts/measure-glyph-smoothing.m` have no
  wrapper. They are compiled by hand from a comment in their own headers, which
  means their invocation is not checked by anything. `./scripts/measure.sh`
  lists them as such rather than hiding it.
- The sample floor is applied only to the frame profile. The shell-cost
  measurement in `drive-shell-ceiling.sh --measure` reports single samples of
  rss and fd counts, which is appropriate for a level but would not be for a
  rate; nothing enforces that distinction.
- No measurement here is protected against being run on a machine under load.
  The numbers say when they were taken and on what; they do not say what else
  was running.
