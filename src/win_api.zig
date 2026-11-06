//! Win32 API bindings used by `win_io.zig`: only documented, stable functions
//! from `kernel32`, `ws2_32`, `bcrypt`, `iphlpapi`, `dnsapi` and the
//! synchronization API set.
//!
//! Flag parameters are plain `u32` values combined from the constants below.
//! Error codes are non-exhaustive enums, so any code returned by the system is
//! a valid value even if it has no name here.

const std = @import("std");

// ---------------------------------------------------------------------------
// Basic types

pub const BOOL = i32;
pub const BOOLEAN = u8;
pub const TRUE: BOOL = 1;
pub const FALSE: BOOL = 0;

/// Same type as `std.os.windows.HANDLE`, so that `std.Io.File.Handle` and
/// `std.Io.Dir.Handle` can be passed directly.
pub const HANDLE = *anyopaque;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const HMODULE = *opaque {};
pub const FARPROC = *const fn () callconv(.winapi) isize;

pub const FILETIME = extern struct {
    dwLowDateTime: u32,
    dwHighDateTime: u32,
};

pub const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: BOOL,
};

pub const OVERLAPPED = extern struct {
    Internal: usize,
    InternalHigh: usize,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: u32,
            OffsetHigh: u32,
        },
        Pointer: ?*anyopaque,
    },
    hEvent: ?HANDLE,
};

pub const LPOVERLAPPED_COMPLETION_ROUTINE = *const fn (
    dwErrorCode: u32,
    dwNumberOfBytesTransfered: u32,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) void;

pub const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,

    /// Parses `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
    pub fn parse(comptime s: *const [36]u8) GUID {
        const hex = struct {
            fn int(comptime T: type, comptime digits: []const u8) T {
                return std.fmt.parseInt(T, digits, 16) catch @compileError("invalid GUID: " ++ s);
            }
        };
        if (s[8] != '-' or s[13] != '-' or s[18] != '-' or s[23] != '-') @compileError("invalid GUID: " ++ s);
        var data4: [8]u8 = undefined;
        for (&data4, [8]usize{ 19, 21, 24, 26, 28, 30, 32, 34 }) |*byte, i| byte.* = hex.int(u8, s[i..][0..2]);
        return .{
            .Data1 = hex.int(u32, s[0..8]),
            .Data2 = hex.int(u16, s[9..13]),
            .Data3 = hex.int(u16, s[14..18]),
            .Data4 = data4,
        };
    }
};

// ---------------------------------------------------------------------------
// Errors

