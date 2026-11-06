//! `AF_UNIX` sockets. std's tests skip them on Windows
//! (https://codeberg.org/ziglang/zig/issues/31499), and `net.has_unix_sockets`
//! is false unless the target's minimum Windows version is at least 10 RS4, so
//! these only run with a target such as `-Dtarget=native`.
const std = @import("std");
const Io = std.Io;
const net = Io.net;
const testing = std.testing;

const WinIo = @import("../win_io.zig");

fn socketPath(io: Io, tmp: *const testing.TmpDir, buf: *[Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(io, buf);
    const suffix = "\\socket.unix";
    if (len + suffix.len > buf.len) return error.NameTooLong;
    @memcpy(buf[len..][0..suffix.len], suffix);
    return buf[0 .. len + suffix.len];
}

test "listen on a unix socket, send bytes, receive bytes" {
    if (!net.has_unix_sockets) return error.SkipZigTest;
    var win_io: WinIo = .init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const socket_path = try socketPath(io, &tmp, &path_buf);
    const socket_addr = try net.UnixAddress.init(socket_path);

    var server = socket_addr.listen(io, .{}) catch |err| switch (err) {
        error.AddressFamilyUnsupported => return error.SkipZigTest,
        else => |e| return e,
    };
    defer server.socket.close(io);

    const S = struct {
        fn clientFn(client_io: Io, path: []const u8) !void {
            const server_path: net.UnixAddress = try .init(path);
            var stream = try server_path.connect(client_io);
            defer stream.close(client_io);

            var stream_writer = stream.writer(client_io, &.{});
            try stream_writer.interface.writeAll("Hello world!");
        }
    };

    var client_task = io.concurrent(S.clientFn, .{ io, socket_path }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return error.SkipZigTest,
    };
    defer client_task.cancel(io) catch {};

    var stream = try server.accept(io);
    defer stream.close(io);

    var buf: [16]u8 = undefined;
    var stream_reader = stream.reader(io, &.{});
    const n = try stream_reader.interface.readSliceShort(&buf);

    try testing.expectEqualStrings("Hello world!", buf[0..n]);
    try client_task.await(io);
}

test "connect to a missing unix socket" {
    if (!net.has_unix_sockets) return error.SkipZigTest;
    var win_io: WinIo = .init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const socket_addr = try net.UnixAddress.init(try socketPath(io, &tmp, &path_buf));

    try testing.expectError(error.FileNotFound, socket_addr.connect(io));
}
