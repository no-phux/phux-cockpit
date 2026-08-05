// The local Cockpit remains the default graph. The production Phux lane is
// materialized only under -Dphux-enabled=true, so default builds never resolve
// its C header, static archive, Objective-C source, or AppKit.
const std = @import("std");
const native_sdk = @import("native_sdk");

fn addImportToArtifacts(
    artifacts: native_sdk.AppArtifacts,
    name: []const u8,
    module: *std.Build.Module,
) void {
    artifacts.exe.root_module.addImport(name, module);
    if (artifacts.tests.root_module != artifacts.exe.root_module)
        artifacts.tests.root_module.addImport(name, module);
}

fn addProviderContractModules(
    b: *std.Build,
    artifacts: native_sdk.AppArtifacts,
) void {
    const roots = [_]*std.Build.Module{
        artifacts.exe.root_module,
        artifacts.tests.root_module,
    };
    for (roots, 0..) |root, index| {
        if (index == 1 and root == artifacts.exe.root_module) continue;
        const contract = b.createModule(.{
            .root_source_file = b.path("src/provider.zig"),
            .target = root.resolved_target.?,
            .optimize = root.optimize.?,
        });
        const sdk_module = root.import_table.get("native_sdk") orelse
            @panic("native-sdk app graph did not expose its root module");
        contract.addImport("native_sdk", sdk_module);
        root.addImport("provider_contract", contract);
    }
}

fn addPhuxModules(
    b: *std.Build,
    artifacts: native_sdk.AppArtifacts,
) void {
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

    const roots = [_]*std.Build.Module{
        artifacts.exe.root_module,
        artifacts.tests.root_module,
    };
    for (roots, 0..) |root, index| {
        if (index == 1 and root == artifacts.exe.root_module) continue;
        const target = root.resolved_target.?;
        const optimize = root.optimize.?;
        const sdk_module = root.import_table.get("native_sdk") orelse
            @panic("native-sdk app graph did not expose its root module");
        const provider_contract = root.import_table.get("provider_contract") orelse
            @panic("cockpit graph did not expose its provider contract module");

        const transport_module = b.createModule(.{
            .root_source_file = b.path("src/phux_transport.zig"),
            .target = target,
            .optimize = optimize,
        });
        const extension_module = b.createModule(.{
            .root_source_file = b.path("src/phux_extension.zig"),
            .target = target,
            .optimize = optimize,
        });
        extension_module.addImport("native_sdk", sdk_module);
        extension_module.addImport("phux_transport", transport_module);

        const host_module = b.createModule(.{
            .root_source_file = b.path("src/phux_host.zig"),
            .target = target,
            .optimize = optimize,
        });
        host_module.addImport("provider_contract", provider_contract);
        host_module.addImport("native_sdk", sdk_module);
        host_module.addImport("phux_transport", transport_module);
        host_module.addIncludePath(.{ .cwd_relative = include_dir });
        host_module.addObjectFile(.{
            .cwd_relative = b.pathJoin(&.{ lib_dir, "libphux_client_ffi.a" }),
        });
        host_module.linkSystemLibrary("c", .{});

        const provider_module = b.createModule(.{
            .root_source_file = b.path("src/phux_provider.zig"),
            .target = target,
            .optimize = optimize,
        });
        provider_module.addImport("native_sdk", sdk_module);
        provider_module.addImport("provider_contract", provider_contract);
        provider_module.addImport("phux_host", host_module);
        provider_module.addImport("phux_transport", transport_module);
        provider_module.addImport("phux_extension", extension_module);

        const pointer_module = b.createModule(.{
            .root_source_file = b.path("src/phux_pointer.zig"),
            .target = target,
            .optimize = optimize,
        });
        pointer_module.addImport("native_sdk", sdk_module);

        root.addImport("phux_transport", transport_module);
        root.addImport("phux_extension", extension_module);
        root.addImport("phux_provider", provider_module);
        root.addImport("phux_pointer", pointer_module);
        root.addCSourceFile(.{
            .file = b.path("src/phux_pointer_macos.m"),
            .flags = &.{ "-fobjc-arc", "-fblocks" },
        });
        if (b.sysroot) |sysroot| {
            root.addFrameworkPath(.{
                .cwd_relative = b.pathJoin(&.{ sysroot, "System/Library/Frameworks" }),
            });
        }
        root.linkFramework("AppKit", .{});
        root.linkSystemLibrary("c", .{});

        // Zig runs tests only from a compilation's root module. Exercise the
        // production FFI adapter itself when that graph is enabled instead of
        // merely proving that importing it compiles.
        if (index == 1) {
            const host_tests = b.addTest(.{
                .name = "phux-host-tests",
                .root_module = host_module,
            });
            if (b.top_level_steps.get("test")) |test_step| {
                test_step.step.dependOn(&b.addRunArtifact(host_tests).step);
            }
        }
    }
}

pub fn build(b: *std.Build) void {
    const dependency = b.dependency("native_sdk", .{});
    const artifacts = native_sdk.addAppArtifacts(b, dependency, .{ .name = "phux-cockpit" });
    const app_module = artifacts.exe.root_module;
    if (app_module.resolved_target.?.result.os.tag != .macos)
        @panic("phux-cockpit supports macOS only");

    const phux_enabled = b.option(
        bool,
        "phux-enabled",
        "Build the production Phux provider instead of the local terminal provider",
    ) orelse false;
    const phux_options = b.addOptions();
    phux_options.addOption(bool, "enabled", phux_enabled);
    addImportToArtifacts(artifacts, "phux_options", phux_options.createModule());
    addProviderContractModules(b, artifacts);
    if (phux_enabled) addPhuxModules(b, artifacts);

    const ghostty = b.dependency("ghostty", .{
        .target = app_module.resolved_target.?,
        .optimize = app_module.optimize.?,
        .simd = false,
        .@"emit-xcframework" = false,
        .@"emit-macos-app" = false,
    });
    const vt = ghostty.module("ghostty-vt");
    addImportToArtifacts(artifacts, "ghostty-vt", vt);
}
