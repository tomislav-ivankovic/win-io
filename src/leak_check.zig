//! Detects OS resources that a test leaves behind, which the testing allocator
//! cannot see: kernel handles (files, sockets, events, threads, sections, ...),
//! threads, loaded modules and mapped views. `src/test_runner.zig` takes a
//! `Snapshot` before initializing `std.testing.io` and compares it with one
//! taken after `deinit`.
//!
//! `GetProcessHandleCount` always reports 0 under Wine, so handles are
//! enumerated with `NtQueryInformationProcess(ProcessHandleSnapshotInformation)`,
//! or, if that is not implemented, with
//! `NtQuerySystemInformation(SystemExtendedHandleInformation)`, which Wine
//! implements.
const std = @import("std");
const windows = std.os.windows;
const HANDLE = windows.HANDLE;
const BOOL = windows.BOOL;

pub const Snapshot = struct {
    /// Sorted.
    handles: []Handle,
    /// Sorted.
    threads: []u32,
    /// Sorted.
    modules: []usize,
    /// Sorted base addresses of `MEM_MAPPED` allocations.
    views: []usize,

    pub const Handle = struct {
        value: usize,
        type_index: u16,

        fn lessThan(_: void, a: Handle, b: Handle) bool {
            return a.value < b.value;
        }
    };

    pub fn take(gpa: std.mem.Allocator) error{ OutOfMemory, Unexpected }!Snapshot {
        const threads = try takeThreads(gpa);
        errdefer gpa.free(threads);
        const modules = try takeModules(gpa);
        errdefer gpa.free(modules);
        const views = try takeViews(gpa);
        errdefer gpa.free(views);
        // Last, so that it does not see the temporary handles of the others.
        const handles = try takeHandles(gpa);
        return .{ .handles = handles, .threads = threads, .modules = modules, .views = views };
    }

    pub fn deinit(s: *Snapshot, gpa: std.mem.Allocator) void {
        gpa.free(s.handles);
        gpa.free(s.threads);
        gpa.free(s.modules);
        gpa.free(s.views);
        s.* = undefined;
    }

    /// Number of resources in `after` that are not in `before`, plus handles in
    /// `before` that are gone from `after` (closing a handle one does not own
    /// is a bug too). Up to `expected.file_handles` new `File` handles are not
    /// counted, but each one that is missing is.
    pub fn diffCount(before: *const Snapshot, after: *const Snapshot, expected: Expected) usize {
        var count: usize = 0;
        var files_left = expected.file_handles;
        for (after.handles) |h| if (!containsHandle(before.handles, h)) {
            if (files_left > 0 and isFileHandle(h.value)) {
                files_left -= 1;
            } else {
                count += 1;
            }
        };
        count += files_left;
        for (before.handles) |h| count += @intFromBool(!containsHandle(after.handles, h));
        for (after.threads) |t| count += @intFromBool(!contains(u32, before.threads, t));
        for (after.modules) |m| count += @intFromBool(!contains(usize, before.modules, m));
        for (after.views) |v| count += @intFromBool(!contains(usize, before.views, v));
        return count;
    }

    pub fn printDiff(before: *const Snapshot, after: *const Snapshot, expected: Expected) void {
        var buf: [256]u8 = undefined;
        const stderr = std.debug.lockStderr(&buf);
        defer std.debug.unlockStderr();
        const w = &stderr.file_writer.interface;
        printDiffTo(w, before, after, expected) catch {};
    }

    fn printDiffTo(w: *std.Io.Writer, before: *const Snapshot, after: *const Snapshot, expected: Expected) std.Io.Writer.Error!void {
        try w.writeAll("leaked OS resources:\n");
        var files_left = expected.file_handles;
        for (after.handles) |h| if (!containsHandle(before.handles, h)) {
            try w.print("  handle 0x{x}: ", .{h.value});
            try describeHandle(w, h.value);
            if (files_left > 0 and isFileHandle(h.value)) {
                files_left -= 1;
                try w.writeAll(" (expected)");
            }
            try w.writeByte('\n');
        };
        if (files_left > 0) {
            try w.print("  {d} of {d} expected leaked File handles not found; update the test runner's expected leaks\n", .{
                files_left, expected.file_handles,
            });
        }
        for (before.handles) |h| if (!containsHandle(after.handles, h)) {
            try w.print("  handle 0x{x}: closed, but was open before the test\n", .{h.value});
        };
        for (after.threads) |t| if (!contains(u32, before.threads, t)) {
            try w.print("  thread {d}: still running\n", .{t});
        };
        for (after.modules) |m| if (!contains(usize, before.modules, m)) {
            try w.print("  module 0x{x}: ", .{m});
            var name: [windows.PATH_MAX_WIDE]u16 = undefined;
            const len = GetModuleFileNameW(@ptrFromInt(m), &name, name.len);
            try w.print("{f}\n", .{std.unicode.fmtUtf16Le(name[0..len])});
        };
        for (after.views) |v| if (!contains(usize, before.views, v)) {
            try w.print("  mapped view at 0x{x}\n", .{v});
        };
        try w.flush();
    }
};