/// System error codes returned by `GetLastError`.
pub const WIN32_ERROR = enum(u32) {
    NO_ERROR = 0,
    ERROR_INVALID_FUNCTION = 1,
    ERROR_FILE_NOT_FOUND = 2,
    ERROR_PATH_NOT_FOUND = 3,
    ERROR_TOO_MANY_OPEN_FILES = 4,
    ERROR_ACCESS_DENIED = 5,
    ERROR_INVALID_HANDLE = 6,
    ERROR_NOT_ENOUGH_MEMORY = 8,
    ERROR_BAD_FORMAT = 11,
    ERROR_NOT_SAME_DEVICE = 17,
    ERROR_NO_MORE_FILES = 18,
    ERROR_WRITE_PROTECT = 19,
    ERROR_NOT_READY = 21,
    ERROR_SEEK = 25,
    ERROR_SHARING_VIOLATION = 32,
    ERROR_LOCK_VIOLATION = 33,
    ERROR_HANDLE_EOF = 38,
    ERROR_HANDLE_DISK_FULL = 39,
    ERROR_NOT_SUPPORTED = 50,
    ERROR_BAD_NETPATH = 53,
    ERROR_UNEXP_NET_ERR = 59,
    ERROR_BAD_NET_NAME = 67,
    ERROR_FILE_EXISTS = 80,
    ERROR_INVALID_PARAMETER = 87,
    ERROR_BROKEN_PIPE = 109,
    ERROR_DISK_FULL = 112,
    ERROR_INSUFFICIENT_BUFFER = 122,
    ERROR_INVALID_NAME = 123,
    ERROR_NEGATIVE_SEEK = 131,
    ERROR_DIR_NOT_EMPTY = 145,
    ERROR_NOT_LOCKED = 158,
    ERROR_BAD_PATHNAME = 161,
    ERROR_LOCK_FAILED = 167,
    ERROR_ALREADY_EXISTS = 183,
    ERROR_INVALID_STARTING_CODESEG = 188,
    ERROR_INVALID_STACKSEG = 189,
    ERROR_INVALID_MODULETYPE = 190,
    ERROR_INVALID_EXE_SIGNATURE = 191,
    ERROR_EXE_MARKED_INVALID = 192,
    ERROR_BAD_EXE_FORMAT = 193,
    ERROR_ITERATED_DATA_EXCEEDS_64k = 194,
    ERROR_INVALID_MINALLOCSIZE = 195,
    ERROR_DYNLINK_FROM_INVALID_RING = 196,
    ERROR_IOPL_NOT_ENABLED = 197,
    ERROR_INVALID_SEGDPL = 198,
    ERROR_AUTODATASEG_EXCEEDS_64k = 199,
    ERROR_RING2SEG_MUST_BE_MOVABLE = 200,
    ERROR_RELOC_CHAIN_XEEDS_SEGLIM = 201,
    ERROR_INFLOOP_IN_RELOC_CHAIN = 202,
    ERROR_ENVVAR_NOT_FOUND = 203,
    ERROR_FILENAME_EXCED_RANGE = 206,
    ERROR_EXE_MACHINE_TYPE_MISMATCH = 216,
    ERROR_VIRUS_INFECTED = 225,
    ERROR_VIRUS_DELETED = 226,
    ERROR_PIPE_BUSY = 231,
    ERROR_NO_DATA = 232,
    ERROR_PIPE_NOT_CONNECTED = 233,
    ERROR_MORE_DATA = 234,
    ERROR_DIRECTORY = 267,
    ERROR_OPERATION_ABORTED = 995,
    ERROR_IO_PENDING = 997,
    ERROR_UNRECOGNIZED_VOLUME = 1005,
    ERROR_FILE_INVALID = 1006,
    ERROR_NOT_FOUND = 1168,
    ERROR_USER_MAPPED_FILE = 1224,
    ERROR_UNIDENTIFIED_ERROR = 1287,
    ERROR_PRIVILEGE_NOT_HELD = 1314,
    ERROR_NO_SYSTEM_RESOURCES = 1450,
    ERROR_WORKING_SET_QUOTA = 1453,
    ERROR_COMMITMENT_LIMIT = 1455,
    ERROR_INVALID_USER_BUFFER = 1784,
    ERROR_NOT_ENOUGH_QUOTA = 1816,
    ERROR_CANT_RESOLVE_FILENAME = 1921,
    ERROR_NOT_A_REPARSE_POINT = 4390,
    _,
};

/// Windows Sockets error codes returned by `WSAGetLastError`, without the
/// `WSA` prefix.
pub const WSA_ERROR = enum(i32) {
    OPERATION_ABORTED = 995,
    IO_PENDING = 997,
    EACCES = 10013,
    EFAULT = 10014,
    EINVAL = 10022,
    EMFILE = 10024,
    EWOULDBLOCK = 10035,
    EINPROGRESS = 10036,
    EALREADY = 10037,
    EMSGSIZE = 10040,
    EPROTOTYPE = 10041,
    ENOPROTOOPT = 10042,
    EPROTONOSUPPORT = 10043,
    ESOCKTNOSUPPORT = 10044,
    EAFNOSUPPORT = 10047,
    EADDRINUSE = 10048,
    EADDRNOTAVAIL = 10049,
    ENETDOWN = 10050,
    ENETUNREACH = 10051,
    ENETRESET = 10052,
    ECONNABORTED = 10053,
    ECONNRESET = 10054,
    ENOBUFS = 10055,
    ENOTCONN = 10057,
    ESHUTDOWN = 10058,
    ETIMEDOUT = 10060,
    ECONNREFUSED = 10061,
    EHOSTUNREACH = 10065,
    EPROCLIM = 10067,
    SYSNOTREADY = 10091,
    NOTINITIALISED = 10093,
    EDISCON = 10101,
    SYSCALLFAILURE = 10107,
    _,
};

/// `NTSTATUS` stored in `OVERLAPPED.Internal` while an operation is in progress.
pub const STATUS_PENDING: usize = 0x103;

pub extern "kernel32" fn GetLastError() callconv(.winapi) WIN32_ERROR;

// ---------------------------------------------------------------------------
// Handles, waiting and synchronization

pub const INFINITE: u32 = std.math.maxInt(u32);
pub const WAIT_OBJECT_0: u32 = 0x0;
pub const WAIT_IO_COMPLETION: u32 = 0xC0;
pub const WAIT_TIMEOUT: u32 = 0x102;

pub const HANDLE_FLAG_INHERIT: u32 = 0x1;
pub const DUPLICATE_SAME_ACCESS: u32 = 0x2;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: HANDLE,
    hSourceHandle: HANDLE,
    hTargetProcessHandle: HANDLE,
    lpTargetHandle: *?HANDLE,
    dwDesiredAccess: u32,
    bInheritHandle: BOOL,
    dwOptions: u32,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: u32, dwFlags: u32) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
