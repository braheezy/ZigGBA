const std = @import("std");
pub const gba = @import("src/build/build.zig");

pub const addGBAExecutable = gba.addGBAExecutable;
pub const convertMode4Images = gba.convertMode4Images;
pub const ImageSourceTarget = gba.ImageSourceTarget;

const gba_thumb_target_query = blk: {
    var target = std.Target.Query{
        .cpu_arch = std.Target.Cpu.Arch.thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
        .os_tag = .freestanding,
    };
    target.cpu_features_add.addFeature(@intFromEnum(std.Target.arm.Feature.thumb_mode));
    break :blk target;
};

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const gba_mod = b.addModule("gba", .{
        .root_source_file = b.path("src/gba/gba.zig"),
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = optimize,
    });
    _ = addGBAExecutable(
        b,
        gba_mod,
        "first",
        "examples/first/first.zig",
    );
    _ = addGBAExecutable(
        b,
        gba_mod,
        "mode3draw",
        "examples/mode3draw/mode3draw.zig",
    );
    _ = addGBAExecutable(
        b,
        gba_mod,
        "mode4draw",
        "examples/mode4draw/mode4draw.zig",
    );
    _ = addGBAExecutable(
        b,
        gba_mod,
        "debugPrint",
        "examples/debugPrint/debugPrint.zig",
    );
    _ = addGBAExecutable(
        b,
        gba_mod,
        "secondsTimer",
        "examples/secondsTimer/secondsTimer.zig",
    );

    // Mode 4 Flip
    const mode4flip = gba.addGBAExecutable(
        b,
        gba_mod,
        "mode4flip",
        "examples/mode4flip/mode4flip.zig",
    );
    gba.convertMode4Images(mode4flip, target, &[_]gba.ImageSourceTarget{
        .{
            .source = "examples/mode4flip/front.bmp",
            .target = "examples/mode4flip/front.agi",
        },
        .{
            .source = "examples/mode4flip/back.bmp",
            .target = "examples/mode4flip/back.agi",
        },
    }, "examples/mode4flip/mode4flip.agp", false);

    // Mode 4 Flip but with lz77 compression
    const mode4fliplz = addGBAExecutable(
        b,
        gba_mod,
        "mode4fliplz",
        "examples/mode4fliplz/mode4fliplz.zig",
    );
    convertMode4Images(mode4fliplz, target, &[_]ImageSourceTarget{
        .{
            .source = "examples/mode4fliplz/front.bmp",
            .target = "examples/mode4fliplz/front.lz",
        },
        .{
            .source = "examples/mode4fliplz/back.bmp",
            .target = "examples/mode4fliplz/back.lz",
        },
    }, "examples/mode4fliplz/mode4fliplz.agp", true);

    // Key demo, TODO: Use image created by the build system once we support indexed image
    _ = addGBAExecutable(
        b,
        gba_mod,
        "keydemo",
        "examples/keydemo/keydemo.zig",
    );

    // Simple OBJ demo, TODO: Use tile and palette data created by the build system
    _ = addGBAExecutable(
        b,
        gba_mod,
        "objDemo",
        "examples/objDemo/objDemo.zig",
    );

    // Music example (Jesu, Joy of Man's Desiring)
    const jesuMusic = gba.addGBAExecutable(b, gba_mod, "jesuMusic", "examples/jesuMusic/jesuMusic.zig");
    const converter = gba.getImageConverter(b, target);
    const run_converter = b.addRunArtifact(converter);
    run_converter.addArgs(&[_][]const u8{
        "tiles",
        "examples/jesuMusic/charset.png",
        "examples/jesuMusic/charset.bin",
        "--bpp",
        "4",
    });
    jesuMusic.step.dependOn(&run_converter.step);

    // tileDemo, TODO: Use tileset, tile and palette created by the build system
    _ = addGBAExecutable(
        b,
        gba_mod,
        "tileDemo",
        "examples/tileDemo/tileDemo.zig",
    );

    // screenBlock
    _ = addGBAExecutable(
        b,
        gba_mod,
        "screenBlock",
        "examples/screenBlock/screenBlock.zig",
    );

    // charBlock
    _ = addGBAExecutable(
        b,
        gba_mod,
        "charBlock",
        "examples/charBlock/charBlock.zig",
    );

    // objAffine
    _ = addGBAExecutable(
        b,
        gba_mod,
        "objAffine",
        "examples/objAffine/objAffine.zig",
    );

    // text
    _ = addGBAExecutable(
        b,
        gba_mod,
        "text",
        "examples/text/text.zig",
    );
}
