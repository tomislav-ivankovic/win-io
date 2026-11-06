//! `WinIo.init_single_threaded` and `WinIo.global_single_threaded`, which work
//! without an allocator and never spawn threads.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const win = @import("../win_api.zig");

const WinIo = @import("../win_io.zig");

// Usable at comptime, like `std.Io.Threaded.global_single_threaded.io()`.
const global_io = WinIo.global_single_threaded.io();

fn currentThreadId() u32 {
    return win.GetCurrentThreadId();
}

fn addOne(x: u32) u32 {
    return x + 1;
}

fn storeThreadId(out: *u32) void {
    out.* = win.GetCurrentThreadId();
}

test "async runs inline and concurrent is unavailable" {
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.io();

    var future = io.async(currentThreadId, .{});
    try testing.expectEqual(win.GetCurrentThreadId(), future.await(io));

    try testing.expectError(error.ConcurrencyUnavailable, io.concurrent(addOne, .{1}));

    var group_thread_id: u32 = 0;
    var group: Io.Group = .init;
    group.async(io, storeThreadId, .{&group_thread_id});
    try group.await(io);
    try testing.expectEqual(win.GetCurrentThreadId(), group_thread_id);

    try testing.expect(win_io.worker_threads.load(.monotonic) == null);
}

test "file I/O without an allocator" {
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "file.txt", .data = "hello" });
    var buffer: [16]u8 = undefined;
    try testing.expectEqualStrings("hello", try tmp.dir.readFile(io, "file.txt", &buffer));

    const file = try tmp.dir.openFile(io, "file.txt", .{ .lock = .exclusive });
    file.close(io);
}

test "receive timeout without threads" {
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.io();

    const localhost: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    const socket = localhost.bind(io, .{ .mode = .dgram }) catch |err| switch (err) {
        error.NetworkDown => return error.SkipZigTest,
        else => |e| return e,
    };
    defer socket.close(io);

    var buffer: [16]u8 = undefined;
    try testing.expectError(error.Timeout, socket.receiveTimeout(io, &buffer, .{ .duration = .{
        .raw = .fromMilliseconds(20),
        .clock = .awake,
    } }));
}

test "global_single_threaded" {
    try global_io.sleep(.fromMilliseconds(1), .awake);
    var bytes: [8]u8 = @splat(0);
    global_io.random(&bytes);
    try testing.expect(!std.mem.allEqual(u8, &bytes, 0));
}

test "spawning a child process needs an allocator" {
    var win_io: WinIo = .init_single_threaded;
    defer win_io.deinit();
    const io = win_io.io();

    try testing.expectError(error.OutOfMemory, std.process.spawn(io, .{ .argv = &.{ "cmd.exe", "/c", "exit" } }));
}
