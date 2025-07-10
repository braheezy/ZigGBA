const std = @import("std");
pub const GBABuilder = @import("GBA/builder.zig");

var is_debug: ?bool = null;

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
    const debug = is_debug orelse blk: {
        const dbg = b.option(bool, "debug", "Generate a debug build") orelse false;
        is_debug = dbg;
        break :blk dbg;
    };
    // const optimize = b.standardOptimizeOption(.{});
    const gba_mod = b.addModule("ZigGBA", .{
        .root_source_file = b.path("GBA/gba.zig"),
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = if (debug) .Debug else .ReleaseFast,
    });
    _ = GBABuilder.addGBAExecutable(
        b,
        "first",
        "examples/first/first.zig",
        gba_mod,
        debug,
    );
    _ = GBABuilder.addGBAExecutable(
        b,
        "mode3draw",
        "examples/mode3draw/mode3draw.zig",
        gba_mod,
        debug,
    );
    _ = GBABuilder.addGBAExecutable(
        b,
        "mode4draw",
        "examples/mode4draw/mode4draw.zig",
        gba_mod,
        debug,
    );
    _ = GBABuilder.addGBAExecutable(
        b,
        "debugPrint",
        "examples/debugPrint/debugPrint.zig",
        gba_mod,
        debug,
    );
    _ = GBABuilder.addGBAExecutable(
        b,
        "secondsTimer",
        "examples/secondsTimer/secondsTimer.zig",
        gba_mod,
        debug,
    );

    // Mode 4 Flip
    const mode4flip = GBABuilder.addGBAExecutable(
        b,
        "mode4flip",
        "examples/mode4flip/mode4flip.zig",
        gba_mod,
        debug,
    );
    GBABuilder.convertMode4Images(mode4flip, &[_]GBABuilder.ImageSourceTarget{
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
    _ = GBABuilder.addGBAExecutable(
        b,
        "keydemo",
        "examples/keydemo/keydemo.zig",
        gba_mod,
        debug,
    );
    // keydemo.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/keydemo/gba_pic.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // Simple OBJ demo, TODO: Use tile and palette data created by the build system
    _ = GBABuilder.addGBAExecutable(
        b,
        "objDemo",
        "examples/objDemo/objDemo.zig",
        gba_mod,
        debug,
    );
    // objDemo.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/objDemo/metroid_sprite_data.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // tileDemo, TODO: Use tileset, tile and palette created by the build system
    _ = GBABuilder.addGBAExecutable(
        b,
        "tileDemo",
        "examples/tileDemo/tileDemo.zig",
        gba_mod,
        debug,
    );
    // tileDemo.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/tileDemo/brin.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // screenBlock
    _ = GBABuilder.addGBAExecutable(
        b,
        "screenBlock",
        "examples/screenBlock/screenBlock.zig",
        gba_mod,
        debug,
    );

    // charBlock
    _ = GBABuilder.addGBAExecutable(
        b,
        "charBlock",
        "examples/charBlock/charBlock.zig",
        gba_mod,
        debug,
    );
    // charBlock.addCSourceFile(.{
    //     .file = .{ .src_path = .{.owner = b, .sub_path = "examples/charBlock/cbb_ids.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });

    // objAffine
    _ = GBABuilder.addGBAExecutable(
        b,
        "objAffine",
        "examples/objAffine/objAffine.zig",
        gba_mod,
        debug,
    );
    // objAffine.addCSourceFile(.{
    //     .file = .{ .src_path = .{ .owner = b, .sub_path = "examples/objAffine/metr.c" } },
    //     .flags = &[_][]const u8{"-std=c99"},
    // });
}
