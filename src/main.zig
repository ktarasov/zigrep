const std = @import("std");
const fs = std.fs;
const io = std.io;
const process = std.process;
const mem = std.mem;
const posix = std.posix;

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
    pattern: []const u8,
    filename: [][:0]u8,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    const config = try parseArgs(args);
    if (config.pattern.len == 0 or config.filename.len == 0) {
        printHelp(args[0]);
        return error.InvalidArguments;
    }

    try processFile(allocator, config);
}

fn parseArgs(args: [][:0]u8) !Config {
    var config = Config{
        .scheme = SCHEMES.get("default").?,
        .pattern = "",
        .filename = undefined,
    };

    var i: usize = 1;
    while (i < args.len) {
        const arg = args[i];
        if (mem.eql(u8, arg, "--color")) {
            if (i + 1 >= args.len) return error.MissingValue;
            config.color_mode = std.meta.stringToEnum(ColorMode, args[i + 1]) orelse return error.InvalidValue;
            i += 2;
        } else if (mem.eql(u8, arg, "--color-scheme")) {
            if (i + 1 >= args.len) return error.MissingValue;
            const scheme_name = args[i + 1];
            config.scheme = SCHEMES.get(scheme_name) orelse {
                std.log.err("Unknown color scheme: '{s}'. Available options:", .{scheme_name});
                for (SCHEMES.keys()) |kv| {
                    std.log.err("  {s}", .{kv});
                }
                return error.InvalidColorScheme;
            };
            i += 2;
        } else if (mem.eql(u8, arg, "--no-line-numbers")) {
            config.show_line_numbers = false;
            i += 1;
        } else if (mem.eql(u8, arg, "--no-filenames")) {
            config.show_filenames = false;
            i += 1;
        } else if (mem.eql(u8, arg, "--help")) {
            printHelp(args[0]);
            process.exit(0);
        } else if (config.pattern.len == 0) {
            config.pattern = arg;
            i += 1;
        } else {
            config.filename = args[i..];
            if (config.filename.len < 2) {
                config.show_filenames = false;
            }
            break;
        }
    }

    // Обработка переменных окружения
    if (posix.getenv("CLICOLOR_FORCE") != null) {
        config.force_color = true;
        config.color_mode = .always;
    } else if (posix.getenv("CLICOLOR") != null) {
        config.color_mode = .always;
    }

    return config;
}

fn processFile(allocator: mem.Allocator, config: Config) !void {
    for (config.filename) |filename_path| {
        const file = try fs.cwd().openFile(filename_path, .{});
        defer file.close();

        var buffered_reader = io.bufferedReader(file.reader());
        var reader = buffered_reader.reader();

        const stdout = io.getStdOut();
        const enable_color = switch (config.color_mode) {
            .always => true,
            .never => false,
            .auto => posix.isatty(stdout.handle) or config.force_color,
        };

        var line_buf: [16384]u8 = undefined;
        var line_num: usize = 1;

        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
            if (mem.indexOf(u8, line, config.pattern)) |_| {
                var highlighted = try highlightLine(allocator, line, config.pattern, config.scheme, enable_color);
                defer highlighted.deinit();

                try printLine(allocator, line_num, filename_path, highlighted.items, config, enable_color);
            }
            line_num += 1;
        }
    }
}

fn highlightLine(
    allocator: mem.Allocator,
    line: []const u8,
    pattern: []const u8,
    scheme: ColorScheme,
    enable_color: bool,
) !std.ArrayList(u8) {
    var result = std.ArrayList(u8).init(allocator);
    var last_pos: usize = 0;

    while (mem.indexOfPos(u8, line, last_pos, pattern)) |pos| {
        try result.appendSlice(line[last_pos..pos]);

        if (enable_color) {
            try result.appendSlice(scheme.pattern);
        }

        try result.appendSlice(line[pos .. pos + pattern.len]);

        if (enable_color) {
            try result.appendSlice(scheme.reset);
        }

        last_pos = pos + pattern.len;
    }
    try result.appendSlice(line[last_pos..]);

    return result;
}

fn printLine(
    allocator: mem.Allocator,
    line_num: usize,
    filename_path: []const u8,
    highlighted_line: []const u8,
    config: Config,
    enable_color: bool,
) !void {
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    if (config.show_line_numbers) {
        if (enable_color) {
            try buffer.appendSlice(config.scheme.line_num);
        }
        try std.fmt.format(buffer.writer(), "{d:>6}: ", .{line_num});
        if (enable_color) {
            try buffer.appendSlice(config.scheme.reset);
        }
    }

    if (config.show_filenames) {
        try std.fmt.format(buffer.writer(), "{s}\t", .{filename_path});
    }

    try buffer.appendSlice(highlighted_line);
    try buffer.append('\n');

    try io.getStdOut().writer().writeAll(buffer.items);
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
        \\  --help                Show this help
        \\
    , .{});
}
