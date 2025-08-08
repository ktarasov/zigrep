const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const io = std.io;
const process = std.process;
const mem = std.mem;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// Цветовые схемы с использованием StaticStringMap
const ColorScheme = struct {
    pattern: []const u8,
    line_num: []const u8,
    reset: []const u8,
};

const SCHEMES = std.StaticStringMap(ColorScheme).initComptime(.{
    .{ "default", @as(ColorScheme, .{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    }) },
    .{ "dark", @as(ColorScheme, .{
        .pattern = "\x1b[38;5;208m",
        .line_num = "\x1b[38;5;245m",
        .reset = "\x1b[0m",
    }) },
    .{ "neon", @as(ColorScheme, .{
        .pattern = "\x1b[38;5;46m",
        .line_num = "\x1b[38;5;201m",
        .reset = "\x1b[0m",
    }) },
    .{ "mono", @as(ColorScheme, .{
        .pattern = "\x1b[7m",
        .line_num = "\x1b[1m",
        .reset = "\x1b[0m",
    }) },
});

const ColorMode = enum { auto, always, never };

// Конфигурация приложения
const Config = struct {
    color_mode: ColorMode = .auto,
    scheme: ColorScheme,
    show_line_numbers: bool = true,
    show_filenames: bool = true,
    force_color: bool = false,
    count_lines: bool = false,
    pattern: []const u8,
    filenames: [][]const u8,

    pub fn deinit(self: *const Config, allocator: Allocator) void {
        allocator.free(self.pattern);
        for (self.filenames) |f| allocator.free(f);
        allocator.free(self.filenames);
    }
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    const config = try parseArgs(allocator, args);
    defer config.deinit(allocator);

    const stdout = std.io.getStdOut().writer();

    _ = try processInput(allocator, config, stdout);
}

fn detectColorMode(config: Config) bool {
    return switch (config.color_mode) {
        .always => true,
        .never => false,
        .auto => std.io.getStdOut().isTty(),
    };
}

fn parseColorScheme(name: []const u8) !ColorScheme {
    return SCHEMES.get(name) orelse {
        std.log.err("Unknown color scheme: '{s}'. Available options:", .{name});
        for (SCHEMES.keys()) |kv| {
            std.log.err("  {s}", .{kv});
        }
        return error.InvalidColorScheme;
    };
}

fn parseArgs(allocator: Allocator, args: [][:0]u8) !Config {
    var filenames = std.ArrayList([]const u8).init(allocator);
    defer filenames.deinit();

    var pattern: ?[]const u8 = null;
    var color_mode: ColorMode = .auto;
    var show_line_numbers = true;
    var show_filenames = true;
    var count_lines = false;
    var force_color = false;
    var scheme = SCHEMES.get("default").?;

    var i: usize = 1; // Skip program name
    while (i < args.len) {
        const arg = args[i];

        if (mem.startsWith(u8, arg, "--")) {
            if (mem.eql(u8, arg, "--color")) {
                i += 1;
                color_mode = std.meta.stringToEnum(ColorMode, args[i]) orelse return error.InvalidColorMode;
            } else if (mem.eql(u8, arg, "--color-scheme")) {
                i += 1;
                scheme = try parseColorScheme(args[i]);
            } else if (mem.eql(u8, arg, "--help")) {
                printHelp(args[0]);
                process.exit(0);
            } else if (mem.eql(u8, arg, "--no-line-numbers")) {
                show_line_numbers = false;
            } else if (mem.eql(u8, arg, "--no-filenames")) {
                show_filenames = false;
            } else if (mem.eql(u8, arg, "--count-lines")) {
                count_lines = true;
            }
        } else if (pattern == null) {
            pattern = try allocator.dupe(u8, arg);
        } else {
            const filename = try allocator.dupe(u8, arg);
            try filenames.append(filename);
        }
        i += 1;
    }

    // Обработка переменных окружения
    if (posix.getenv("CLICOLOR_FORCE") != null) {
        force_color = true;
        color_mode = .always;
    } else if (posix.getenv("CLICOLOR") != null) {
        color_mode = .always;
    }

    // Если поиск о потоке или в единственном файле,
    // то нет смысла выводить имя файла
    if (filenames.items.len < 2) {
        show_filenames = false;
    }

    return Config{
        .pattern = pattern orelse return error.MissingPattern,
        .filenames = filenames.toOwnedSlice() catch |err| {
            // Явное освобождение при ошибке
            for (filenames.items) |f| allocator.free(f);
            return err;
        },
        .scheme = scheme,
        .color_mode = color_mode,
        .force_color = force_color,
        .show_line_numbers = show_line_numbers,
        .show_filenames = show_filenames,
        .count_lines = count_lines,
    };
}

