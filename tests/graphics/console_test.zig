const std = @import("std");
const console = @import("kernel").console;

test "typeChar writes into cell buffer" {
    var console_instance = console.Console.init();
    var cells: [80 * 24]u8 = undefined;
    console_instance.reset(80, 24, &cells);
    console_instance.typeChar('h');
    console_instance.typeChar('i');
    try std.testing.expectEqual(@as(u8, 'h'), cells[0]);
    try std.testing.expectEqual(@as(u8, 'i'), cells[1]);
    try std.testing.expectEqual(@as(usize, 2), console_instance.cursor_col);
}

test "newline moves cursor to next row" {
    var console_instance = console.Console.init();
    var cells: [4 * 3]u8 = undefined;
    console_instance.reset(4, 3, &cells);
    console_instance.typeChar('a');
    console_instance.newline();
    try std.testing.expectEqual(@as(usize, 0), console_instance.cursor_col);
    try std.testing.expectEqual(@as(usize, 1), console_instance.cursor_row);
}

test "line wrap moves to next row" {
    var console_instance = console.Console.init();
    var cells: [4 * 3]u8 = undefined;
    console_instance.reset(4, 3, &cells);
    for (0..5) |i| {
        console_instance.typeChar('a' + @as(u8, @intCast(i)));
    }
    try std.testing.expectEqual(@as(usize, 1), console_instance.cursor_row);
    try std.testing.expectEqual(@as(u8, 'e'), cells[4]);
}

test "backspace erases last char" {
    var console_instance = console.Console.init();
    var cells: [80 * 24]u8 = undefined;
    console_instance.reset(80, 24, &cells);
    console_instance.typeChar('x');
    console_instance.typeChar('y');
    console_instance.backspace();
    try std.testing.expectEqual(@as(usize, 1), console_instance.cursor_col);
    try std.testing.expectEqual(@as(u8, ' '), cells[1]);
}

test "scroll shifts rows up" {
    var console_instance = console.Console.init();
    var cells: [4 * 2]u8 = undefined;
    console_instance.reset(4, 2, &cells);
    console_instance.typeChar('1');
    console_instance.newline();
    console_instance.typeChar('2');
    console_instance.newline();
    try std.testing.expectEqual(@as(u8, '2'), cells[0]);
    try std.testing.expectEqual(@as(u8, ' '), cells[4]);
    try std.testing.expectEqual(@as(usize, 1), console_instance.cursor_row);
}

test "clear resets all cells" {
    var console_instance = console.Console.init();
    var cells: [4 * 2]u8 = undefined;
    console_instance.reset(4, 2, &cells);
    console_instance.typeChar('z');
    console_instance.clear();
    for (cells) |c| {
        try std.testing.expectEqual(@as(u8, ' '), c);
    }
}
