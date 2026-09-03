import { Cmd, asciiBytes } from "@native-sdk/core";
import { applyTextInputEvent, type TextEditState, type TextInputEvent } from "@native-sdk/core/text";
import {
  ENGINE_CHANNEL_KEY,
  type WireU64,
  invalidation,
  intent,
  nextU64,
  sameU64,
  snapshot,
} from "./protocol.ts";

export interface Tab {
  readonly id: number;
  readonly index: number;
  readonly title: Uint8Array;
  readonly selected: boolean;
  readonly attention: boolean;
}

/// One row of the terminal switcher: the tab's position as the person reads
/// it off the strip, and its title, matched against the typed needle.
export interface SwitcherRow {
  readonly id: number;
  readonly index: number;
  readonly label: Uint8Array;
  readonly highlighted: boolean;
}

export interface ThemeRow {
  readonly index: number;
  readonly label: Uint8Array;
  readonly active: boolean;
  readonly highlighted: boolean;
}

export type TabPlacement = "top" | "side";
export type ChannelState = "data" | "closed" | "rejected";

export interface Model {
  readonly tabs: readonly Tab[];
  /// The run the band has room for, always holding the selected tab. The
  /// toolkit cannot bound a run by itself, and the core cannot measure a
  /// band; the engine's snapshot carries the shipping projection's answer
  /// and the core slices to it, with a cue for the rest.
  readonly visibleTabs: readonly Tab[];
  readonly tabWidth: number;
  readonly hasOverflow: boolean;
  readonly overflowLabel: Uint8Array;
  readonly selectedTab: number;
  readonly tabPlacement: TabPlacement;
  readonly paletteOpen: boolean;
  readonly paletteQuery: Uint8Array;
  readonly paletteAnchor: number;
  readonly paletteFocus: number;
  readonly paletteRows: readonly SwitcherRow[];
  readonly paletteCursor: number;
  readonly settingsOpen: boolean;
  readonly themes: readonly ThemeRow[];
  readonly settingsCursor: number;
  readonly configExists: boolean;
  readonly configNotice: Uint8Array;
  readonly engineConnected: boolean;
  readonly engineSequence: WireU64;
  readonly engineRevision: WireU64;
  readonly status: Uint8Array;
}

export type Msg =
  | { readonly kind: "select_tab"; readonly index: number }
  | { readonly kind: "new_terminal" }
  | { readonly kind: "close_selected_tab" }
  | { readonly kind: "toggle_tab_placement" }
  | { readonly kind: "palette_open" }
  | { readonly kind: "palette_close" }
  | { readonly kind: "palette_edit"; readonly edit: TextInputEvent }
  | { readonly kind: "palette_move"; readonly delta: number }
  | { readonly kind: "palette_submit" }
  | { readonly kind: "palette_pick"; readonly index: number }
  | { readonly kind: "settings_open" }
  | { readonly kind: "settings_close" }
  | { readonly kind: "settings_move"; readonly delta: number }
  | { readonly kind: "settings_pick"; readonly index: number }
  | { readonly kind: "settings_commit" }
  | { readonly kind: "settings_reveal" }
  // Posted by the native engine for every shell event it consumed: no bytes
  // ride along, the core only learns that the grids beneath it moved.
  | { readonly kind: "engine_wake" }
  | { readonly kind: "snapshot_loaded"; readonly body: Uint8Array }
  | { readonly kind: "snapshot_failed"; readonly error: Uint8Array }
  | {
      readonly kind: "engine_event";
      readonly key: number;
      readonly state: ChannelState;
      readonly bytes: Uint8Array;
      readonly droppedPending: number;
      readonly droppedTotal: number;
    };

export const viewUnbound = [
  "selectedTab",
  "paletteAnchor",
  "paletteFocus",
  "paletteCursor",
  "settingsCursor",
  "palette_move",
  "settings_move",
  "engineConnected",
  "engineSequence",
  "engineRevision",
  "engine_event",
  "engine_wake",
  "snapshot_loaded",
  "snapshot_failed",
] as const;

const ZERO_U64: WireU64 = { hi: 0, lo: 0 };

