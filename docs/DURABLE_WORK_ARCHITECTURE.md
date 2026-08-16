# Durable Work Architecture

Bead `phux-cockpit-p1q.1`. This is the architecture, design, and delivery
record for the durable-work foundation. It defines the contracts the
`phux-cockpit-p1q.1` through `.11` sequence must establish before Cockpit claims
that work, runs, or sessions survive presentation changes, app restarts, or
provider reconnects.

The immediate product remains a fast, polished native terminal. This design
adds identity, evidence, and recovery beneath that product; it does not turn the
terminal into a fleet dashboard.

## 1. Problem and product principles

Today Cockpit can preserve local window, tab, pane-tree, focus, divider, and
working-directory state. It intentionally starts fresh shell processes after a
restart. Phux terminals can retain provider identity and a complete frozen
canvas across a socket reconnect, but Cockpit does not persist their identity.
The Native SDK test recorder can reconstruct a terminal offline, but it is a
deterministic test facility, not a user-facing run history or process owner.

Those are honest, useful boundaries. They do not yet answer the durable-work
questions:

- What outcome was this process pursuing?
- Is this the same run or a later attempt?
- Can the app disappear without killing the work?
- Can a person reconnect without applying stale input to a replacement process?
- What evidence remains after a run completes?
- Which failures require attention, and which are ordinary progress?
- Which component is authoritative after reconnect, replay, or crash recovery?

The governing principles come from `AGENTS.md` and
`docs/PRODUCT_DIRECTION.md`:

1. Work is the product object. A terminal is one provider-backed session onto
   work, not the work itself.
2. Stable product identity is above tabs, panes, windows, PIDs, PTY keys,
   sockets, provider enumeration order, and effect keys.
3. Presentation moves without changing execution identity. Reconnect changes
   an attachment generation, not a `SessionId` or `RunId`.
4. Evidence and lineage are preserved from Objective through Run, Session,
   Artifact, and Signal.
5. Local operation is complete without a cloud control plane. Remote execution
   extends the same model and states its weaker or stronger guarantees.
6. Durability is never inferred from a stale canvas or a saved layout. A seam
   either owns the process and can prove reattachment, or the UI says the
   process is gone.
7. More concurrent work must not create proportionally more chrome. Healthy
   work stays quiet; exceptions aggregate and progressively disclose detail.
8. Every queue, payload, parser, retained buffer, and recovery scan is bounded.
   Loss, truncation, and incomplete evidence are explicit states, never silent
   degradation.

The decision test remains the one in `docs/PRODUCT_DIRECTION.md`: a change must
improve the terminal now or reduce what the operator must remember later.

## 2. Current assets and gaps

### Assets to preserve

- `src/providers/contract.zig` already separates `ProviderId`, provider-owned
  `TerminalId`, provider-qualified `TerminalRef`, and generation-pinned
  `ReplicaOwner`. `Generation.sameReplica` correctly excludes sequence progress
  while fencing epoch, stream, and bootstrap replacement.
- `src/providers/local/provider.zig` mints monotonic terminal IDs and PTY keys,
  never routes by registry offset, bounds the registry at 32 terminals, and
  accounts for input/output loss instead of hiding it.
- `src/providers/phux/host.zig` keeps the FFI client on its owning UI thread,
  publishes only after the ATTACHED/READY barrier, freezes complete canvases on
  failure, rejects stale owners before input, bounds terminal, notice, title,
  search, and history storage, and preserves terminal identity across reordered
  enumeration and reconnect.
- `src/providers/phux/transport.zig` crosses threads with owned complete frames,
  bounds frame count and bytes, preserves the first disconnect reason, and
  treats overflow as a disconnect requiring recovery rather than continuing
  from a corrupt prefix.
- `src/cockpit/model.zig` owns app-wide provider resources separately from
  per-window workspace placement. One terminal cannot occupy two pane-tree
  leaves, and provider normalization cannot invent a resource.
- `src/cockpit/topology.zig`, `src/cockpit/session_state.zig`, and
  `docs/TOPOLOGY_SNAPSHOTS.md` provide a canonical, versioned, bounded,
  non-recursive, truncation-detecting local topology format. Version 4 explicitly
  sets `process_restoration_supported = false` and excludes remote terminals,
  PIDs, PTY keys, generations, emulator cells, and pending input.
- `src/cockpit/terminal_runtime.zig` fences local asynchronous activity by spawn
  generation, provides bounded ordered outbound buffering, and never tears a
  terminal control sequence to pretend partial delivery succeeded.
- `src/tests/record_replay_tests.zig` proves that journaled PTY bytes and effects
  rebuild a fresh `grid.Session` byte-identically with no shell present. The
  state fingerprint covers cells through the accessibility tree rather than
  merely comparing byte counters.
- `README.md` and the current chrome implement a strong attention precedent:
  cumulative loss is evidence, while acknowledged watermarks determine whether
  it still needs attention. Healthy single-terminal use has no standing status
  surface.

### Gaps this sequence closes

- There is no stable Objective, Run, Session, Artifact, or Signal model.
- `TerminalRef` identifies a provider resource, not the product session using
  it, and a PID or Phux host-local number can be reused outside Cockpit's
  in-memory lifetime.
- Phux `Notice` values are held in a 64-item in-memory queue. Overflow drops the
  oldest notice, and Cockpit currently has no durable consumer or typed mapping.
- The local PTY is owned by the UI process. Closing or crashing Cockpit ends the
  execution, so local reattachment cannot be claimed.
- The topology file restores presentation shape only. It cannot bind a leaf to
  a durable session until a durable session owner exists.
- SDK recording has no durable run manifest, retention policy, completed-run
  seal, lineage, gap semantics, or user-facing transcript contract.
- Persistence is one 24 KiB topology file. There is no transactional work store,
  event cursor, content-addressed artifact store, or schema migration path for
  durable history.
- Existing bell, lifecycle, loss, config, and Phux notices do not share one
  signal model, deduplication rule, acknowledgement history, or severity policy.

## 3. Stable product identity

### 3.1 Identity types

The work layer introduces opaque, versioned 128-bit IDs:

