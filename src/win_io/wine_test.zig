//! Adapted versions of std tests that cannot pass under Wine because of how
//! Wine maps Windows semantics onto Linux. Each test checks what the original
//! checks, minus the part Linux cannot provide, and runs on Windows too
//! (asserting the original, stricter behavior there where it differs).
//!
//! Not adapted, because they test ntdll rather than `std.Io`:
//! - "Io.Threaded.test.toPrefixedFileW": Wine's `RtlGetFullPathName_U` keeps
//!   the trailing `\` of `\\server\share\` when `..` components climb past the
//!   share.
//! - "os.windows.nls.test.upcaseW matches RtlUpcaseUnicodeChar": Wine's case
//!   tables differ from Windows' (e.g. U+019B).
const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const net = Io.net;
const testing = std.testing;
const win = @import("../win_api.zig");
const windows = std.os.windows;

const WinIo = @import("../win_io.zig");

fn initWinIo() WinIo {
    return .init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
}

fn isWine() bool {
    const ntdll = win.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return false;
    return win.GetProcAddress(ntdll, "wine_get_version") != null;
}

// Adapted from "fs.test.max file name component lengths". The original uses
// `NAME_MAX` (255) WTF-16 code units of three-byte WTF-8 characters, which Wine
// stores as 765-byte UTF-8 names, but Linux limits names to 255 bytes. Here the
// WTF-16 limit is exercised with ASCII, and the three-byte encoding with the
// longest name of such characters that fits in 255 Linux bytes.
test "max file name component lengths" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const ascii: [windows.NAME_MAX]u8 = @splat('1');
    const euro = "€".*;
    const euros_buf: [255 / euro.len][euro.len]u8 = @splat(euro);
    const euros: []const u8 = @ptrCast(&euros_buf);
    try testFilenameLimits(io, tmp.dir, &ascii, euros);

    var tmp2 = testing.tmpDir(.{ .iterate = true });
    defer tmp2.cleanup();
    try testFilenameLimits(io, tmp2.dir, euros, &ascii);
}

/// Copy of `testFilenameLimits` from Zig's lib/std/fs/test.zig.
fn testFilenameLimits(io: Io, iterable_dir: Dir, maxed_filename: []const u8, maxed_dirname: []const u8) !void {
    // create a file, a dir, and a nested file all with maxed filenames
    {
        try iterable_dir.writeFile(io, .{ .sub_path = maxed_filename, .data = "" });

        var maxed_dir = try iterable_dir.createDirPathOpen(io, maxed_dirname, .{});
        defer maxed_dir.close(io);

        try maxed_dir.writeFile(io, .{ .sub_path = maxed_filename, .data = "" });
    }
    // Low level API with minimum buffer length
    {
        var reader_buf: [Dir.Reader.min_buffer_len]u8 align(@alignOf(usize)) = undefined;
        var reader: Dir.Reader = .init(iterable_dir, &reader_buf);

        var file_count: usize = 0;
        var dir_count: usize = 0;
        while (try reader.next(io)) |entry| {
            switch (entry.kind) {
                .file => {
                    try testing.expectEqualStrings(maxed_filename, entry.name);
                    file_count += 1;
                },
                .directory => {
                    try testing.expectEqualStrings(maxed_dirname, entry.name);
                    dir_count += 1;
                },
                else => return error.TestFailed,
            }
        }
        try testing.expectEqual(@as(usize, 1), file_count);
        try testing.expectEqual(@as(usize, 1), dir_count);
    }
    // High level walk API
    {
        var walker = try iterable_dir.walk(testing.allocator);
        defer walker.deinit();

        var file_count: usize = 0;
        var dir_count: usize = 0;
        while (try walker.next(io)) |entry| {
            switch (entry.kind) {
                .file => {
                    try testing.expectEqualStrings(maxed_filename, entry.basename);
                    file_count += 1;
                },
                .directory => {
                    try testing.expectEqualStrings(maxed_dirname, entry.basename);
                    dir_count += 1;
                },
                else => return error.TestFailed,
            }
        }
        try testing.expectEqual(@as(usize, 2), file_count);
        try testing.expectEqual(@as(usize, 1), dir_count);
    }

    // ensure that we can delete the tree
    try iterable_dir.deleteTree(io, maxed_filename);
}

// Adapted from "fs.test.read from locked file". Wine keeps byte-range locks in
// wineserver but reads with plain read(2), so locks never block reads (Linux
// has no mandatory locking). The lock taken by `createFile` must still be
// visible to other handles.
test "read from locked file" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const filename = "read_lock_file_test.txt";

    {
        const f = try tmp.dir.createFile(io, filename, .{ .read = true });
        defer f.close(io);
        var buffer: [1]u8 = undefined;
        _ = try f.readPositional(io, &.{&buffer}, 0);
    }
    {
        const f = try tmp.dir.createFile(io, filename, .{
            .read = true,
            .lock = .exclusive,
        });
        defer f.close(io);
        const f2 = try tmp.dir.openFile(io, filename, .{});
        defer f2.close(io);
        try testing.expect(!try f2.tryLock(io, .shared));
        try testing.expect(!try f2.tryLock(io, .exclusive));
        var buffer: [1]u8 = undefined;
        if (isWine()) {
            try testing.expectEqual(0, f2.readPositional(io, &.{&buffer}, 0));
        } else {
            try testing.expectError(error.LockViolation, f2.readPositional(io, &.{&buffer}, 0));
        }
    }
    // The lock is gone once its handle is closed.
    {
        const f = try tmp.dir.openFile(io, filename, .{});
        defer f.close(io);
        try testing.expect(try f.tryLock(io, .exclusive));
    }
}

