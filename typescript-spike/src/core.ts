import { Cmd, asciiBytes } from "@native-sdk/core";
import {
  ENGINE_CHANNEL_KEY,
  type WireU64,
  invalidation,
  intent,
  nextU64,
  sameU64,
} from "./protocol.ts";

export interface Tab {
  readonly index: number;
  readonly title: Uint8Array;
  readonly selected: boolean;
  readonly attention: boolean;
}

export type TabPlacement = "top" | "side";
export type ChannelState = "data" | "closed" | "rejected";

export interface Model {
  readonly tabs: readonly Tab[];
  readonly selectedTab: number;
  readonly tabPlacement: TabPlacement;
  readonly paletteOpen: boolean;
  readonly settingsOpen: boolean;
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
  | { readonly kind: "settings_open" }
  | { readonly kind: "settings_close" }
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
  "engineConnected",
  "engineSequence",
  "engineRevision",
  "engine_event",
] as const;

const ZERO_U64: WireU64 = { hi: 0, lo: 0 };

export function initialModel(): [Model, Cmd<Msg>] {
  return [
    {
      tabs: [{ index: 0, title: asciiBytes("Terminal 1"), selected: true, attention: false }],
      selectedTab: 0,
      tabPlacement: "top",
      paletteOpen: false,
      settingsOpen: false,
      engineConnected: false,
      engineSequence: ZERO_U64,
      engineRevision: ZERO_U64,
      status: asciiBytes("CONNECTING"),
    },
    Cmd.channelOpen(ENGINE_CHANNEL_KEY, { event: "engine_event" }),
  ];
}

function selectTab(tabs: readonly Tab[], selected: number): readonly Tab[] {
  return tabs.map((tab) => ({ ...tab, selected: tab.index === selected }));
}

export function update(model: Model, msg: Msg): Model | [Model, Cmd<Msg>] {
  switch (msg.kind) {
    case "select_tab":
      return [
        { ...model, tabs: selectTab(model.tabs, msg.index), selectedTab: msg.index },
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
      return { ...model, paletteOpen: true };
    case "palette_close":
      return { ...model, paletteOpen: false };
    case "settings_open":
      return { ...model, settingsOpen: true };
    case "settings_close":
      return { ...model, settingsOpen: false };
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
      return {
        ...model,
        engineConnected: true,
        engineSequence: event.sequence,
        engineRevision: event.revision,
        status: contiguous || sameU64(model.engineSequence, ZERO_U64)
          ? asciiBytes("READY")
          : asciiBytes("RESYNCING"),
      };
    }
  }
}
