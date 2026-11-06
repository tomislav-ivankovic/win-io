//! Tests for process-related `WinIo` functions. The standard library has no
//! unit tests that spawn child processes, so these cover what
//! `zig build test-std` cannot.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;

const WinIo = @import("../win_io.zig");

fn initWinIo() WinIo {
    return .init(testing.allocator, .{ .environ = .{ .block = .global } });
}

test "run cmd.exe and capture stdout" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    const result = try std.process.run(testing.allocator, io, .{
        .argv = &.{ "cmd.exe", "/c", "echo hello" },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try testing.expectEqualStrings("hello", std.mem.trimEnd(u8, result.stdout, "\r\n"));
}

test "child exit code" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", "exit 3" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    try testing.expectEqual(std.process.Child.Term{ .exited = 3 }, try child.wait(io));
}

test "child reads stdin pipe" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ "findstr", "b" },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer child.kill(io);

    try child.stdin.?.writeStreamingAll(io, "abc\r\nxyz\r\n");
    child.stdin.?.close(io);
    child.stdin = null;

    var buffer: [64]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &buffer);
    const output = try reader.interface.allocRemaining(testing.allocator, .limited(1024));
    defer testing.allocator.free(output);
    try testing.expectEqualStrings("abc", std.mem.trimEnd(u8, output, "\r\n "));
    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, try child.wait(io));
}

test "child cwd and environment map" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp.dir.realPath(io, &tmp_path_buf)];

    var environ_map: std.process.Environ.Map = .init(testing.allocator);
    defer environ_map.deinit();
    try environ_map.put("ZIG_IO_TEST_VAR", "from-map");
    const result = try std.process.run(testing.allocator, io, .{
        .argv = &.{ "cmd.exe", "/c", "cd & echo %ZIG_IO_TEST_VAR%" },
        .cwd = .{ .dir = tmp.dir },
        .environ_map = &environ_map,
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
    try testing.expect(std.ascii.eqlIgnoreCase(tmp_path, lines.next().?));
    try testing.expectEqualStrings("from-map", std.mem.trimEnd(u8, lines.next().?, " "));
}

test "run batch script with quoted arguments" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "args.bat", .data = "@echo %~1\r\n" });

    const result = try std.process.run(testing.allocator, io, .{
        // Wine's cmd.exe does not handle the escaping of `&` and `%` in
        // arguments (see `argvToScriptCommandLineWindows`), so only spaces are tested.
        .argv = &.{ "args.bat", "hello world" },
        .cwd = .{ .dir = tmp.dir },
        .exe = .{ .path = tmp.dir },
    });
    defer testing.allocator.free(result.stdout);
    defer testing.allocator.free(result.stderr);

    try testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try testing.expectEqualStrings("hello world", std.mem.trimEnd(u8, result.stdout, "\r\n "));
}

test "spawn nonexistent program" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    try testing.expectError(error.FileNotFound, std.process.spawn(io, .{
        .argv = &.{"win-io-this-program-does-not-exist"},
    }));
}

test "kill child" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    // Waits for input that never arrives.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "cmd.exe", "/c", "set /p v=" },
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    child.kill(io);
    try testing.expect(child.id == null);
}

test "lock stderr" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var buffer: [16]u8 = undefined;
    const stderr = try io.lockStderr(&buffer, null);
    // Recursive locking from the same thread is allowed.
    const again = try io.lockStderr(&buffer, null);
    _ = again;
    io.unlockStderr();
    _ = stderr;
    io.unlockStderr();
    const try_locked = (try io.tryLockStderr(&buffer, .no_color)).?;
    _ = try_locked;
    io.unlockStderr();
}

test "executable path and current directory" {
    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var exe_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_path = exe_buf[0..try std.process.executablePath(io, &exe_buf)];
    try testing.expect(std.ascii.endsWithIgnoreCase(exe_path, ".exe"));
    const exe = try std.process.openExecutable(io, .{});
    exe.close(io);

    var original_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const original = original_buf[0..try std.process.currentPath(io, &original_buf)];
    defer std.process.setCurrentPath(io, original) catch {};

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var tmp_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = tmp_path_buf[0..try tmp.dir.realPath(io, &tmp_path_buf)];

    try std.process.setCurrentDir(io, tmp.dir);
    var cwd_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try std.process.currentPath(io, &cwd_buf)];
    try testing.expect(std.ascii.eqlIgnoreCase(tmp_path, cwd));
}
