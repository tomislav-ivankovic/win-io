//! Waits that could block forever: cancelation of tasks blocked in operations
//! that are interrupted by something other than `CancelSynchronousIo` or a
//! futex wake, and batches awaited from another thread. Each test unblocks
//! the operation after `rescue_ms` if it is still stuck, so that a regression
//! fails the test instead of hanging it.
const std = @import("std");
const Io = std.Io;
const testing = std.testing;
const win = @import("../win_api.zig");

const WinIo = @import("../win_io.zig");

const rescue_ms = 2000;
/// Cancelation is expected to take far less than this.
const max_cancel_ms = rescue_ms / 2;

fn initWinIo() WinIo {
    return .init(testing.allocator, .{ .argv0 = .empty, .environ = .empty });
}

/// Runs `rescueFn(context)` on another thread unless `stop` is called within
/// `rescue_ms`.
fn Watchdog(comptime Context: type, comptime rescueFn: fn (Context) void) type {
    return struct {
        context: Context,
        stop_event: win.HANDLE,
        thread: win.HANDLE,
        rescued: bool,

        const Self = @This();

        fn start(self: *Self, context: Context) !void {
            self.* = .{
                .context = context,
                .stop_event = win.CreateEventW(null, win.TRUE, win.FALSE, null) orelse return error.CreateEventFailed,
                .thread = undefined,
                .rescued = false,
            };
            errdefer _ = win.CloseHandle(self.stop_event);
            self.thread = win.CreateThread(null, 0, run, self, 0, null) orelse return error.CreateThreadFailed;
        }

        /// Returns whether the watchdog had to rescue.
        fn stop(self: *Self) bool {
            _ = win.SetEvent(self.stop_event);
            _ = win.WaitForSingleObject(self.thread, std.math.maxInt(u32));
            _ = win.CloseHandle(self.thread);
            _ = win.CloseHandle(self.stop_event);
            return self.rescued;
        }

        fn run(param: ?*anyopaque) callconv(.winapi) u32 {
            const self: *Self = @ptrCast(@alignCast(param));
            if (win.WaitForSingleObject(self.stop_event, rescue_ms) != 0) {
                self.rescued = true;
                rescueFn(self.context);
            }
            return 0;
        }
    };
}

fn millisecondsSince(start: u64) u64 {
    return win.GetTickCount64() - start;
}

/// A pipe whose read end is overlapped (`File.flags.nonblocking`).
const OverlappedPipe = struct {
    read_end: Io.File,
    write_end: win.HANDLE,

    var counter: std.atomic.Value(u32) = .init(0);

    fn create() !OverlappedPipe {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrintSentinel(&name_buf, "\\\\.\\pipe\\win-io-deadlock-test-{d}-{d}", .{
            win.GetCurrentProcessId(),
            counter.fetchAdd(1, .monotonic),
        }, 0);
        var name_w: [64:0]u16 = undefined;
        name_w[try std.unicode.utf8ToUtf16Le(&name_w, name)] = 0;
        const server = win.CreateNamedPipeW(&name_w, win.PIPE_ACCESS_INBOUND | win.FILE_FLAG_OVERLAPPED, 0, 1, 4096, 4096, 0, null);
        if (server == win.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        errdefer _ = win.CloseHandle(server);
        const client = win.CreateFileW(&name_w, win.GENERIC_WRITE, 0, null, .OPEN_EXISTING, 0, null);
        if (client == win.INVALID_HANDLE_VALUE) return error.CreatePipeFailed;
        return .{
            .read_end = .{ .handle = server, .flags = .{ .nonblocking = true } },
            .write_end = client,
        };
    }

    fn close(pipe: OverlappedPipe) void {
        _ = win.CloseHandle(pipe.read_end.handle);
        _ = win.CloseHandle(pipe.write_end);
    }

    fn writeByte(write_end: win.HANDLE) void {
        var written: u32 = 0;
        _ = win.WriteFile(write_end, "x", 1, &written, null);
    }
};

test "cancel Batch.awaitAsync blocked on a pipe read" {
    const global = struct {
        fn awaitBatchRead(io: Io, pipe: Io.File) !void {
            var storage: [1]Io.Operation.Storage = undefined;
            var batch: Io.Batch = .init(&storage);
            var buf: [1]u8 = undefined;
            batch.addAt(0, .{ .file_read_streaming = .{ .file = pipe, .data = &.{&buf} } });
            try batch.awaitAsync(io);
            return error.UnexpectedData;
        }
    };

    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    const pipe: OverlappedPipe = try .create();
    defer pipe.close();

    var watchdog: Watchdog(win.HANDLE, OverlappedPipe.writeByte) = undefined;
    try watchdog.start(pipe.write_end);

    var future = io.concurrent(global.awaitBatchRead, .{ io, pipe.read_end }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            _ = watchdog.stop();
            return error.SkipZigTest;
        },
    };
    try io.sleep(.fromMilliseconds(50), .awake);
    const start = win.GetTickCount64();
    const result = future.cancel(io);
    const elapsed = millisecondsSince(start);
    const rescued = watchdog.stop();

    try testing.expectError(error.Canceled, result);
    try testing.expect(!rescued);
    try testing.expect(elapsed < max_cancel_ms);
}

