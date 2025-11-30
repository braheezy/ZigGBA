const std = @import("std");
const ziggba = @import("ziggba");
const color = ziggba.color;

pub fn build(b: *std.Build) void {
    // const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});

    const gba_b = ziggba.GbaBuild.create(b);

    var bgAffine = gba_b.addExecutable(.{
        .name = "bgAffine",
        .root_source_file = b.path("bgAffine.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    const bgAffine_pal = color.PalettizerNearest.create(
        gba_b.allocator(),
        &[_]color.ColorRgba32{
            .transparent,
            .white,
            .red,
            .green,
            .aqua,
        },
    ) catch @panic("OOM");
    _ = bgAffine.addConvertImageTiles8BppStep(.{
        .image_path = "tiles.png",
        .output_path = "tiles.bin",
        .options = .{ .palettizer = bgAffine_pal.pal() },
    });
}