```text
ObjectiveId  outcome pursued across one or more attempts
RunId        one immutable execution attempt for an Objective
SessionId    one durable interactive or observable execution session
ArtifactId   one logical output with immutable revisions
SignalId     one immutable attention/progress fact
EventId      one immutable fact in an authoritative event stream
ProviderInstanceId  one installed runner or remote coordinator authority
SessionBindingId   one immutable binding to a provider resource locator
```

IDs are locally mintable UUIDv7 values encoded as 16 bytes in storage and
lower-case canonical text at logs and protocol boundaries. UUIDv7 gives useful
time locality without making wall-clock order authoritative; the event sequence
does that. The format follows RFC 9562 rather than a home-grown timestamp ID:
https://www.rfc-editor.org/rfc/rfc9562.html.

An ID is never an array index and never encodes its parent. Relationships are
explicit foreign keys, so moving a session or reparenting an artifact under a
corrective migration does not rewrite identity.

### 3.2 Object contracts

**Objective** is mutable intent. It owns a title, optional description, state
(`open`, `satisfied`, `abandoned`), creation time, and revision. Objective edits
are events; the current row is a projection.

**Run** is one attempt. It has exactly one `ObjectiveId`, an ordinal allocated
transactionally within that objective, an actor descriptor, requested policy,
and terminal outcome. A retry always creates a new `RunId`; it never resets an
old run to `starting`.

**Session** is the stable product identity for interactive access to a run. A
run may have zero or many sessions; a session belongs to exactly one run. Its
kind is initially `terminal`. `SessionId` survives provider reconnect,
attachment loss, window movement, tab movement, and app restart. It does not
survive an explicit "start another session" operation.

**Artifact** is logical evidence produced by a run. Each revision records a
content digest, media type, byte length, producer session when known, creation
event, and storage locator. The mutable `ArtifactId` gives a report or build a
stable name; every content revision is immutable and digest-addressed.

**Signal** is an immutable durable fact that may need operator attention. It has
source, kind, severity, occurrence data, and links to the narrowest known
Objective, Run, Session, or Artifact. Open, acknowledged, suppressed, escalated,
and resolved are mutable attention-projection states recorded by separate events;
they are not fields that rewrite the Signal fact. A Signal is not an
unstructured notification and acknowledgement does not erase its evidence.

### 3.3 Provider bindings

Provider identity is attached below `SessionId`:

```text
SessionId
  -> SessionBindingId
  -> ProviderInstanceId + typed provider resource locator
  -> attachment generation + provider generation
```

`ProviderId` in `src/providers/contract.zig` remains a provider-kind tag. It is
not an authority namespace and cannot distinguish two coordinators or two local
runner installations. `ProviderInstanceId` is issued once by the authoritative
installation/coordinator and is persisted independently of mutable host text.

`SessionBindingId` is immutable. A session can acquire a replacement binding
when execution migrates, but history retains both. The binding stores a typed
provider locator, never a string that the UI parses. For the current providers:

- Local durable runner: runner installation ID plus runner session ID.
- Phux: coordinator identity plus the full current `RemoteTerminalId`
  (`kind`, `id`, and host), with `TerminalRef` used only in the live adapter.

Tabs and pane leaves eventually reference `SessionId`, then resolve its current
binding to a live `TerminalRef` presentation. Window IDs, PIDs, sockets, PTY
keys, FFI pointers, and effect keys are runtime diagnostics only and are never
foreign keys in the work store.

Existing `TerminalRef` remains the correct identity for the existing terminal
provider API. It is not widened into a universal Work ID.

## 4. Lineage, ordering, and generation fencing

### 4.1 Lineage

The minimum lineage chain is:

```text
ObjectiveId -> RunId -> SessionId
                       -> ArtifactId/revision
                       -> SignalId
```

Every event also carries optional `causation_event_id` and `correlation_id`.
Commands create a correlation ID; the accepted command event causes lifecycle,
artifact, and signal events. This supports "why did this happen?" without
inferring causality from timestamps.

Deletion is tombstoning plus retention processing. Foreign keys never dangle.
Artifact bytes may be purged while metadata and a `content_purged` state remain.

### 4.2 Generations

Stable identity answers "which thing?" Generation answers "which incarnation?"
They must never be conflated.

Each mutable execution owner publishes:

```text
OwnerGeneration {
  authority_epoch: u64,
  attachment_epoch: u64,
  bootstrap_epoch: u64,
  last_seq: u64,
}
```

This mirrors the proven shape of `provider.Generation` in
`src/providers/contract.zig`, but it does not reuse that process-local value as
historical identity. `ReplicaOwner` remains an ephemeral stale-command fence.
`last_seq` advances within an incarnation and is excluded from replica equality.
Authority, attachment, or bootstrap changes
invalidate held input, pointer capture, selection anchors, asynchronous search,
snapshot deltas, and command completions.

Every mutating command includes `SessionId`, `SessionBindingId`, and expected
generation. The owner validates all three immediately before applying it. A
stale command returns `stale_generation`; it is never silently redirected to
the current process. The rejection itself is observable and can open a bounded
diagnostic Signal if it is not an expected reconnect race.

Generation counters use checked increment. Exhaustion is terminal for that
owner identity; wrap is forbidden. Replacing an owner mints a new authority
epoch and requires a full snapshot before deltas can publish.

### 4.3 Publication barriers

A binding is attachable only after one atomic publication contains:

- the stable IDs and current generation,
- authoritative lifecycle phase,
- a complete snapshot at event sequence `N`,
- the next event cursor `N + 1`,
- capabilities and evidence completeness state.

Deltas arriving before the barrier are staged but invisible. This generalizes
the Phux ATTACHED/READY behavior in `src/providers/phux/host.zig`. A failed
bootstrap leaves the prior complete projection frozen and marked stale; it
never mixes old rows with a new generation.

## 5. Narrow provider capability seams

There is no broad provider interface claiming all runners can detach, resume,
replay, or produce artifacts. Providers expose independent capabilities:

```text
DiscoverSessions   enumerate stable bindings and current generations
ObserveEvents      read ordered events from a cursor and request resync
AttachSession      acquire/release a generation-fenced interactive lease
PresentTerminal    publish complete terminal snapshots and ordered deltas
ControlTerminal    key, text, paste, mouse, focus, resize, signal
ControlRun         start, cancel, pause, resume when honestly supported
ReadEvidence       read sealed event/output ranges and artifact manifests
ReadArtifacts      open immutable artifact revisions by digest
```

