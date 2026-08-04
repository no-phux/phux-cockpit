# Topology Snapshots

`Model.topologySnapshot()` is the durable boundary between terminal identity
and a live local process. The current version is `1`, and
`process_restoration_supported` is explicitly `false`.

## Persisted State

- Ordered stable **local** terminal IDs, up to native-sdk's four-PTY limit
- Selected local terminal ID or the permanent Web surface
- Single or split layout
- At most two attached local terminal IDs, focused attachment, and split fraction

## Deliberately Ephemeral State

- PID and PTY transport handles
- PTY effect keys and spawn generations
- Emulator cells, scrollback, selection, and pending input
- Process phase, exit status, and clipboard operations
- **Every Phux (remote) terminal identity**

## Local Only, By Construction

Snapshots carry local topology only. A Phux terminal exists because its
coordinator says so; writing one into a Cockpit snapshot would claim a
durability this app does not have and cannot honor — on the next launch that
terminal may be gone, owned by another client, or renumbered.

The snapshot types enforce this rather than relying on discipline:
`terminal_order` and `attachments` hold `LocalTerminalId`, and the selection is
a dedicated `SnapshotSelection` whose terminal arm is local. A model whose
selection names a remote terminal persists as `.web`.

Because a live model may hold remote identities in tab order, in a placement,
or as the selection, `Model.topologySnapshot()` **filters** them out and then
settles what filtering disturbed: a split with only one surviving attachment
collapses to single, a selection whose terminal is gone falls back to Web, and
focus moves to a retained attachment. This settling is confined to the
projection into snapshot space; it never mutates the live model, and the
emitted snapshot is still passed through `validate()` before it is returned.

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

`Model.topologySnapshot()` returns an error if the projected topology is still
not canonical after the remote-filtering settlement described above — it never
emits an invalid snapshot and never rewrites the live model to make one valid.
Version 0 migration may explicitly normalize its older, less expressive
representation before emitting a validated version 1 snapshot.

## Migration

`migrateTopologySnapshot()` accepts the tagged `PersistedTopologySnapshot`
union. Version 0 stored only terminal count, selected index, split state, and
divider fraction. Migration assigns the original terminal-ID sequence,
normalizes impossible split layouts, reconstructs attachments, and emits a
validated version 1 snapshot.

Unknown versions are not guessed. Invalid counts, duplicate or exhausted IDs,
dangling selection or attachment references, duplicate attachments, impossible
split/focus rules, and out-of-range divider values are rejected.