function overflowLabel(hidden: number): Uint8Array {
  // "+N" for N in 1..255 without string building or division, neither of
  // which the compiled subset offers on an integer path: peel hundreds and
  // tens by subtraction.
  let rest = hidden;
  let hundreds = 0;
  while (rest >= 100) {
    rest -= 100;
    hundreds += 1;
  }
  let tens = 0;
  while (rest >= 10) {
    rest -= 10;
    tens += 1;
  }
  const digits = hundreds > 0 ? 3 : tens > 0 ? 2 : 1;
  const out = new Uint8Array(1 + digits);
  out[0] = 43;
  let at = 1;
  if (hundreds > 0) {
    out[at] = 48 + hundreds;
    at += 1;
  }
  if (hundreds > 0 || tens > 0) {
    out[at] = 48 + tens;
    at += 1;
  }
  out[at] = 48 + rest;
  return out;
}

function lower(byte: number): number {
  return byte >= 65 && byte <= 90 ? byte + 32 : byte;
}

/// Case-insensitive ASCII substring, the shipping palette's rule
/// (workspace_projection.zig containsIgnoreCase).
function containsIgnoreCase(haystack: Uint8Array, needle: Uint8Array): boolean {
  if (needle.length === 0) return true;
  if (needle.length > haystack.length) return false;
  for (let start = 0; start + needle.length <= haystack.length; start += 1) {
    let matched = true;
    for (let at = 0; at < needle.length; at += 1) {
      if (lower(haystack[start + at]) !== lower(needle[at])) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}

function positionBytes(index: number): Uint8Array {
  return overflowLabel(index + 1).subarray(1);
}

function joinBytes(head: Uint8Array, mid: Uint8Array, tail: Uint8Array): Uint8Array {
  const out = new Uint8Array(head.length + mid.length + tail.length);
  let at = 0;
  for (let i = 0; i < head.length; i += 1) {
    out[at] = head[i];
    at += 1;
  }
  for (let i = 0; i < mid.length; i += 1) {
    out[at] = mid[i];
    at += 1;
  }
  for (let i = 0; i < tail.length; i += 1) {
    out[at] = tail[i];
    at += 1;
  }
  return out;
}

const TWO_SPACES = asciiBytes("  ");
const NO_BYTES = new Uint8Array(0);
// Typed empties: a bare `[]` in a record literal is inferred as number[] and
// the record then fails to be a Model at the union boundary, at runtime.
const NO_ROWS: readonly SwitcherRow[] = [];
const NO_THEMES: readonly ThemeRow[] = [];

/// The switcher rows for a needle: every tab whose strip position or title
/// contains it, the shipping palette's rule minus the working directory,
/// which the snapshot does not carry yet. The cursor is clamped into the
/// filtered list so an Enter always lands on a row that is showing.
function switcherRows(tabs: readonly Tab[], needle: Uint8Array, cursor: number): readonly SwitcherRow[] {
  const rows: SwitcherRow[] = [];
  for (let index = 0; index < tabs.length; index += 1) {
    if (!(index >= 0 && index <= 255)) break;
    const tab = tabs[index];
    const position = positionBytes(index);
    if (!containsIgnoreCase(position, needle) && !containsIgnoreCase(tab.title, needle)) continue;
    rows.push({ id: tab.id, index, label: joinBytes(position, TWO_SPACES, tab.title), highlighted: false });
  }
  if (rows.length === 0) return rows;
  const at = cursor >= 0 && cursor < rows.length ? Math.trunc(cursor) : 0;
  return rows.map((row, i) => ({ ...row, highlighted: i === at }));
}

function paletteState(model: Model): TextEditState {
  return {
    text: model.paletteQuery,
    selection: { anchor: model.paletteAnchor, focus: model.paletteFocus },
    composition: null,
  };
}

function withSwitcher(model: Model, query: Uint8Array, anchor: number, focus: number, cursor: number): Model {
  // Caret and cursor positions enter integer slots: fenced to the query's
  // own bound and the row count, then stated whole.
  const a = anchor >= 0 && anchor <= 4096 ? Math.trunc(anchor) : 0;
  const f = focus >= 0 && focus <= 4096 ? Math.trunc(focus) : 0;
  const rows = switcherRows(model.tabs, query, cursor);
  const clamped = rows.length === 0 ? 0 : cursor >= 0 && cursor < rows.length && cursor <= 255 ? Math.trunc(cursor) : 0;
  return { ...model, paletteQuery: query, paletteAnchor: a, paletteFocus: f, paletteRows: rows, paletteCursor: clamped };
}

const IN_EFFECT = asciiBytes("  (in effect)");

function themeRows(themes: readonly { readonly index: number; readonly name: Uint8Array }[], active: number, cursor: number): readonly ThemeRow[] {
  return themes.map((theme) => {
    const index = theme.index >= 0 && theme.index <= 32 ? Math.trunc(theme.index) : 0;
    return {
      index,
      label: index === active ? joinBytes(theme.name, IN_EFFECT, NO_BYTES) : theme.name,
      active: index === active,
      highlighted: index === cursor,
    };
  });
}

/// Re-highlight the catalog at `cursor`. A loop rather than a map with a
/// captured cursor: the compiled subset loses an integer proof across the
/// capture, and the cursor also lands in an integer slot.
function highlightThemes(themes: readonly ThemeRow[], cursor: number): readonly ThemeRow[] {
  const out: ThemeRow[] = [];
  for (let i = 0; i < themes.length; i += 1) {
    const t = themes[i];
    out.push({ index: t.index, label: t.label, active: t.active, highlighted: t.index === cursor });
  }
  return out;
}

/// The Configuration line the shipping settings panel shows, from the
/// engine's probe. Same sentences, same conditions (view.zig settingsPanel).
function configNotice(enabled: boolean, probed: boolean, exists: boolean, writable: boolean, refused: boolean, path: Uint8Array): Uint8Array {
  if (!enabled) return asciiBytes("No config location could be resolved; changes apply to this run only.");
  if (!probed) return joinBytes(asciiBytes("Active configuration file: "), path, NO_BYTES);
  if (refused) return joinBytes(path, asciiBytes(" refused the write; changes apply to this run only."), NO_BYTES);
  if (!writable) return joinBytes(path, asciiBytes(" is read-only; changes apply to this run only."), NO_BYTES);
  if (!exists) return joinBytes(path, asciiBytes(" will be created when you save."), NO_BYTES);
  return joinBytes(asciiBytes("Active configuration file: "), path, NO_BYTES);
}

/// Slice the tab list to the engine's run. Every index is proven whole from
/// the wire (protocol.ts fences the bytes), so the slice needs no more.
function sliceRun(tabs: readonly Tab[], runStart: number, runCount: number): readonly Tab[] {
  const total = tabs.length;
  if (!(runStart >= 0 && runStart <= 255) || !(runCount >= 0 && runCount <= 255)) return tabs;
  const start = Math.trunc(runStart);
  const count = Math.trunc(runCount);
  if (start + count > total) return tabs;
  return tabs.slice(start, start + count);
}

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      tabs: [{ id: 1, index: 0, title: asciiBytes("Terminal 1"), selected: true, attention: false }],
      visibleTabs: [{ id: 1, index: 0, title: asciiBytes("Terminal 1"), selected: true, attention: false }],
      tabWidth: 168,
      hasOverflow: false,
      overflowLabel: new Uint8Array(0),
      selectedTab: 0,
      tabPlacement: "top",
      paletteOpen: false,
      paletteQuery: new Uint8Array(0),
      paletteAnchor: 0,
      paletteFocus: 0,
      paletteRows: NO_ROWS,
      paletteCursor: 0,
      settingsOpen: false,
      themes: NO_THEMES,
      settingsCursor: 0,
      configExists: false,
      configNotice: new Uint8Array(0),
      engineConnected: false,
      engineSequence: ZERO_U64,
      engineRevision: ZERO_U64,
      status: asciiBytes("CONNECTING"),
    },
    Cmd.batch([
      Cmd.channelOpen(ENGINE_CHANNEL_KEY, { event: "engine_event" }),
      Cmd.request("cockpit.snapshot", new Uint8Array(0), {
        key: "cockpit-snapshot",
        ok: "snapshot_loaded",
        err: "snapshot_failed",
      }),
    ]),
  ];
}

