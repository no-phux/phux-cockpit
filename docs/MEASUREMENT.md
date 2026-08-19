# Measurement harness

Start with `./scripts/measure.sh`. It discovers runnable measurements from the
`# measures:` line in each script rather than maintaining a second catalog that
can drift.

## Rules

1. A pinned number names the command that derives it. A number without a
   re-runnable derivation is a guess wearing a constant's clothes.
2. Measurements print `MEASURED-BASIS` before results. Existing `MEASURED`
   records remain stable because they are cited verbatim elsewhere.
3. The pinned SDK keeps a rolling 128-sample ring per stage. Snapshot `_n` is a
   lifetime total, not percentile population; the harness therefore prints
   `*_population_n=min(*_n,128)` and never permits a floor above 128. Each
   stage's percentiles are printed only if that actual population independently
   meets `MEASURE_SAMPLE_FLOOR`. Churn additionally refuses success until the
   named topology stages (`rebuild`, `layout`, `reconcile`, `emit`, `a11y`,
   `plan`, `patch`, and `encode`) all hold a full rolling population.
4. Driven app measurements launch through `scripts/lib/dev-app.sh`: the bundle
   is identity-staged and re-signed, config and state are isolated, and both app
   and CLI run from a private working directory so they share a private
   automation dropbox. `scripts/lib/app-instance.sh` still binds every read to
   the launched pid and refuses a same-name sibling or an empty tree. A
   retained `--keep` run prints the exact cwd-pinned wrapper command and
   dropbox path needed to inspect that same instance.
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
