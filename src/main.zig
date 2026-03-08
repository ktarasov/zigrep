const std = @import("std");
const testing = std.testing;
const fs = std.fs;
const Io = std.Io;
const process = std.process;
const mem = std.mem;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Aligned;

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

pub fn main( init: std.process.Init) !void {
    //Обработка случая отсутствия аргументов
    if( init.minimal.args.vector.len == 1 ){
      printHelp();
      return;
    }
    var args = init.minimal.args.iterate();

    const config = try parseArgs(init.gpa, &args, init.environ_map);
    defer config.deinit(init.gpa);

    const out_buf: []u8  =  try init.gpa.alloc(u8, std.heap.page_size_max);
    defer init.gpa.free( out_buf );

    var stdout: std.Io.File.Writer = .init( std.Io.File.stdout(), init.io, out_buf);

    _ = try processInput(init.gpa, config, &stdout.interface, init.io);
}

// Не используется
// fn detectColorMode(config: Config, output: *std.Io.File.Writer) bool {
//     return switch (config.color_mode) {
//         .always => true,
//         .never => false,
//         .auto => w.*.file.isTty(),
//     };
// }

fn parseColorScheme(name: []const u8) ColorScheme {
    return SCHEMES.get(name) orelse {
        std.log.defaultLog( .err, .default,"Unknown color scheme: '{s}'. Available options:", .{name});
        for (SCHEMES.keys()) |kv| {
            std.log.defaultLog( .err, .default,"  {s}", .{kv});
        }

        return SCHEMES.get("default").?;
    };
}