fn processStream(
    allocator: Allocator,
    reader: anytype,
    config: Config,
    source_name: []const u8,
    writer: anytype,
) !u32 {
    var buf_reader = std.io.bufferedReader(reader);
    var in_stream = buf_reader.reader();
    var count: u32 = 0;
    var line_num: u32 = 1;

    var line_buffer = std.ArrayList(u8).init(allocator);
    defer line_buffer.deinit();

    while (in_stream.readUntilDelimiterArrayList(&line_buffer, '\n', 16384)) : (line_num += 1) {
        defer line_buffer.clearRetainingCapacity();

        const line = line_buffer.items;
        if (mem.indexOf(u8, line, config.pattern) != null) {
            count += 1;

            if (!config.count_lines) {
                const highlighted = try highlightLine(
                    allocator,
                    line,
                    config.pattern,
                    config.scheme,
                    config.show_line_numbers,
                    config.show_filenames,
                    source_name,
                    line_num,
                );
                defer highlighted.deinit();

                try writer.print("{s}\n", .{highlighted.items});
            }
        }
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }

    return count;
}

fn processInput(allocator: Allocator, config: Config, writer: anytype) !u32 {
    const stdin = std.io.getStdIn().reader();
    var total_count: u32 = 0;

    if (config.filenames.len > 0) {
        for (config.filenames) |filename| {
            if (mem.eql(u8, filename, "-")) {
                const count = try processStream(allocator, stdin, config, "(stdin)", writer);
                total_count += count;
            } else {
                const file = fs.cwd().openFile(filename, .{}) catch |err| {
                    std.log.err("Failed to open '{s}': {s}", .{ filename, @errorName(err) });
                    continue;
                };
                defer file.close();

                const count = try processStream(allocator, file.reader(), config, filename, writer);
                total_count += count;
            }
        }
    } else {
        const count = try processStream(allocator, stdin, config, "(stdin)", writer);
        total_count += count;
    }

    if (config.count_lines) {
        try writer.print("{d}\n", .{total_count});
    }

    return total_count;
}

fn highlightLine(
    allocator: Allocator,
    line: []const u8,
    pattern: []const u8,
    scheme: ColorScheme,
    show_numbers: bool,
    show_filenames: bool,
    filename_path: []const u8,
    line_num: u32,
) !std.ArrayList(u8) {
    var result = std.ArrayList(u8).init(allocator);
    var last_idx: usize = 0;

    if (show_numbers) {
        try result.writer().print("{s}{d:>6}:{s} ", .{ scheme.line_num, line_num, scheme.reset });
    }

    if (show_filenames) {
        try result.writer().print("{s}\t", .{filename_path});
    }

    while (mem.indexOf(u8, line[last_idx..], pattern)) |start| {
        const abs_start = last_idx + start;
        try result.appendSlice(line[last_idx..abs_start]);
        try result.appendSlice(scheme.pattern);
        try result.appendSlice(pattern);
        try result.appendSlice(scheme.reset);
        last_idx = abs_start + pattern.len;
    }
    try result.appendSlice(line[last_idx..]);
    return result;
}

fn printHelp(prog_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPTIONS] PATTERN FILE
        \\Options:
        \\  --color <MODE>        Color mode (always/auto/never)
        \\  --color-scheme <NAME> Color scheme (available: 
    , .{prog_name});

    for (SCHEMES.keys(), 0..) |kv, i| {
        if (i > 0) std.debug.print("|", .{});
        std.debug.print("{s}", .{kv});
    }

    std.debug.print(")\n", .{});

    std.debug.print(
        \\  --no-line-numbers     Disable line numbers
        \\  --no-filenames        Disable filenames
        \\  --count-lines         Show the count lines has been found
        \\  --help                Show this help
        \\
    , .{});
}

