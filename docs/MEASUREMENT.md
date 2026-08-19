# Measurement harness

Start with `./scripts/measure.sh`. It discovers runnable measurements from the
`# measures:` line in each script rather than maintaining a second catalog that
can drift.

## Rules

1. A pinned number names the command that derives it. A number without a
   re-runnable derivation is a guess wearing a constant's clothes.
2. Measurements print `MEASURED-BASIS` before results. Existing `MEASURED`
   records remain stable because they are cited verbatim elsewhere.
3. Each stage's percentiles are printed only if that stage independently meets
   `MEASURE_SAMPLE_FLOOR` from `scripts/lib/measure.sh`; counts remain visible
   and refusals name omitted stages. A high draw count does not make a low plan
   or rebuild count meaningful.
4. Driven app measurements launch through `scripts/lib/dev-app.sh`: the bundle
   is identity-staged and re-signed, config and state are isolated, and both app
   and CLI run from a private working directory so they share a private
   automation dropbox. `scripts/lib/app-instance.sh` still binds every read to
   the launched pid and refuses a same-name sibling or an empty tree.
5. Dependency pins continue to be read only by `scripts/lib/zon.sh`. A local
   `.path` override is a named refusal, never permission to consume the next
   dependency's URL.

## Adding A Measurement

Add `# measures: <description>` to a runnable script, source
`scripts/lib/measure.sh`, print `measure_basis` before scalar results, and use
`measure_print_frame_profile` or `measure_require_sample_floor` for statistics.
Every driven assertion needs a negative control or an explicitly checked state
transition.

Stored machine-dependent baselines and a wrapper that normalizes every
instrument's flags are deliberately omitted. Re-run derivations and compare
the same basis instead.
