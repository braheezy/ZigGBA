const std = @import("std");
const image = @import("../image/root.zig");

pub const Decoder = @import("decoder.zig");

pub const decode = Decoder.decode;
pub const decodeConfig = Decoder.decodeConfig;

/// Convenience API to decode from an in-memory buffer.
pub fn loadFromBuffer(allocator: std.mem.Allocator, buffer: []const u8) !image.Image {
    var fixed_reader = std.Io.Reader.fixed(buffer);
    const reader: *std.Io.Reader = &fixed_reader;
    return try decode(allocator, reader);
}

/// Probe whether the provided memory buffer looks like a JPEG file.
pub fn probeBuffer(buffer: []const u8) bool {
    // JPEG starts with FF D8 and ends with FF D9 typically; we only check SOI.
    return buffer.len >= 2 and buffer[0] == 0xFF and buffer[1] == 0xD8;
}

/// Probe whether the file at `path` looks like a JPEG file.
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
    return n >= 2 and buf[0] == 0xFF and buf[1] == 0xD8;
}

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !image.Image {
    const jpeg_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.log.err("Failed to open jpeg file {s}: {any}", .{ path, err });
        return err;
    };
    defer jpeg_file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = jpeg_file.reader(io, &read_buffer);
    const reader: *std.Io.Reader = &file_reader.interface;

    const img = decode(allocator, reader) catch |err| {
        std.log.err("Failed to decode jpeg file: {any}", .{err});
        return err;
    };

    return img;
}

comptime {
    std.testing.refAllDecls(@This());
}