pub fn parseArgs(allocator: Allocator, args: *std.process.Args.Iterator, env_map: *std.process.Environ.Map) !Config {
    var filenames = try ArrayList([]const u8, .@"8").initCapacity(allocator, 16);
    defer filenames.deinit( allocator );

    var pattern: ?[]const u8 = null;
    var color_mode: ColorMode = .auto;
    var show_line_numbers = true;
    var show_filenames = true;
    var count_lines = false;
    var ignore_case = false;
    var force_color = false;
    var scheme = SCHEMES.get("default").?;

    _ = args.skip(); // Пропуск относительного пути вызываемой программы

    while (args.next()) |arg| {
      const state: u16 = @bitCast( [2]u8{arg[0],arg[1]} );
      lbl: switch( state ) {
        // ВНИАНИЕ: эти константы рассчитаны на little-endian (см. @bitCast)
        0x682D => { //   -h, --help  Show help page
          printHelp();
          process.exit(0);
        },
        0x2D2D => {
          // '-' в ASCII имеет код 2D ССЫЛКА: https://hexoback.vercel.app/cheatsheets/ASCII_Tables.docset/Contents/Resources/Documents/
          // Обработка длинных аргументов, что начинаются с '--'
          if( arg[2] == 0 ) return error.WrongArg;
          // Обработка длинных флаговов

          //TODO - Добавить обработку через Trie или staticstringmap. Как сделано с цветовыми схемами.
          const long_flag = arg[2..];
          if (mem.eql(u8, long_flag, "help")) {
              printHelp();
              process.exit(0);
          } else if(mem.eql(u8, long_flag, "color-scheme")) {
              scheme = parseColorScheme(args.next().?);
          } else if(mem.eql(u8, long_flag, "color")) {
              color_mode = std.meta.stringToEnum(ColorMode, args.next().?) orelse return error.InvalidColorMode;
          } else if (mem.eql(u8, long_flag, "no-line-numbers")) {
              show_line_numbers = false;
          } else if (mem.eql(u8, long_flag, "no-filenames")) {
              show_filenames = false;
          } else if (mem.eql(u8, long_flag, "count-lines")) {
              count_lines = true;
          } else if (mem.eql(u8, long_flag, "ignore-case")) {
              ignore_case = true;
          }
        },
        0x6C2D => { show_line_numbers = false; continue :lbl 0;},  //   -l, --no-line-numbers     Disable line numbers
        0x632D => { count_lines = true; continue :lbl 0;},         //   -c, --count-lines         Show the count lines has been found
        0x662D => { show_filenames = false; continue :lbl 0;},     //   -f, --no-filenames        Disable filenames
        0x692D => { ignore_case = true; continue :lbl 0;},         //   -i, --ignore-case         Case insensitive search
        0x3D70 => { pattern = pattern_blk:{                        //   p=PATTERN                 Alternative way to set pattern
          if( arg[2] == 0 ) continue;
          if( pattern != null ) allocator.free( pattern.? );
          const new_pattern = try allocator.dupe(u8, arg[2..]);
          break :pattern_blk new_pattern;
          };
        },
        0x0000 => { //Сделанно только чтобы была возможность писать аргументы в виде -lci. Так как естественным путём вы никак не получите такую строку. 
          var i: usize = 2;
          while( arg[i] != 0 ):( i += 1 ){
            switch( arg[i] ){
              'h' => {
                printHelp();
                process.exit(0);
              },
              'c' => count_lines = true,
              'f' => show_filenames = false,
              'i' => ignore_case = true,
              'l' => show_line_numbers = false,
              else => return error.WrongArg,
            }
          }
        },
        else => {
          if( pattern == null ) {
            pattern = try allocator.dupe(u8, arg);
          } else {  
            const filename = try allocator.dupe(u8, arg);
            try filenames.append(allocator, filename);
          }
        }
      }
    }

    // Обработка переменных окружения
    if (env_map.get("CLICOLOR_FORCE") != null) {
        force_color = true;
        color_mode = .always;
    } else if (env_map.get("CLICOLOR") != null) {
        color_mode = .always;
    }

    // Если поиск о потоке или в единственном файле,
    // то нет смысла выводить имя файла
    if (filenames.items.len < 2) {
        show_filenames = false;
    }

    return Config{
        .pattern = pattern orelse {
            printHelp();
            process.exit(0);
        },
        .filenames = filenames.toOwnedSlice( allocator ) catch |err| {
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
    input_file: std.Io.File,
    config: Config,
    source_name: []const u8,
    writer: *std.Io.Writer,
    io: Io,
) !u32 {
    const buf_length = std.heap.page_size_max * 4;
    var line_buffer: [buf_length]u8 = undefined;
    var r = input_file.reader(io, &line_buffer);
    const stream = &r.interface;

    var count: u32 = 0;
    var line_num: u32 = 1;

    while (true) {
        // Получим данные из потока до разделителя (перенос строки)
        const line = stream.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
        };

        // Если длина считанного равна 0 - прерываем цикл
        // if (line.len == 0) {
        //     continue;
        // }
        //Закомментировал ради тестов

        var patternIsFound = false;
        if (config.ignore_case) {
            patternIsFound = try caseInsensitiveSearch(allocator, line, config.pattern) != null;
        } else {
            patternIsFound = mem.indexOf(u8, line, config.pattern) != null;
        }

        if (patternIsFound) {
            count += 1;

            if (!config.count_lines) {
                var highlighted = try highlightLine(
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
                defer highlighted.deinit( allocator );

              try writer.print("{s}", .{highlighted.items});
              try writer.flush();
            }
        }

        // // Проверим не достигли ли мы конца потока
        // // Если достигли, то выходим из цикла
        // if (in_stream.seek == in_stream.end) {
        //     break;
        // }

        // Так как при четнии линии и так есть проверка на EndOfStream - это откровенно лишнее


        // // Пропустим разделитель, чтобы не споткнуться
        // // об него на следующей итерации :)
        // in_stream.toss(1);

        //Вместо этого можно использовать takeDelimeterInclusive, что я и сделал. Это никак не повредило коду

        line_num += 1;
    }

    return count;
}

fn processInput(allocator: Allocator, config: Config, writer: *Io.Writer, io: Io) !u32 {
    const stdin = std.Io.File.stdin();

    // Работает как cat, если нет аргументов - читает из стандартного воода
    if (config.filenames.len == 0) {
        _ = try processStream(allocator, stdin, config, "(stdin)", writer, io);
        return 1;
    }

    var total_count: u32 = 0;
    for (config.filenames) |filename| {
      const file = std.Io.Dir.cwd().openFile( io, filename, .{}) catch |err| {
            std.log.defaultLog(.err, .default, "Failed to open '{s}': {s}", .{ filename, @errorName(err) });
            continue;
        };
        defer file.close( io );

        const count = try processStream(allocator, file, config, filename, writer, io);
        total_count += count;
    }
  
    if (config.count_lines) {
        try writer.print("{d}\n", .{total_count});
        try writer.flush();
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
  ) !ArrayList(u8, .@"1" ) {
    var result = try ArrayList(u8, .@"1" ).initCapacity(allocator, 16 );
    var last_idx: usize = 0;

    if (show_numbers) {
        try result.print(allocator, "{s}{d:>6}:{s} ", .{ scheme.line_num, line_num, scheme.reset });
    }

    if (show_filenames) {
        try result.print(allocator, "{s}\t", .{filename_path});
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
            try result.appendSlice(allocator, remaining);
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

        try result.appendSlice(allocator, line[last_idx..abs_start]);
        try result.appendSlice(allocator, scheme.pattern);
        try result.appendSlice(allocator, line[abs_start .. abs_start + pattern.len]);
        try result.appendSlice(allocator, scheme.reset);
        last_idx = abs_start + pattern.len;
    }

    // Добавляем оставшуюся часть строки
    try result.appendSlice(allocator, line[last_idx..]);
    return result;
}

// Кастомное преобразование строки в нижний регистр, с поддержкой
// обработки русских символов, латиницы и акцентированных знаков.
fn toLowerCustom(allocator: Allocator, str: []const u8) ![]const u8 {
    var result = try ArrayList(u8, .@"1").initCapacity(allocator, 16);
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
        try result.appendSlice(allocator, buf[0..len]);
    }

    return result.toOwnedSlice( allocator );
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

    return std.mem.find(u8, lowerHay, lowerNeedle);
}

fn printHelp() void {
    std.debug.print(
        \\Usage: zigrep [OPTIONS] PATTERN FILE
        \\Options:
        \\      --color <MODE>        Color mode (always/auto/never)
        \\      --color-scheme <NAME> Color scheme (available: 
    , .{});

    for (SCHEMES.keys(), 0..) |kv, i| {
        if (i > 0) std.debug.print("|", .{});
        std.debug.print("{s}", .{kv});
    }

    std.debug.print(
        \\
        \\  -l, --no-line-numbers     Disable line numbers
        \\  -f, --no-filenames        Disable filenames
        \\  -i, --ignore-case         Case insensitive search
        \\  -c, --count-lines         Show the count lines has been found
        \\  -h, --help                Show this help
        \\  p=PATTERN                 Alternative way to set pattern
        \\
    , .{});
}
