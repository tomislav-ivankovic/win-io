# win_io

A `std.Io` implementation for Windows (`src/win_io.zig`) that uses only the stable,
documented Win32 API, so Zig programs keep working under Wine. Behavior follows
`std.Io.Threaded` from Zig 0.17.0.

## Usage

Add the package to your project:

```sh
zig fetch --save=win_io <url-of-a-win_io-release-tarball-or-git-ref>
```

and import its `win_io` module in `build.zig`. The module has no target or
optimize mode of its own; it uses those of the module that imports it, so
there is nothing to pass to `b.dependency`:

```zig
const win_io = b.dependency("win_io", .{});
exe.root_module.addImport("win_io", win_io.module("win_io"));
```

The module only compiles for Windows targets. A cross-platform project can
still depend on it and add the import unconditionally, as long as it only
references the module when targeting Windows (for example behind
`if (builtin.os.tag == .windows)`).

```zig
const std = @import("std");
const WinIo = @import("win_io");

// Route std.debug output through WinIo too (see "Binary size and features").
pub const std_options_debug_io: std.Io = WinIo.global_single_threaded.io();

pub fn main(init: std.process.Init.Minimal) !void {
    var win_io: WinIo = .init(std.heap.smp_allocator, .{ .environ = init.environ });
    defer win_io.deinit();
    const io = win_io.io();
    // ...
}
```

`WinIo.InitOptions` is `std.Io.Threaded.InitOptions`.

`dnsapi.dll` and `iphlpapi.dll` are imported, so they are loaded and unloaded
with the module that contains WinIo; nothing is loaded or freed at run time.
(`DnsQueryEx`, which Wine may not export, is looked up in the loaded
`dnsapi.dll`.) The only thing `deinit` releases that can take the loader
lock is Winsock (`WSACleanup`, if the instance used sockets). If a thread
that `DllMain` waits for during `DLL_PROCESS_DETACH` deinitializes the
`WinIo`, that deadlocks. `deinitWithOptions(.{ .cleanup_winsock = false })`
skips `WSACleanup` instead, leaving one Winsock reference for the lifetime of
the process. `std.Io.Threaded` has no Winsock state, never unloads
`dnsapi.dll`, and unloads `iphlpapi.dll` in `deinit`, which takes the loader
lock.

Like `std.Io.Threaded`, there is a variant that needs no allocator and no
initialization call, for code that runs before an allocator exists (such as
`DllMain`). It never spawns threads: `async` runs tasks inline and `concurrent`
fails with `error.ConcurrencyUnavailable`. Spawning child processes needs an
allocator and fails with `error.OutOfMemory`.

```zig
var win_io: WinIo = .init_single_threaded; // or WinIo.global_single_threaded
const io = win_io.io();
```

## Binary size and features

std uses its own `std.Io.Threaded` in two places that a WinIo program does not
need. Each one compiles all of Threaded into the program next to WinIo:

- `std.debug` (`print`, panics, stack traces) uses `std.Options.debug_io`,
  which is `Threaded.global_single_threaded` by default. Declare
  `std_options_debug_io` in the root file, as in the example above.
- `main(init: std.process.Init)` makes `start.zig` create a Threaded instance
  for `init.io`. Take `std.process.Init.Minimal` instead, which has the
  arguments and environment, and pass WinIo an allocator.

For a ReleaseSmall program that writes "hi" to stdout, the first one is the
difference between 502.5 KiB and 190.5 KiB, and the second adds 46.5 KiB.

`io()` has every `std.Io` operation. `ioWithFeatures` only has the groups of
operations a program enables; the code of the others is not analyzed,
compiled or linked, so the program gets smaller and builds faster. Every
`Features` field defaults to `false`: list the ones the program uses
(`Features.all` enables every one).

```zig
const features: WinIo.Features = .{ .concurrency = true, .fs = true, .fs_modify = true };
pub const std_options_debug_io: std.Io = WinIo.global_single_threaded.ioWithFeatures(features);
// ...
const io = win_io.ioWithFeatures(features);
```

