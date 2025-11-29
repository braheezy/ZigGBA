/// Color utilities
pub const color = @import("color/root.zig");

/// High‑level image API
pub const image = @import("image/root.zig");

/// JPEG support
pub const jpeg = @import("jpeg/root.zig");

/// PNG support
pub const png = @import("png/root.zig");

/// QOI (Quite OK Image) support
pub const qoi = @import("qoi/root.zig");

/// BMP support
pub const bmp = @import("bmp/root.zig");

const std = @import("std");

/// Try to decode an image from a file path, probing supported formats.
pub fn fromFilePath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !image.Image {
    // Probe in order: PNG, JPEG, QOI, BMP
    if (png.probePath(io, path) catch false) return try png.load(allocator, io, path);
    if (jpeg.probePath(io, path) catch false) return try jpeg.load(allocator, io, path);
    if (qoi.probePath(io, path) catch false) return try qoi.load(allocator, io, path);
    if (bmp.probePath(io, path) catch false) return try bmp.load(allocator, io, path);
    return error.UnknownImageFormat;
}

/// Try to decode an image from a memory buffer, probing supported formats.
pub fn fromBuffer(allocator: std.mem.Allocator, buffer: []const u8) !image.Image {
    if (png.probeBuffer(buffer)) return try png.loadFromBuffer(allocator, buffer);
    if (jpeg.probeBuffer(buffer)) return try jpeg.loadFromBuffer(allocator, buffer);
    if (qoi.probeBuffer(buffer)) return try qoi.loadFromBuffer(allocator, buffer);
    if (bmp.probeBuffer(buffer)) return try bmp.loadFromBuffer(allocator, buffer);
    return error.UnknownImageFormat;
}
