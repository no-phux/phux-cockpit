//! Module root for the TypeScript-core build graph. The extension module
//! that fronts the compiled core lives under `typescript-spike/`, and a Zig
//! module may only import files below its own root, so the engine is
//! exposed to it as a module rooted here (`cockpit_engine` in build.zig)
//! rather than by relative path.
const std = @import("std");

pub const engine = @import("cockpit/native/ts_engine.zig");
pub const protocol = @import("cockpit/native/ts_protocol.zig");
pub const snapshot = @import("cockpit/native/ts_snapshot.zig");
pub const projection = @import("cockpit/native/workspace_projection.zig");
pub const Engine = engine.Engine;
pub const NoShells = engine.NoShells;

test {
    std.testing.refAllDecls(@This());
}
