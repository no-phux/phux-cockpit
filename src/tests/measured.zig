//! Opt-in diagnostic output for MEASURED tests.
//!
//! These tests record a number that was measured rather than guessed, and the
//! number is worth printing when someone is actually studying it. Printing it
//! on every run is not free, though, and the cost is not cosmetic:
//!
//! `std.debug.print` from a test lands in the build runner's
//! `Step.result_stderr`. Zig 0.16's build runner then does this
//! (lib/zig/compiler/build_runner.zig, around line 1381):
//!
//!     // No matter the result, we want to display error/warning messages.
//!     if (s.result_error_bundle.errorMessageCount() > 0 or
//!         s.result_error_msgs.items.len > 0 or
//!         s.result_stderr.len > 0)
//!     { ... printErrorMessages(...) ... }
//!
//! `printErrorMessages` renders a step-FAILURE report: the step name, a
//! `printStepFailure` suffix, the captured stderr, and finally
//! `failed command: <argv>` — because `Step.result_failed_command` is
//! populated for every run step whether or not it failed
//! (lib/zig/std/Build/Step.zig:356 and :420).
//!
//! So a single unconditional `std.debug.print` in a PASSING test makes a
//! fully green `zig build test` print `failed command: .../test --listen=-`.
//! That is phux-cockpit-5px, and it already caused a green gate to be read as
//! red. Route measurement output through here instead.
//!
//! To see the numbers:
//!
//!     zig build test -Dmeasure=true
//!
//! Note that doing so re-introduces the `failed command:` line, for the reason
//! above. The exit code remains the only thing that says pass or fail.
//!
//! This is a build option rather than an environment variable because Zig 0.16
//! has no free-function `getenv` (std.posix.getenv is gone, and std.c.getenv
//! would make the test binary depend on libc being linked). A build option is
//! comptime-known, so a default run compiles the print calls out entirely.
const std = @import("std");
const options = @import("test_options");

/// True when the caller asked for measurement output, via -Dmeasure=true.
pub const enabled: bool = options.measure;

/// `std.debug.print`, but compiled out unless -Dmeasure=true.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    if (!enabled) return;
    std.debug.print(fmt, args);
}
