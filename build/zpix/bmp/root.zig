const std = @import("std");
const image = @import("../image/root.zig");

pub const Decoder = @import("decoder.zig");

pub const decode = Decoder.decode;

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !image.Image {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.log.err("Failed to open bmp file {s}: {any}", .{ path, err });
        return err;
    };
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const reader: *std.Io.Reader = &file_reader.interface;
    return try decode(allocator, reader);
}

pub fn loadFromBuffer(allocator: std.mem.Allocator, buffer: []const u8) !image.Image {
    var fixed_reader = std.Io.Reader.fixed(buffer);
    const reader: *std.Io.Reader = &fixed_reader;
    return try decode(allocator, reader);
}

/// Probe whether the provided memory buffer looks like a BMP file.
pub fn probeBuffer(buffer: []const u8) bool {
    // BMP signature is ASCII 'B''M'
    return buffer.len >= 2 and buffer[0] == 'B' and buffer[1] == 'M';
}

/// Probe whether the file at `path` looks like a BMP file.
pub fn probePath(io: std.Io, path: []const u8) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();
    var buf: [2]u8 = undefined;
    var io_buf: [32]u8 = undefined;
    var file_reader = file.reader(io, &io_buf);
    const reader: *std.Io.Reader = &file_reader.interface;
    const n = try reader.readSliceShort(&buf);
    return n >= 2 and buf[0] == 'B' and buf[1] == 'M';
}

comptime {
    _ = @import("decoder_test.zig");
}
