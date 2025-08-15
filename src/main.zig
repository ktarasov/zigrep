const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const io = std.io;
const process = std.process;
const mem = std.mem;
const posix = std.posix;
const Allocator = std.mem.Allocator;

// Цветовые схемы с использованием StaticStringMap
pub const ColorScheme = struct {
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
pub const Config = struct {
    color_mode: ColorMode = .auto,
    scheme: ColorScheme,
    show_line_numbers: bool = true,
    show_filenames: bool = true,
    force_color: bool = false,
    count_lines: bool = false,
    pattern: []const u8,
    filenames: [][]const u8,
    ignore_case: bool = false,

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

pub fn parseArgs(allocator: Allocator, args: [][:0]u8) !Config {
    var filenames = std.ArrayList([]const u8).init(allocator);
    defer filenames.deinit();

    var pattern: ?[]const u8 = null;
    var color_mode: ColorMode = .auto;
    var show_line_numbers = true;
    var show_filenames = true;
    var count_lines = false;
    var ignore_case = false;
    var force_color = false;
    var scheme = SCHEMES.get("default").?;

    var i: usize = 1; // Skip program name
    while (i < args.len) {
        const arg = args[i];

        if (mem.startsWith(u8, arg, "-")) {
            if (mem.startsWith(u8, arg, "--")) {
                if (arg.len > 2) {
                    // Обработка длинных флаговов
                    const long_flag = arg[2..];
                    if (mem.eql(u8, long_flag, "color")) {
                        i += 1;
                        color_mode = std.meta.stringToEnum(ColorMode, args[i]) orelse return error.InvalidColorMode;
                    } else if (mem.eql(u8, long_flag, "color-scheme")) {
                        i += 1;
                        scheme = try parseColorScheme(args[i]);
                    } else if (mem.eql(u8, long_flag, "help")) {
                        printHelp(args[0]);
                        process.exit(0);
                    } else if (mem.eql(u8, long_flag, "no-line-numbers")) {
                        show_line_numbers = false;
                    } else if (mem.eql(u8, long_flag, "no-filenames")) {
                        show_filenames = false;
                    } else if (mem.eql(u8, long_flag, "count-lines")) {
                        count_lines = true;
                    } else if (mem.eql(u8, long_flag, "ignore-case")) {
                        ignore_case = true;
                    }
                } else unreachable;
            } else {
                // Обработка коротких флаговов
                var j: usize = 1;
                while (j < arg.len) : (j += 1) {
                    const flag = arg[j];
                    switch (flag) {
                        'h' => {
                            printHelp(args[0]);
                            process.exit(0);
                        },
                        'c' => {
                            count_lines = true;
                        },
                        'l' => {
                            show_line_numbers = false;
                        },
                        'f' => {
                            show_filenames = false;
                        },
                        'i' => {
                            ignore_case = true;
                        },
                        else => continue,
                    }
                }
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
        .pattern = pattern orelse {
            printHelp(args[0]);
            process.exit(0);
        },
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
        .ignore_case = ignore_case,
    };
}

pub fn processStream(
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

        var patternIsFound = false;
        if (config.ignore_case) {
            patternIsFound = try caseInsensitiveSearch(allocator, line, config.pattern) != null;
        } else {
            patternIsFound = mem.indexOf(u8, line, config.pattern) != null;
        }

        if (patternIsFound) {
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
                    config.ignore_case,
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

pub fn highlightLine(
    allocator: Allocator,
    line: []const u8,
    pattern: []const u8,
    scheme: ColorScheme,
    show_numbers: bool,
    show_filenames: bool,
    filename_path: []const u8,
    line_num: u32,
    ignore_case: bool,
) !std.ArrayList(u8) {
    var result = std.ArrayList(u8).init(allocator);
    var last_idx: usize = 0;

    if (show_numbers) {
        try result.writer().print("{s}{d:>6}:{s} ", .{ scheme.line_num, line_num, scheme.reset });
    }

    if (show_filenames) {
        try result.writer().print("{s}\t", .{filename_path});
    }

    while (true) {
        const remaining = line[last_idx..];
        if (remaining.len < pattern.len) break;

        const start_opt = if (ignore_case)
            try caseInsensitiveSearch(allocator, remaining, pattern)
        else
            std.mem.indexOf(u8, remaining, pattern);

        const start = start_opt orelse break;
        const abs_start = last_idx + start;

        // Критически важная проверка границ
        if (abs_start + pattern.len > line.len) {
            try result.appendSlice(remaining);
            break;
        }

        // Проверка полного совпадения для ignore_case
        if (ignore_case) {
            const candidate = line[abs_start .. abs_start + pattern.len];
            const is_full_eql = try caseInsensitiveSearch(allocator, candidate, pattern);
            if (is_full_eql == null) {
                last_idx += 1;
                continue;
            }
        }

        try result.appendSlice(line[last_idx..abs_start]);
        try result.appendSlice(scheme.pattern);
        try result.appendSlice(line[abs_start .. abs_start + pattern.len]);
        try result.appendSlice(scheme.reset);
        last_idx = abs_start + pattern.len;
    }

    // Добавляем оставшуюся часть строки
    try result.appendSlice(line[last_idx..]);
    return result;
}

// Кастомное преобразование строки в нижний регистр, с поддержкой
// обработки русских символов, латиницы и акцентированных знаков.
fn toLowerCustom(allocator: Allocator, str: []const u8) ![]const u8 {
    var result = std.ArrayList(u8).init(allocator);
    var iter = std.unicode.Utf8Iterator{ .bytes = str, .i = 0 };

    while (iter.nextCodepoint()) |cp| {
        const lower = blk: {
            // Русские символы
            if (cp >= 'А' and cp <= 'Я') break :blk cp + ('а' - 'А');
            if (cp == 'Ё') break :blk 'ё';

            // Базовые латинские символы
            if (cp >= 'A' and cp <= 'Z') break :blk cp + 32;

            // Обработка акцентированных символов
            break :blk switch (cp) {
                0xC0...0xD6 => cp + 32, // À-Ö → à-ö
                0xD8...0xDE => cp + 32, // Ø-Þ → ø-þ
                0x100...0x17F => handleLatinExtended(cp),
                else => cp,
            };
        };

        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(lower, &buf) catch unreachable;
        try result.appendSlice(buf[0..len]);
    }

    return result.toOwnedSlice();
}

fn handleLatinExtended(cp: u21) u21 {
    // Для сложных преобразований добавьте дополнительные правила в switch
    return switch (cp) {
        0x0100 => 0x0101, // Ā → ā
        0x0102 => 0x0103, // Ă → ă
        0x0104 => 0x0105, // Ą → ą
        // ... другие символы Latin Extended-A
        else => cp,
    };
}

// Регистронезависимый поиск подстроки в строке
fn caseInsensitiveSearch(allocator: Allocator, haystack: []const u8, needle: []const u8) !?usize {
    const lowerHay = try toLowerCustom(allocator, haystack);
    defer allocator.free(lowerHay);

    const lowerNeedle = try toLowerCustom(allocator, needle);
    defer allocator.free(lowerNeedle);

    return std.mem.indexOf(u8, lowerHay, lowerNeedle);
}

fn printHelp(prog_name: []const u8) void {
    std.debug.print(
        \\Usage: {s} [OPTIONS] PATTERN FILE
        \\Options:
        \\      --color <MODE>        Color mode (always/auto/never)
        \\      --color-scheme <NAME> Color scheme (available: 
    , .{prog_name});

    for (SCHEMES.keys(), 0..) |kv, i| {
        if (i > 0) std.debug.print("|", .{});
        std.debug.print("{s}", .{kv});
    }

    std.debug.print(")\n", .{});

    std.debug.print(
        \\  -l, --no-line-numbers     Disable line numbers
        \\  -f, --no-filenames        Disable filenames
        \\  -i, --ignore-case         Case insensitive search
        \\  -c, --count-lines         Show the count lines has been found
        \\  -h, --help                Show this help
        \\
    , .{});
}
