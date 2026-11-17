//! Tests for `WinIo.ioWithFeatures`. `zig build test-features` checks that
//! each feature set compiles and does not load the DLLs of disabled features.
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const win = @import("../win_api.zig");

const WinIo = @import("../win_io.zig");

/// Entries that disabled features replace with something other than a stub
/// that fails: dependent operations are illegal, `async` and `groupAsync` run
/// the task inline, and the operation and batch functions only leave sockets
/// out. `netLookup` closes its queue, so it is tested with a real one.
const not_failing = [_][]const u8{
    "netLookup",
    "childWait",
    "childKill",
    "netClose",
    "await",
    "cancel",
    "groupAwait",
    "groupCancel",
    "async",
    "groupAsync",
    "operate",
    "batchAwaitAsync",
    "batchAwaitConcurrent",
    "batchCancel",
};

test "io is ioWithFeatures(.all)" {
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    try testing.expectEqual(win_io.io().vtable, win_io.ioWithFeatures(.all).vtable);
    // Features are opt-in.
    try testing.expectEqual(win_io.ioWithFeatures(.none).vtable, win_io.ioWithFeatures(.{}).vtable);
}

test "disabled operations fail" {
    @setEvalBranchQuota(10_000);
    // Each one warns once in Debug builds.
    testing.log_level = .err;
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const all = comptime WinIo.global_single_threaded.io().vtable;
    const none = comptime WinIo.global_single_threaded.ioWithFeatures(.none).vtable;
    var disabled: usize = 0;
    var fallback: usize = 0;
    inline for (@typeInfo(Io.VTable).@"struct".field_names) |name| skip: {
        inline for (not_failing) |other| {
            if (comptime std.mem.eql(u8, name, other)) break :skip;
        }
        const f = @field(none, name);
        if (comptime f == @field(all, name)) break :skip;
        disabled += 1;

        const Fn = @typeInfo(@TypeOf(f)).pointer.child;
        const R = @typeInfo(Fn).@"fn".return_type.?;
        const E = switch (@typeInfo(R)) {
            .error_union => |eu| eu.error_set,
            else => R,
        };
        const expected: E = if (comptime hasError(E, "Unimplemented"))
            error.Unimplemented
        else if (comptime hasError(E, "OperationUnsupported"))
            error.OperationUnsupported
        else {
            // Calls the `std.Io.failing` function, which may use its arguments.
            fallback += 1;
            break :skip;
        };
        // These stubs ignore their arguments.
        var args: std.meta.ArgsTuple(Fn) = undefined;
        args[0] = &win_io;
        const result = @call(.auto, f, args);
        const err: E = switch (@typeInfo(R)) {
            .error_union => if (result) |_| {
                std.debug.print("{s} did not fail\n", .{name});
                return error.TestUnexpectedResult;
            } else |err| err,
            else => result,
        };
        testing.expectEqual(expected, err) catch |test_err| {
            std.debug.print("{s} failed with {t}\n", .{ name, err });
            return test_err;
        };
    }
    // Every operation listed in `Features`, except the ones above.
    try testing.expectEqual(44, disabled);
    try testing.expectEqual(33, fallback);
}

fn hasError(comptime E: type, comptime name: []const u8) bool {
    const names = @typeInfo(E).error_set.error_names orelse return true;
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

test "process_spawn disabled" {
    testing.log_level = .err;
    var win_io: WinIo = .init(testing.allocator, .{ .environ = .{ .block = .global } });
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(.{});
    try testing.expectError(error.OperationUnsupported, std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", "exit" },
    }));
}

test "net and dns disabled" {
    testing.log_level = .err;
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(.{});

    // As with `std.Io.failing`, since `ListenError` has neither
    // `error.Unimplemented` nor `error.OperationUnsupported`.
    const localhost: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    try testing.expectError(error.NetworkDown, localhost.listen(io, .{}));

    var results: [16]Io.net.HostName.LookupResult = undefined;
    var queue: Io.Queue(Io.net.HostName.LookupResult) = .init(&results);
    const host_name: Io.net.HostName = try .init("localhost");
    // `HostName.LookupError` has neither `error.Unimplemented` nor
    // `error.OperationUnsupported`.
    try testing.expectError(error.NetworkDown, host_name.lookup(io, &queue, .{ .port = 80 }));
    // The queue is closed even on error.
    try testing.expectError(error.Closed, queue.getOne(io));
}

fn addOne(x: u32) u32 {
    return x + 1;
}

fn storeThreadId(out: *u32) void {
    out.* = win.GetCurrentThreadId();
}

test "concurrency disabled" {
    var win_io: WinIo = .init(testing.allocator, .{});
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(.{});

    var future = io.async(addOne, .{1});
    try testing.expectEqual(2, future.await(io));
    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(addOne, .{1}));

    var group_thread_id: u32 = 0;
    var group: Io.Group = .init;
    group.async(io, storeThreadId, .{&group_thread_id});
    try group.await(io);
    try testing.expectEqual(win.GetCurrentThreadId(), group_thread_id);

    // No worker thread was started.
    try testing.expect(win_io.worker_threads.load(.monotonic) == null);
}

test "concurrency disabled: futexes work across std.Thread" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var win_io: WinIo = .init(testing.allocator, .{});
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(.{});

    var event: Io.Event = .unset;
    const thread = try std.Thread.spawn(.{}, Io.Event.set, .{ &event, io });
    defer thread.join();
    try event.wait(io);
}

test "fs without fs_modify" {
    testing.log_level = .err;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "file.txt", .data = "hello" });

    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(.{ .fs = true });

    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", try tmp.dir.readFile(io, "file.txt", &buffer));
    // As with `std.Io.failing`: the file system is full and the file absent.
    try testing.expectError(error.NoSpaceLeft, tmp.dir.createDir(io, "dir", .default_dir));
    try testing.expectError(error.FileNotFound, tmp.dir.deleteFile(io, "file.txt"));
    try testing.expectEqualStrings("hello", try tmp.dir.readFile(io, "file.txt", &buffer));
}

test "fs disabled" {
    testing.log_level = .err;
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.ioWithFeatures(.{});

    // As with `std.Io.failing`: the file system is empty and full.
    try testing.expectError(error.FileNotFound, Io.Dir.cwd().openFile(io, "file.txt", .{}));
    try testing.expectError(error.NoSpaceLeft, Io.Dir.cwd().createDir(io, "dir", .default_dir));

    // I/O on handles still works.
    _ = try Io.File.stderr().isTty(io);
    _ = Io.Clock.awake.now(io);
}
