//! Tests ported from Zig's lib/std/Io/Threaded/test.zig (0.17.0) that construct
//! their own `Io` instance and therefore are not covered by `zig build test-std`
//! (which only swaps `std.testing.io`). They use `WinIo` instead of
//! `std.Io.Threaded`.
//!
//! Not ported: "toPrefixedFileW", "removeDotDirs" and "getWin32PathType vs
//! RtlDetermineDosPathNameType_U", which test Threaded's internal NT path
//! conversion helpers.
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const assert = std.debug.assert;
const win = @import("../win_api.zig");

const WinIo = @import("../win_io.zig");

test "concurrent vs main prevents deadlock via oversubscription" {
    var win_io: WinIo = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
        .async_limit = .nothing,
    });
    defer win_io.deinit();
    const io = win_io.io();

    var queue: Io.Queue(u8) = .init(&.{});

    var putter = io.concurrent(put, .{ io, &queue }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };
    defer putter.cancel(io);

    try testing.expectEqual(42, queue.getOneUncancelable(io));
}

fn put(io: Io, queue: *Io.Queue(u8)) void {
    queue.putOneUncancelable(io, 42) catch unreachable;
}

fn get(io: Io, queue: *Io.Queue(u8)) void {
    assert(queue.getOneUncancelable(io) catch unreachable == 42);
}

test "concurrent vs concurrent prevents deadlock via oversubscription" {
    var win_io: WinIo = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
        .async_limit = .nothing,
    });
    defer win_io.deinit();
    const io = win_io.io();

    var queue: Io.Queue(u8) = .init(&.{});

    var putter = io.concurrent(put, .{ io, &queue }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            try testing.expect(builtin.single_threaded);
            return;
        },
    };
    defer putter.cancel(io);

    var getter = try io.concurrent(get, .{ io, &queue });
    defer getter.cancel(io);

    getter.await(io);
    putter.await(io);
}

const ByteArray256 = struct { x: [32]u8 align(32) };
const ByteArray512 = struct { x: [64]u8 align(64) };

fn concatByteArrays(a: ByteArray256, b: ByteArray256) ByteArray512 {
    return .{ .x = a.x ++ b.x };
}

test "async/concurrent context and result alignment" {
    var buffer: [2048]u8 align(@alignOf(ByteArray512)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);

    var win_io: WinIo = .init(fba.allocator(), .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer win_io.deinit();
    const io = win_io.io();

    const a: ByteArray256 = .{ .x = @splat(2) };
    const b: ByteArray256 = .{ .x = @splat(3) };
    const expected: ByteArray512 = .{ .x = @as([32]u8, @splat(2)) ++ @as([32]u8, @splat(3)) };

    {
        var future = io.async(concatByteArrays, .{ a, b });
        const result = future.await(io);
        try std.testing.expectEqualSlices(u8, &expected.x, &result.x);
    }
    {
        var future = io.concurrent(concatByteArrays, .{ a, b }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => {
                try testing.expect(builtin.single_threaded);
                return;
            },
        };
        const result = future.await(io);
        try std.testing.expectEqualSlices(u8, &expected.x, &result.x);
    }
}

fn concatByteArraysResultPtr(a: ByteArray256, b: ByteArray256, result: *ByteArray512) void {
    result.* = .{ .x = a.x ++ b.x };
}

test "Group.async context alignment" {
    var buffer: [2048]u8 align(@alignOf(ByteArray512)) = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buffer);

    var win_io: WinIo = .init(fba.allocator(), .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer win_io.deinit();
    const io = win_io.io();

    const a: ByteArray256 = .{ .x = @splat(2) };
    const b: ByteArray256 = .{ .x = @splat(3) };
    const expected: ByteArray512 = .{ .x = @as([32]u8, @splat(2)) ++ @as([32]u8, @splat(3)) };

    var group: std.Io.Group = .init;
    var result: ByteArray512 = undefined;
    group.async(io, concatByteArraysResultPtr, .{ a, b, &result });
    try group.await(io);
    try std.testing.expectEqualSlices(u8, &expected.x, &result.x);
}

fn returnArray() [32]u8 {
    return @splat(5);
}

test "async with array return type" {
    var win_io: WinIo = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer win_io.deinit();
    const io = win_io.io();

    var future = io.async(returnArray, .{});
    const result = future.await(io);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(5)), &result);
}

test "cancel blocked read from pipe" {
    const global = struct {
        fn readFromPipe(io: Io, pipe: Io.File) !void {
            var buf: [1]u8 = undefined;
            if (pipe.readStreaming(io, &.{&buf})) |_| {
                return error.UnexpectedData;
            } else |err| switch (err) {
                error.Canceled => return,
                else => |e| return e,
            }
        }
    };

    var win_io: WinIo = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
    });
    defer win_io.deinit();
    const io = win_io.io();

    // The original test uses `Threaded.windowsCreatePipe` (NtCreateNamedPipeFile).
    // An anonymous pipe from the documented `CreatePipe` is also synchronous, so
    // the blocked read can only be interrupted by something like `CancelSynchronousIo`.
    var read_handle: ?win.HANDLE = null;
    var write_handle: ?win.HANDLE = null;
    if (win.CreatePipe(&read_handle, &write_handle, null, 0) == 0) return error.CreatePipeFailed;
    const read_end: Io.File = .{ .handle = read_handle.?, .flags = .{ .nonblocking = false } };
    const write_end: Io.File = .{ .handle = write_handle.?, .flags = .{ .nonblocking = false } };
    defer {
        read_end.close(io);
        write_end.close(io);
    }

    var future = io.concurrent(global.readFromPipe, .{ io, read_end }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    defer _ = future.cancel(io) catch {};
    try io.sleep(.fromMilliseconds(10), .awake);
    try future.cancel(io);
}

test "memory mapping fallback" {
    var win_io: WinIo = .init(std.testing.allocator, .{
        .argv0 = .empty,
        .environ = .empty,
        .disable_memory_mapping = true,
    });
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "blah.txt",
        .data = "this is my data123",
    });

    {
        var file = try tmp.dir.openFile(io, "blah.txt", .{ .mode = .read_write });
        defer file.close(io);

        // The `Io.File.MemoryMap` API does not specify what happens if we supply a
        // length greater than file size, but this is testing specifically the
        // fallback path taken with disable_memory_mapping = true.
        var mm = try file.createMemoryMap(io, .{ .len = "this is my data123".len + 3 });
        defer mm.destroy(io);

        try testing.expectEqualStrings("this is my data123\x00\x00\x00", mm.memory);
        mm.memory[4] = '9';
        mm.memory[7] = '9';

        try mm.write(io);
    }

    var buffer: [100]u8 = undefined;
    const updated_contents = try tmp.dir.readFile(io, "blah.txt", &buffer);
    try testing.expectEqualStrings("this9is9my data123\x00\x00\x00", updated_contents);

    {
        var file = try tmp.dir.openFile(io, "blah.txt", .{ .mode = .read_only });
        defer file.close(io);

        var mm = try file.createMemoryMap(io, .{
            .len = "this9is9my".len,
            .protection = .{ .read = true },
        });
        defer mm.destroy(io);

        try testing.expectEqualStrings("this9is9my", mm.memory);

        const new_len = "this9is9my data123".len;
        mm.setLength(io, new_len) catch |err| switch (err) {
            error.OperationUnsupported => {
                mm.destroy(io);
                mm = try file.createMemoryMap(io, .{ .len = new_len });
            },
            else => |e| return e,
        };
        try mm.read(io);

        try testing.expectEqualStrings("this9is9my data123", mm.memory);
    }
}