pub extern "kernel32" fn WaitForSingleObjectEx(hHandle: HANDLE, dwMilliseconds: u32, bAlertable: BOOL) callconv(.winapi) u32;
pub extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
pub extern "kernel32" fn SleepEx(dwMilliseconds: u32, bAlertable: BOOL) callconv(.winapi) u32;

pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*SECURITY_ATTRIBUTES,
    bManualReset: BOOL,
    bInitialState: BOOL,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

/// Documented as part of `Synchronization.lib`, which forwards to this API set.
pub extern "api-ms-win-core-synch-l1-2-0" fn WaitOnAddress(
    Address: *const volatile anyopaque,
    CompareAddress: *const anyopaque,
    AddressSize: usize,
    dwMilliseconds: u32,
) callconv(.winapi) BOOL;
pub extern "api-ms-win-core-synch-l1-2-0" fn WakeByAddressSingle(Address: *const anyopaque) callconv(.winapi) void;
pub extern "api-ms-win-core-synch-l1-2-0" fn WakeByAddressAll(Address: *const anyopaque) callconv(.winapi) void;

// ---------------------------------------------------------------------------
// Threads and processes

pub const ALL_PROCESSOR_GROUPS: u16 = 0xFFFF;

pub const THREAD_TERMINATE: u32 = 0x0001;
pub const THREAD_SET_CONTEXT: u32 = 0x0010;
pub const STACK_SIZE_PARAM_IS_A_RESERVATION: u32 = 0x00010000;

pub const CREATE_SUSPENDED: u32 = 0x00000004;
pub const CREATE_UNICODE_ENVIRONMENT: u32 = 0x00000400;
pub const CREATE_NO_WINDOW: u32 = 0x08000000;
pub const STARTF_USESTDHANDLES: u32 = 0x00000100;

pub const LPTHREAD_START_ROUTINE = *const fn (lpThreadParameter: ?*anyopaque) callconv(.winapi) u32;
pub const PAPCFUNC = *const fn (Parameter: usize) callconv(.winapi) void;

pub const STARTUPINFOW = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE,
    hStdOutput: ?HANDLE,
    hStdError: ?HANDLE,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: HANDLE,
    hThread: HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

pub const PROCESS_MEMORY_COUNTERS = extern struct {
    cb: u32,
    PageFaultCount: u32,
    PeakWorkingSetSize: usize,
    WorkingSetSize: usize,
    QuotaPeakPagedPoolUsage: usize,
    QuotaPagedPoolUsage: usize,
    QuotaPeakNonPagedPoolUsage: usize,
    QuotaNonPagedPoolUsage: usize,
    PagefileUsage: usize,
    PeakPagefileUsage: usize,
};

pub extern "kernel32" fn GetActiveProcessorCount(GroupNumber: u16) callconv(.winapi) u32;

