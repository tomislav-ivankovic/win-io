//! What `WinIo.deinit` and `WinIo.deinitWithOptions` release. `dnsapi.dll` and
//! `iphlpapi.dll` are imported, so they never need to be freed; only Winsock
//! does, and `cleanup_winsock = false` leaves it initialized so that
//! `deinit` cannot deadlock on the loader lock.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const win = @import("../win_api.zig");

const WinIo = @import("../win_io.zig");

/// Starts Winsock (by listening on a socket) and calls `iphlpapi.dll` (by
/// resolving an interface name) through `io`.
fn useNetworking(io: Io) !void {
    const address: Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    server.deinit(io);
    const name: Io.net.Interface.Name = try .fromSlice("win-io-none");
    _ = name.resolve(io) catch |err| switch (err) {
        error.InterfaceNotFound => {},
        else => |e| return e,
    };
}

/// Whether Winsock is initialized, checked by creating a socket.
fn winsockStarted() bool {
    const socket = win.socket(win.AF_INET, win.SOCK_STREAM, 0);
    if (@intFromPtr(socket) == win.INVALID_SOCKET) {
        std.debug.assert(win.WSAGetLastError() == .NOTINITIALISED);
        return false;
    }
    _ = win.closesocket(socket);
    return true;
}

fn moduleLoaded(comptime name: []const u8) bool {
    return win.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral(name)) != null;
}

test "dnsapi and iphlpapi are loaded with the program" {
    try testing.expect(moduleLoaded("dnsapi.dll"));
    try testing.expect(moduleLoaded("iphlpapi.dll"));
}

test "deinit releases Winsock" {
    try testing.expect(!winsockStarted());

    var win_io: WinIo = .init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    try useNetworking(win_io.io());
    try testing.expect(winsockStarted());
    win_io.deinit();

    try testing.expect(!winsockStarted());
}

test "deinitWithOptions without cleaning up Winsock leaves only Winsock behind" {
    try testing.expect(!winsockStarted());

    var win_io: WinIo = .init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
    try useNetworking(win_io.io());
    win_io.deinitWithOptions(.{ .cleanup_winsock = false });

    try testing.expect(winsockStarted());
    // Release it, as the leak check requires. Anything else left behind
    // (handles, threads, modules, mapped views) fails the leak check.
    try testing.expectEqual(0, win.WSACleanup());
    try testing.expect(!winsockStarted());
}