| `Features` field | Operations | Saved when disabled |
|---|---|---|
| `process_spawn` | `std.process.spawn` and `replace`, waiting for and killing children | 47.5 KiB |
| `dns` | host name lookups, network interface names; drops the `dnsapi.dll` and `iphlpapi.dll` imports | 14.5 KiB |
| `concurrency` | `async`/`Group.async` (then run inline), `concurrent`, `Group.concurrent` | 11.5 KiB |
| `net` | sockets; drops the `ws2_32.dll` import | 11.0 KiB |
| `fs` | everything that takes a path, and listing directories | 11.0 KiB |
| `fs_modify` | creating directories, deleting, renaming, links, atomic files, setting owners, permissions and timestamps; requires `fs` | 7.0 KiB |

Savings are for the ReleaseSmall program above with every other feature
enabled (190.5 KiB with `Features.all`, 93.5 KiB with `.{}`). Each group saves the
most in programs that do not use it at all. Always available: I/O on file and directory handles (stdio, inherited
handles, `Dir.cwd()`), clocks, sleeping, futexes and the primitives built on
them (`Io.Mutex`, `Io.Condition`, ...), randomness, cancelation, batches,
memory mapping, file locks, the executable and current paths, and stderr
locking.

Disabled operations behave like `std.Io.failing`: they return
`error.Unimplemented` or `error.OperationUnsupported` if their error set has
one, otherwise the error `std.Io.failing` returns, as if the file system were
empty and full and there were no network (`dirOpenFile` returns
`error.FileNotFound`, `dirCreateDir` `error.NoSpaceLeft`, `netListenIp`
`error.NetworkDown`, `concurrent` `error.ConcurrencyUnavailable`). Listing a
directory finds no entries. In Debug builds, each disabled operation logs a
warning the first time it is called. Without `concurrency`, `async` runs the
task before returning, as with `init_single_threaded`.

Use one feature set per instance. Operations on something that only an
enabled feature creates (awaiting a future, waiting for a child process,
closing a socket) are illegal behavior with the feature disabled: they panic
in Debug and ReleaseSafe builds.

There are no dependencies. All Win32 API bindings (functions, structures and
constants) are declared in `src/win_api.zig`, since std's `std.os.windows`
only binds what std itself uses:

```zig
const win = @import("win_api.zig");
```

## Differences from `std.Io.Threaded`

The structure (thread pool, futures, groups, the cancelation state machine,
batches) is ported from `std.Io.Threaded`. What differs is the OS interface:

