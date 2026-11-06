const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_arch = .x86_64, .os_tag = .windows },
    });
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option([]const []const u8, "test-filter", "Skip tests that do not match any filter") orelse &.{};
    const std_io = b.option(StdIo, "io", "Io implementation backing std.testing.io in test-std (default: win)") orelse .win;

    // No target or optimize mode: the module inherits them from the module
    // that imports it. Non-Windows targets are rejected by a compile error in
    // src/win_io.zig, so cross-platform projects can depend on win_io and
    // only import it when targeting Windows.
    const mod = b.addModule("win_io", .{
        .root_source_file = b.path("src/win_io.zig"),
    });

    // Everything below is for this project's own tests, so projects that
    // depend on win_io never fetch the Zig source.
    if (!b.isRoot()) return;

    // Zig's source release (binary releases strip std's tests). Passing the
    // version string keeps Zig's build.zig from looking for a git checkout.
    const zig_src = b.lazyDependency("zig", .{
        .@"version-string" = @as([]const u8, "0.17.0"),
    }) orelse return;

    // A copy of its lib directory with std/testing.zig patched so that
    // src/test_runner.zig can back `std.testing.io` with WinIo.
    const patch_zig_lib = b.addExecutable(.{
        .name = "patch_zig_lib",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/patch_zig_lib.zig"),
            .target = b.graph.host,
        }),
    });
    const run_patch_zig_lib = b.addRunArtifact(patch_zig_lib);
    run_patch_zig_lib.addDirectoryArg(zig_src.path("lib"));
    const zig_lib = run_patch_zig_lib.addOutputDirectoryArg("lib");

    // Unit tests of this project. They use the same test runner as test-std
    // for its OS resource leak checks, which needs the patched zig lib and a
    // `win_io` import in the root module.
    const mod_test_module = b.createModule(.{
        .root_source_file = b.path("src/win_io.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod_test_module.addImport("win_io", mod_test_module);
    const mod_tests = b.addTest(.{
        .root_module = mod_test_module,
        .filters = test_filters,
        .zig_lib_dir = zig_lib,
        .test_runner = .{ .path = b.path("src/test_runner.zig"), .mode = .server },
    });
    const test_step = b.step("test", "Run win_io unit tests (use -fwine on Linux)");
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // The standard library's own tests, compiled against the patched zig lib
    // so that `std.testing.io` can be backed by WinIo.
    const std_tests = b.addTest(.{
        .name = b.fmt("std-{t}", .{std_io}),
        .root_module = b.createModule(.{
            .root_source_file = zig_lib.path(b, "std/std.zig"),
            .target = target,
            .optimize = optimize,
            // A custom test runner inherits the root module's imports.
            .imports = &.{
                .{ .name = "win_io", .module = mod },
            },
        }),
        .filters = test_filters,
        .zig_lib_dir = zig_lib,
        .test_runner = switch (std_io) {
            .win => .{ .path = b.path("src/test_runner.zig"), .mode = .server },
            .threaded => null,
        },
    });
    const test_std_step = b.step("test-std", "Run std tests with std.testing.io = -Dio (use -fwine on Linux)");
    test_std_step.dependOn(&b.addRunArtifact(std_tests).step);

    const install_std_tests = b.addInstallArtifact(std_tests, .{});
    const install_std_tests_step = b.step("install-test-std", "Install the std test executable to zig-out/bin");
    install_std_tests_step.dependOn(&install_std_tests.step);
}

const StdIo = enum {
    /// This project's Win32-based implementation.
    win,
    /// Stock `std.Io.Threaded`, for baseline comparison.
    threaded,
};
