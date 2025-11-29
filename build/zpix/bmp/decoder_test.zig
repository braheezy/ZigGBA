const std = @import("std");
const testing = std.testing;
const image = @import("image");
const png = @import("png");
const bmp = @import("root.zig");

fn compareImages(al: std.mem.Allocator, img0: image.Image, img1: image.Image) !void {
    const b0 = img0.bounds();
    const b1 = img1.bounds();
    try testing.expectEqual(b0.min.x, b1.min.x);
    try testing.expectEqual(b0.min.y, b1.min.y);
    try testing.expectEqual(b0.max.x, b1.max.x);
    try testing.expectEqual(b0.max.y, b1.max.y);

    const p0 = try img0.rgbaPixels(al);
    defer al.free(p0);
    const p1 = try img1.rgbaPixels(al);
    defer al.free(p1);

    try testing.expectEqual(p0.len, p1.len);
    try testing.expect(std.mem.eql(u8, p0, p1));
}

test "bmp: decode parity with png" {
    const al = testing.allocator;
    const cases = [_][]const u8{
        "colormap",
        "colormap-0",
        "colormap-251",
        "video-001",
        "yellow_rose-small",
        "yellow_rose-small-v5",
        "bmp_1bpp",
        "bmp_4bpp",
        "bmp_8bpp",
    };

    var i: usize = 0;
    while (i < cases.len) : (i += 1) {
        const name = cases[i];

        const png_path = try std.fmt.allocPrint(al, "src/testdata/{s}.png", .{name});
        defer al.free(png_path);
        const bmp_path = try std.fmt.allocPrint(al, "src/testdata/{s}.bmp", .{name});
        defer al.free(bmp_path);

        const img_png = png.load(al, png_path) catch |err| {
            std.debug.print("failed to load png {s}: {t}\n", .{ png_path, err });
            return err;
        };
        defer img_png.free(al);

        const img_bmp = bmp.load(al, bmp_path) catch |err| {
            std.debug.print("failed to load bmp {s}: {t}\n", .{ bmp_path, err });
            return err;
        };
        defer img_bmp.free(al);

        try compareImages(al, img_png, img_bmp);
    }
}

test "bmp: empty input returns eof" {
    // Decode from empty buffer should error.
    var reader_val = std.Io.Reader.fixed(&[_]u8{});
    const reader: *std.Io.Reader = &reader_val;
    const res = bmp.Decoder.decode(testing.allocator, reader);
    try testing.expectError(error.EndOfStream, res);
}
