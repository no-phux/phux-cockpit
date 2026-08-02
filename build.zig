// This example owns its build: the emulator core (libghostty-vt) is a
// third-party Zig module the generated app graph does not provide, so the
// app and test modules import it here on top of the standard app build.
const std = @import("std");
const native_sdk = @import("native_sdk");

fn phuxHostModule(
    b: *std.Build,
    app_module: *std.Build.Module,
    phux_enabled: bool,
) *std.Build.Module {
    if (!phux_enabled) {
        return b.createModule(.{
            .root_source_file = b.path("src/phux_host_disabled.zig"),
            .target = app_module.resolved_target.?,
            .optimize = app_module.optimize.?,
        });
    }
    const include_dir = b.option(
        []const u8,
        "phux-client-ffi-include-dir",
        "Directory containing phux/client.h (required with -Dphux-enabled=true)",
    ) orelse @panic("-Dphux-enabled=true requires -Dphux-client-ffi-include-dir=<dir>");
    const lib_dir = b.option(
        []const u8,
        "phux-client-ffi-lib-dir",
        "Directory containing libphux_client_ffi.a (required with -Dphux-enabled=true)",
    ) orelse @panic("-Dphux-enabled=true requires -Dphux-client-ffi-lib-dir=<dir>");
    const archive = b.pathJoin(&.{ lib_dir, "libphux_client_ffi.a" });
    const module = b.createModule(.{
        .root_source_file = b.path("src/phux_host.zig"),
        .target = app_module.resolved_target.?,
        .optimize = app_module.optimize.?,
    });
    module.addIncludePath(.{ .cwd_relative = include_dir });
    module.addObjectFile(.{ .cwd_relative = archive });
    module.linkSystemLibrary("c", .{});
    return module;
}

pub fn build(b: *std.Build) void {
    const artifacts = native_sdk.addAppArtifacts(b, b.dependency("native_sdk", .{}), .{ .name = "terminal" });
    const app_module = artifacts.exe.root_module;
    const phux_enabled = b.option(
        bool,
        "phux-enabled",
        "Build the real phux client host instead of the local spike fixture",
    ) orelse false;
    const phux_host = phuxHostModule(b, app_module, phux_enabled);
    app_module.addImport("phux_host", phux_host);
    if (phux_enabled and app_module.resolved_target.?.result.os.tag == .macos) {
        app_module.addCSourceFile(.{
            .file = b.path("src/phux_pointer_macos.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        app_module.linkFramework("AppKit", .{});
    }
    const ghostty = b.dependency("ghostty", .{
        .target = app_module.resolved_target.?,
        .optimize = app_module.optimize.?,
        // Keep the vt module pure Zig: the SIMD paths pull vendored C++
        // dependencies the terminal example does not need.
        .simd = false,
        // Only the vt MODULE is consumed: ghostty's own macOS app and
        // xcframework artifacts default ON for Darwin hosts and their
        // CONFIGURE step resolves the iOS libc — which aborts on a
        // machine with only the command-line tools. Neither artifact is
        // wanted here on any host.
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    const vt = ghostty.module("ghostty-vt");
    app_module.addImport("ghostty-vt", vt);
    if (artifacts.tests.root_module != app_module) {
        artifacts.tests.root_module.addImport("ghostty-vt", vt);
        artifacts.tests.root_module.addImport("phux_host", phux_host);
    }
}
