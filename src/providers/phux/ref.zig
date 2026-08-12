//! Force the semantic analyzer to look at every declaration in a phux module.
//!
//! Zig analyzes only what is referenced. Nothing in Cockpit currently calls
//! `PhuxProvider.search` or `Host.search` -- scrollback search is a local
//! session concern -- so those bodies were never analyzed by any build,
//! including `zig build test -Dphux-enabled=true`. MEASURED 2026-08-12: adding
//! a fourth parameter to `Host.search`, leaving the three-argument call in
//! `PhuxProvider.search` behind, produced exit=0 from all three of
//!
//!   zig build test
//!   PHUX_CLIENT_FFI_*=... zig build test
//!   zig build test -Dphux-enabled=true -Dphux-client-ffi-*=...
//!
//! "In the build graph" is therefore weaker than "compiled", and a verdict
//! claiming the provider was compiled has to mean the stronger thing. Rooting
//! a test artifact at a module and referencing every declaration in it makes
//! the two the same.
//!
//! std.testing.refAllDeclsRecursive is gone in Zig 0.16; std.testing.refAllDecls
//! survives but does not descend into nested types, which is exactly where the
//! provider's methods live.
const std = @import("std");
const builtin = @import("builtin");

/// Reference every declaration in `T`, descending into every container it
/// declares. No-op outside test builds.
pub fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