Capability negotiation returns a version and explicit limits. Absence means
unsupported, not best-effort emulation. `detach_survives_client`,
`detach_survives_runner_restart`, `completed_replay`, and `input_recording` are
separate flags because they make different promises.

The current `Presentation`, input, anchor, search, and viewport methods in
`src/providers/contract.zig` and `src/providers/phux/provider.zig` stay narrow
terminal capabilities. Work providers adapt them; the terminal contract does
not absorb Objective or Artifact methods.

## 6. Typed ordered event envelope

### 6.1 Envelope

All authoritative changes append one typed event:

```text
WorkEvent {
  schema_version: u16,
  event_id: EventId,
  stream_kind: objective | run | session | artifact | signal | provider,
  stream_id: [16]u8,
  stream_seq: u64,
  store_seq: u64,
  producer_id: [16]u8,
  producer_epoch: u64,
  occurred_at_ns: i64,
  observed_at_ns: i64,
  causation_event_id: ?EventId,
  correlation_id: ?[16]u8,
  objective_id: ?ObjectiveId,
  run_id: ?RunId,
  session_id: ?SessionId,
  artifact_id: ?ArtifactId,
  signal_id: ?SignalId,
  payload: union(enum) { ... },
}
```

`stream_seq` is the authoritative contiguous order within one object stream.
`store_seq` is a local commit cursor for efficient projection and subscriptions;
it is not a distributed total-order claim. Timestamps are display and latency
evidence only. `observed_at_ns` is assigned locally; untrusted provider clocks
cannot reorder state.

The initial payload union includes:

```text
objective_created, objective_changed, objective_closed
run_created, run_started, run_cancel_requested, run_finished
session_created, binding_added, binding_retired
attachment_opened, attachment_closed, attachment_rejected
session_snapshot, terminal_output, terminal_resized, terminal_metadata
session_input_accepted, session_input_rejected
artifact_declared, artifact_revision_committed, artifact_purged
provider_notice_observed
signal_opened, signal_updated, signal_acknowledged, signal_resolved
evidence_gap, retention_applied
```

### 6.2 Append and decode rules

- Append is transactional with an expected prior `stream_seq`. A conflict is
  retried from the new head or rejected; two writers cannot both allocate the
  same next sequence.
- `event_id` is unique and makes provider retry idempotent.
- Payload kind and version are stored separately from a bounded length-prefixed
  payload. The decoder validates every count, length, enum, UTF-8 field, and ID
  before allocation.
- Unknown payload versions are retained as opaque evidence but never applied to
  a current projection. The stream becomes `requires_newer_reader`; it is not
  guessed.
- One event is at most 1 MiB. Terminal output is chunked at 64 KiB before the
  envelope. Artifact content never rides in the event log.
- A checksum covers immutable envelope columns plus payload. Database integrity
  protects pages; the event checksum detects application-level corruption or a
  bad migration.
- Projectors are pure and deterministic. Rebuilding from event zero produces
  the same current tables and completed-run manifest.

## 7. Provider notice to Signal mapping

The first durable action on any Phux `Notice` from
`src/providers/phux/host.zig` is append `provider_notice_observed` with notice
kind, detail, status code, authoritative source event identity/cursor when the
provider supplies one, `ProviderInstanceId`, typed provider resource locator,
live `TerminalRef`, provider stream incarnation and sequence, occurrence and
ingestion time, trust state, and bounded raw payload. Mapping happens after that
append, so an unknown code remains evidence. `ReplicaOwner` and `TerminalRef`
alone are insufficient source identity.

The existing 64-entry queue silently evicts its oldest notice. The adapter cannot
claim completeness until `src/providers/phux/host.zig` reports overflow as an
explicit source range/cursor gap or disconnects and resynchronizes. A volatile
notice may be shown as unverified live status, but it is never admitted as
verified evidence after durable data was silently lost.

Mapping policy is typed and table-driven:

| Provider fact | Durable interpretation |
|---|---|
| title/status metadata | session metadata event; no Signal |
| history progress | session evidence status; no Signal |
| history unavailable | warning Signal only when requested evidence is incomplete |
| detached/socket loss while retrying | session state update; informational Signal only after retry budget or user action is blocked |
| resync required | warning Signal linked to the affected Session; resolve after a complete newer-generation snapshot |
| server error | error Signal linked to Session or provider when no Session is known |
| job progress | progress event; no attention by default |
| job completion success | run progress/completion; quiet unless explicitly watched |
| job failure/cancel/approval request | error, warning, or decision Signal according to typed status |
| unknown kind/detail/status | diagnostic Signal plus preserved raw notice |

The mapping never parses human payload text to determine state. Text is detail
for inspection. Codes and provider capability versions determine semantics.

The Signal dedupe key is `(source, kind, narrowest object ID, generation class)`.
Repeated notices update one open Signal and increment occurrence count. A newer
generation may resolve a reconnect/resync Signal but cannot erase its event
history. Acknowledgement records actor and event; it does not mutate provider
state. Resolution is emitted by the authoritative recovery/completion fact.

Local bell, output loss, write refusal, delivery failure, spawn failure, runner
loss, storage pressure, and evidence gaps use the same Signal projection. Their
existing cumulative counters remain evidence. The existing "since you looked"
watermark behavior in `src/providers/local/provider.zig` becomes per-Signal
acknowledgement rather than a second attention system.

## 8. Completed-run replay and transcript evidence

### 8.1 Evidence captured

For every durable terminal Session, the execution owner appends:

- exact PTY output bytes in sequence,
- resize events in sequence,
- lifecycle and exit facts,
- title and working-directory reports as metadata,
- explicit gap events when any byte range is unavailable,
- accepted input metadata by default, but not input payload bytes.

Input bytes are excluded by default because commands, pasted secrets, and
credentials are materially more sensitive than the fact that input occurred.
An explicit per-Objective policy may enable encrypted input evidence later;
initial release slices do not expose that option. Terminal output is also
sensitive and follows local retention and file permissions in section 11.

Raw output is authoritative terminal evidence. A plain-text transcript is a
derived, versioned artifact produced by replaying output and resize events
through `libghostty-vt`. It records the replay engine version and source event
range. Search indexes and accessibility text derive from the transcript and can
always be rebuilt.