function selectTab(tabs: readonly Tab[], selected: number): readonly Tab[] {
  return tabs.map((tab) => ({ ...tab, selected: tab.index === selected }));
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "select_tab":
      return [
        {
          ...model,
          tabs: selectTab(model.tabs, msg.index),
          visibleTabs: selectTab(model.visibleTabs, msg.index),
          selectedTab: msg.index,
        },
        Cmd.host("cockpit.intent", intent(1, model.engineRevision, msg.index)),
      ];
    case "new_terminal":
      return [model, Cmd.host("cockpit.intent", intent(2, model.engineRevision, 0))];
    case "close_selected_tab":
      return [model, Cmd.host("cockpit.intent", intent(3, model.engineRevision, model.selectedTab))];
    case "toggle_tab_placement": {
      const placement: TabPlacement = model.tabPlacement === "top" ? "side" : "top";
      return [
        { ...model, tabPlacement: placement },
        Cmd.host("cockpit.intent", intent(4, model.engineRevision, placement === "side" ? 1 : 0)),
      ];
    }
    case "palette_open":
      // Two modal surfaces cannot both own the keyboard; the one just asked
      // for wins. Opening is idempotent so a repeat never clears a needle.
      if (model.paletteOpen) return model;
      return withSwitcher({ ...model, paletteOpen: true, settingsOpen: false }, new Uint8Array(0), 0, 0, 0);
    case "palette_close":
      return { ...model, paletteOpen: false, paletteQuery: new Uint8Array(0), paletteRows: NO_ROWS, paletteCursor: 0 };
    case "palette_edit": {
      if (!model.paletteOpen) return model;
      const next = applyTextInputEvent(paletteState(model), msg.edit, 96);
      if (next === null) return model;
      return withSwitcher(model, next.text, next.selection.anchor, next.selection.focus, 0);
    }
    case "palette_move": {
      if (!model.paletteOpen || model.paletteRows.length === 0) return model;
      const step = msg.delta >= 0 ? 1 : -1;
      const last = model.paletteRows.length - 1;
      const raw = model.paletteCursor + step < 0 ? 0 : model.paletteCursor + step > last ? last : model.paletteCursor + step;
      return withSwitcher(model, model.paletteQuery, model.paletteAnchor, model.paletteFocus, raw);
    }
    case "palette_submit": {
      if (!model.paletteOpen) return model;
      const closed: Model = { ...model, paletteOpen: false, paletteQuery: new Uint8Array(0), paletteRows: NO_ROWS, paletteCursor: 0 };
      // A commit with nothing matching still dismisses: an Enter that found
      // nothing and left the switcher up reads as a stuck keyboard.
      if (model.paletteRows.length === 0) return closed;
      const row = model.paletteRows[model.paletteCursor];
      const picked = row.index;
      const selected: Model = { ...closed, tabs: selectTab(model.tabs, picked), visibleTabs: selectTab(model.visibleTabs, picked), selectedTab: picked };
      return [selected, Cmd.host("cockpit.intent", intent(1, model.engineRevision, picked))];
    }
    case "palette_pick": {
      if (!model.paletteOpen) return model;
      const index = msg.index;
      if (!(index >= 0 && index < model.tabs.length)) return model;
      const picked = Math.trunc(index);
      const chosen: Model = {
        ...model,
        paletteOpen: false,
        paletteQuery: new Uint8Array(0),
        paletteRows: NO_ROWS,
        paletteCursor: 0,
        tabs: selectTab(model.tabs, picked),
        visibleTabs: selectTab(model.visibleTabs, picked),
        selectedTab: picked,
      };
      return [chosen, Cmd.host("cockpit.intent", intent(1, model.engineRevision, picked))];
    }
    case "settings_open": {
      if (model.settingsOpen) return model;
      // The probe is the engine's, once per opening, exactly as the shipping
      // app asks the disk once when the panel opens and never per frame.
      return [
        { ...model, settingsOpen: true, paletteOpen: false },
        Cmd.host("cockpit.intent", intent(7, model.engineRevision, 0)),
      ];
    }
    case "settings_close":
      return { ...model, settingsOpen: false };
    case "settings_move": {
      if (!model.settingsOpen || model.themes.length === 0) return model;
      const step = msg.delta >= 0 ? 1 : -1;
      const last = model.themes.length - 1;
      const raw = model.settingsCursor + step < 0 ? 0 : model.settingsCursor + step > last ? last : model.settingsCursor + step;
      const cursor = raw >= 0 && raw <= 32 ? Math.trunc(raw) : 0;
      return { ...model, settingsCursor: cursor, themes: highlightThemes(model.themes, cursor) };
    }
    case "settings_pick": {
      if (!model.settingsOpen) return model;
      const index = msg.index;
      if (!(index >= 0 && index < model.themes.length && index <= 32)) return model;
      const cursor = Math.trunc(index);
      return { ...model, settingsCursor: cursor, themes: highlightThemes(model.themes, cursor) };
    }
    case "settings_commit": {
      if (!model.settingsOpen) return model;
      return [
        { ...model, settingsOpen: false },
        Cmd.host("cockpit.intent", intent(5, model.engineRevision, model.settingsCursor)),
      ];
    }
    case "settings_reveal":
      if (!model.settingsOpen || !model.configExists) return model;
      return [model, Cmd.host("cockpit.intent", intent(6, model.engineRevision, 0))];
    case "engine_wake":
      return { ...model };
    case "snapshot_loaded": {
      const projected = snapshot(msg.body);
      if (projected === null) {
        return { ...model, engineConnected: false, status: asciiBytes("BAD SNAPSHOT") };
      }
      // Bits 0..4 are the engine model's own limit and write refusals; bit 7
      // is the seam's: the last intent named a revision the engine had left.
      const refusedMask = projected.flags & 159;
      const rawSelected = projected.selectedTab;
      if (!(rawSelected >= 0 && rawSelected <= 255)) {
        return { ...model, engineConnected: false, status: asciiBytes("BAD SNAPSHOT") };
      }
      const selectedTab = Math.trunc(rawSelected);
      const rawWidth = projected.tabWidth;
      if (!(rawWidth >= 0 && rawWidth <= 65535)) {
        return { ...model, engineConnected: false, status: asciiBytes("BAD SNAPSHOT") };
      }
      const tabWidth = Math.trunc(rawWidth);
      const hidden = projected.tabs.length - projected.runCount;
      const active = projected.activeTheme;
      const cursor = model.settingsOpen ? model.settingsCursor : active >= 0 && active <= 32 && active < projected.themes.length ? Math.trunc(active) : 0;
      const refused = (projected.flags & 8) !== 0;
      const synced: Model = {
        ...model,
        themes: themeRows(projected.themes, active, cursor),
        settingsCursor: cursor,
        configExists: projected.configExists,
        configNotice: configNotice(projected.configEnabled, projected.configProbed, projected.configExists, projected.configWritable, refused, projected.configPath),
        tabs: projected.tabs,
        visibleTabs: sliceRun(projected.tabs, projected.runStart, projected.runCount),
        tabWidth,
        hasOverflow: hidden > 0,
        overflowLabel: hidden > 0 ? overflowLabel(hidden) : new Uint8Array(0),
        selectedTab,
        tabPlacement: projected.tabPlacement === 1 ? "side" : "top",
        engineConnected: true,
        engineSequence: projected.sequence,
        engineRevision: projected.revision,
        status: refusedMask === 0 ? asciiBytes("READY") : asciiBytes("ACTION REFUSED"),
      };
      return model.paletteOpen
        ? withSwitcher(synced, model.paletteQuery, model.paletteAnchor, model.paletteFocus, model.paletteCursor)
        : synced;
    }
    case "snapshot_failed":
      return { ...model, engineConnected: false, status: asciiBytes("ENGINE UNAVAILABLE") };
    case "engine_event": {
      if (msg.state !== "data") {
        return {
          ...model,
          engineConnected: false,
          status: msg.state === "rejected" ? asciiBytes("ENGINE REFUSED") : asciiBytes("ENGINE CLOSED"),
        };
      }
      const event = invalidation(msg.bytes);
      if (event === null) return { ...model, status: asciiBytes("ENGINE PROTOCOL ERROR") };
      const contiguous = sameU64(event.sequence, nextU64(model.engineSequence));
      const next = {
        ...model,
        engineSequence: event.sequence,
        status: contiguous || sameU64(model.engineSequence, ZERO_U64)
          ? asciiBytes("SYNCING")
          : asciiBytes("RESYNCING"),
      };
      return [
        next,
        Cmd.request("cockpit.snapshot", new Uint8Array(0), {
          key: "cockpit-snapshot",
          ok: "snapshot_loaded",
          err: "snapshot_failed",
        }),
      ];
    }
  }
}