| Area | `std.Io.Threaded` | `WinIo` |
|---|---|---|
| Futex, sleep | `NtWaitForAlertByThreadId` parking | `WaitOnAddress`, alertable `SleepEx` |
| Worker threads | `std.Thread` (`NtCreateThreadEx`) | `CreateThread` |
| Interrupting blocked calls | `NtCancelSynchronousIoFile`, `NtAlertThread` | `CancelSynchronousIo`, `QueueUserAPC`, `CancelIoEx` |
| File I/O | `NtReadFile`/`NtWriteFile` with APCs | `ReadFile`/`WriteFile`, `ReadFileEx`/`WriteFileEx` |
| Paths | `NtCreateFile` relative to a directory handle | absolute `\\?\` paths built from `GetFinalPathNameByHandleW`, `CreateFileW` |
| Directory listing | `NtQueryDirectoryFile` | `GetFileInformationByHandleEx(FileIdBothDirectoryInfo)` |
| Sockets | AFD driver ioctls | Winsock 2, overlapped (`AcceptEx`, `ConnectEx`, `WSARecv`, ...) |
| DNS | `DnsQueryEx` | `DnsQueryEx`, falling back to `DnsQuery_W` (Wine lacks `DnsQueryEx`) |
| Random | `\Device\CNG` ioctl | `BCryptGenRandom` |
| Child processes | named pipes via `NtCreateNamedPipeFile`, PEB environment | `CreateNamedPipeW`, `GetEnvironmentStringsW`, `FindFirstFileExW` |

Intentional behavior differences:

- Network receives and stream reads in an `Io.Batch` are overlapped, so
  `receiveTimeout` and friends work instead of returning
  `error.ConcurrencyUnavailable`. When `batchAwaitConcurrent` times out or is
  canceled, pending operations are canceled (`Io.operateTimeout` abandons the
  batch without calling `Batch.cancel`).
- Overlapped batch operations signal a per-batch event (kept in
  `Io.Batch.userdata` while operations are pending) instead of completing
  through APCs, so a batch with pending operations can be awaited or canceled
  from a different thread than the one that submitted them. With APCs, as in
  Threaded, the completions only run on the submitting thread.
- `File.MemoryMap` honors `offset` (Threaded maps from offset 0).
- `Dir.setPermissions`, `Dir.setFilePermissions` and `Dir.setTimestamps` are
  implemented (Threaded panics with TODO).
- Blocking file locks (`File.lock`, `.lock` without `lock_nonblocking`) poll
  `LockFileEx(LOCKFILE_FAIL_IMMEDIATELY)` with cancelable sleeps of up to
  16 ms, so waiters are not served in order. A blocking `LockFileEx` cannot
  be canceled under Wine.
- Renames use `MoveFileExW` and report replacing a directory with a file (or the
  reverse) as `error.IsDir`/`error.NotDir`.

## Testing

```sh
zig build test -fwine                    # this project's unit tests
zig build test-std -fwine                # std's tests with std.testing.io = WinIo
zig build test-std -fwine -Dio=threaded  # same tests with stock Threaded (baseline)
zig build test-std -fwine -Dtest-filter=fs.test -Dtest-filter=Io.net.test
zig build test -fwine -Dsingle-threaded  # as built by a -fsingle-threaded project
zig build test-features -fwine           # a program per WinIo.Features set
```

`test-features` builds a program with all features, with each one disabled
alone, and with none, and checks that the DLLs of disabled features are not
loaded.

On Windows, drop `-fwine`. `net.has_unix_sockets` is false unless the target's
minimum Windows version is at least 10 RS4, which the default `x86_64-windows`
target is not, so `AF_UNIX` code is only compiled and tested with a target such
as `-Dtarget=native` (`src/win_io/unix_socket_test.zig`; std's own Unix socket
tests skip Windows).

The tests are compiled against the Zig 0.17.0 source release (std test files
are stripped from binary releases), which `build.zig.zon` declares as a lazy
`zig` dependency. It is fetched on the first `zig build` of this project, but
never for projects that depend on `win_io`. At build time,
`tools/patch_zig_lib.zig` copies its `lib` directory into the cache and applies
one patch:

- `std/testing.zig`: `testing.io_instance` has type `root.TestingIo` if the
  test runner declares it, otherwise `Io.Threaded`.

The tool fails if the code it patches is not found exactly once, so upgrading
Zig cannot silently drop the patch.

`src/test_runner.zig` is a copy of Zig's `lib/compiler/test_runner.zig` that
declares `pub const TestingIo = @import("win_io");`. Requirements this puts on
`WinIo`: `init(gpa, Io.Threaded.InitOptions)`, `deinit()`, and an `io()` that is
comptime-callable (static vtable).

Both `test` and `test-std` use this runner, which also checks every test for
leaked OS resources, which the testing allocator cannot see
(`src/leak_check.zig`): it compares the process's kernel handles (by
`NtQueryInformationProcess`, or `NtQuerySystemInformation` if that is not
implemented, since Wine's `GetProcessHandleCount` always returns 0), threads,
loaded modules and mapped views before `testing.io` is initialized and after it
is deinitialized. New resources, and handles that were open before but are now
closed, count as leaks and are listed on stderr with handle types and file
paths. The process's current directory handle is ignored, since
`SetCurrentDirectoryW` replaces it. Before the first test, the runner creates
state that Wine, crypt32, bcrypt, `CreatePipe`, `CreateProcessW` and the DNS
client create lazily and keep for the lifetime of the thread or process, so
that it is not blamed on the first test that triggers it.

Not covered by `test-std`: tests that construct `Io.Threaded` directly or call
`std.os.windows` directly, and the runner's own I/O (`std.debug`, `std.Progress`),
which uses `Threaded.global_single_threaded`. The relevant tests from
`std/Io/Threaded/test.zig` are ported to `src/win_io/test.zig`, and
`src/win_io/process_test.zig` covers child processes (std has no unit tests
for them); both run with `zig build test`. `src/win_io/wine_test.zig` holds
adapted versions of the std tests that cannot pass under Wine (see below).

Most `fs.test` tests also run each case through a UNC path
(`\\127.0.0.1\Z$\...`). Wine has no admin shares, but it resolves
`\\server\share` through `$WINEPREFIX/dosdevices/unc/server/share`, so one
symlink per drive enables them (`Z:` is `/`, where the test tmp dirs are):

```sh
mkdir -p "${WINEPREFIX:-$HOME/.wine}/dosdevices/unc/127.0.0.1"
ln -s / "${WINEPREFIX:-$HOME/.wine}/dosdevices/unc/127.0.0.1/Z\$"
```

32-bit Windows is supported too: add `-Dtarget=x86-windows` to any of the
commands above.

### Results on Windows 11 (10.0.26200)

| | passed | skipped | failed |
|---|---|---|---|
| stock `Threaded` | 3254 | 70 | 0 |
| `WinIo` | 3257 | 67 | 0 |
| stock `Threaded`, `-Dtarget=x86-windows` (WoW64) | 3249 | 75 | 0 |
| `WinIo`, `-Dtarget=x86-windows` (WoW64) | 3252 | 72 | 0 |

`zig build test` passes (35 tests with `-Dtarget=native`, 33 and 2 skipped
without, and 33 and 2 skipped with `-Dtarget=x86-windows`). The five extra
skips on x86 are std's own 32-bit skips, the same for both implementations.
The only leak is the std one described below.

### Results under Wine 11.17

| | passed | skipped | failed |
|---|---|---|---|
| stock `Threaded` (`tests/baseline-threaded-wine.txt`) | 3209 | 66 | 48 + 1 crash |
| `WinIo` | 3236 | 66 | 22 |
| `WinIo`, with the UNC symlink | 3252 | 66 | 6 |
| stock `Threaded`, with the UNC symlink, `-Dtarget=x86-windows` | 3215 | 71 | 37 + 1 crash |
| `WinIo`, with the UNC symlink, `-Dtarget=x86-windows` | 3247 | 71 | 6 |

The x86 rows were measured with Wine 11.21, where the x86_64 `WinIo` results
are unchanged. On x86, Threaded fails the same tests as on x86_64, and both
implementations skip the same five 32-bit tests as on Windows. `zig build test`
passes on both targets (33 passed, 2 skipped).

The remaining `WinIo` failures cannot pass under Wine, so `src/test_runner.zig`
reports them as skipped when it detects Wine (ntdll exports `wine_get_version`);
the table counts them as failed. On Windows they run as usual. The first four have
adapted versions with the same names in `src/win_io/wine_test.zig`, which pass
under Wine and keep the original assertion on Windows:

- `fs.test.max file name component lengths`: uses 255 three-byte characters
  (765 UTF-8 bytes), but Linux limits names to 255 bytes. Adapted: 255 ASCII
  characters, and 85 three-byte ones.
- `fs.test.read from locked file`: Wine does not enforce byte-range locks on
  reads (Linux has no mandatory locking). Adapted: checks the lock from a
  second handle with `tryLock`.
- `fs.test.readlink on Windows`: reads `C:\Users\All Users` and similar
  junctions, which a Wine prefix does not have. Adapted: creates a junction
  with `FSCTL_SET_REPARSE_POINT` and reads it back.
- `Io.net.test.listen on an in use port`: on Linux, `SO_REUSEADDR` never
  allows two listeners, and Wine fails the second bind with `WSAEACCES`.
  Adapted: checks with `getsockopt` that the option is set; also
  `listen without reuse_address` checks for `error.AddressInUse`.
- `Io.Threaded.test.toPrefixedFileW`: Wine's `RtlGetFullPathName_U` keeps a
  trailing `\` when `..` climbs past a UNC share. Tests Threaded's path helper.
- `os.windows.nls.test.upcaseW matches RtlUpcaseUnicodeChar`: Wine's case
  tables differ from Windows' (first at U+019B). Tests a std helper against
  ntdll.

The last two do not involve `std.testing.io`, so they are not adapted.

The leak check reports one leak, in std: `fs.test.walker without fully
iterating` leaves a directory handle open, because `Dir.Walker.deinit` has no
`Io` to close the directories still on its stack (despite its documentation).
The test runner lists it as an expected leak (`expected_leaks` in
`src/test_runner.zig`), so that test must leak exactly one `File` handle: any
other leak, or the leak no longer happening, still fails it.