/// Creates OS state that is created lazily and then kept for the lifetime of
/// the thread or process, so that it is not reported as leaked by the first
/// test that triggers it. Call on the thread that runs the tests.
pub fn warmUp() void {
    // Wine's ws2_32 creates an event for the calling thread the first time a
    // socket call has to wait for wineserver (such as a failing `bind`), and
    // keeps it until the thread exits.
    var wsa_data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x0202, &wsa_data) == 0) {
        defer _ = WSACleanup();
        var address: [16]u8 = .{ AF_INET, 0, 0, 0, 127, 0, 0, 1 } ++ @as([8]u8, @splat(0));
        const first = socket(AF_INET, SOCK_STREAM, 0);
        defer _ = closesocket(first);
        const second = socket(AF_INET, SOCK_STREAM, 0);
        defer _ = closesocket(second);
        var len: i32 = address.len;
        if (bind(first, &address, address.len) == 0 and getsockname(first, &address, &len) == 0) {
            _ = bind(second, &address, address.len);
        }
    }

    // crypt32 loads its default cryptographic provider (rsaenh.dll), which
    // keeps it and a handle loaded for the lifetime of the process.
    const crypt32 = windows.crypt32;
    if (crypt32.CertOpenSystemStoreW(.NULL, std.unicode.utf8ToUtf16LeStringLiteral("ROOT"))) |store| {
        var context = crypt32.CertEnumCertificatesInStore(store, null);
        while (context) |c| context = crypt32.CertEnumCertificatesInStore(store, c);
        _ = crypt32.CertCloseStore(store, .{});
    }

    // On Windows, the first `BCryptGenRandom` loads bcryptprimitives.dll,
    // which keeps a handle to the CNG device and two ETW registrations, and
    // the second creates a wait completion packet.
    var random: [16]u8 = undefined;
    for (0..2) |_| _ = BCryptGenRandom(null, &random, random.len, BCRYPT_USE_SYSTEM_PREFERRED_RNG);

    // On Windows, `CreatePipe` opens `\Device\NamedPipe\` once and keeps the
    // handle.
    var pipe_read: HANDLE = undefined;
    var pipe_write: HANDLE = undefined;
    if (CreatePipe(&pipe_read, &pipe_write, null, 0).toBool()) {
        windows.CloseHandle(pipe_read);
        windows.CloseHandle(pipe_write);
    }

    // On Windows, the first DNS query connects to the DNS Client service and
    // keeps the connection (an ALPC port, a thread, events, ETW registrations).
    // Only the cache is queried, so nothing is sent over the network.
    var records: ?*anyopaque = null;
    const dns_name = std.unicode.utf8ToUtf16LeStringLiteral("win-io-leak-check.invalid");
    if (DnsQuery_W(dns_name, DNS_TYPE_A, DNS_QUERY_NO_WIRE_QUERY, null, &records, null) == 0) {
        DnsFree(records, DnsFreeRecordList);
    }

    // On Windows, the first `CreateProcessW` keeps a registry key and an ETW
    // registration.
    var command_line = std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe /c exit 0").*;
    var startup_info = std.mem.zeroes(windows.STARTUPINFOW);
    startup_info.cb = @sizeOf(windows.STARTUPINFOW);
    var process_info: windows.PROCESS.INFORMATION = undefined;
    if (CreateProcessW(null, &command_line, null, null, .FALSE, CREATE_NO_WINDOW, null, null, &startup_info, &process_info).toBool()) {
        _ = WaitForSingleObject(process_info.hProcess, INFINITE);
        windows.CloseHandle(process_info.hProcess);
        windows.CloseHandle(process_info.hThread);
    }
}

