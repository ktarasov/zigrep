const std = @import("std");

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

    try grep(allocator, args[1], args[2..], .{});
}

/// Функция поиска строки внутри списка файлов
fn grep(allocator: std.mem.Allocator, pattern: [:0]const u8, file_names: []const [:0]const u8, options: Options) !void {
    _ = options;

    const stdout = std.io.getStdOut().writer();

    for (file_names) |file_path| {
        const absolute_path = try std.fs.realpathAlloc(allocator, file_path);
        defer allocator.free(absolute_path);

        const file = try std.fs.openFileAbsolute(absolute_path, .{});
        defer file.close();

        var buf_reader = std.io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();

        var line_buf: [8192]u8 = undefined;
        while (try in_stream.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (std.mem.indexOf(u8, line, pattern)) |index| {
                try stdout.print("{s}:{d}: {s}\n", .{ absolute_path, index + 1, line });
            }
        }
    }
}
