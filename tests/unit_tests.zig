const std = @import("std");
const testing = std.testing;
const mem = std.mem;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
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

test "process file input" {
    const allocator = testing.allocator;

    var tests_dir = try std.fs.cwd().openDir("tests", .{ .iterate = true });
    defer tests_dir.close();

    const test_input = try tests_dir.openFile("input.txt", .{});
    defer test_input.close();

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

    var output = ArrayList(u8).init(allocator);
    defer output.deinit();

    _ = try main_mod.processStream(allocator, test_input, config, "input.txt", output.writer());

    const expected = "input.txt\tsecond \x1b[31merror\x1b[0m line\n";
    try testing.expectEqualStrings(expected, output.items);
}

test "Russian case insensitive search" {
    const allocator = std.testing.allocator;
    const line = "Проверка СоВмеСТных ТестЁВ";
    const pattern = "тестё";

    const result = try main_mod.highlightLine(allocator, line, pattern, main_mod.ColorScheme{ .pattern = "*", .line_num = "*", .reset = "*" }, false, false, "", 1, true);
    defer result.deinit();

    try std.testing.expectEqualStrings("Проверка СоВмеСТных *ТестЁ*В", result.items);
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
        var tests_dir = try std.fs.cwd().openDir("tests", .{ .iterate = true });
        defer tests_dir.close();

        const test_input = try tests_dir.openFile("input_rus.txt", .{});
        defer test_input.close();

        const config = main_mod.Config{
            .pattern = "строка",
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

        var output = ArrayList(u8).init(allocator);
        defer output.deinit();

        const count = try main_mod.processStream(allocator, test_input, config, "input_rus.txt", output.writer());

        // std.debug.print("Количество обранруженных: {d}\n", .{count});
        // std.debug.print("Выходные данные:\n{s}\n", .{output.items});

        try testing.expect(count == 3);
        try testing.expect(mem.eql(u8, output.items, "input_rus.txt\tПервая СТРОКА\n" ++
            "input_rus.txt\tВторая строка\n" ++
            "input_rus.txt\tТРЕТЬЯ Строка\n"));
    }
}