/// Takes snapshots until one matches `before` or `timeout_ms` passes, since
/// exiting threads release their resources asynchronously. Returns the number
/// of differences in the last snapshot, after printing them. Returns 0 if a
/// snapshot cannot be taken.
pub fn check(gpa: std.mem.Allocator, before: *const Snapshot, timeout_ms: u32, expected: Expected) usize {
    const start = GetTickCount64();
    while (true) {
        var after = Snapshot.take(gpa) catch return 0;
        defer after.deinit(gpa);
        const count = before.diffCount(&after, expected);
        if (count == 0) return 0;
        if (GetTickCount64() - start >= timeout_ms) {
            before.printDiff(&after, expected);
            return count;
        }
        Sleep(10);
    }
}

/// Resources that a test is known to leak, which then must leak exactly: an
/// expected leak that does not happen is reported too, so that fixed leaks get
/// their exception removed.
pub const Expected = struct {
    /// New handles of type `File` (files and directories).
    file_handles: usize = 0,
};

fn isFileHandle(value: usize) bool {
    var type_buf: [512]u8 align(@alignOf(windows.UNICODE_STRING)) = undefined;
    if (NtQueryObject(@ptrFromInt(value), .ObjectTypeInformation, &type_buf, type_buf.len, null) != .SUCCESS) {
        return false;
    }
    const type_name: *const windows.UNICODE_STRING = @ptrCast(&type_buf);
    const type_slice = type_name.Buffer.?[0 .. type_name.Length / 2];
    return std.mem.eql(u16, type_slice, std.unicode.utf8ToUtf16LeStringLiteral("File"));
}

fn contains(comptime T: type, sorted: []const T, x: T) bool {
    const S = struct {
        fn order(a: T, b: T) std.math.Order {
            return std.math.order(a, b);
        }
    };
    return std.sort.binarySearch(T, sorted, x, S.order) != null;
}

fn containsHandle(sorted: []const Snapshot.Handle, h: Snapshot.Handle) bool {
    const S = struct {
        fn order(a: Snapshot.Handle, b: Snapshot.Handle) std.math.Order {
            return std.math.order(a.value, b.value);
        }
    };
    const i = std.sort.binarySearch(Snapshot.Handle, sorted, h, S.order) orelse return false;
    // A handle value that was closed and reused for another kind of object.
    return sorted[i].type_index == h.type_index;
}

fn describeHandle(w: *std.Io.Writer, value: usize) std.Io.Writer.Error!void {
    const handle: HANDLE = @ptrFromInt(value);
    var type_buf: [512]u8 align(@alignOf(windows.UNICODE_STRING)) = undefined;
    if (NtQueryObject(handle, .ObjectTypeInformation, &type_buf, type_buf.len, null) != .SUCCESS) {
        return w.writeAll("unknown type");
    }
    const type_name: *const windows.UNICODE_STRING = @ptrCast(&type_buf);
    const type_slice = type_name.Buffer.?[0 .. type_name.Length / 2];
    try w.print("{f}", .{std.unicode.fmtUtf16Le(type_slice)});
    if (!std.mem.eql(u16, type_slice, std.unicode.utf8ToUtf16LeStringLiteral("File"))) return;

    // Only query the path of disk files: querying the name of a pipe can block.
    switch (GetFileType(handle)) {
        FILE_TYPE_DISK => {
            var path: [windows.PATH_MAX_WIDE]u16 = undefined;
            const len = GetFinalPathNameByHandleW(handle, &path, path.len, 0);
            if (len == 0 or len > path.len) return w.writeAll(" (disk)");
            try w.print(" {f}", .{std.unicode.fmtUtf16Le(path[0..len])});
        },
        FILE_TYPE_CHAR => try w.writeAll(" (character device)"),
        FILE_TYPE_PIPE => try w.writeAll(" (pipe or socket)"),
        else => try w.writeAll(" (unknown)"),
    }
}

fn takeHandles(gpa: std.mem.Allocator) error{ OutOfMemory, Unexpected }![]Snapshot.Handle {
    var list: std.ArrayList(Snapshot.Handle) = .empty;
    errdefer list.deinit(gpa);
    appendProcessHandles(gpa, &list) catch |err| switch (err) {
        error.Unsupported => try appendSystemHandles(gpa, &list),
        else => |e| return e,
    };
    std.mem.sort(Snapshot.Handle, list.items, {}, Snapshot.Handle.lessThan);
    return list.toOwnedSlice(gpa);
}

