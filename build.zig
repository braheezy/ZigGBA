//! Build script for ZigGBA - A GBA development library for Zig.

const std = @import("std");

pub const GbaBuild = @import("gba_build.zig").GbaBuild;

// Import asset processing utilities
const root_path = GbaBuild.ziggbaPath();
pub const color = @import("build/color.zig");

// Build all example ROMs.
fn buildExamples(b: *GbaBuild) void {
    var charBlock = b.addExecutable(.{
        .name = "charBlock",
        .root_source_file = b.path("examples/charBlock/charBlock.zig"),
    });
    var charBlock_assets = charBlock.createAssetModule();
    _ = charBlock_assets.addImage("ids", .{
        .source_file = b.path("examples/charBlock/charBlock.png"),
        .format = .bg_tilemap_4bpp_multi_bank,
        .multi_bank_tilemap_4bpp = .{ .dedupe = true, .dedupe_flips = true },
        .transforms = .{
            .tiles = .{ .lz77 = .{} },
            .map = .{ .lz77 = .{} },
        },
    });
    charBlock_assets.addImport("assets");
    _ = b.addExecutable(.{
        .name = "debugPrint",
        .root_source_file = b.path("examples/debugPrint/debugPrint.zig"),
    });
    _ = b.addExecutable(.{
        .name = "first",
        .root_source_file = b.path("examples/first/first.zig"),
    });
    _ = b.addExecutable(.{
        .name = "hello",
        .root_source_file = b.path("examples/hello/hello.zig"),
        .build_options = .{ .text_charsets = .{ .latin = true } },
    });
    _ = b.addExecutable(.{
        .name = "helloWorld",
        .root_source_file = b.path("examples/helloWorld/helloWorld.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "interrupts",
        .root_source_file = b.path("examples/interrupts/interrupts.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "keydemo",
        .root_source_file = b.path("examples/keydemo/keydemo.zig"),
    });
    _ = b.addExecutable(.{
        .name = "memory",
        .root_source_file = b.path("examples/memory/memory.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "mode3draw",
        .root_source_file = b.path("examples/mode3draw/mode3draw.zig"),
    });
    _ = b.addExecutable(.{
        .name = "mode4draw",
        .root_source_file = b.path("examples/mode4draw/mode4draw.zig"),
    });
    _ = b.addExecutable(.{
        .name = "objAffine",
        .root_source_file = b.path("examples/objAffine/objAffine.zig"),
    });
    _ = b.addExecutable(.{
        .name = "objDemo",
        .root_source_file = b.path("examples/objDemo/objDemo.zig"),
    });
    _ = b.addExecutable(.{
        .name = "panic",
        .root_source_file = b.path("examples/panic/panic.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "secondsTimer",
        .root_source_file = b.path("examples/secondsTimer/secondsTimer.zig"),
    });
    _ = b.addExecutable(.{
        .name = "screenBlock",
        .root_source_file = b.path("examples/screenBlock/screenBlock.zig"),
    });
    _ = b.addExecutable(.{
        .name = "surfaces",
        .root_source_file = b.path("examples/surfaces/surfaces.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "tileDemo",
        .root_source_file = b.path("examples/tileDemo/tileDemo.zig"),
    });
    _ = b.addExecutable(.{
        .name = "swiDemo",
        .root_source_file = b.path("examples/swiDemo/swiDemo.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "soundDemo",
        .root_source_file = b.path("examples/soundDemo/soundDemo.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    _ = b.addExecutable(.{
        .name = "swiVsync",
        .root_source_file = b.path("examples/swiVsync/swiVsync.zig"),
        .build_options = .{ .text_charsets = .all },
    });

    var bgAffine = b.addExecutable(.{
        .name = "bgAffine",
        .root_source_file = b.path("examples/bgAffine/bgAffine.zig"),
        .build_options = .{ .text_charsets = .all },
    });
    var bgAffine_assets = bgAffine.createAssetModule();
    _ = bgAffine_assets.addImage("background", .{
        .source_file = b.path("examples/bgAffine/tiles.png"),
        .format = .affine_bg_tilemap_8bpp,
        .palette = .{ .provided = &.{ .white, .red, .green, color.ColorRgb555.rgb(0, 16, 31) } },
        .affine_tilemap_8bpp = .{
            .repeat_source = true,
            .dedupe = true,
        },
    });
    bgAffine_assets.addImport("assets");

    var jesuMusic = b.addExecutable(.{
        .name = "jesuMusic",
        .root_source_file = b.path("examples/jesuMusic/jesuMusic.zig"),
    });
    var jesuMusic_assets = jesuMusic.createAssetModule();
    _ = jesuMusic_assets.addImage("charset", .{
        .source_file = b.path("examples/jesuMusic/charset.png"),
    });
    jesuMusic_assets.addImport("assets");

    var mode4flip = b.addExecutable(.{
        .name = "mode4flip",
        .root_source_file = b.path("examples/mode4flip/mode4flip.zig"),
    });
    const mode4flip_palette = mode4flip.addMode4Palette(.{
        .source_files = &.{
            b.path("examples/mode4flip/front.bmp"),
            b.path("examples/mode4flip/back.bmp"),
        },
    });
    var mode4flip_assets = mode4flip.createAssetModule();
    _ = mode4flip_assets.addImage("front", .{
        .source_file = b.path("examples/mode4flip/front.bmp"),
        .format = .mode4_bitmap_8bpp,
        .palette = .{ .provided = mode4flip_palette.getOpaqueColors() },
        .transforms = .{ .pixels = .{ .lz77 = .{} } },
    });
    _ = mode4flip_assets.addImage("back", .{
        .source_file = b.path("examples/mode4flip/back.bmp"),
        .format = .mode4_bitmap_8bpp,
        .palette = .{ .provided = mode4flip_palette.getOpaqueColors() },
        .transforms = .{ .pixels = .{ .lz77 = .{} } },
    });
    mode4flip_assets.addImport("assets");

    var mode4fliplz = b.addExecutable(.{
        .name = "mode4fliplz",
        .root_source_file = b.path("examples/mode4fliplz/mode4fliplz.zig"),
    });
    const mode4fliplz_pal = color.PalettizerNaive.create(
        b.allocator(),
        256,
    ) catch @panic("OOM");
    var mode4fliplz_pal_step = mode4fliplz.addSaveQuantizedPalettizerPaletteStep(.{
        .palettizer = mode4fliplz_pal.pal(),
        .output_path = "examples/mode4fliplz/mode4fliplz.agp",
    });
    const mode4fliplz_front_step = mode4fliplz.addConvertImageBitmap8BppStep(.{
        .image_path = "examples/mode4fliplz/front.bmp",
        .output_path = "examples/mode4fliplz/front.lz",
        .options = .{
            .palettizer = mode4fliplz_pal.pal(),
            .compress_lz77 = true,
        },
    });
    const mode4fliplz_back_step = mode4fliplz.addConvertImageBitmap8BppStep(.{
        .image_path = "examples/mode4fliplz/back.bmp",
        .output_path = "examples/mode4fliplz/back.lz",
        .options = .{
            .palettizer = mode4fliplz_pal.pal(),
            .compress_lz77 = true,
        },
    });
    mode4fliplz_pal_step.step.dependOn(&mode4fliplz_back_step.step);
    mode4fliplz_pal_step.step.dependOn(&mode4fliplz_front_step.step);
}

// Build entry point.
pub fn build(std_b: *std.Build) void {
    const b = GbaBuild.create(std_b);

    // TODO: Use tile and palette data created by the build system for demos

    // Build font data with `zig build font`.
    const font_step = std_b.step("font", "Build fonts for gba.text");
    font_step.dependOn(&b.addBuildFontsStep().step);

    // Build all examples.
    buildExamples(b);

    const host_target = std_b.standardTargetOptions(.{});
    const optimize = std_b.standardOptimizeOption(.{});

    // Run tests from the repository root so SDK and host build helpers can
    // share one test target without escaping the module path.
    const test_sdk = std_b.addRunArtifact(std_b.addTest(.{
        .root_module = std_b.createModule(.{
            .root_source_file = std_b.path("test.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    }));

    const test_step = std_b.step("test", "Run unit tests");
    test_step.dependOn(&test_sdk.step);
}