### 8.2 Completion seal

A completed Run is replayable only after one transaction commits:

- terminal outcome and exit facts,
- final sequence for every Session stream,
- evidence completeness (`complete` or explicit gap ranges),
- artifact revision manifest,
- digest of each Session event range and the run manifest,
- `run_finished` event.

The seal is immutable. Late provider evidence creates a corrective supplement
linked to the original seal; it never changes what an earlier digest meant.

"Replayable" and "complete" are separate. A run with a known gap can replay
the retained prefix/suffix with a visible gap marker, but cannot claim a
byte-identical transcript. Missing blobs, checksum mismatch, unknown event
versions, or an unsealed live run are explicit replay states.

### 8.3 Replay behavior

Completed replay creates a read-only `grid.Session`, feeds exact output and
resize events in order, and performs no spawn, socket connection, input write,
clipboard operation, notification, or external navigation. This extends the
proof in `src/tests/record_replay_tests.zig`; it does not reuse the SDK session
journal as the persisted user format.

The current SDK recorder remains a deterministic app/effect test mechanism.
The work event log is the product evidence mechanism. An adapter may use common
blob storage in tests, but neither format is declared compatible with the
other.

## 9. Resumable attachments and snapshots

An attachment is a revocable view/control lease, not execution identity:

```text
AttachmentLease {
  attachment_id,
  session_id,
  binding_id,
  expected_generation,
  mode: observe | control,
  snapshot_seq,
  expires_at,
}
```

Opening an attachment is a three-step protocol:

1. Negotiate capability versions and limits.
2. Receive one complete immutable snapshot at sequence `N` with generation.
3. Subscribe to deltas beginning exactly at `N + 1`, then publish READY.

A gap, duplicate with different bytes, generation change, or cursor older than
retention invalidates the bootstrap and requests a new complete snapshot. The
UI may keep the prior snapshot visibly frozen while recovering, as the Phux
provider does today, but cannot accept control input against it.

Snapshots are immutable content-addressed blobs with bounded metadata:

- Session and binding IDs,
- owner generation,
- lifecycle phase,
- terminal rows, columns, cursor, modes, title, cwd, and complete visible grid,
- evidence cursor and available history range,
- checksum and codec version.

For terminal history, a snapshot may reference sealed output chunks rather than
copying all scrollback. A snapshot is not process memory and cannot resurrect a
process. Resumption succeeds because a runner or coordinator still owns the
process and accepts the lease.

The v4 topology snapshot remains unchanged during the foundation slices. Only
after durable local attachment is proven may a later workspace schema store
`SessionId` leaves. Migration must keep v4's current behavior for old local
leaves: start fresh shells, never attach them to arbitrary surviving sessions.

## 10. Durable local runner boundary

### 10.1 Process boundary

Local durability requires an owner outside the Cockpit UI process. The local
runner is a small companion executable with one responsibility: own local child
processes, PTYs, ordered session evidence, and attachment snapshots.

The UI must not daemonize a child and then infer ownership from a PID file. The
runner holds an exclusive installation lock, publishes a versioned Unix-domain
socket, and answers an authenticated handshake. The UI can start it when absent,
but after READY the runner's lifetime is independent. Initial durability means
survives UI close/crash and UI relaunch on the same login session. Survival of
logout, reboot, runner upgrade, or machine migration is not claimed until a
later supervised-runner design proves it.

The runner owns:

- process spawn, PTY master, process group, resize, signal, and exit wait,
- local `SessionId` binding and owner generation,
- exact output sequencing and durable append before publication,
- terminal snapshot production or checkpoint-plus-tail production,
- bounded attachment leases and control ownership,
- the single-writer local work store service described in section 11.

Cockpit owns:

- native windows, input routing, focus, accessibility, and presentation,
- user intent and command issuance,
- ephemeral tab/pane/window placement,
- read-only projections received from the runner/store.

`libghostty-vt` remains the terminal engine. The runner may maintain the
authoritative emulator or produce output/checkpoints from which Cockpit builds
one, but there must be one stated owner per generation. Two independently
mutable emulators are forbidden.

### 10.2 Local protocol

The local protocol is framed, versioned, bounded, and generation-fenced. It uses
the same complete-frame ownership principles as
`src/providers/phux/transport.zig`:

- socket path and lock file are mode `0600` in the app state directory,
- peer effective UID must match on both ends,
- every request has request ID, payload length, deadline class, and expected
  generation when mutating,
- replies echo request ID and return typed errors,
- subscriptions carry cursor and credit,
- frames are capped at 1 MiB; artifact bytes use a separate bounded file/stream
  path,
- malformed or over-limit frames close the connection and preserve the first
  failure reason.

Control is single-writer per Session in the first release. A new control lease
revokes the old lease and increments attachment epoch before accepting input.
Observe leases can coexist. This prevents two restored windows from both typing
into one process while leaving read-only inspection cheap.

### 10.3 Honest failure behavior

- UI crash: runner retains process and evidence; new UI bootstraps from a fresh
  generation-fenced snapshot and cursor.
- Runner crash: the UI freezes the last complete snapshot, marks the Session
  `owner_lost`, and opens a Signal. A PID discovered afterward is not adopted.
- Store unavailable or disk full: runner stops admitting new commands, retains
  a bounded output buffer, then stops reading the PTY so kernel backpressure
  reaches the child. It never publishes bytes it could not durably order. The
  product reports `storage_blocked`; a lossy continue mode is not in the first
  release.
- UI disconnect during input: only requests acknowledged as accepted are
  treated as delivered. Request IDs deduplicate retries.
- Upgrade incompatibility: old runner keeps work alive; UI reports incompatible
  owner and offers no fake attachment. Replacement requires an explicit drain
  protocol in a later slice.

## 11. State ownership and persistence

### 11.1 Authority

There is one authority for each fact:

| Fact | Authority |
|---|---|
| Objective/Run/Session/Artifact/Signal records for local work | local runner/store service |
| local process, PTY, output order, exit | local runner |
| Phux execution and provider generation | Phux coordinator/provider |
| cached remote events and local acknowledgement | local store |
| tab, pane, window, focus placement | Cockpit model/topology state |
| terminal rendering projection | active provider generation |
| completed transcript/search index | rebuildable local projection |

