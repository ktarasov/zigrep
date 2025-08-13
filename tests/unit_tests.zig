const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const main_mod = @import("zigrep");

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

    const config = try main_mod.parseArgs(allocator, args);
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

    const config = try main_mod.parseArgs(allocator, args);
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

    const config = try main_mod.parseArgs(allocator, args);
    defer config.deinit(allocator);

    try testing.expect(config.color_mode == .always);
}

test "highlightLine basic test" {
    const allocator = testing.allocator;

    const line = "Hello world";
    const pattern = "world";
    const scheme = main_mod.ColorScheme{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    };

    var result = try main_mod.highlightLine(allocator, line, pattern, scheme, false, false, "(test)", 1, false);
    defer result.deinit();

    const expected = "Hello \x1b[31mworld\x1b[0m";
    try testing.expect(mem.eql(u8, result.items, expected));
}

test "highlightLine multiple matches test" {
    const allocator = testing.allocator;

    const line = "foo bar foo";
    const pattern = "foo";
    const scheme = main_mod.ColorScheme{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    };

    var result = try main_mod.highlightLine(allocator, line, pattern, scheme, false, false, "(test)", 1, false);
    defer result.deinit();

    const expected = "\x1b[31mfoo\x1b[0m bar \x1b[31mfoo\x1b[0m";
    try testing.expect(mem.eql(u8, result.items, expected));
}

test "highlightLine no match test" {
    const allocator = testing.allocator;

    const line = "Hello world";
    const pattern = "nonexistent";
    const scheme = main_mod.ColorScheme{
        .pattern = "\x1b[31m",
        .line_num = "\x1b[33m",
        .reset = "\x1b[0m",
    };

    var result = try main_mod.highlightLine(allocator, line, pattern, scheme, false, false, "(test)", 1, false);
    defer result.deinit();

    try testing.expect(mem.eql(u8, result.items, line));
}

test "process stdin input" {
    const allocator = testing.allocator;

    // Эмулируем ввод через pipe
    const input = "first line\nsecond error line\nthird line";
    var fbs = std.io.fixedBufferStream(input);

    const config = main_mod.Config{
        .pattern = "error",
        .filenames = &[_][]const u8{},
        .scheme = main_mod.ColorScheme{
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

    _ = try main_mod.processStream(allocator, fbs.reader(), config, "(stdin)", output.writer());

    const expected = "(stdin)\tsecond \x1b[31merror\x1b[0m line\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "case insensitive search" {
    const allocator = testing.allocator;

    // Тест 1: Проверка парсинга флага -i
    {
        const args = try allocator.alloc([:0]u8, 4);
        defer {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }

        args[0] = try allocator.dupeZ(u8, "zgrep");
        args[1] = try allocator.dupeZ(u8, "-i");
        args[2] = try allocator.dupeZ(u8, "PaTtErN");
        args[3] = try allocator.dupeZ(u8, "file.txt");

        const config = try main_mod.parseArgs(allocator, args);
        defer config.deinit(allocator);

        try testing.expect(config.ignore_case);
        try testing.expect(mem.eql(u8, config.pattern, "PaTtErN"));
    }

    // Тест 2: Проверка парсинга флага --ignore-case
    {
        const args = try allocator.alloc([:0]u8, 4);
        defer {
            for (args) |arg| allocator.free(arg);
            allocator.free(args);
        }

        args[0] = try allocator.dupeZ(u8, "zgrep");
        args[1] = try allocator.dupeZ(u8, "--ignore-case");
        args[2] = try allocator.dupeZ(u8, "PaTtErN");
        args[3] = try allocator.dupeZ(u8, "file.txt");

        const config = try main_mod.parseArgs(allocator, args);
        defer config.deinit(allocator);

        try testing.expect(config.ignore_case);
        try testing.expect(mem.eql(u8, config.pattern, "PaTtErN"));
    }

    // Тест 3: Проверка фактического поиска без учета регистра
    {
        const input = "First LINE\nSecond line\nTHIRD Line\n";
        var fbs = std.io.fixedBufferStream(input);

        const config = main_mod.Config{
            .pattern = "line",
            .filenames = &[_][]const u8{},
            .scheme = main_mod.ColorScheme{
                .pattern = "",
                .line_num = "",
                .reset = "",
            },
            .color_mode = .never,
            .show_line_numbers = false,
            .count_lines = false,
            .ignore_case = true,
        };

        var output = std.ArrayList(u8).init(allocator);
        defer output.deinit();

        const count = try main_mod.processStream(allocator, fbs.reader(), config, "test.txt", output.writer());

        try testing.expect(count == 3);
        try testing.expect(mem.eql(u8, output.items, "test.txt\tFirst LINE\n" ++
            "test.txt\tSecond line\n" ++
            "test.txt\tTHIRD Line\n"));
    }
}
