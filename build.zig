const std = @import("std");
pub const GBABuilder = @import("GBA/builder.zig");

pub const addGBAExecutable = GBABuilder.addGBAExecutable;
pub const convertMode4Images = GBABuilder.convertMode4Images;
pub const ImageSourceTarget = GBABuilder.ImageSourceTarget;

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
        .root_source_file = b.path("GBA/gba.zig"),
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
    const mode4flip = addGBAExecutable(
        b,
        gba_mod,
        "mode4flip",
        "examples/mode4flip/mode4flip.zig",
    );
    convertMode4Images(mode4flip, target, &[_]ImageSourceTarget{
        .{
            .source = "examples/mode4flip/front.bmp",
            .target = "examples/mode4flip/front.agi",
        },
        .{
            .source = "examples/mode4flip/back.bmp",
            .target = "examples/mode4flip/back.agi",
        },
    }, "examples/mode4flip/mode4flip.agp");

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
    // objDemo.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/objDemo/metroid_sprite_data.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // tileDemo, TODO: Use tileset, tile and palette created by the build system
    _ = addGBAExecutable(
        b,
        gba_mod,
        "tileDemo",
        "examples/tileDemo/tileDemo.zig",
    );
    // tileDemo.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/tileDemo/brin.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

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
    // charBlock.addCSourceFile(.{
    //     .file = .{ .src_path = .{.owner = b, .sub_path = "examples/charBlock/cbb_ids.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // objAffine
    _ = addGBAExecutable(
        b,
        gba_mod,
        "objAffine",
        "examples/objAffine/objAffine.zig",
    );
    // objAffine.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/objAffine/metr.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // text
    _ = addGBAExecutable(
        b,
        gba_mod,
        "text",
        "examples/text/text.zig",
    );
}
