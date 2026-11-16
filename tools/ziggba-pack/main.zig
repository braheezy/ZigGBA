const std = @import("std");
const image = @import("image.zig");

fn parseImageArgs(args: []const []const u8) ![]const u8 {
    if (args.len == 0) return error.MissingInput;
    if (!std.mem.eql(u8, args[0], "--input")) return error.UnknownArgument;
    if (args.len == 1 or args[1].len == 0) return error.MissingArgumentValue;
    if (args.len != 2) return error.UnexpectedArgument;
    return args[1];
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len == 1 or (args.len == 2 and std.mem.eql(u8, args[1], "--help"))) {
        try help(init.io);
        return;
    }
    if (!std.mem.eql(u8, args[1], "image-info")) {
        std.debug.print("ziggba-pack: unknown command '{s}'; use --help\n", .{args[1]});
        std.process.exit(2);
    }
    const input = parseImageArgs(args[2..]) catch |err| {
        std.debug.print("ziggba-pack image-info: {s}; use --help\n", .{@errorName(err)});
        std.process.exit(2);
    };
    const info = image.inspect(allocator, init.io, input) catch |err| {
        std.debug.print("ziggba-pack image-info: input '{s}': {s}\n", .{ input, @errorName(err) });
        std.process.exit(1);
    };
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try std.zon.stringify.serialize(info, .{}, &stdout.interface);
    try stdout.interface.writeByte('\n');
    try stdout.interface.flush();
}

fn help(io: std.Io) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.writeAll(
        \\ziggba-pack - Prepare assets for ZigGBA
        \\
        \\Usage:
        \\  ziggba-pack --help
        \\  ziggba-pack image-info --input <image>
        \\
        \\image-info decodes a PNG, JPEG, QOI, or BMP and writes its width and
        \\height to stdout as ZON. No conversion output is written to the source tree.
        \\
    );
    try stdout.interface.flush();
}

test "image-info requires exactly one input" {
    try std.testing.expectEqualStrings("image.png", try parseImageArgs(&.{ "--input", "image.png" }));
    try std.testing.expectError(error.MissingInput, parseImageArgs(&.{}));
    try std.testing.expectError(error.UnknownArgument, parseImageArgs(&.{"--unknown"}));
    try std.testing.expectError(error.MissingArgumentValue, parseImageArgs(&.{"--input"}));
    try std.testing.expectError(error.UnexpectedArgument, parseImageArgs(&.{ "--input", "a", "--input", "b" }));
}

test {
    _ = image;
}
