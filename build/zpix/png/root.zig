const std = @import("std");
const image = @import("../image/root.zig");

pub const Decoder = @import("decoder.zig");

pub const decode = Decoder.decode;
pub const DecoderType = Decoder;
pub const sng = @import("sng.zig").sng;

// PNG 8-byte signature
const png_signature = "\x89PNG\r\n\x1a\n";

pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !image.Image {
    const png_file = std.fs.cwd().openFile(path, .{}) catch |err| {
        std.log.err("Failed to open png file {s}: {any}", .{ path, err });
        return err;
    };
    defer png_file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = png_file.reader(io, &read_buffer);
    const reader: *std.Io.Reader = &file_reader.interface;

    const img = try decode(allocator, reader);

    return img;
}

pub fn loadFromBuffer(allocator: std.mem.Allocator, buffer: []const u8) !image.Image {
    // create a buffer reader from the buffer
    var fixed_reader = std.Io.Reader.fixed(buffer);
    const reader: *std.Io.Reader = &fixed_reader;
    return try decode(allocator, reader);
}

/// Probe whether the provided memory buffer looks like a PNG file.
pub fn probeBuffer(buffer: []const u8) bool {
    return buffer.len >= png_signature.len and std.mem.eql(u8, buffer[0..png_signature.len], png_signature);
}

/// Probe whether the file at `path` looks like a PNG file.
pub fn probePath(io: std.Io, path: []const u8) !bool {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| {
        return err;
    };
    defer file.close();
    var io_buf: [64]u8 = undefined;
    var file_reader = file.reader(io, &io_buf);
    const reader: *std.Io.Reader = &file_reader.interface;
    var buf: [8]u8 = undefined;
    const n = try reader.readSliceShort(&buf);
    return n >= 8 and std.mem.eql(u8, buf[0..8], png_signature);
}

comptime {
    _ = @import("decoder_test.zig");
}