// Adapted from "fs.test.readlink on Windows". The original reads the junctions
// a Windows installation has (`C:\Users\All Users` -> `C:\ProgramData`, ...),
// which a Wine prefix does not create. Here a junction to an absolute path is
// created with `FSCTL_SET_REPARSE_POINT` and read back the same way.
test "readlink on Windows" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "target", .default_dir);
    try tmp.dir.createDir(io, "junction", .default_dir);

    var tmp_path_buf: [Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp.dir.realPath(io, &tmp_path_buf)];
    const target_path = try Dir.path.join(testing.allocator, &.{ tmp_path, "target" });
    defer testing.allocator.free(target_path);
    const junction_path = try Dir.path.join(testing.allocator, &.{ tmp_path, "junction" });
    defer testing.allocator.free(junction_path);

    try makeJunction(junction_path, target_path);

    var buffer: [Dir.max_path_bytes]u8 = undefined;
    try testing.expectEqualStrings(target_path, buffer[0..try Dir.readLinkAbsolute(io, junction_path, &buffer)]);
    try testing.expectEqualStrings(target_path, buffer[0..try tmp.dir.readLink(io, "junction", &buffer)]);
}

/// Turns the empty directory `link_path` into a junction to `target_path`.
fn makeJunction(link_path: []const u8, target_path: []const u8) !void {
    const gpa = testing.allocator;
    const link_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, link_path);
    defer gpa.free(link_w);
    const nt_target = try std.mem.concat(gpa, u8, &.{ "\\??\\", target_path });
    defer gpa.free(nt_target);
    const substitute_w = try std.unicode.wtf8ToWtf16LeAlloc(gpa, nt_target);
    defer gpa.free(substitute_w);
    const print_w = try std.unicode.wtf8ToWtf16LeAlloc(gpa, target_path);
    defer gpa.free(print_w);

    const handle = win.CreateFileW(link_w.ptr, win.GENERIC_WRITE, 0, null, .OPEN_EXISTING, win.FILE_FLAG_BACKUP_SEMANTICS | win.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (handle == win.INVALID_HANDLE_VALUE) return error.Unexpected;
    defer _ = win.CloseHandle(handle);

    // REPARSE_DATA_BUFFER header, MOUNT_POINT_REPARSE_BUFFER, then both names,
    // each NUL-terminated.
    var buf: [windows.MAXIMUM_REPARSE_DATA_BUFFER_SIZE]u8 align(4) = undefined;
    const names_len = (substitute_w.len + 1 + print_w.len + 1) * 2;
    const data_len = 8 + names_len;
    std.mem.writeInt(u32, buf[0..4], win.IO_REPARSE_TAG_MOUNT_POINT, .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(data_len), .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u16, buf[8..10], 0, .little);
    std.mem.writeInt(u16, buf[10..12], @intCast(substitute_w.len * 2), .little);
    std.mem.writeInt(u16, buf[12..14], @intCast((substitute_w.len + 1) * 2), .little);
    std.mem.writeInt(u16, buf[14..16], @intCast(print_w.len * 2), .little);
    const names: []align(1) u16 = @ptrCast(buf[16..][0..names_len]);
    @memcpy(names[0..substitute_w.len], substitute_w);
    names[substitute_w.len] = 0;
    @memcpy(names[substitute_w.len + 1 ..][0..print_w.len], print_w);
    names[names.len - 1] = 0;

    var returned: u32 = 0;
    if (win.DeviceIoControl(handle, win.FSCTL_SET_REPARSE_POINT, &buf, @intCast(8 + data_len), null, 0, &returned, null) == 0)
        return error.Unexpected;
}

// Adapted from "Io.net.test.listen on an in use port". On Windows,
// `SO_REUSEADDR` lets a second socket listen on a port that is in use. Wine
// backs the socket with a Linux one, where `SO_REUSEADDR` never allows two
// listeners (that needs `SO_REUSEPORT`), and fails the bind with `WSAEACCES`.
// Under Wine this only checks that `reuse_address` reaches the socket.
test "listen on an in use port" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    const localhost: net.IpAddress = .{ .ip4 = .loopback(0) };

    var server1 = localhost.listen(io, .{ .reuse_address = true }) catch |err| switch (err) {
        error.NetworkDown => return error.SkipZigTest,
        else => |e| return e,
    };
    defer server1.deinit(io);
    try testing.expect(getReuseAddress(server1.socket));

    if (isWine()) return;
    var server2 = try server1.socket.address.listen(io, .{ .reuse_address = true });
    defer server2.deinit(io);
    try testing.expect(getReuseAddress(server2.socket));
}

test "listen without reuse_address" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    const localhost: net.IpAddress = .{ .ip4 = .loopback(0) };

    var server1 = localhost.listen(io, .{}) catch |err| switch (err) {
        error.NetworkDown => return error.SkipZigTest,
        else => |e| return e,
    };
    defer server1.deinit(io);
    try testing.expect(!getReuseAddress(server1.socket));

    try testing.expectError(error.AddressInUse, server1.socket.address.listen(io, .{}));
}

fn getReuseAddress(socket: net.Socket) bool {
    var value: u32 = 0;
    var len: i32 = @sizeOf(u32);
    if (win.getsockopt(@ptrCast(socket.handle), win.SOL_SOCKET, win.SO_REUSEADDR, @ptrCast(&value), &len) != 0) unreachable;
    return value != 0;
}