Cockpit never writes current rows directly. It sends typed commands; the
authority appends events and updates projections in one transaction. Remote
provider facts retain their provider event IDs/cursors so reconnect ingestion is
idempotent.

### 11.2 Storage shape

The local work store is an embedded SQLite database in the platform state
directory, owned by the runner/store process. SQLite supplies transactional
schema migration, foreign keys, crash recovery, and a single-writer/many-reader
model without introducing a server. WAL behavior and its same-host constraints
are documented at https://sqlite.org/wal.html; atomic commit assumptions are at
https://sqlite.org/atomiccommit.html.

Initial tables are:

```text
store_meta, producers, events
objectives, runs, sessions, session_bindings
artifacts, artifact_revisions
signals, signal_occurrences, signal_acknowledgements
attachment_leases
projection_cursors, retention_marks
```

Events are append-only. Current-object tables are disposable projections except
for uniqueness and command concurrency checks performed in the same append
transaction. Foreign keys are enabled and checked at startup and after every
migration.

Large output chunks, snapshots, and artifact content live in a content-addressed
blob directory beside the database. The digest is BLAKE3, the file name is the
lower-case digest, and the database stores length, media type, digest, and
reference count. A blob is written to a same-filesystem temporary file, synced,
renamed atomically, then referenced by a committed database transaction.
Unreferenced temporaries are collected after a grace period; referenced missing
blobs produce evidence-gap Signals and are never silently ignored.

Topology remains in `workspace.state` under its existing contract. Work state
uses a separate `work.sqlite3` and `blobs/`; configuration remains separate
again. Debug builds use the same isolation rule as
`src/cockpit/session_state.zig` and never open the installed app's work store.

### 11.3 Durability levels

Commands that create identity, accept terminal input, record output, finish a
run, or commit an artifact acknowledge only after the event transaction is
durable according to the store's configured sync policy. UI-only observation
cursors may be coalesced. A run completion seal always forces a durable
checkpoint boundary before reporting completion.

The product exposes `durable`, `buffered`, `blocked`, and `incomplete` evidence
states. It does not use one green "connected" state to summarize all four.

## 12. Security and local-first trust

- The local runner listens only on its Unix socket. No TCP listener, discovery
  broadcast, browser bridge, or cloud account is required.
- State directory, database, blobs, socket, and lock are user-only. Startup
  rejects a socket or store owned by another UID or reachable through an unsafe
  symlink. Paths are opened relative to the trusted state directory where the
  platform allows it.
- Local peer credentials and a per-installation random secret bind the UI to the
  runner. The secret is never placed in argv, logs, environment inherited by
  child processes, terminal output, or artifacts.
- Provider payloads, titles, cwd values, artifact names, and transcript text are
  untrusted data. They never become shell commands, file paths, format strings,
  or UI markup without typed validation. The existing quoting boundary in
  `src/providers/local/provider.zig` remains the model for cwd handling.
- Artifact materialization never follows provider-supplied absolute paths or
  `..`; it copies bytes into content-addressed storage. Opening or executing an
  artifact is a separate explicit user action.
- Logs contain stable IDs, sequence numbers, sizes, codes, and digests, not PTY
  bytes, input, tokens, environment, or artifact content.
- Output and artifacts are private user data. Retention and delete operate
  locally and visibly. Encryption at rest beyond macOS filesystem protection is
  deferred; the UI must not claim it.
- Non-loopback Phux TCP without authenticated encryption remains an unverified
  live-terminal channel and cannot supply trusted Signals, artifacts, approvals,
  or evidence. `phux-cockpit-p1q.11` establishes coordinator authority identity,
  certificate/peer verification, scoped authorization, Keychain-backed client
  credentials, rotation, and visible trust state before remote evidence ships.
  Unix sockets require owner/mode/path checks and peer credentials; a pathname
  alone is not identity. Attach/create permissions are distinct scopes.

## 13. Progressive-disclosure UX

The first surface remains the terminal described by `README.md`, not a work
dashboard.

At rest:

- one healthy attached session shows the terminal with no added standing band,
- tabs and panes remain spatial placement, not identity labels,
- ordinary progress and successful completion do not demand attention,
- reconnect keeps the last complete canvas frozen with one precise state label,
  not a stream of toasts.

Attention:

- existing tab attention becomes a projection of open, unacknowledged Signals,
- multiple occurrences collapse into one marker with the highest severity,
- window/app summaries count Objectives or Signals requiring decisions, not all
  running processes,
- background notification is reserved for new decision/error Signals and the
  existing deliberate terminal bell policy.

Disclosure path:

```text
terminal/tab marker
  -> compact signal popover or command-palette result
  -> native inspector with identity, lineage, generation, policy, and evidence
  -> read-only completed terminal replay, transcript, or artifact
```

The inspector uses the chrome register in `docs/DESIGN_SYSTEM.md`: existing
Geist tokens, 40-point bands with 32-point controls, 4-point shoulders, bounded
text measure, minimum pointer targets, accessible state not encoded by elevation
alone, and no terminal-grid animation. It is not introduced until its data is
real. There are no fake "detached", "restored", or "live" labels.

Keyboard and accessibility are first-class. Every Signal marker has kind,
severity, object name, occurrence count, and acknowledgement state in semantics.
Completed replay identifies itself as read-only and announces evidence gaps.
The command palette searches stable work identity and lineage without requiring
a standing navigator.

## 14. Invariants

The implementation and tests must preserve these invariants:

1. Every Objective, Run, Session, Artifact, Signal, Event, Binding, and
   Attachment ID is globally unique within supported stores and never reused.
2. A Run belongs to exactly one Objective. A Session belongs to exactly one
   Run. A retry creates a new Run.
3. A provider resource is never treated as a stable product identity without a
   persisted Session binding.
4. Tabs, panes, windows, process IDs, sockets, PTY/effect keys, and provider
   enumeration positions are never durable work identity.
5. Stream sequences are contiguous. Duplicate event IDs are idempotent;
   conflicting bytes for one event ID are corruption.
6. A projector applies events only in stream order and never applies an unknown
   payload version.
7. A mutating command is applied only to its exact Session, Binding, and owner
   generation. `last_seq` progress alone does not revoke ownership.