/// The process owns a handle to its current directory, which
/// `SetCurrentDirectoryW` replaces, so a test that changes the current
/// directory and restores it leaves a different handle open.
fn isCurrentDirectoryHandle(value: usize) bool {
    // Read as `usize` since it can be null.
    const cwd_handle: *const usize = @ptrCast(&windows.peb().ProcessParameters.CurrentDirectory.Handle);
    return value == cwd_handle.*;
}

/// Lists only this process's handles, which is much faster than
/// `appendSystemHandles` on Windows, where the system has tens of thousands of
/// handles.
fn appendProcessHandles(gpa: std.mem.Allocator, list: *std.ArrayList(Snapshot.Handle)) error{ OutOfMemory, Unexpected, Unsupported }!void {
    const Entry = extern struct {
        handle: usize,
        handle_count: usize,
        pointer_count: usize,
        granted_access: u32,
        object_type_index: u32,
        handle_attributes: u32,
        reserved: u32,
    };
    const Info = extern struct {
        count: usize,
        reserved: usize,
        // Followed by `count` entries.
    };
    const ProcessHandleSnapshotInformation = 51;

    var len: usize = 1 << 14;
    const buf = while (true) {
        const buf = try gpa.alignedAlloc(u8, .of(Entry), len);
        var needed: u32 = 0;
        switch (NtQueryInformationProcess(windows.GetCurrentProcess(), ProcessHandleSnapshotInformation, buf.ptr, @intCast(buf.len), &needed)) {
            .SUCCESS => break buf,
            .INFO_LENGTH_MISMATCH, .BUFFER_TOO_SMALL, .BUFFER_OVERFLOW => {
                gpa.free(buf);
                len = @max(len * 2, needed + (needed / 4));
            },
            else => {
                gpa.free(buf);
                return error.Unsupported;
            },
        }
    };
    defer gpa.free(buf);

    const info: *const Info = @ptrCast(buf.ptr);
    const entries: [*]const Entry = @ptrCast(buf.ptr + @sizeOf(Info));
    for (entries[0..info.count]) |e| {
        if (isCurrentDirectoryHandle(e.handle)) continue;
        try list.append(gpa, .{ .value = e.handle, .type_index = @intCast(e.object_type_index) });
    }
}

fn appendSystemHandles(gpa: std.mem.Allocator, list: *std.ArrayList(Snapshot.Handle)) error{ OutOfMemory, Unexpected }!void {
    const Entry = extern struct {
        object: ?*anyopaque,
        process_id: usize,
        handle: usize,
        granted_access: u32,
        creator_back_trace_index: u16,
        object_type_index: u16,
        handle_attributes: u32,
        reserved: u32,
    };
    const Info = extern struct {
        count: usize,
        reserved: usize,
        // Followed by `count` entries.
    };
    const SystemExtendedHandleInformation: windows.SYSTEM.INFORMATION_CLASS = @fromBackingInt(@intCast(64));

    var len: usize = 1 << 16;
    const buf = while (true) {
        const buf = try gpa.alignedAlloc(u8, .of(Entry), len);
        var needed: u32 = 0;
        switch (windows.ntdll.NtQuerySystemInformation(SystemExtendedHandleInformation, buf.ptr, @intCast(buf.len), &needed)) {
            .SUCCESS => break buf,
            .INFO_LENGTH_MISMATCH, .BUFFER_TOO_SMALL, .BUFFER_OVERFLOW => {
                gpa.free(buf);
                // Other processes can open handles in the meantime.
                len = @max(len * 2, needed + (needed / 4));
            },
            else => {
                gpa.free(buf);
                return error.Unexpected;
            },
        }
    };
    defer gpa.free(buf);

    const info: *const Info = @ptrCast(buf.ptr);
    const entries: [*]const Entry = @ptrCast(buf.ptr + @sizeOf(Info));
    const pid = GetCurrentProcessId();
    for (entries[0..info.count]) |e| {
        if (e.process_id != pid or isCurrentDirectoryHandle(e.handle)) continue;
        try list.append(gpa, .{ .value = e.handle, .type_index = e.object_type_index });
    }
}

