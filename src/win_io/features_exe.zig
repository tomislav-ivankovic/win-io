//! Built by `zig build test-features` once per feature set, from the
//! `features` options module, to check that each one compiles and that the
//! DLLs of disabled features are not loaded.
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;

const WinIo = @import("win_io");
const options = @import("features");

const features: WinIo.Features = .{
    .process_spawn = options.process_spawn,
    .dns = options.dns,
    .net = options.net,
    .concurrency = options.concurrency,
    .fs = options.fs,
    .fs_modify = options.fs_modify,
};

pub const std_options_debug_io: Io = WinIo.global_single_threaded.ioWithFeatures(features);

// `win_api.zig` belongs to the `win_io` module.
extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;

pub fn main() !void {
    var win_io: WinIo = .init(std.heap.page_allocator, .{});
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(features);
    _ = Io.Clock.awake.now(io);

    // `enabled`: the DLL may be loaded. `imported`: the program imports it.
    const dlls = [_]struct { name: [:0]const u16, enabled: bool, imported: bool }{
        // `dnsapi.dll` loads it under Wine, but not on Windows.
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("ws2_32.dll"), .enabled = features.net or features.dns, .imported = features.net },
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("dnsapi.dll"), .enabled = features.dns, .imported = features.dns },
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("iphlpapi.dll"), .enabled = features.dns, .imported = features.dns },
    };
    var failed = false;
    for (dlls) |dll| {
        // Optimized builds leave out the vtable entries this program does not
        // call, so the DLLs of enabled features are only certain to be loaded
        // in Debug builds.
        const expected: bool = if (!dll.enabled) false else if (dll.imported and builtin.mode == .debug) true else continue;
        const loaded = GetModuleHandleW(dll.name) != null;
        if (loaded != expected) {
            std.debug.print("{f} is {s}loaded\n", .{
                std.unicode.fmtUtf16Le(dll.name),
                if (loaded) "" else "not ",
            });
            failed = true;
        }
    }
    if (failed) return error.TestUnexpectedResult;
}
