# Topology Snapshots

`Model.topologySnapshot()` is the durable boundary between terminal identity
and a live local process. The current version is `1`.

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
old processes do not.

## Migration

`migrateTopologySnapshot()` accepts the tagged `PersistedTopologySnapshot`
union. Version 0 stored only terminal count, selected index, split state, and
divider fraction. Migration assigns the original terminal-ID sequence,
normalizes impossible split layouts, reconstructs attachments, and emits a
validated version 1 snapshot.

Unknown versions are not guessed. Invalid counts, duplicate IDs, dangling
selection or attachment references, duplicate attachments, and non-finite
divider values are rejected.