fn takeThreads(gpa: std.mem.Allocator) error{ OutOfMemory, Unexpected }![]u32 {
    var list: std.ArrayList(u32) = .empty;
    errdefer list.deinit(gpa);
    appendProcessThreads(gpa, &list) catch |err| switch (err) {
        error.Unsupported => {
            list.clearRetainingCapacity();
            try appendSystemThreads(gpa, &list);
        },
        else => |e| return e,
    };
    std.mem.sort(u32, list.items, {}, std.sort.asc(u32));
    return list.toOwnedSlice(gpa);
}

/// Lists only this process's running threads, which is much faster than
/// `appendSystemThreads` on Windows.
fn appendProcessThreads(gpa: std.mem.Allocator, list: *std.ArrayList(u32)) error{ OutOfMemory, Unsupported }!void {
    const THREAD_QUERY_LIMITED_INFORMATION = 0x0800;
    const SYNCHRONIZE = 0x00100000;
    var thread: ?HANDLE = null;
    defer if (thread) |t| windows.CloseHandle(t);
    while (true) {
        var next: ?HANDLE = null;
        switch (NtGetNextThread(windows.GetCurrentProcess(), thread, THREAD_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, 0, 0, &next)) {
            .SUCCESS => {},
            .NO_MORE_ENTRIES => return,
            else => return error.Unsupported,
        }
        if (thread) |t| windows.CloseHandle(t);
        thread = next;
        // Threads that have exited but whose objects are still referenced.
        if (WaitForSingleObject(next.?, 0) == WAIT_OBJECT_0) continue;
        try list.append(gpa, GetThreadId(next.?));
    }
}

fn appendSystemThreads(gpa: std.mem.Allocator, list: *std.ArrayList(u32)) error{ OutOfMemory, Unexpected }!void {
    const snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
    if (snapshot == windows.INVALID_HANDLE_VALUE) return error.Unexpected;
    defer windows.CloseHandle(snapshot);

    const pid = GetCurrentProcessId();
    var entry: THREADENTRY32 = undefined;
    entry.dwSize = @sizeOf(THREADENTRY32);
    var ok = Thread32First(snapshot, &entry);
    while (ok.toBool()) : (ok = Thread32Next(snapshot, &entry)) {
        if (entry.th32OwnerProcessID == pid) try list.append(gpa, entry.th32ThreadID);
    }
}

fn takeModules(gpa: std.mem.Allocator) error{ OutOfMemory, Unexpected }![]usize {
    var modules: []windows.HMODULE = &.{};
    defer gpa.free(modules);
    while (true) {
        var needed: u32 = 0;
        if (!K32EnumProcessModules(windows.GetCurrentProcess(), modules.ptr, @intCast(modules.len * @sizeOf(windows.HMODULE)), &needed).toBool()) {
            return error.Unexpected;
        }
        const count = needed / @sizeOf(windows.HMODULE);
        if (count <= modules.len) {
            const result = try gpa.alloc(usize, count);
            for (result, modules[0..count]) |*r, m| r.* = @intFromPtr(m);
            std.mem.sort(usize, result, {}, std.sort.asc(usize));
            return result;
        }
        gpa.free(modules);
        modules = &.{};
        modules = try gpa.alloc(windows.HMODULE, count + 16);
    }
}

fn takeViews(gpa: std.mem.Allocator) error{OutOfMemory}![]usize {
    var list: std.ArrayList(usize) = .empty;
    errdefer list.deinit(gpa);
    var address: usize = 0;
    while (true) {
        var info: MEMORY_BASIC_INFORMATION = undefined;
        if (VirtualQuery(@ptrFromInt(address), &info, @sizeOf(MEMORY_BASIC_INFORMATION)) == 0) break;
        const base = @intFromPtr(info.BaseAddress);
        if (info.Type == MEM_MAPPED and base == @intFromPtr(info.AllocationBase)) {
            try list.append(gpa, base);
        }
        address = std.math.add(usize, base, info.RegionSize) catch break;
    }
    return list.toOwnedSlice(gpa);
}

const AF_INET = 2;
const BCRYPT_USE_SYSTEM_PREFERRED_RNG = 0x00000002;
const CREATE_NO_WINDOW = 0x08000000;
const DNS_TYPE_A = 0x0001;
const DNS_QUERY_NO_WIRE_QUERY = 0x00000010;
const DnsFreeRecordList = 1;
const INFINITE = 0xFFFFFFFF;
const WAIT_OBJECT_0 = 0;
const SOCK_STREAM = 1;
const SOCKET = usize;
const FILE_TYPE_CHAR = 0x0002;
const FILE_TYPE_DISK = 0x0001;
const FILE_TYPE_PIPE = 0x0003;
const MEM_MAPPED = 0x40000;
const TH32CS_SNAPTHREAD = 0x00000004;

