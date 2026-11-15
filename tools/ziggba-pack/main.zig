const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.writeAll(
        \\ziggba-pack - Prepare assets for ZigGBA
        \\
        \\Usage:
        \\  ziggba-pack --help
        \\
    );
    try stdout.interface.flush();
}