8. A new owner generation publishes no delta until a complete snapshot/READY
   barrier.
9. One local Session has at most one control lease and may have bounded observe
   leases.
10. Published output has a durable event sequence. Backpressure precedes silent
    output loss.
11. Completion is immutable and has one sealed evidence manifest. A gap is part
    of the manifest, not omitted from it.
12. Artifact revisions are immutable and digest-verified before use.
13. Signal acknowledgement never deletes evidence; resolution requires an
    authoritative resolving fact.
14. Replaying completed work performs no external side effects.
15. Topology restore continues to create fresh local shells until a later schema
    explicitly references proven durable Session IDs.
16. Every accepted persisted snapshot or event stream round-trips canonically,
    or migration emits a validated current representation. Unknown future
    versions are rejected, not normalized optimistically.
17. Every capacity refusal is visible and machine-readable. No bounded queue
    drops authoritative data without an evidence-gap event or disconnect/resync.

## 15. Capacity, bounds, and backpressure

Initial hard ceilings are conservative and explicit:

| Resource | Initial bound | Crossing behavior |
|---|---:|---|
| active local runner Sessions | 32 | refuse start; open capacity Signal |
| active Phux terminal presentations | existing 16 | provider resync/refusal |
| attachments per Session | 1 control + 8 observe | refuse lease |
| event envelope | 1 MiB | reject malformed/oversize producer |
| terminal output payload | 64 KiB per event | chunk before append |
| local protocol frame | 1 MiB | disconnect offending client |
| in-memory not-yet-durable output | 8 MiB per Session, 64 MiB runner-wide | stop PTY reads; storage-blocked Signal |
| subscription credit | 256 events or 8 MiB | producer pauses that subscriber |
| snapshot visible grid | SDK terminal row/column/cell ceilings | reject snapshot and request provider resync |
| signal raw detail | 64 KiB | retain typed fields; explicit truncated-detail flag |
| artifact single revision | policy value, default 2 GiB | refuse commit before materialization |
| local store total | policy value, default 20 GiB | retention, then block new evidence |

Bounds are named constants derived where a lower layer already owns the limit.
The implementation must not restate `native_sdk` terminal or PTY ceilings as
unrelated literals.

Control and lifecycle frames have reserved queue capacity so bulk output cannot
hide cancellation, exit, or storage failure. Retention runs by sealed Run, never
by deleting arbitrary middle output chunks. Pinned runs and open Objectives are
not automatically purged. If retention cannot create enough space, new durable
work is refused rather than started without evidence.

Remote event ingestion uses cursor, bounded credit, and complete resync. The
existing Phux frame limits in `src/providers/phux/transport.zig` remain in force
below work-event bounds.

## 16. Migration and compatibility

- `workspace.state` v4 and its v2-v4 migration remain untouched through the
  foundation. Work persistence is a new store, not v5 hidden inside the topology
  parser.
- Existing terminals open at upgrade remain legacy UI-owned local Sessions.
  They may be displayed normally but are marked `ephemeral`; they are not
  adopted into the runner. New durable sessions start through the runner.
- A future topology version may add tagged leaves (`fresh_local` or
  `durable_session SessionId`). Migration of an old leaf always chooses
  `fresh_local`. It never guesses a Session from title, cwd, PID, or ordinal.
- SQLite migrations are ordered, transactional, and forward-only within a major
  store version. Before a destructive migration, the service checkpoints WAL,
  verifies integrity, and creates a same-volume backup. Failure leaves the old
  store usable by the old binary.
- Event payload versions are independent from database schema versions. Old
  events remain immutable; projectors carry explicit decoders/migrations.
- Debug and release stores are isolated, matching the topology isolation proven
  in `src/tests/topology_persistence_tests.zig`.
- Phux adapters negotiate capabilities. A provider without durable event or
  resume support remains a live terminal provider; Cockpit does not synthesize
  completed evidence or detach support.
- Export is a separate, versioned, read-only operation. The database and blob
  directory are implementation state, not a public interchange API.

## 17. Observability and failure injection

### 17.1 Operational evidence

Structured local logs and diagnostics expose:

- Objective, Run, Session, Binding, Signal, producer, and correlation IDs,
- generation and stream/store sequence,
- append, fsync/checkpoint, projection, snapshot, and attach latency,
- queue count/bytes/high-water marks and credit stalls,
- reconnect attempts, resync cause, stale-command rejections,
- output/event/blob bytes, retention decisions, and evidence gaps,
- runner PID only as a diagnostic field, never identity.

The inspector can show a bounded diagnostic timeline sourced from events. It
does not expose raw logs as product chrome. Metrics are counters/histograms with
bounded labels; IDs belong in traces/logs, not metric dimensions.

### 17.2 Deterministic failure seams

Tests require injected clocks, ID generators, storage, blob IO, transport, and
runner spawn/wait. Test-only failpoints cover:

- before and after event transaction commit,
- after blob sync but before rename, and after rename before DB reference,
- WAL checkpoint and disk-full/permission failures,
- output queue at every byte/count boundary,
- UI disconnect before request, after send, after durable apply, and before ack,
- runner death before spawn ack, mid-output, during snapshot, and after exit
  before completion seal,
- duplicate, skipped, reordered, and conflicting provider events,
- generation change during pointer/input/search/snapshot work,
- malformed, oversized, truncated, future-version, and random persisted input,
- Phux disconnect before READY and between snapshot and first delta.

Crash tests use real subprocesses and `SIGKILL` at named barriers. Recovery
asserts exact process ownership, event cursor, blob references, and visible
state; a unit mock alone cannot prove process survival.

## 18. Test strategy and proof standard

### Unit and property tests

- ID codec, ordering locality, collision rejection, and checked generation
  exhaustion.
- Event codec round trips, bounded decoding, checksum failure, unknown version,
  duplicate idempotence, conflicting duplicate rejection, and random bytes.
- Pure projector determinism from shuffled cross-stream delivery while
  preserving per-stream order; rejection of intra-stream gaps.
- Signal mapping and dedupe for every known Phux code, unknown codes, repeated
  occurrences, acknowledgement, resolution, and generation change.
- Snapshot canonicality, bounds, generation equality, complete-before-delta,
  and checkpoint-plus-tail equivalence.