test "cancel blocked file lock" {
    const global = struct {
        fn lockFile(io: Io, dir: Io.Dir) !void {
            const file = try dir.openFile(io, "lock", .{ .lock = .exclusive });
            file.close(io);
            return error.LockAcquired;
        }

        fn closeHolder(handle: win.HANDLE) void {
            _ = win.CloseHandle(handle);
        }
    };

    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const holder = try tmp.dir.createFile(io, "lock", .{ .lock = .exclusive });

    var watchdog: Watchdog(win.HANDLE, global.closeHolder) = undefined;
    try watchdog.start(holder.handle);

    var future = io.concurrent(global.lockFile, .{ io, tmp.dir }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            if (!watchdog.stop()) holder.close(io);
            return error.SkipZigTest;
        },
    };
    try io.sleep(.fromMilliseconds(50), .awake);
    const start = win.GetTickCount64();
    const result = future.cancel(io);
    const elapsed = millisecondsSince(start);
    const rescued = watchdog.stop();
    if (!rescued) holder.close(io);

    try testing.expectError(error.Canceled, result);
    try testing.expect(!rescued);
    try testing.expect(elapsed < max_cancel_ms);
}

// A batch may be awaited by a different thread than the one that submitted
// its pending operations. Completions must not depend on the submitting
// thread (which is not alertable here) running an APC.
test "await Batch on another thread than the one that submitted" {
    const global = struct {
        fn awaitRest(
            io: Io,
            batch: *Io.Batch,
            thread: *std.atomic.Value(?win.HANDLE),
            done: *std.atomic.Value(bool),
        ) Io.Cancelable!void {
            thread.store(win.OpenThread(win.THREAD_SET_CONTEXT, win.FALSE, win.GetCurrentThreadId()), .release);
            defer done.store(true, .release);
            try batch.awaitAsync(io);
        }

        fn noopApc(_: usize) callconv(.winapi) void {}
    };

    var win_io = initWinIo();
    defer win_io.deinit();
    const io = win_io.io();

    const pipe0: OverlappedPipe = try .create();
    defer pipe0.close();
    const pipe1: OverlappedPipe = try .create();
    defer pipe1.close();

    var storage: [2]Io.Operation.Storage = undefined;
    var batch: Io.Batch = .init(&storage);
    var buf0: [1]u8 = undefined;
    var buf1: [1]u8 = undefined;
    batch.addAt(0, .{ .file_read_streaming = .{ .file = pipe0.read_end, .data = &.{&buf0} } });
    batch.addAt(1, .{ .file_read_streaming = .{ .file = pipe1.read_end, .data = &.{&buf1} } });

    // Submit both reads on this thread; only the first completes.
    OverlappedPipe.writeByte(pipe0.write_end);
    try batch.awaitAsync(io);
    {
        const completion = batch.next().?;
        try testing.expectEqual(0, completion.index);
        try testing.expectEqual(1, try completion.result.file_read_streaming);
        try testing.expect(batch.next() == null);
    }

    // Await the second read on a worker thread.
    var thread: std.atomic.Value(?win.HANDLE) = .init(null);
    var done: std.atomic.Value(bool) = .init(false);
    var future = io.concurrent(global.awaitRest, .{ io, &batch, &thread, &done }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => {
            batch.cancel(io);
            return error.SkipZigTest;
        },
    };
    try io.sleep(.fromMilliseconds(50), .awake);
    OverlappedPipe.writeByte(pipe1.write_end);

    // Wait without being alertable, so that APCs queued to this thread do not run.
    const start = win.GetTickCount64();
    while (!done.load(.acquire) and millisecondsSince(start) < rescue_ms) win.Sleep(10);
    const completed_in_time = done.load(.acquire);
    // Rescue: run the completion APC queued to this thread and wake the worker.
    while (!done.load(.acquire)) {
        _ = win.SleepEx(10, win.TRUE);
        if (thread.load(.acquire)) |handle| _ = win.QueueUserAPC(global.noopApc, handle, 0);
    }
    try future.await(io);
    if (thread.load(.acquire)) |handle| _ = win.CloseHandle(handle);

    try testing.expect(completed_in_time);
    const completion = batch.next().?;
    try testing.expectEqual(1, completion.index);
    try testing.expectEqual(1, try completion.result.file_read_streaming);
    try testing.expect(batch.next() == null);
}
