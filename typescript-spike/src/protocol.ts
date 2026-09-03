export const ENGINE_CHANNEL_KEY = 0x434f434b0001;
export const PROTOCOL_VERSION = 1;

const STATE_INVALIDATED = 1;
const SNAPSHOT = 2;
const INVALIDATION_LENGTH = 18;

export interface WireU64 {
  readonly hi: number;
  readonly lo: number;
}

export interface Invalidation {
  readonly sequence: WireU64;
  readonly revision: WireU64;
}

export interface SnapshotTab {
  readonly id: number;
  readonly index: number;
  readonly title: Uint8Array;
  readonly selected: boolean;
  readonly attention: boolean;
}

export interface EngineSnapshot extends Invalidation {
  readonly activeWindow: number;
  readonly tabPlacement: number;
  readonly selectedTab: number;
  readonly flags: number;
  /// The run the band has room for, by the engine's projection: the first
  /// visible tab, how many, and the per-tab extent in points.
  readonly runStart: number;
  readonly runCount: number;
  readonly tabWidth: number;
  readonly tabs: readonly SnapshotTab[];
}

function readU32(bytes: Uint8Array, at: number): number {
  const value = bytes[at]
    + bytes[at + 1] * 256
    + bytes[at + 2] * 65536
    + bytes[at + 3] * 16777216;
  return value >= 0 && value <= 4294967295 ? Math.trunc(value) : 0;
}

function readU64(bytes: Uint8Array, at: number): WireU64 {
  const low = readU32(bytes, at);
  const high = readU32(bytes, at + 4);
  return {
    lo: low >= 0 && low <= 4294967295 ? Math.trunc(low) : 0,
    hi: high >= 0 && high <= 4294967295 ? Math.trunc(high) : 0,
  };
}

export function sameU64(left: WireU64, right: WireU64): boolean {
  return left.hi === right.hi && left.lo === right.lo;
}

export function nextU64(value: WireU64): WireU64 {
  if (value.lo < 4294967295) return { hi: value.hi, lo: value.lo + 1 };
  return { hi: value.hi < 4294967295 ? value.hi + 1 : 0, lo: 0 };
}

export function invalidation(bytes: Uint8Array): Invalidation | null {
  if (bytes.length !== INVALIDATION_LENGTH) return null;
  if (bytes[0] !== PROTOCOL_VERSION || bytes[1] !== STATE_INVALIDATED) return null;
  return { sequence: readU64(bytes, 2), revision: readU64(bytes, 10) };
}

export function snapshot(bytes: Uint8Array): EngineSnapshot | null {
  if (bytes.length < 28) return null;
  if (bytes[0] !== PROTOCOL_VERSION || bytes[1] !== SNAPSHOT) return null;
  const count = bytes[20];
  const selected = bytes[21];
  // ScriptC proves every integer slot ahead of time: a byte read past the
  // end is NaN in TypeScript, so each value is fenced with an ordered
  // comparison before it may enter the model. The bounds are the wire's own
  // (u8 count, u32 id), not guesses.
  if (!(count >= 0 && count <= 255)) return null;
  if (!(selected >= 0 && selected <= 255)) return null;
  if (selected >= count && count !== 0) return null;
  const runStart = bytes[24];
  const runCount = bytes[25];
  const tabWidth = bytes[26] + bytes[27] * 256;
  if (!(runStart >= 0 && runStart <= 255) || !(runCount >= 0 && runCount <= 255)) return null;
  if (!(tabWidth >= 0 && tabWidth <= 65535)) return null;
  if (runStart + runCount > count) return null;
  const tabs: SnapshotTab[] = [];
  let at = 28;
  for (let index = 0; index < count; index += 1) {
    if (!(index >= 0 && index <= 255)) return null;
    if (at + 6 > bytes.length) return null;
    const rawId = readU32(bytes, at);
    const titleLength = bytes[at + 5];
    if (!(rawId >= 1 && rawId <= 4294967295)) return null;
    const id = Math.trunc(rawId);
    if (!(titleLength >= 0 && titleLength <= 255)) return null;
    if (at + 6 + titleLength > bytes.length) return null;
    tabs.push({
      id,
      index,
      title: bytes.subarray(at + 6, at + 6 + titleLength),
      selected: index === selected,
      attention: bytes[at + 4] !== 0,
    });
    at += 6 + titleLength;
  }
  if (at !== bytes.length) return null;
  return {
    sequence: readU64(bytes, 2),
    revision: readU64(bytes, 10),
    activeWindow: bytes[18],
    tabPlacement: bytes[19],
    selectedTab: selected,
    flags: bytes[22],
    runStart,
    runCount,
    tabWidth,
    tabs,
  };
}

function writeU32(bytes: Uint8Array, at: number, input: number): void {
  const value = input >= 0 && input <= 4294967295 ? Math.trunc(input) : 0;
  bytes[at] = value % 256;
  bytes[at + 1] = Math.floor(value / 256) % 256;
  bytes[at + 2] = Math.floor(value / 65536) % 256;
  bytes[at + 3] = Math.floor(value / 16777216) % 256;
}

export function intent(kind: number, expectedRevision: WireU64, argument: number): Uint8Array {
  const bytes = new Uint8Array(11);
  bytes[0] = PROTOCOL_VERSION;
  bytes[1] = kind;
  writeU32(bytes, 2, expectedRevision.lo);
  writeU32(bytes, 6, expectedRevision.hi);
  bytes[10] = argument;
  return bytes;
}