- Retention never removes unsealed, open, pinned, or middle evidence.

### Integration tests

- Start local work, kill Cockpit, prove the child remains runner-owned, relaunch,
  attach from a complete snapshot, and continue input exactly once.
- Kill the runner and prove Cockpit does not adopt the surviving PID or claim a
  resume.
- Fill queues and disk budgets and prove bounded memory, PTY backpressure,
  visible Signals, and no unreported gap.
- Record and seal a completed Run, remove every executable/provider, replay
  offline through a fresh `grid.Session`, and compare exact terminal state and
  manifest digests.
- Corrupt or remove one blob and prove replay says incomplete rather than
  silently skipping it.
- Reconnect/reorder Phux resources and prove Session IDs and lineage remain
  stable while stale generations cannot mutate the new owner.
- Crash at each storage barrier and recover to either the old complete
  transaction or the new complete transaction, never a plausible prefix.
- Upgrade fixtures through every store/event version and prove IDs and sealed
  digests do not change.

### UI and accessibility tests

- Healthy one-session layout remains chrome-free.
- Signal aggregation reveals only exception/decision state and has complete
  keyboard and accessibility semantics.
- Frozen, reconnecting, replay, incomplete evidence, and owner-lost states are
  textually and semantically distinct.
- Completed replay is read-only and cannot route terminal input or side effects.
- Layout audit covers every new state at every declared window size and
  pseudo-locale expansion under `src/tests/chrome_register_tests.zig`.
- Screenshots may prove retained geometry only. They cannot prove CoreText
  rendering; `docs/RENDER_FIDELITY.md` remains controlling.

### Red-proof expectations

Every regression test must be demonstrated red against the code immediately
before its fix, or against a deliberate one-line mutation that removes the
guard. A test that has only ever passed is not evidence. Storage crash tests
must show which barrier makes the uncorrected implementation lose, duplicate,
or misorder data. Replay tests must compare real cells/transcript bytes, not
only counts. Capacity tests must cross `N + 1`, not merely fill `N`.

### Gates

The repository gate is judged by exit code and its final verdict block:

```sh
zig build test > /tmp/t.log 2>&1; echo "exit=$?"
```

No verdict block is not green. Any change under `src/providers/phux/`, Phux
notice mapping, or Phux event ingestion requires the full Phux-inclusive gate:

```sh
zig build test \
  -Dphux-enabled=true \
  -Dphux-client-ffi-include-dir="$PWD/../phux/crates/phux-client-ffi/include" \
  -Dphux-client-ffi-lib-dir="$PWD/../phux/target/ffi-release"
```

`PASS, INCOMPLETE` does not verify a Phux change. Real-app runner lifecycle
proof uses `./scripts/dev-run.sh` and its isolated `.dev-run/` state, never the
installed app.

## 19. Dependency-ordered delivery: `p1q.1` through `.11`

The sequence is intentionally seam-first. A later phase may begin only when the
listed predecessor invariants and red proofs are green.

### `phux-cockpit-p1q.1` - architecture and contracts

This record fixes vocabulary, authority, boundaries, invariants, bounds,
failure semantics, and release ordering. It adds no product claim by itself.

Exit evidence: architecture review against current provider, topology, replay,
security, and product contracts; unresolved implementation choices are narrowed
to codecs or dependencies that do not change authority.

### `phux-cockpit-p1q.2` - stable work identity and lineage

Implement opaque IDs, `ProviderInstanceId`, typed provider resource locators,
Objective/Run/Session/Artifact/Signal records, immutable lineage, provider
bindings, owner generations, and capability descriptors. Keep terminal layout
on `TerminalRef`; add explicit adapters rather than a flag day.

Depends on `.1`. Exit evidence: uniqueness across restart, provider instances,
host rename, source-ID reuse, import/export, and concurrent issuance; retry
creates a new Run; movement does not change Session; legacy topology offsets
mint new identity rather than inheriting lineage; stale binding/generation
commands fail.

### `phux-cockpit-p1q.10` - event envelope and crash-safe evidence store

Implement the single-writer store, event envelope/codec, append concurrency,
projections, cursors, content-addressed blobs, explicit gaps, schema migration,
retention, integrity, redaction, and bounded subscriptions. This remains separate
from the Native SDK record/replay test harness.

Depends on `.2`. Exit evidence: crash-atomic append, deterministic rebuild,
duplicate/reorder/gap/source-reset handling, unknown event preservation,
disk-full and permission behavior, concurrent-launch refusal, downgrade safety,
and old-or-new complete recovery at every named write barrier.

### `phux-cockpit-p1q.6` - durable local runner

Move new local process/PTY ownership and authoritative event append behind the
companion runner protocol. Prove UI crash/relaunch reattachment, single control
lease, output backpressure, owner-loss honesty, and clean shutdown. Existing
UI-owned terminals remain explicitly ephemeral during migration.

Depends on `.2` and `.10`. Exit evidence requires real subprocess kill/restart,
GUI crash, orphan and PID-reuse refusal, machine-login boundary documentation,
and crash-safe store recovery; mocks are insufficient.

### `phux-cockpit-p1q.11` - authenticated provider authority

Establish authenticated Phux transport and stable coordinator authority before
remote data can be trusted evidence. Cover TCP peer verification, Unix peer
trust, Keychain credential storage, authorization scopes, rotation,
attach/create policy, and visible trust state.

Depends on `.2`. Exit evidence: spoofed coordinator, TLS/peer failure,
credential rotation, malicious local socket, unauthorized attach/create, and
trust-projection tests under the full Phux gate. Unverified provider data cannot
appear as verified evidence.

### `phux-cockpit-p1q.3` - provider notices into typed Signals

Adapt Phux raw notices into the event contract only after durable admission and
authority verification. Preserve source identity, cursor, incarnation, raw
payload, trust, and normalization version. Replace silent queue eviction with
explicit gap evidence or disconnect/resync. Keep acknowledgement, suppression,
escalation, and resolution as separate projection events.

Depends on `.2`, `.10`, `.6`, and `.11`. Exit evidence: known/unknown mapping,
duplicate delivery, reorder, source reset, queue overflow, reconnect, stale
generation, trust downgrade, and no silent loss under the full Phux gate.

