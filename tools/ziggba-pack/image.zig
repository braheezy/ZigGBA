//! The first image operation: decode an image and report its dimensions.
const std = @import("std");
const zpix = @import("zpix");

pub const Info = struct {
    width: u32,
    height: u32,
};

pub fn inspect(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Info {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited);
    defer allocator.free(bytes);
    return inspectBuffer(allocator, bytes);
}

pub fn inspectBuffer(allocator: std.mem.Allocator, bytes: []const u8) !Info {
    var image = try zpix.fromBuffer(allocator, bytes);
    defer image.free(allocator);
    return .{ .width = @intCast(image.width()), .height = @intCast(image.height()) };
}

test "decode a one-pixel QOI image and report its dimensions" {
    const bytes = "qoif" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x04\x00" ++
        "\xff\x12\x34\x56\xff" ++
        "\x00\x00\x00\x00\x00\x00\x00\x01";
    const info = try inspectBuffer(std.testing.allocator, bytes);
    try std.testing.expectEqualDeep(Info{ .width = 1, .height = 1 }, info);
}

test "reject unsupported image data" {
    try std.testing.expectError(error.UnknownImageFormat, inspectBuffer(std.testing.allocator, "not an image"));
}
