//! `zig build release`: zips the ready-to-run app folder (zig-out/bin, without debug files and
//! without CEF files older builds left there)
//! into zig-out/zzz-zon-tool-windows.zip, inside a "zzz-zon-tool" folder.
//! Uses Windows' built-in tar (it writes .zip with -a); elsewhere `zip`.
//!
//!   package <bin-dir> <out-dir>

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.Usage;
    // absolute paths: the packer changes folder before writing the zip
    const bin = try std.Io.Dir.cwd().realPathFileAlloc(io, args[1], init.arena.allocator());
    const out_dir = try std.Io.Dir.cwd().realPathFileAlloc(io, args[2], init.arena.allocator());
    const out = try std.fs.path.join(gpa, &.{ out_dir, "zzz-zon-tool-windows.zip" });
    defer gpa.free(out);
    std.Io.Dir.cwd().deleteFile(io, out) catch {};

    const argv: []const []const u8 = if (builtin.os.tag == .windows)
        &.{ "tar", "-a", "-c", "-f", out, "-C", bin, "--exclude", "*.pdb", "--exclude", "dxcompiler.dll", "--exclude", "vk_swiftshader*", "--exclude", "vulkan-1.dll", "-s", ",^\\.,zzz-zon-tool,", "." }
    else
        &.{ "sh", "-c", try std.fmt.allocPrint(init.arena.allocator(), "cd '{s}/..' && rm -rf zzz-zon-tool && cp -al '{s}' zzz-zon-tool && zip -qr '{s}' zzz-zon-tool -x '*.pdb' '*dxcompiler.dll' '*vk_swiftshader*' '*vulkan-1.dll' && rm -rf zzz-zon-tool", .{ bin, bin, out }) };
    const r = try std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(1 << 20), .stderr_limit = .limited(1 << 20) });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    if (!r.term.success()) {
        std.debug.print("Packing failed:\n{s}{s}\n", .{ r.stdout, r.stderr });
        return error.PackFailed;
    }
    const st = try std.Io.Dir.cwd().statFile(io, out, .{});
    std.debug.print("Made {s} ({d} MB). Unzip it anywhere and run zzz-zon-tool.exe.\n", .{ out, st.size >> 20 });
}