### `phux-cockpit-p1q.4` - completed-run terminal evidence

Persist ordered output/resize/lifecycle evidence, blob references, run seals,
derived transcripts, gaps, retention marks, and read-only offline replay. Reuse
`libghostty-vt`, not SDK journal persistence. Ordinary exit may close the pane
while preserving evidence attached to stable lineage.

Depends on `.2`, `.10`, and `.6`. Exit evidence: byte-identical offline replay
with no process, manifest digest verification, corrupt/missing blob failure,
retention/redaction behavior, and side-effect suppression.

### `phux-cockpit-p1q.5` - provider-neutral session inspector

Build provider-independent read projections for lineage, lifecycle,
capabilities, evidence cursor/completeness, Signals, history/search, reconnect,
and artifacts. Providers produce observations and accept commands; the
inspector does not consume local pane types or terminal grid internals.

Depends on `.3` and `.4`. Exit evidence: live ingestion and full historical
replay produce identical projections without side effects; absent capabilities
are honest; healthy work adds no standing chrome; keyboard and accessibility
paths are complete.

### `phux-cockpit-p1q.7` - calm operator interaction polish

Apply staged Escape, spatially stable active-resource navigation, semantic
accent consistency, contrast-safe variants, non-modal action feedback,
searchable live-preview settings, and sanitized diagnostics only where the
inspector and Signal model provide real behavior.

Depends on `.5`. Exit evidence: design-register and reduced-motion audits,
focus/input isolation, accessibility, and distinguishing live-app proofs.

### `phux-cockpit-p1q.8` - capability documentation correction

Correct stale README claims about multi-window/fullscreen restoration and
provider search while preserving the honest no-process-restoration and
non-durable remote-placement boundaries. This documentation-only bead may land
independently and is already complete in this branch.

### `phux-cockpit-p1q.9` - release proof

Ship the smallest supported vertical slice: local Objective -> Run -> durable
terminal Session, UI close/relaunch reattach, Signal on exception, sealed
completed replay/transcript, and artifact drill-down. Phux may join this slice
only where coordinator capabilities pass the same contracts.

Depends on `.1` through `.6`, `.8`, `.10`, and `.11`; a release that also
includes `.7` must close and verify it. Exit evidence: full default and Phux
gates with complete verdicts, red-proof ledger for every durability claim, real macOS
lifecycle exercise, recovery from forced UI/runner/store failures, retention
exercise, accessibility audit, and explicit release notes naming unsupported
durability levels.

## 20. Release slices

The internal phases above produce four user-visible slices:

1. **Identity and store slice** (`.2`, `.10`): stable local work identity and a
   crash-safe evidence contract with no detach claim and no remote trust claim.
2. **Durable local slice** (`.6`, `.4`): new runner-owned terminal Sessions
   survive Cockpit UI close/crash and reattach in the same login session;
   completed work leaves sealed read-only evidence. Legacy UI-owned terminals
   remain visibly ephemeral.
3. **Trusted provider slice** (`.11`, `.3`): authenticated Phux authority and
   loss-aware typed Signals join the same event model.
4. **Operator slice** (`.5`, `.7`, `.9`): provider-neutral inspection, quotas,
   migration, diagnostics, progressive-disclosure UX, and one releasable
   Objective-to-evidence path.

Each slice can ship independently only if its labels state exactly what survives
and its failure state is inspectable. No release waits for fleet UI, distributed
scheduling, or collaboration.

## 21. Explicit non-goals

This foundation does not deliver:

- multiplayer presence, shared cursors, simultaneous terminal control, or
  conflict-free collaborative editing,
- web or mobile Cockpit clients,
- Windows support or a cross-platform local runner,
- fleet dashboards, generic cards, metric walls, chat-first navigation, or a
  separate enterprise mode,
- distributed scheduling, placement, formations, budgets, policy engines, or
  thousands-of-agent orchestration,
- durable in-memory process checkpoints, VM/container snapshots, process
  adoption by PID, reboot survival, machine migration, or runner hot upgrade,
- arbitrary provider plug-ins or one broad lowest-common-denominator provider
  interface,
- cloud synchronization, hosted artifact storage, account systems, or remote
  access through Cockpit's local runner,
- input recording by default, secret detection, or a claim of application-level
  encryption at rest,
- replacing `libghostty-vt`, Phux coordinator authority, the Native SDK, or the
  existing topology format before their explicit seams require it.

Those are deferred, not smuggled into the first schema as inactive UI.

## 22. External evidence and inference

Superlogical publicly describes a "durable session around the work itself"
that spans interactive and automatic work, preserves history, exposes structured
data/actions, and begins with a long-lived terminal multiplexer:
https://www.superlogical.com/. Mitchell Hashimoto separately states that it will
begin as a terminal multiplexer built on public `libghostty` components:
https://mitchellh.com/writing/superlogical.

Useful evidence: the same terminal-first wedge, durable-session boundary,
native terminal quality, reconnect, and history concerns are independently
recognized as foundational rather than disposable terminal polish.

Inference, not evidence: those public statements do not publish Superlogical's
identity schema, event ordering, runner authority, persistence format, security
model, or orchestration architecture. This record therefore borrows no hidden
technical claim from them. Cockpit's Objective/Run/Session/Artifact/Signal model
comes from `docs/PRODUCT_DIRECTION.md`; its concrete fences, barriers, bounds,
and replay requirements come from this repository's existing implementations
and failures.

## 23. Decision summary

Cockpit will add durable work above, not inside, terminal placement. Stable Work
IDs and immutable lineage name the product objects. Narrow provider bindings and
generation-fenced attachment leases connect Sessions to live resources. A typed
per-stream ordered event log is authoritative; current rows, Signals,
transcripts, search indexes, and UI are projections. Completed evidence is
sealed and replayed offline without side effects. Local processes become truly
reattachable only when an independent bounded runner owns them. SQLite and
content-addressed blobs provide local transactional persistence. The UX stays a
calm terminal and reveals lineage, exceptions, replay, and artifacts only when
the operator asks or must decide.

Until each seam is implemented and red-proven, current honest behavior remains:
topology can restore, local processes cannot; Phux canvases can freeze and
reconnect, remote identity is not locally durable; SDK replay can prove terminal
determinism, but it is not completed-run evidence.
