# Topology Snapshots

`Model.topologySnapshot()` is the durable boundary between terminal identity
and a live local process. The current version is `4`, and
`process_restoration_supported` is explicitly `false`.

## Persisted State

- The ordered **window** list, window 0 first (the scene's own window)
- The ordered tab list, flat across every window: each window owns the
  contiguous run of `tab_count` tabs that follows the windows before it
- Each tab's **pane tree**: leaves naming stable local terminal IDs, branches
  carrying an orientation and a divider fraction
- Each window's selected tab — numbered **within that window's run** — and each
  tree's focused leaf
- Each terminal's working directory, when one was reported

## Windows

Tabs are stored once, in one flat array, in window order. A window records how
many of them are its and which one it had selected; the offset into the array is
derived (`TopologySnapshot.windowTabOffset`). There is deliberately no per-tab
window tag: a tag and a count are two encodings of one fact, and only one of
them can be wrong. `validate()` proves the windows' counts account for the tab
array exactly, so a snapshot can neither strand a tab no window owns nor let a
window read past its own run.

The tab ceiling is per window (`max_tabs`, 16); the whole-session ceiling is
`max_snapshot_tabs` (32, the registry size — a persistable tab holds at least
one local terminal). Windows cap at `max_snapshot_windows` (5: the scene's
window plus the four the toolkit budgets).

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

The snapshot types enforce this rather than relying on discipline: a leaf holds
a `LocalTerminalId`, and the selection is a dedicated `SnapshotSelection` whose
terminal arm is local.

Because a live model may hold remote identities in a pane tree or as the
selection, `Model.topologySnapshot()` **filters** them out and then settles what
filtering disturbed — a branch that loses one child collapses to its surviving
sibling, exactly as `closePane` does at runtime, and focus moves to a retained
leaf. This settling is confined to the projection into snapshot space; it never
mutates the live model, and the emitted snapshot is still passed through
`validate()` before it is returned.

`restoreModel()` validates references and uniqueness before allocating fresh
libghostty-vt sessions. Starting the restored app spawns one new shell per
restored terminal, in that terminal's recorded working directory when one
survived validation. Stable terminal IDs and pane geometry survive; the old
processes do not.

## Working Directories

Directories are a side table keyed by **registry offset**, not by tree node.
`validate()` already proves every leaf names a distinct terminal, so one entry
per terminal (32) replaces one path per node (31 per tab, on a by-value struct)
— a few kilobytes instead of hundreds.

A directory is recorded only if it can actually be restored. `SnapshotCwd.set`
refuses a relative path, an embedded NUL, an embedded newline, or an over-long
value, so "not recorded" degrades to `$HOME` and never to `/` or to a truncated
path that names a different directory. Restoring one goes through
`local.paneArgvIn`, which single-quotes the path and escapes `'` as `'\''` —
the only quoting with no escape sequences of its own — and falls back to `$HOME`
with `;` rather than `&&`, so a directory that has since moved yields a normal
shell instead of a pane that exits the moment it opens.

## Canonical Invariant

Every accepted snapshot restores exactly and captures back byte-for-byte at the
struct level; restore never clamps or normalizes current-version topology.
Validation therefore rejects non-canonical state:

- terminal IDs are unique across ALL tabs, allocatable, and leave the exhausted
  integer edge
- every tree is a tree: no cycles, no node reachable as a child twice, no
  orphans, exactly one root
- a branch names two distinct existing children; a leaf names a terminal
- focus names a **leaf**, never a branch or a free slot
- each window's selection references a tab that window owns
- the windows' tab counts sum to exactly the tab list's length, so no tab is
  orphaned and no window reads past its own run
- windows past `window_count` are blank
- divider fractions are finite and already within `0.05...0.95`
- recorded working directories are absolute and free of NUL and newline
- an empty registry has no tabs and selects nothing

`Model.topologySnapshot()` returns an error if the projected topology is still
not canonical after the remote-filtering settlement described above — it never
emits an invalid snapshot and never rewrites the live model to make one valid.
Migration from an older version may explicitly normalize its less expressive
representation before emitting a validated current snapshot.

## Migration

`migrateTopologySnapshot()` accepts the tagged `PersistedTopologySnapshot`
union.

- **Version 0** stored only terminal count, selected index, split state, and
  divider fraction. Migration assigns the original terminal-ID sequence and
  reconstructs a layout from it.
- **Version 1** stored a flat tab order plus at most two attachments and one
  split fraction — the two-pane model that predated pane trees. A v1 split
  becomes ONE tab holding a horizontal branch over its two attachments, which
  is what that state always meant.
- **Version 2** is byte-identical to version 3 except for working directories,
  so its migration is exactly "no directory was recorded".
- **Version 3** is one window's worth of tabs plus a single file-level
  selection — the schema from before windows existed. It migrates to a v4
  snapshot with `window_count == 1` whose only window owns every tab it
  carried, so **a pre-multi-window snapshot restores as exactly one window**.
  A v3 file with no tabs stays a zero-window snapshot, which is what "there is
  nothing to reopen" has always meant.

Unknown versions are not guessed. Invalid counts, duplicate or exhausted IDs,
dangling references, malformed trees, focus on a non-leaf, and out-of-range
divider values are all rejected in favour of a normal fresh launch.

## On-Disk Form

The snapshot is written to the platform **state** directory (not the config
directory — layout is state) as a flat, line-oriented text file terminated by an
explicit `end`:

```
phux-cockpit-state 4
placement top
window tab 1
tab 0 0
node 0 leaf - 0
tab 2 1
node 0 leaf 2 1
node 1 leaf 2 2
node 2 branch - horizontal 0.5 0 1
window web
tab 0 0
node 0 leaf - 3
end
```

A `window` line OPENS a window's run, and every `tab` line after it belongs to
that window until the next `window` line — so a window's tab count is implied
by the file's own structure rather than written down twice. The window's own
`web`/`tab N` argument is its selection, numbered within its run. A `tab` line
before any `window` line is a tab with no owner and rejects the file.

Version 3 and earlier have no `window` line and carry one file-level
`selection` line instead; a `selection` line in a v4 file is a parse failure,
because it is a claim the schema stopped making.

The format is deliberately non-nesting. This file is read at startup, from a
user-editable path, and may have been half-written by a crash. A recursive
parser over a nested document has stack depth proportional to its input, which
turns "a file of random bytes must never crash" into a claim about how deeply
the bytes happened to nest. A flat grammar is one forward pass with fixed work
per line and no recursion, so it is structurally incapable of overflowing a
stack or looping. Structural claims stay where they already were, in
`validate()`; the parser only fills fields.

Truncation is **detected, not inferred**: a write cut short fails the terminator
check instead of parsing as a smaller but entirely plausible workspace.

Writes are debounced and edge-triggered off a hash of the workspace *shape*.
That hash deliberately excludes working directories — folding them in would
make every `cd` a disk write. A shutdown flush is synchronous, because nothing
drains an effect queue after shutdown.