// `PartitionId` exists only in the 64-bit layout.
const MEMORY_BASIC_INFORMATION = if (@sizeOf(usize) == 8) extern struct {
    BaseAddress: ?*anyopaque,
    AllocationBase: ?*anyopaque,
    AllocationProtect: u32,
    PartitionId: u16,
    RegionSize: usize,
    State: u32,
    Protect: u32,
    Type: u32,
} else extern struct {
    BaseAddress: ?*anyopaque,
    AllocationBase: ?*anyopaque,
    AllocationProtect: u32,
    RegionSize: usize,
    State: u32,
    Protect: u32,
    Type: u32,
};

const THREADENTRY32 = extern struct {
    dwSize: u32,
    cntUsage: u32,
    th32ThreadID: u32,
    th32OwnerProcessID: u32,
    tpBasePri: i32,
    tpDeltaPri: i32,
    dwFlags: u32,
};

const OBJECT_INFORMATION_CLASS = enum(c_int) {
    ObjectTypeInformation = 2,
    _,
};

extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern "kernel32" fn GetFileType(h: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetFinalPathNameByHandleW(h: HANDLE, path: [*]u16, len: u32, flags: u32) callconv(.winapi) u32;
extern "kernel32" fn GetModuleFileNameW(m: ?windows.HMODULE, name: [*]u16, len: u32) callconv(.winapi) u32;
extern "kernel32" fn K32EnumProcessModules(p: HANDLE, modules: [*]windows.HMODULE, cb: u32, needed: *u32) callconv(.winapi) BOOL;
extern "kernel32" fn VirtualQuery(address: ?*const anyopaque, info: *MEMORY_BASIC_INFORMATION, len: usize) callconv(.winapi) usize;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) HANDLE;
extern "kernel32" fn Thread32First(snapshot: HANDLE, entry: *THREADENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn Thread32Next(snapshot: HANDLE, entry: *THREADENTRY32) callconv(.winapi) BOOL;
extern "kernel32" fn CreatePipe(read: *HANDLE, write: *HANDLE, attributes: ?*anyopaque, size: u32) callconv(.winapi) BOOL;
extern "kernel32" fn CreateProcessW(
    application_name: ?[*:0]const u16,
    command_line: [*:0]u16,
    process_attributes: ?*anyopaque,
    thread_attributes: ?*anyopaque,
    inherit_handles: BOOL,
    flags: u32,
    environment: ?*anyopaque,
    current_directory: ?[*:0]const u16,
    startup_info: *windows.STARTUPINFOW,
    process_info: *windows.PROCESS.INFORMATION,
) callconv(.winapi) BOOL;
extern "kernel32" fn WaitForSingleObject(h: HANDLE, ms: u32) callconv(.winapi) u32;
extern "dnsapi" fn DnsQuery_W(name: [*:0]const u16, kind: u16, options: u32, extra: ?*anyopaque, results: *?*anyopaque, reserved: ?*anyopaque) callconv(.winapi) i32;
extern "dnsapi" fn DnsFree(data: ?*anyopaque, free_type: c_int) callconv(.winapi) void;
extern "bcrypt" fn BCryptGenRandom(algorithm: ?*anyopaque, buf: [*]u8, len: u32, flags: u32) callconv(.winapi) i32;
extern "kernel32" fn GetThreadId(thread: HANDLE) callconv(.winapi) u32;
extern "ntdll" fn NtGetNextThread(process: HANDLE, thread: ?HANDLE, access: u32, attributes: u32, flags: u32, next: *?HANDLE) callconv(.winapi) windows.NTSTATUS;
extern "ntdll" fn NtQueryInformationProcess(process: HANDLE, class: c_int, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) windows.NTSTATUS;
extern "ntdll" fn NtQueryObject(h: HANDLE, class: OBJECT_INFORMATION_CLASS, info: *anyopaque, len: u32, ret: ?*u32) callconv(.winapi) windows.NTSTATUS;
extern "ws2_32" fn WSAStartup(version: u16, data: *[512]u8) callconv(.winapi) i32;
extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, kind: i32, protocol: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn bind(s: SOCKET, address: *const [16]u8, len: i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(s: SOCKET, address: *[16]u8, len: *i32) callconv(.winapi) i32;
