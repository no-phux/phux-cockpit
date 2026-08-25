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

export function snapshotHeader(bytes: Uint8Array): Invalidation | null {
  if (bytes.length < INVALIDATION_LENGTH) return null;
  if (bytes[0] !== PROTOCOL_VERSION || bytes[1] !== SNAPSHOT) return null;
  return { sequence: readU64(bytes, 2), revision: readU64(bytes, 10) };
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
