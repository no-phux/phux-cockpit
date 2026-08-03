# Topology Snapshots

`Model.topologySnapshot()` is the durable boundary between terminal identity
and a live local process. The current version is `1`, and
`process_restoration_supported` is explicitly `false`.

## Persisted State

- Ordered stable terminal IDs, up to native-sdk's four-PTY limit
- Selected terminal ID or the permanent Web surface
- Single or split layout
- At most two attached terminal IDs, focused attachment, and split fraction

## Deliberately Ephemeral State

- PID and PTY transport handles
- PTY effect keys and spawn generations
- Emulator cells, scrollback, selection, and pending input
- Process phase, exit status, and clipboard operations

`restoreModel()` validates references and uniqueness before allocating fresh
libghostty-vt sessions. Starting the restored app spawns one new shell per
restored terminal. Stable terminal IDs and presentation topology survive; the
old processes do not. Writing snapshots to or loading them from the filesystem
is intentionally outside this slice.

## Canonical Invariant

Every accepted snapshot restores exactly and captures back byte-for-byte at the
struct level; restore never clamps or normalizes version 1 topology. Validation
therefore rejects non-canonical state:

- terminal IDs are unique, allocatable, and leave the exhausted integer edge
- unused order entries retain their canonical default
- selection and attachments reference known terminals
- a selected terminal is the focused attachment
- split layout has two distinct attachments
- focus names an attachment when retained attachments exist
- divider fractions are finite and already within `0.05...0.95`
- an empty registry selects Web, uses single layout, and has no attachments

`Model.topologySnapshot()` returns an error if an internal transient topology is
not canonical rather than silently rewriting it. Version 0 migration may
explicitly normalize its older, less expressive representation before emitting
a validated version 1 snapshot.

## Migration

`migrateTopologySnapshot()` accepts the tagged `PersistedTopologySnapshot`
union. Version 0 stored only terminal count, selected index, split state, and
divider fraction. Migration assigns the original terminal-ID sequence,
normalizes impossible split layouts, reconstructs attachments, and emits a
validated version 1 snapshot.

Unknown versions are not guessed. Invalid counts, duplicate or exhausted IDs,
dangling selection or attachment references, duplicate attachments, impossible
split/focus rules, and out-of-range divider values are rejected.