pub extern "kernel32" fn CreateThread(
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    dwStackSize: usize,
    lpStartAddress: LPTHREAD_START_ROUTINE,
    lpParameter: ?*anyopaque,
    dwCreationFlags: u32,
    lpThreadId: ?*u32,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn OpenThread(dwDesiredAccess: u32, bInheritHandle: BOOL, dwThreadId: u32) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetCurrentThread() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetCurrentThreadId() callconv(.winapi) u32;
pub extern "kernel32" fn QueueUserAPC(pfnAPC: PAPCFUNC, hThread: HANDLE, dwData: usize) callconv(.winapi) u32;
pub extern "kernel32" fn GetThreadTimes(
    hThread: HANDLE,
    lpCreationTime: *FILETIME,
    lpExitTime: *FILETIME,
    lpKernelTime: *FILETIME,
    lpUserTime: *FILETIME,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetCurrentProcess() callconv(.winapi) HANDLE;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
pub extern "kernel32" fn GetProcessTimes(
    hProcess: HANDLE,
    lpCreationTime: *FILETIME,
    lpExitTime: *FILETIME,
    lpKernelTime: *FILETIME,
    lpUserTime: *FILETIME,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: u32,
    lpEnvironment: ?*const anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn K32GetProcessMemoryInfo(Process: HANDLE, ppsmemCounters: *PROCESS_MEMORY_COUNTERS, cb: u32) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Process environment

pub const STD_HANDLE = enum(u32) {
    INPUT = @bitCast(@as(i32, -10)),
    OUTPUT = @bitCast(@as(i32, -11)),
    ERROR = @bitCast(@as(i32, -12)),
};

/// Returns `INVALID_HANDLE_VALUE` on failure and null if there is no handle.
pub extern "kernel32" fn GetStdHandle(nStdHandle: STD_HANDLE) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: ?[*]u16, nSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetEnvironmentStringsW() callconv(.winapi) ?[*:0]u16;
pub extern "kernel32" fn FreeEnvironmentStringsW(penv: [*:0]u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetCurrentDirectoryW(nBufferLength: u32, lpBuffer: [*]u16) callconv(.winapi) u32;
pub extern "kernel32" fn SetCurrentDirectoryW(lpPathName: [*:0]const u16) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetSystemDirectoryW(lpBuffer: [*]u16, uSize: u32) callconv(.winapi) u32;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?HMODULE;
pub extern "kernel32" fn GetModuleFileNameW(hModule: ?HMODULE, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetProcAddress(hModule: HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?FARPROC;

// ---------------------------------------------------------------------------
// System information, time and random numbers

pub const SYSTEM_INFO = extern struct {
    wProcessorArchitecture: u16,
    wReserved: u16,
    dwPageSize: u32,
    lpMinimumApplicationAddress: ?*anyopaque,
    lpMaximumApplicationAddress: ?*anyopaque,
    dwActiveProcessorMask: usize,
    dwNumberOfProcessors: u32,
    dwProcessorType: u32,
    dwAllocationGranularity: u32,
    wProcessorLevel: u16,
    wProcessorRevision: u16,
};

pub extern "kernel32" fn GetSystemInfo(lpSystemInfo: *SYSTEM_INFO) callconv(.winapi) void;
pub extern "kernel32" fn GetSystemTimePreciseAsFileTime(lpSystemTimeAsFileTime: *FILETIME) callconv(.winapi) void;
pub extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
pub extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) BOOL;

pub const BCRYPT_USE_SYSTEM_PREFERRED_RNG: u32 = 0x00000002;

/// Returns an `NTSTATUS`.
pub extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pbBuffer: [*]u8, cbBuffer: u32, dwFlags: u32) callconv(.winapi) i32;

// ---------------------------------------------------------------------------
// Files

pub const GENERIC_READ: u32 = 0x80000000;
pub const GENERIC_WRITE: u32 = 0x40000000;
pub const DELETE: u32 = 0x00010000;
pub const READ_CONTROL: u32 = 0x00020000;
pub const SYNCHRONIZE: u32 = 0x00100000;
pub const FILE_LIST_DIRECTORY: u32 = 0x0001;
pub const FILE_READ_EA: u32 = 0x0008;
pub const FILE_TRAVERSE: u32 = 0x0020;
pub const FILE_READ_ATTRIBUTES: u32 = 0x0080;
pub const FILE_WRITE_ATTRIBUTES: u32 = 0x0100;

pub const FILE_SHARE_READ: u32 = 0x1;
pub const FILE_SHARE_WRITE: u32 = 0x2;
pub const FILE_SHARE_DELETE: u32 = 0x4;

pub const FILE_ATTRIBUTE_READONLY: u32 = 0x1;
pub const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
pub const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
pub const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
pub const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;

pub const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
pub const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
pub const FILE_FLAG_FIRST_PIPE_INSTANCE: u32 = 0x00080000;
pub const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;

pub const FILE_TYPE_DISK: u32 = 0x1;
pub const FILE_TYPE_PIPE: u32 = 0x3;

pub const FILE_NAME_NORMALIZED: u32 = 0x0;

pub const LOCKFILE_FAIL_IMMEDIATELY: u32 = 0x1;
pub const LOCKFILE_EXCLUSIVE_LOCK: u32 = 0x2;

pub const MOVEFILE_REPLACE_EXISTING: u32 = 0x1;

pub const SYMBOLIC_LINK_FLAG_DIRECTORY: u32 = 0x1;
pub const SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE: u32 = 0x2;

pub const FIND_FIRST_EX_LARGE_FETCH: u32 = 0x2;

pub const FSCTL_SET_REPARSE_POINT: u32 = 0x000900A4;
pub const FSCTL_GET_REPARSE_POINT: u32 = 0x000900A8;
pub const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
pub const IO_REPARSE_TAG_SYMLINK: u32 = 0xA000000C;

pub const FILE_CREATION_DISPOSITION = enum(u32) {
    CREATE_NEW = 1,
    CREATE_ALWAYS = 2,
    OPEN_EXISTING = 3,
    OPEN_ALWAYS = 4,
    TRUNCATE_EXISTING = 5,
};

/// `dwMoveMethod` of `SetFilePointerEx`: `FILE_BEGIN`, `FILE_CURRENT`, `FILE_END`.
pub const FILE_MOVE_METHOD = enum(u32) {
    BEGIN = 0,
    CURRENT = 1,
    END = 2,
};

pub const FILE_INFO_BY_HANDLE_CLASS = enum(u32) {
    FileBasicInfo = 0,
    FileStandardInfo = 1,
    FileNameInfo = 2,
    FileRenameInfo = 3,
    FileDispositionInfo = 4,
    FileAllocationInfo = 5,
    FileEndOfFileInfo = 6,
    FileStreamInfo = 7,
    FileCompressionInfo = 8,
    FileAttributeTagInfo = 9,
    FileIdBothDirectoryInfo = 10,
    FileIdBothDirectoryRestartInfo = 11,
    FileIoPriorityHintInfo = 12,
    FileRemoteProtocolInfo = 13,
    FileFullDirectoryInfo = 14,
    FileFullDirectoryRestartInfo = 15,
    FileStorageInfo = 16,
    FileAlignmentInfo = 17,
    FileIdInfo = 18,
    FileIdExtdDirectoryInfo = 19,
    FileIdExtdDirectoryRestartInfo = 20,
    FileDispositionInfoEx = 21,
    FileRenameInfoEx = 22,
    FileCaseSensitiveInfo = 23,
    FileNormalizedNameInfo = 24,
};

pub const FINDEX_INFO_LEVELS = enum(u32) {
    Standard = 0,
    Basic = 1,
};

pub const FINDEX_SEARCH_OPS = enum(u32) {
    NameMatch = 0,
    LimitToDirectories = 1,
    LimitToDevices = 2,
};

pub const BY_HANDLE_FILE_INFORMATION = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    dwVolumeSerialNumber: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    nNumberOfLinks: u32,
    nFileIndexHigh: u32,
    nFileIndexLow: u32,
};

pub const FILE_BASIC_INFO = extern struct {
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    FileAttributes: u32,
};

pub const FILE_NAME_INFO = extern struct {
    FileNameLength: u32,
    FileName: [1]u16,
};

pub const FILE_DISPOSITION_INFO = extern struct {
    DeleteFile: BOOLEAN,
};

pub const FILE_DISPOSITION_INFO_EX = extern struct {
    Flags: u32,
};
pub const FILE_DISPOSITION_FLAG_DELETE: u32 = 0x1;
pub const FILE_DISPOSITION_FLAG_POSIX_SEMANTICS: u32 = 0x2;
pub const FILE_DISPOSITION_FLAG_IGNORE_READONLY_ATTRIBUTE: u32 = 0x10;

pub const FILE_END_OF_FILE_INFO = extern struct {
    EndOfFile: i64,
};

pub const FILE_ATTRIBUTE_TAG_INFO = extern struct {
    FileAttributes: u32,
    ReparseTag: u32,
};

pub const FILE_ID_BOTH_DIR_INFO = extern struct {
    NextEntryOffset: u32,
    FileIndex: u32,
    CreationTime: i64,
    LastAccessTime: i64,
    LastWriteTime: i64,
    ChangeTime: i64,
    EndOfFile: i64,
    AllocationSize: i64,
    FileAttributes: u32,
    FileNameLength: u32,
    EaSize: u32,
    ShortNameLength: i8,
    ShortName: [12]u16,
    FileId: i64,
    FileName: [1]u16,
};

pub const WIN32_FIND_DATAW = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

/// Returns `INVALID_HANDLE_VALUE` on failure.
pub extern "kernel32" fn CreateFileW(
    lpFileName: [*:0]const u16,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: FILE_CREATION_DISPOSITION,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn CreateDirectoryW(lpPathName: [*:0]const u16, lpSecurityAttributes: ?*SECURITY_ATTRIBUTES) callconv(.winapi) BOOL;
pub extern "kernel32" fn MoveFileExW(lpExistingFileName: [*:0]const u16, lpNewFileName: ?[*:0]const u16, dwFlags: u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn CreateSymbolicLinkW(lpSymlinkFileName: [*:0]const u16, lpTargetFileName: [*:0]const u16, dwFlags: u32) callconv(.winapi) BOOLEAN;

pub extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn ReadFileEx(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpOverlapped: *OVERLAPPED,
    lpCompletionRoutine: LPOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn WriteFileEx(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpOverlapped: *OVERLAPPED,
    lpCompletionRoutine: LPOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFilePointerEx(
    hFile: HANDLE,
    liDistanceToMove: i64,
    lpNewFilePointer: ?*i64,
    dwMoveMethod: FILE_MOVE_METHOD,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileType(hFile: HANDLE) callconv(.winapi) u32;
pub extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
pub extern "kernel32" fn GetFileInformationByHandle(hFile: HANDLE, lpFileInformation: *BY_HANDLE_FILE_INFORMATION) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFileInformationByHandleEx(
    hFile: HANDLE,
    FileInformationClass: FILE_INFO_BY_HANDLE_CLASS,
    lpFileInformation: *anyopaque,
    dwBufferSize: u32,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetFileInformationByHandle(
    hFile: HANDLE,
    FileInformationClass: FILE_INFO_BY_HANDLE_CLASS,
    lpFileInformation: *const anyopaque,
    dwBufferSize: u32,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetFinalPathNameByHandleW(hFile: HANDLE, lpszFilePath: [*]u16, cchFilePath: u32, dwFlags: u32) callconv(.winapi) u32;
pub extern "kernel32" fn GetFullPathNameW(
    lpFileName: [*:0]const u16,
    nBufferLength: u32,
    lpBuffer: [*]u16,
    lpFilePart: ?*?[*:0]u16,
) callconv(.winapi) u32;
pub extern "kernel32" fn LockFileEx(
    hFile: HANDLE,
    dwFlags: u32,
    dwReserved: u32,
    nNumberOfBytesToLockLow: u32,
    nNumberOfBytesToLockHigh: u32,
    lpOverlapped: *OVERLAPPED,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn UnlockFileEx(
    hFile: HANDLE,
    dwReserved: u32,
    nNumberOfBytesToUnlockLow: u32,
    nNumberOfBytesToUnlockHigh: u32,
    lpOverlapped: *OVERLAPPED,
) callconv(.winapi) BOOL;

/// Returns `INVALID_HANDLE_VALUE` on failure.
pub extern "kernel32" fn FindFirstFileExW(
    lpFileName: [*:0]const u16,
    fInfoLevelId: FINDEX_INFO_LEVELS,
    lpFindFileData: *anyopaque,
    fSearchOp: FINDEX_SEARCH_OPS,
    lpSearchFilter: ?*anyopaque,
    dwAdditionalFlags: u32,
) callconv(.winapi) HANDLE;
pub extern "kernel32" fn FindNextFileW(hFindFile: HANDLE, lpFindFileData: *WIN32_FIND_DATAW) callconv(.winapi) BOOL;
pub extern "kernel32" fn FindClose(hFindFile: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Device I/O and asynchronous I/O

pub extern "kernel32" fn DeviceIoControl(
    hDevice: HANDLE,
    dwIoControlCode: u32,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: u32,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: u32,
    lpBytesReturned: ?*u32,
    lpOverlapped: ?*OVERLAPPED,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn GetOverlappedResult(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
    lpNumberOfBytesTransferred: *u32,
    bWait: BOOL,
) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelIoEx(hFile: HANDLE, lpOverlapped: ?*OVERLAPPED) callconv(.winapi) BOOL;
pub extern "kernel32" fn CancelSynchronousIo(hThread: HANDLE) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Pipes

pub const PIPE_ACCESS_INBOUND: u32 = 0x1;
pub const PIPE_ACCESS_OUTBOUND: u32 = 0x2;
pub const PIPE_TYPE_BYTE: u32 = 0x0;
pub const PIPE_READMODE_BYTE: u32 = 0x0;
pub const PIPE_WAIT: u32 = 0x0;

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *?HANDLE,
    hWritePipe: *?HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: u32,
) callconv(.winapi) BOOL;

/// Returns `INVALID_HANDLE_VALUE` on failure.
pub extern "kernel32" fn CreateNamedPipeW(
    lpName: [*:0]const u16,
    dwOpenMode: u32,
    dwPipeMode: u32,
    nMaxInstances: u32,
    nOutBufferSize: u32,
    nInBufferSize: u32,
    nDefaultTimeOut: u32,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
) callconv(.winapi) HANDLE;

// ---------------------------------------------------------------------------
// Memory mapping

pub const PAGE_READONLY: u32 = 0x02;
pub const PAGE_READWRITE: u32 = 0x04;
pub const PAGE_EXECUTE_READ: u32 = 0x20;
pub const PAGE_EXECUTE_READWRITE: u32 = 0x40;

pub const FILE_MAP_WRITE: u32 = 0x0002;
pub const FILE_MAP_READ: u32 = 0x0004;
pub const FILE_MAP_EXECUTE: u32 = 0x0020;

pub const WIN32_MEMORY_RANGE_ENTRY = extern struct {
    VirtualAddress: *anyopaque,
    NumberOfBytes: usize,
};

pub extern "kernel32" fn CreateFileMappingW(
    hFile: HANDLE,
    lpFileMappingAttributes: ?*SECURITY_ATTRIBUTES,
    flProtect: u32,
    dwMaximumSizeHigh: u32,
    dwMaximumSizeLow: u32,
    lpName: ?[*:0]const u16,
) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn MapViewOfFile(
    hFileMappingObject: HANDLE,
    dwDesiredAccess: u32,
    dwFileOffsetHigh: u32,
    dwFileOffsetLow: u32,
    dwNumberOfBytesToMap: usize,
) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn UnmapViewOfFile(lpBaseAddress: *const anyopaque) callconv(.winapi) BOOL;
pub extern "kernel32" fn PrefetchVirtualMemory(
    hProcess: HANDLE,
    NumberOfEntries: usize,
    VirtualAddresses: [*]WIN32_MEMORY_RANGE_ENTRY,
    Flags: u32,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Console

pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x4;

pub extern "kernel32" fn GetConsoleMode(hConsoleHandle: HANDLE, lpMode: *u32) callconv(.winapi) BOOL;
pub extern "kernel32" fn SetConsoleMode(hConsoleHandle: HANDLE, dwMode: u32) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// Windows Sockets

pub const SOCKET = *opaque {};
pub const INVALID_SOCKET: usize = std.math.maxInt(usize);

pub const AF_UNIX: i32 = 1;
pub const AF_INET: i32 = 2;
pub const AF_INET6: i32 = 23;

pub const SOCK_STREAM: i32 = 1;
pub const SOCK_DGRAM: i32 = 2;

pub const SOL_SOCKET: i32 = 0xffff;
pub const SO_REUSEADDR: i32 = 0x0004;
pub const SO_BROADCAST: i32 = 0x0020;
pub const SO_UPDATE_ACCEPT_CONTEXT: i32 = 0x700B;
pub const SO_UPDATE_CONNECT_CONTEXT: i32 = 0x7010;
pub const IPPROTO_IPV6: i32 = 41;
pub const IPV6_V6ONLY: i32 = 27;

pub const WSA_FLAG_OVERLAPPED: u32 = 0x01;
pub const WSA_FLAG_NO_HANDLE_INHERIT: u32 = 0x80;

pub const MSG_OOB: u32 = 0x1;
pub const MSG_PEEK: u32 = 0x2;

pub const SD_RECEIVE: i32 = 0;
pub const SD_SEND: i32 = 1;
pub const SD_BOTH: i32 = 2;

pub const SIO_GET_EXTENSION_FUNCTION_POINTER: u32 = 0xC8000006;
pub const WSAID_ACCEPTEX: GUID = .parse("b5367df1-cbac-11cf-95ca-00805f48a192");
pub const WSAID_CONNECTEX: GUID = .parse("25a207b9-ddf3-4660-8ee9-76e58c74063e");

pub const SOCKADDR = extern struct {
    sa_family: u16,
    sa_data: [14]u8,
};

/// `sockaddr_un` from `afunix.h`.
pub const SOCKADDR_UN = extern struct {
    sun_family: u16 = AF_UNIX,
    sun_path: [108]u8,
};

pub const WSABUF = extern struct {
    len: u32,
    buf: [*]u8,
};

pub const WSADATA = if (@sizeOf(usize) == 8) extern struct {
    wVersion: u16,
    wHighVersion: u16,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
} else extern struct {
    wVersion: u16,
    wHighVersion: u16,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?[*]u8,
};

pub const LPWSAOVERLAPPED_COMPLETION_ROUTINE = *const fn (
    dwError: u32,
    cbTransferred: u32,
    lpOverlapped: ?*OVERLAPPED,
    dwFlags: u32,
) callconv(.winapi) void;

/// `AcceptEx`, looked up with `WSAID_ACCEPTEX`.
pub const LPFN_ACCEPTEX = *const fn (
    sListenSocket: SOCKET,
    sAcceptSocket: SOCKET,
    lpOutputBuffer: *anyopaque,
    dwReceiveDataLength: u32,
    dwLocalAddressLength: u32,
    dwRemoteAddressLength: u32,
    lpdwBytesReceived: *u32,
    lpOverlapped: *OVERLAPPED,
) callconv(.winapi) BOOL;

/// `ConnectEx`, looked up with `WSAID_CONNECTEX`.
pub const LPFN_CONNECTEX = *const fn (
    s: SOCKET,
    name: *const SOCKADDR,
    namelen: i32,
    lpSendBuffer: ?*const anyopaque,
    dwSendDataLength: u32,
    lpdwBytesSent: ?*u32,
    lpOverlapped: *OVERLAPPED,
) callconv(.winapi) BOOL;

/// Returns 0 or a `WSA_ERROR` code.
pub extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.winapi) i32;
pub extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetLastError() callconv(.winapi) WSA_ERROR;

/// Returns `INVALID_SOCKET` on failure.
pub extern "ws2_32" fn WSASocketW(
    af: i32,
    @"type": i32,
    protocol: i32,
    lpProtocolInfo: ?*anyopaque,
    g: u32,
    dwFlags: u32,
) callconv(.winapi) SOCKET;
/// Returns `INVALID_SOCKET` on failure.
pub extern "ws2_32" fn socket(af: i32, @"type": i32, protocol: i32) callconv(.winapi) SOCKET;
pub extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
pub extern "ws2_32" fn bind(s: SOCKET, name: *const SOCKADDR, namelen: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn listen(s: SOCKET, backlog: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn connect(s: SOCKET, name: *const SOCKADDR, namelen: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn shutdown(s: SOCKET, how: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getsockname(s: SOCKET, name: *SOCKADDR, namelen: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getpeername(s: SOCKET, name: *SOCKADDR, namelen: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn setsockopt(s: SOCKET, level: i32, optname: i32, optval: ?[*]const u8, optlen: i32) callconv(.winapi) i32;
pub extern "ws2_32" fn getsockopt(s: SOCKET, level: i32, optname: i32, optval: [*]u8, optlen: *i32) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAIoctl(
    s: SOCKET,
    dwIoControlCode: u32,
    lpvInBuffer: ?*const anyopaque,
    cbInBuffer: u32,
    lpvOutBuffer: ?*anyopaque,
    cbOutBuffer: u32,
    lpcbBytesReturned: *u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;
pub extern "ws2_32" fn WSARecv(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesRecvd: ?*u32,
    lpFlags: *u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;
pub extern "ws2_32" fn WSARecvFrom(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesRecvd: ?*u32,
    lpFlags: *u32,
    lpFrom: ?*SOCKADDR,
    lpFromlen: ?*i32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;
pub extern "ws2_32" fn WSASend(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesSent: ?*u32,
    dwFlags: u32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;
pub extern "ws2_32" fn WSASendTo(
    s: SOCKET,
    lpBuffers: [*]WSABUF,
    dwBufferCount: u32,
    lpNumberOfBytesSent: ?*u32,
    dwFlags: u32,
    lpTo: ?*const SOCKADDR,
    iTolen: i32,
    lpOverlapped: ?*OVERLAPPED,
    lpCompletionRoutine: ?LPWSAOVERLAPPED_COMPLETION_ROUTINE,
) callconv(.winapi) i32;
pub extern "ws2_32" fn WSAGetOverlappedResult(
    s: SOCKET,
    lpOverlapped: *OVERLAPPED,
    lpcbTransfer: *u32,
    fWait: BOOL,
    lpdwFlags: *u32,
) callconv(.winapi) BOOL;

// ---------------------------------------------------------------------------
// IP Helper

pub extern "iphlpapi" fn ConvertInterfaceNameToLuidW(InterfaceName: [*:0]const u16, InterfaceLuid: *u64) callconv(.winapi) WIN32_ERROR;
pub extern "iphlpapi" fn ConvertInterfaceLuidToIndex(InterfaceLuid: *const u64, InterfaceIndex: *u32) callconv(.winapi) WIN32_ERROR;
pub extern "iphlpapi" fn ConvertInterfaceIndexToLuid(InterfaceIndex: u32, InterfaceLuid: *u64) callconv(.winapi) WIN32_ERROR;
pub extern "iphlpapi" fn ConvertInterfaceLuidToNameW(InterfaceLuid: *const u64, InterfaceName: [*]u16, Length: usize) callconv(.winapi) WIN32_ERROR;

// ---------------------------------------------------------------------------
// DNS. The record and query structures are the ones `std` uses.

pub const DNS = std.os.windows.DNS;

pub extern "dnsapi" fn DnsFree(pData: ?*anyopaque, FreeType: DNS.FREE_TYPE) callconv(.winapi) void;
/// `Options` is a `DWORD`, unlike `DnsQueryEx`'s `ULONG64` (`DNS.QUERY`);
/// passing a `DNS.QUERY` misaligns the stack on x86. Use `dnsQueryOptions`.
pub extern "dnsapi" fn DnsQuery_W(
    pszName: [*:0]const u16,
    wType: DNS.TYPE,
    Options: u32,
    pExtra: ?*anyopaque,
    ppQueryResults: *?*DNS.RECORD,
    pReserved: ?*anyopaque,
) callconv(.winapi) DNS.STATUS;

/// The `DnsQuery_W` options word: the low 32 bits of `DNS.QUERY`.
pub fn dnsQueryOptions(options: DNS.QUERY) u32 {
    return @truncate(@as(u64, @bitCast(options)));
}

/// `DnsQueryEx`, which is not exported by every `dnsapi.dll` (Wine lacks it),
/// so it is looked up with `GetProcAddress` instead of being imported.
pub const PFN_DNS_QUERY_EX = *const fn (
    pQueryRequest: *const DNS.QUERY.REQUEST,
    pQueryResults: *DNS.QUERY.RESULT,
    pCancelHandle: ?*DNS.QUERY.CANCEL,
) callconv(.winapi) DNS.STATUS;
