const std = @import("std");
const zglob = @import("zglob");

const Options = struct {};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Получаем аргументы командной строки
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        std.debug.print("Usage: {s} PATTERN FILE...\n", .{args[0]});
        return error.InvalidArguments;
    }

    var list = std.ArrayList([:0]const u8).init(allocator);
    defer list.deinit();
    try list.appendSlice(args[2..]);

    try grep(allocator, args[1], list, .{});
}

fn grep(allocator: std.mem.Allocator, pattern: [:0]const u8, file_names: std.ArrayList([:0]const u8), options: Options) !void {
    _ = options;

    for (file_names.items) |file_path| {
        const absolutePath = try std.fs.realpathAlloc(allocator, file_path);
        defer allocator.free(absolutePath);

        const file = try std.fs.openFileAbsolute(absolutePath, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var line_buf: [8192]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (std.mem.indexOf(u8, line, pattern)) |index| {
                std.debug.print("{s}:{d}: {s}\n", .{ absolutePath, index + 1, line });
            }
        }
    }
}

test "grep memory leeks" {
    const allocator = std.testing.allocator;
    const pattern: [:0]const u8 = "GeneralPurposeAllocator";

    const file_paths = [_][:0]const u8{ "../learning-zig-rus/src/ch06.md", "../learning-zig-rus/src/ch07.md", "../learning-zig-rus/src/ch08.md", "../learning-zig-rus/src/ch09.md" };

    var list = std.ArrayList([:0]const u8).init(allocator);
    defer list.deinit();
    try list.appendSlice(file_paths[0..]);

    try grep(allocator, pattern, list, .{});
}
