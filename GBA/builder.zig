const std = @import("std");
const ImageConverter = @import("assetconverter/image_converter.zig").ImageConverter;
const ArrayList = std.ArrayList;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const Step = std.Build.Step;
const builtin = std.builtin;
const fmt = std.fmt;
const fs = std.fs;

pub const ImageSourceTarget = @import("assetconverter/image_converter.zig").ImageSourceTarget;

const gba_linker_script = libRoot() ++ "/gba.ld";
const gba_lib_file = libRoot() ++ "/gba.zig";

// Embed the contents so we can emit them into the build directory regardless of the package's location.
const crt0_contents = @embedFile("gba_crt0.s");
const ld_contents = @embedFile("gba.ld");
const asset_converter_contents = @embedFile("assetconverter/main.zig");
const image_converter_contents = @embedFile("assetconverter/image_converter.zig");
const color_contents = @embedFile("color.zig");

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

fn libRoot() []const u8 {
    return std.fs.path.dirname(@src().file) orelse ".";
}

pub fn addGBAStaticLibrary(b: *std.Build, lib_name: []const u8, source_file: []const u8, debug: bool) *std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = lib_name,
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = source_file } },
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = if (debug) .Debug else .ReleaseFast,
    });

    lib.setLinkerScript(.{ .src_path = .{
        .owner = b,
        .sub_path = gba_linker_script,
    } });

    return lib;
}

pub fn createGBALib(b: *std.Build, debug: bool) *std.Build.Step.Compile {
    return addGBAStaticLibrary(b, "ZigGBA", gba_lib_file, debug);
}

pub fn addGBAExecutable(
    b: *std.Build,
    rom_name: []const u8,
    source_file: []const u8,
    gba_mod: *std.Build.Module,
    debug: bool,
) *std.Build.Step.Compile {
    const use_gdb = use_gdb_option orelse blk: {
        const gdb = b.option(bool, "gdb", "Generate a ELF file for easier debugging with mGBA remote GDB support") orelse false;
        use_gdb_option = gdb;
        break :blk gdb;
    };

    const exe_mod = b.createModule(.{
        .root_source_file = .{ .src_path = .{ .owner = b, .sub_path = source_file } },
        .target = b.resolveTargetQuery(gba_thumb_target_query),
        .optimize = if (debug) .Debug else .ReleaseFast,
    });

    const exe = b.addExecutable(.{
        .name = rom_name,
        .root_module = exe_mod,
    });

    // Generate the linker script and crt0 assembly inside the build directory.
    const write_step = b.addWriteFiles();
    const ld_path = write_step.add("gba.ld", ld_contents);
    const crt0_path = write_step.add("gba_crt0.s", crt0_contents);

    exe.setLinkerScript(ld_path);
    exe.addAssemblyFile(crt0_path);

    if (use_gdb) {
        b.installArtifact(exe);
    } else {
        const objcopy_step = exe.addObjCopy(.{
            .format = .bin,
        });

        const install_bin_step = b.addInstallBinFile(objcopy_step.getOutput(), b.fmt("{s}.gba", .{rom_name}));
        install_bin_step.step.dependOn(&objcopy_step.step);

        b.default_step.dependOn(&install_bin_step.step);
    }

    exe_mod.addImport("gba", gba_mod);

    b.default_step.dependOn(&exe.step);

    return exe;
}

const Mode4ConvertStep = struct {
    step: Step,
    images: []const ImageSourceTarget,
    target_palette_path: []const u8,
    converter_exe: *std.Build.Step.Compile,
    install_step: *std.Build.Step.InstallArtifact,

    pub fn init(b: *std.Build, images: []const ImageSourceTarget, target_palette_path: []const u8) Mode4ConvertStep {
        const write_step = b.addWriteFiles();
        const asset_converter_path = write_step.add("assetconverter/main.zig", asset_converter_contents);
        const color_path = write_step.add("color.zig", color_contents);
        _ = write_step.add("assetconverter/image_converter.zig", image_converter_contents);

        const mod = b.createModule(.{
            .root_source_file = asset_converter_path,
            .optimize = .Debug,
            .target = b.standardTargetOptions(.{}),
        });

        // Build the image converter executable
        const converter_exe = b.addExecutable(.{
            .name = "image-converter",
            .root_module = mod,
        });

        // Add zigimg as a module dependency
        const zigimg_dep = b.dependency("zigimg", .{});
        const zigimg_mod = zigimg_dep.module("zigimg");
        mod.addImport("zigimg", zigimg_mod);

        // Add the GBA directory as a module
        const color_mod = b.createModule(.{
            .root_source_file = color_path,
        });
        mod.addImport("color", color_mod);

        // Install the converter so we can run it
        var install_step = b.addInstallArtifact(converter_exe, .{});

        var step = Step.init(.{
            .id = .custom,
            .name = b.fmt("ConvertMode4Image {s}", .{target_palette_path}),
            .owner = b,
            .makeFn = make,
        });

        // Make our step depend on the installation
        step.dependOn(&install_step.step);

        return Mode4ConvertStep{
            .step = step,
            .images = images,
            .target_palette_path = target_palette_path,
            .converter_exe = converter_exe,
            .install_step = install_step,
        };
    }

    fn make(step: *Step, options: Step.MakeOptions) anyerror!void {
        const self: *Mode4ConvertStep = @fieldParentPtr("step", step);
        var node = options.progress_node.start("Converting mode4 images", 1);
        defer node.end();

        // Convert all images in a single invocation
        const convert_step = self.step.owner.addRunArtifact(self.converter_exe);

        // Add all source and target paths as arguments
        var args = std.ArrayList([]const u8).init(self.step.owner.allocator);
        defer args.deinit();

        for (self.images) |image| {
            try args.append(self.step.owner.pathFromRoot(image.source));
            try args.append(self.step.owner.pathFromRoot(image.target));
        }
        try args.append(self.step.owner.pathFromRoot(self.target_palette_path));

        convert_step.addArgs(args.items);
        try convert_step.step.make(options);
    }
};

pub fn convertMode4Images(compile_step: *std.Build.Step.Compile, images: []const ImageSourceTarget, target_palette_path: []const u8) void {
    const convert_image_step = compile_step.step.owner.allocator.create(Mode4ConvertStep) catch unreachable;
    convert_image_step.* = Mode4ConvertStep.init(compile_step.step.owner, images, target_palette_path);
    compile_step.step.dependOn(&convert_image_step.step);
}