// Test section

test "parseArgs basic test" {
    const allocator = testing.allocator;

    // Создаем аргументы с нуль-терминатором
    const args = try allocator.alloc([:0]u8, 3);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    args[0] = try allocator.dupeZ(u8, "zigrep");
    args[1] = try allocator.dupeZ(u8, "pattern");
    args[2] = try allocator.dupeZ(u8, "file.txt");

    const config = try parseArgs(allocator, args);
    defer config.deinit(allocator);

    // Проверяем значения с использованием try
    try testing.expect(mem.eql(u8, config.pattern, "pattern"));
    try testing.expect(config.filenames.len == 1);
    try testing.expect(mem.eql(u8, config.filenames[0], "file.txt"));
}

test "parseArgs color scheme test" {
    const allocator = testing.allocator;

    const args = try allocator.alloc([:0]u8, 5);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    args[0] = try allocator.dupeZ(u8, "zigrep");
    args[1] = try allocator.dupeZ(u8, "--color-scheme");
    args[2] = try allocator.dupeZ(u8, "dark");
    args[3] = try allocator.dupeZ(u8, "pattern");
    args[4] = try allocator.dupeZ(u8, "file.txt");

    const config = try parseArgs(allocator, args);
    defer config.deinit(allocator);

    try testing.expect(mem.eql(u8, config.scheme.pattern, "\x1b[38;5;208m")); // Исправлен escape-код
}

test "parseArgs color mode test" {
    const allocator = testing.allocator;

    const args = try allocator.alloc([:0]u8, 5);
    defer {
        for (args) |arg| allocator.free(arg);
        allocator.free(args);
    }

    args[0] = try allocator.dupeZ(u8, "zigrep");
    args[1] = try allocator.dupeZ(u8, "--color");
    args[2] = try allocator.dupeZ(u8, "always");
    args[3] = try allocator.dupeZ(u8, "pattern");
    args[4] = try allocator.dupeZ(u8, "file.txt");

    const config = try parseArgs(allocator, args);
    defer config.deinit(allocator);

    try testing.expect(config.color_mode == .always);
}

test "highlightLine basic test" {
    const allocator = testing.allocator;

    const line = "Hello world";
    const pattern = "world";
    const scheme = ColorScheme{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    };

    var result = try highlightLine(allocator, line, pattern, scheme, false, false, "(test)", 1);
    defer result.deinit();

    const expected = "Hello \x1b[31mworld\x1b[0m";
    try testing.expect(mem.eql(u8, result.items, expected));
}

test "highlightLine multiple matches test" {
    const allocator = testing.allocator;

    const line = "foo bar foo";
    const pattern = "foo";
    const scheme = ColorScheme{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    };

    var result = try highlightLine(allocator, line, pattern, scheme, false, false, "(test)", 1);
    defer result.deinit();

    const expected = "\x1b[31mfoo\x1b[0m bar \x1b[31mfoo\x1b[0m";
    try testing.expect(mem.eql(u8, result.items, expected));
}

test "highlightLine no match test" {
    const allocator = testing.allocator;

    const line = "Hello world";
    const pattern = "nonexistent";
    const scheme = ColorScheme{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    };

    var result = try highlightLine(allocator, line, pattern, scheme, false, false, "(test)", 1);
    defer result.deinit();

    try testing.expect(mem.eql(u8, result.items, line));
}

test "process stdin input" {
    const allocator = testing.allocator;

    // Эмулируем ввод через pipe
    const input = "first line\nsecond error line\nthird line";
    var fbs = std.io.fixedBufferStream(input);

    const config = Config{
        .pattern = "error",
        .filenames = &[_][]const u8{},
        .scheme = ColorScheme{
            .pattern = "\x1b[31m",
            .line_num = "\x1b[33m",
            .reset = "\x1b[0m",
        },
        .color_mode = .always,
        .show_line_numbers = false,
        .show_filenames = true,
        .count_lines = false,
    };

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    _ = try processStream(allocator, fbs.reader(), config, "(stdin)", output.writer());

    const expected = "(stdin)\tsecond \x1b[31merror\x1b[0m line\n";
    try testing.expectEqualStrings(expected, output.items);
}
