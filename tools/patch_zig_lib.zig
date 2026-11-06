//! Build tool: `patch_zig_lib <zig lib dir> <output dir>`
//!
//! Copies Zig's lib directory and patches `std/testing.zig` so that the test
//! runner can choose the `Io` implementation behind `std.testing.io` by
//! declaring `pub const TestingIo`. Fails if the original code is not found
//! exactly once, so that a Zig upgrade cannot silently drop the patch.

const std = @import("std");
const Io = std.Io;

const testing_path = "std/testing.zig";

const original =
    \\pub var io_instance: Io.Threaded = undefined;
    \\
;

const replacement =
    \\/// win_io patch: the test runner may override the `Io` implementation behind
    \\/// `testing.io` by declaring `pub const TestingIo`. The type must provide
    \\/// `init(gpa, Io.Threaded.InitOptions)`, `deinit()`, and a comptime-callable `io()`.
    \\pub const IoInstance = if (builtin.is_test and @hasDecl(@import("root"), "TestingIo"))
    \\    @import("root").TestingIo
    \\else
    \\    Io.Threaded;
    \\pub var io_instance: IoInstance = undefined;
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) std.process.fatal("usage: {s} <zig lib dir> <output dir>", .{args[0]});

    var src = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer src.close(io);
    try Io.Dir.cwd().createDirPath(io, args[2]);
    var dst = try Io.Dir.cwd().openDir(io, args[2], .{});
    defer dst.close(io);

    var walker = try src.walk(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| switch (entry.kind) {
        .directory => try dst.createDirPath(io, entry.path),
        .file => try src.copyFile(entry.path, dst, entry.path, io, .{}),
        else => std.process.fatal("{s}: unexpected {t} in zig lib dir", .{ entry.path, entry.kind }),
    };

    const source = try src.readFileAlloc(io, testing_path, arena, .unlimited);
    const index = std.mem.indexOf(u8, source, original) orelse
        std.process.fatal("{s}: code to patch not found", .{testing_path});
    if (std.mem.indexOfPos(u8, source, index + original.len, original) != null)
        std.process.fatal("{s}: code to patch found more than once", .{testing_path});
    const patched = try std.mem.concat(arena, u8, &.{ source[0..index], replacement, source[index + original.len ..] });
    try dst.writeFile(io, .{ .sub_path = testing_path, .data = patched });
}
