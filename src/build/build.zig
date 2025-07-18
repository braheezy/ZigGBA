//! This module provides helpers for building Zig code as a GBA ROM.

const std = @import("std");
const ImageConverter = @import("image_converter.zig").ImageConverter;
const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Step = std.Build.Step;
const builtin = std.builtin;
const fmt = std.fmt;
const fs = std.fs;

pub const GBAColor = @import("../gba/color.zig").Color;
pub const tiles = @import("tiles.zig");
pub const ImageSourceTarget = @import("image_converter.zig").ImageSourceTarget;

fn libRoot() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

const gba_linker_script = libRoot() ++ "/../gba/gba.ld";
const gba_crt0_asm = libRoot() ++ "/../gba/crt0.s";
const gba_start_zig_file = libRoot() ++ "/../gba/start.zig";
const gba_lib_file = libRoot() ++ "/../gba/gba.zig";

var is_debug: ?bool = null;
var use_gdb_option: ?bool = null;

const gba_thumb_target_query = blk: {
    var target = std.Target.Query{
        .cpu_arch = std.Target.Cpu.Arch.thumb,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
        .os_tag = .freestanding,
    };
    target.cpu_features_add.addFeature(@intFromEnum(std.Target.arm.Feature.thumb_mode));
    break :blk target;
};

/// Add a build step to compile a static library.
/// The library will be compiled to run on the GBA.
pub fn addGBAStaticLibrary(
    b: *std.Build,
    lib_name: []const u8,
    source_file: []const u8,
    debug: bool,
) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = lib_name,
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = source_file } },
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = if (debug) .Debug else .ReleaseFast,
    });
    lib.setLinkerScript(.{
        .src_path = .{
            .owner = b,
            .sub_path = gba_linker_script,
        },
    });
    return lib;
}

/// Add a build step to compile an executable, i.e. a GBA ROM.
pub fn addGBAExecutable(
    b: *std.Build,
    rom_name: []const u8,
    source_file: []const u8,
) *std.Build.Step.Compile {
    const debug = is_debug orelse blk: {
        const dbg = b.option(bool, "debug", "Generate a debug build") orelse false;
        is_debug = dbg;
        break :blk dbg;
    };

    const use_gdb = use_gdb_option orelse blk: {
        const gdb = b.option(bool, "gdb", "Generate a ELF file for easier debugging with mGBA remote GDB support") orelse false;
        use_gdb_option = gdb;
        break :blk gdb;
    };

    const start_zig_obj = b.addObject(.{
        .name = "gba_start",
        .root_source_file = .{
            .src_path = .{
                .owner = b,
                .sub_path = gba_start_zig_file,
            },
        },
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = if (debug) .Debug else .ReleaseFast,
    });

    const exe = b.addExecutable(.{
        .name = rom_name,
        .root_source_file = .{
            .src_path = .{
                .owner = b,
                .sub_path = source_file,
            },
        },
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = if (debug) .Debug else .ReleaseFast,
    });

    exe.addObject(start_zig_obj);
    exe.setLinkerScript(.{
        .src_path = .{
            .owner = b,
            .sub_path = gba_linker_script,
        },
    });
    exe.addAssemblyFile(.{
        .src_path = .{
            .owner = b,
            .sub_path = gba_crt0_asm,
        },
    });
    if (use_gdb) {
        b.installArtifact(exe);
    } else {
        const objcopy_step = exe.addObjCopy(.{
            .format = .bin,
        });

        const install_bin_step = b.addInstallBinFile(
            objcopy_step.getOutput(),
            b.fmt("{s}.gba", .{rom_name}),
        );
        install_bin_step.step.dependOn(&objcopy_step.step);

        b.default_step.dependOn(&install_bin_step.step);
    }

    const gba_lib = addGBAStaticLibrary(b, "ZigGBA", gba_lib_file, debug);
    exe.root_module.addAnonymousImport("gba", .{
        .root_source_file = .{
            .src_path = .{
                .owner = b,
                .sub_path = gba_lib_file,
            },
        },
    });
    exe.linkLibrary(gba_lib);

    b.default_step.dependOn(&exe.step);

    return exe;
}

const Mode4ConvertStep = struct {
    step: Step,
    images: []const ImageSourceTarget,
    target_palette_path: []const u8,

    pub fn init(b: *std.Build, images: []const ImageSourceTarget, target_palette_path: []const u8) Mode4ConvertStep {
        return Mode4ConvertStep{
            .step = Step.init(.{
                .id = .custom,
                .name = b.fmt("ConvertMode4Image {s}", .{target_palette_path}),
                .owner = b,
                .makeFn = make,
            }),
            .images = images,
            .target_palette_path = target_palette_path,
        };
    }

    fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
        const self: *Mode4ConvertStep = @fieldParentPtr("step", step);
        const ImageSourceTargetList = ArrayList(ImageSourceTarget);

        var full_images = ImageSourceTargetList.init(step.owner.allocator);
        defer full_images.deinit();

        var node = options.progress_node.start("Converting mode4 images", 1);
        defer node.end();

        for (self.images) |image| {
            try full_images.append(ImageSourceTarget{
                .source = self.step.owner.pathFromRoot(image.source),
                .target = self.step.owner.pathFromRoot(image.target),
            });
        }

        const full_target_palette_path = self.step.owner.pathFromRoot(self.target_palette_path);
        try ImageConverter.convertMode4Image(self.step.owner.allocator, full_images.items, full_target_palette_path);
    }
};

pub fn convertMode4Images(compile_step: *std.Build.Step.Compile, images: []const ImageSourceTarget, target_palette_path: []const u8) void {
    const convert_image_step = compile_step.step.owner.allocator.create(Mode4ConvertStep) catch unreachable;
    convert_image_step.* = Mode4ConvertStep.init(compile_step.step.owner, images, target_palette_path);
    compile_step.step.dependOn(&convert_image_step.step);
}
