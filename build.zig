//! Build script for ZigGBA - A GBA development library for Zig.

const std = @import("std");
const cc_helper = @import("cc_helper");

// Import asset processing utilities
const color = @import("build/color.zig");
const font = @import("build/font.zig");
const image = @import("build/image.zig");

// Import types from GBA runtime
const LoggerInterface = @import("src/gba/debug.zig").LoggerInterface;
const CharsetFlags = font.CharsetFlags;

const gba_linker_script_path = "src/gba/gba.ld";
const gba_start_zig_file_path = "src/gba/start.zig";
const gba_lib_file_path = "src/gba/gba.zig";

const asm_file_paths = [_][]const u8{
    "src/gba/crt0.s",
    "src/gba/isr.s",
    "src/gba/math.s",
    "src/gba/mem.s",
};

pub const GbaBuild = struct {
    pub const CliOptions = struct {
        debug: bool = false,
        safe: bool = false,
        gdb: bool = false,
    };

    /// These build options control some aspects of how ZigGBA is compiled.
    pub const BuildOptions = struct {
        /// Choose default logger for use with `gba.debug.print` and
        /// `gba.debug.write`.
        default_logger: LoggerInterface = .mgba,
        /// Options relating to `gba.text`.
        /// Each charset flag, e.g. `charset_latin`, controls whether `gba.text`
        /// will embed font data for a certain subset of Unicode code points
        /// into the compiled ROM.
        text_charsets: CharsetFlags = .{},
    };

    /// `std.Target.Query` object for GBA thumb compilation target.
    pub const thumb_target_query = blk: {
        var target = std.Target.Query{
            .cpu_arch = std.Target.Cpu.Arch.thumb,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm7tdmi },
            .os_tag = .freestanding,
        };
        target.cpu_features_add.addFeature(@intFromEnum(std.Target.arm.Feature.thumb_mode));
        break :blk target;
    };

    b: *std.Build,
    ziggba_dep: ?*std.Build.Dependency,
    thumb_target: std.Build.ResolvedTarget,
    optimize_mode: std.builtin.OptimizeMode,
    gdb: bool,

    pub fn create(b: *std.Build) *GbaBuild {
        const gba_b = b.allocator.create(GbaBuild) catch @panic("OOM");
        gba_b.* = GbaBuild.init(b);
        return gba_b;
    }

    pub fn init(b: *std.Build) GbaBuild {
        const cli_options = GbaBuild.getCliOptions(b);
        var ziggba_dep: ?*std.Build.Dependency = null;
        for (b.available_deps) |dep| {
            if (std.mem.eql(u8, dep[0], "ziggba")) {
                ziggba_dep = b.dependency("ziggba", .{});
                break;
            }
        }
        var optimize_mode: std.builtin.OptimizeMode = .ReleaseFast;
        if (cli_options.debug) {
            optimize_mode = .Debug;
        } else if (cli_options.safe) {
            optimize_mode = .ReleaseSafe;
        }
        return .{
            .b = b,
            .ziggba_dep = ziggba_dep,
            .thumb_target = b.resolveTargetQuery(GbaBuild.thumb_target_query),
            .optimize_mode = optimize_mode,
            .gdb = cli_options.gdb,
        };
    }

    /// Get the allocator belonging to the underling `std.Build` instance.
    pub fn allocator(self: GbaBuild) std.mem.Allocator {
        return self.b.allocator;
    }

    /// Get a path relative to the build directory.
    pub fn path(self: GbaBuild, sub_path: []const u8) std.Build.LazyPath {
        return self.b.path(sub_path);
    }

    /// Get a path relative to the ZigGBA build directory.
    pub fn ziggbaPath(self: GbaBuild, sub_path: []const u8) std.Build.LazyPath {
        if (self.ziggba_dep) |dep| {
            return .{
                .dependency = .{
                    .dependency = dep,
                    .sub_path = sub_path,
                },
            };
        } else {
            return self.b.path(sub_path);
        }
    }

    /// Get options passed via compiler arguments.
    /// - -Ddebug - Do a debug build, instead of an optimized release build.
    /// - -Dgdb - Output an ELF containing debug symbols.
    pub fn getCliOptions(b: *std.Build) CliOptions {
        return .{
            .debug = blk: {
                break :blk b.option(
                    bool,
                    "debug",
                    "Build the GBA ROM in debug mode instead of release mode.",
                ) orelse false;
            },
            .safe = blk: {
                break :blk b.option(
                    bool,
                    "safe",
                    "Build the GBA ROM in ReleaseSafe mode instead of ReleaseFast.",
                ) orelse false;
            },
            .gdb = blk: {
                break :blk b.option(
                    bool,
                    "gdb",
                    "Generate an ELF file with debug symbols alongside the GBA ROM.",
                ) orelse false;
            },
        };
    }

    /// Get an `std.Build.Step.Options` object corresponding to some given
    /// `BuildOptions`.
    fn getBuildOptions(
        b: *std.Build,
        build_options: BuildOptions,
    ) *std.Build.Step.Options {
        const b_options = b.addOptions();
        b_options.addOption(LoggerInterface, "default_logger", build_options.default_logger);
        b_options.addOption(CharsetFlags, "text_charsets", build_options.text_charsets);
        return b_options;
    }

    /// Add font-related imports to a module.
    /// These files contain glyph data bitmaps used by `gba.text`.
    pub fn addFontImports(
        self: GbaBuild,
        module: *std.Build.Module,
        build_options: BuildOptions,
    ) void {
        inline for (font.charsets) |charset| {
            if (@field(build_options.text_charsets, charset.name)) {
                const png_path = comptime ("assets/font_" ++ charset.name ++ ".bin");
                module.addAnonymousImport(
                    "ziggba_font_" ++ charset.name ++ ".bin",
                    .{ .root_source_file = self.ziggbaPath(png_path) },
                );
            }
        }
    }

    /// Add `ziggba_build_options` import to a module.
    pub fn addBuildOptions(
        self: GbaBuild,
        module: *std.Build.Module,
        build_options: BuildOptions,
    ) void {
        const b_options = GbaBuild.getBuildOptions(self.b, build_options);
        module.addOptions("ziggba_build_options", b_options);
    }

    /// Add a build step to compile a module.
    pub fn addModule(
        self: GbaBuild,
        name: []const u8,
        root_source_file: std.Build.LazyPath,
        build_options: BuildOptions,
    ) *std.Build.Module {
        const module = self.b.addModule(name, .{
            .target = self.thumb_target,
            .optimize = self.optimize_mode,
            .root_source_file = root_source_file,
        });
        self.addFontImports(module, build_options);
        self.addBuildOptions(module, build_options);
        return module;
    }

    /// Add a build step to compile a static library.
    pub fn addStaticLibrary(
        self: GbaBuild,
        library_name: []const u8,
        root_module: *std.Build.Module,
        build_options: BuildOptions,
    ) *std.Build.Step.Compile {
        const lib = self.b.addLibrary(.{
            .linkage = .static,
            .name = library_name,
            .root_module = root_module,
        });
        lib.setLinkerScript(self.ziggbaPath(gba_linker_script_path));
        self.addFontImports(lib.root_module, build_options);
        self.addBuildOptions(lib.root_module, build_options);
        return lib;
    }

    pub fn addObject(
        self: GbaBuild,
        object_name: []const u8,
        root_source_file: std.Build.LazyPath,
        build_options: BuildOptions,
    ) *std.Build.Step.Compile {
        const object = self.b.addObject(.{
            .name = object_name,
            .root_module = self.b.createModule(.{
                .root_source_file = root_source_file,
                .target = self.thumb_target,
                .optimize = self.optimize_mode,
            }),
        });
        self.addFontImports(object.root_module, build_options);
        self.addBuildOptions(object.root_module, build_options);
        return object;
    }

    pub const ExecutableOptions = struct {
        name: []const u8,
        root_source_file: std.Build.LazyPath,
        build_options: BuildOptions = .{},
    };

    /// Add a build step to compile an executable, i.e. a GBA ROM.
    pub fn addExecutable(
        self: *GbaBuild,
        options: ExecutableOptions,
    ) *GbaExecutable {
        const exe_module = self.b.createModule(.{
            .target = self.thumb_target,
            .optimize = self.optimize_mode,
            .root_source_file = options.root_source_file,
        });
        const exe = self.b.addExecutable(.{
            .name = options.name,
            .root_module = exe_module,
        });
        self.addFontImports(exe_module, options.build_options);
        self.addBuildOptions(exe_module, options.build_options);
        self.b.default_step.dependOn(&exe.step);
        // Zig entry point and startup routine
        exe.addObject(self.addObject(
            "gba_start",
            self.ziggbaPath(gba_start_zig_file_path),
            options.build_options,
        ));
        // ZigGBA as a static library
        const gba_module = self.addModule(
            "gba",
            self.ziggbaPath(gba_lib_file_path),
            options.build_options,
        );
        exe.linkLibrary(self.addStaticLibrary(
            "ziggba",
            gba_module,
            options.build_options,
        ));
        exe_module.addImport("gba", gba_module);
        // Linker script
        exe.setLinkerScript(self.ziggbaPath(gba_linker_script_path));
        // Assembly modules
        for (asm_file_paths) |asm_path| {
            exe.addAssemblyFile(self.ziggbaPath(asm_path));
        }
        // Generate GBA ROM
        // Use cc_helper's objcopy (port of Zig 0.14.1) to avoid Zig 0.15.1 padding bug
        // See: https://github.com/ziglang/zig/issues/24522
        const objcopy = self.b.dependency("cc_helper", .{
            .target = self.b.graph.host,
            .optimize = .ReleaseFast,
        }).artifact("objcopy");

        const gba_file = self.b.fmt("{s}.gba", .{options.name});
        const run_objcopy = self.b.addRunArtifact(objcopy);
        run_objcopy.addArgs(&.{ "-O", "binary" });
        run_objcopy.addFileArg(exe.getEmittedBin());
        const raw_gba = run_objcopy.addOutputFileArg(self.b.fmt("{s}.bin", .{options.name}));

        // Strip padding from the binary
        // Search for Nintendo logo + branch instruction pattern at ROM start (more unique than just branch)
        const strip_padding = self.b.addSystemCommand(&.{
            "python3",
            "-c",
            "import sys; data = open(sys.argv[1], 'rb').read(); logo_start = data.find(b'\\x24\\xff\\xae\\x51\\x69\\x9a\\xa2\\x21'); idx = max(0, logo_start - 4) if logo_start > 0 else 0; open(sys.argv[2], 'wb').write(data[idx:])",
        });
        strip_padding.addFileArg(raw_gba);
        const gba_output = strip_padding.addOutputFileArg(gba_file);

        const install_bin_step = self.b.addInstallFile(gba_output, gba_file);
        self.b.default_step.dependOn(&install_bin_step.step);
        // Optionally generate ELF file with debug symbols
        if (self.gdb) {
            const install_elf_step = self.b.addInstallArtifact(exe, .{
                // TODO: Why are ELF files still emitting with no extension?
                .dest_sub_path = self.b.fmt("{s}.elf", .{options.name}),
            });
            self.b.getInstallStep().dependOn(&install_elf_step.step);
        }
        // Fin
        return .create(self, exe);
    }

    /// Add a build step for building font data for `gba.text`, converting
    /// PNG images to bitmap data in a compact binary format.
    pub fn addBuildFontsStep(
        self: *GbaBuild,
    ) *font.BuildFontsStep {
        return font.BuildFontsStep.create(self);
    }

    pub fn addConvertImageTiles4BppStep(
        self: GbaBuild,
        options: image.ConvertImageTiles4BppStep.Options,
    ) *image.ConvertImageTiles4BppStep {
        return image.ConvertImageTiles4BppStep.create(self.b, options);
    }

    pub fn addConvertImageTiles8BppStep(
        self: GbaBuild,
        options: image.ConvertImageTiles8BppStep.Options,
    ) *image.ConvertImageTiles8BppStep {
        return image.ConvertImageTiles8BppStep.create(self.b, options);
    }

    pub fn addConvertImageBitmap8BppStep(
        self: GbaBuild,
        options: image.ConvertImageBitmap8BppStep.Options,
    ) *image.ConvertImageBitmap8BppStep {
        return image.ConvertImageBitmap8BppStep.create(self.b, options);
    }

    pub fn addConvertImageBitmap16BppStep(
        self: GbaBuild,
        options: image.ConvertImageBitmap16BppStep.Options,
    ) *image.ConvertImageBitmap16BppStep {
        return image.ConvertImageBitmap16BppStep.create(self.b, options);
    }

    pub fn addSavePaletteStep(
        self: GbaBuild,
        options: color.SavePaletteStep.Options,
    ) *color.SavePaletteStep {
        return color.SavePaletteStep.create(self.b, options);
    }

    pub fn addSaveQuantizedPalettizerPaletteStep(
        self: GbaBuild,
        options: color.SaveQuantizedPalettizerPaletteStep.Options,
    ) *color.SaveQuantizedPalettizerPaletteStep {
        return color.SaveQuantizedPalettizerPaletteStep.create(self.b, options);
    }
};

pub const GbaExecutable = struct {
    b: *GbaBuild,
    step: *std.Build.Step.Compile,

    pub fn init(b: *GbaBuild, step: *std.Build.Step.Compile) GbaExecutable {
        return .{ .b = b, .step = step };
    }

    pub fn create(b: *GbaBuild, step: *std.Build.Step.Compile) *GbaExecutable {
        const exe = b.allocator().create(GbaExecutable) catch @panic("OOM");
        exe.* = .init(b, step);
        return exe;
    }

    pub fn getOwner(self: GbaExecutable) *std.Build {
        return self.step.step.owner;
    }

    pub fn dependOn(self: *GbaExecutable, step: *std.Build.Step) void {
        self.step.step.dependOn(step);
    }

    /// Add a step that the executable depends on.
    pub fn addBuildFontsStep(
        self: *GbaExecutable,
    ) *font.BuildFontsStep {
        const step = font.BuildFontsStep.create(self.b);
        self.dependOn(&step.step);
        return step;
    }

    /// Add a step that the executable depends on.
    pub fn addConvertImageTiles4BppStep(
        self: *GbaExecutable,
        options: image.ConvertImageTiles4BppStep.Options,
    ) *image.ConvertImageTiles4BppStep {
        const step = image.ConvertImageTiles4BppStep.create(
            self.getOwner(),
            options,
        );
        self.dependOn(&step.step);
        return step;
    }

    /// Add a step that the executable depends on.
    pub fn addConvertImageTiles8BppStep(
        self: *GbaExecutable,
        options: image.ConvertImageTiles8BppStep.Options,
    ) *image.ConvertImageTiles8BppStep {
        const step = image.ConvertImageTiles8BppStep.create(
            self.getOwner(),
            options,
        );
        self.dependOn(&step.step);
        return step;
    }

    /// Add a step that the executable depends on.
    pub fn addConvertImageBitmap8BppStep(
        self: *GbaExecutable,
        options: image.ConvertImageBitmap8BppStep.Options,
    ) *image.ConvertImageBitmap8BppStep {
        const step = image.ConvertImageBitmap8BppStep.create(
            self.getOwner(),
            options,
        );
        self.dependOn(&step.step);
        return step;
    }

    /// Add a step that the executable depends on.
    pub fn addConvertImageBitmap16BppStep(
        self: *GbaExecutable,
        options: image.ConvertImageBitmap16BppStep.Options,
    ) *image.ConvertImageBitmap16BppStep {
        const step = image.ConvertImageBitmap16BppStep.create(
            self.getOwner(),
            options,
        );
        self.dependOn(&step.step);
        return step;
    }

    /// Add a step that the executable depends on.
    pub fn addSavePaletteStep(
        self: *GbaExecutable,
        options: color.SavePaletteStep.Options,
    ) *color.SavePaletteStep {
        const step = color.SavePaletteStep.create(
            self.getOwner(),
            options,
        );
        self.dependOn(&step.step);
        return step;
    }

    /// Add a step that the executable depends on.
    pub fn addSaveQuantizedPalettizerPaletteStep(
        self: *GbaExecutable,
        options: color.SaveQuantizedPalettizerPaletteStep.Options,
    ) *color.SaveQuantizedPalettizerPaletteStep {
        const step = color.SaveQuantizedPalettizerPaletteStep.create(
            self.getOwner(),
            options,
        );
        self.dependOn(&step.step);
        return step;
    }
};

/// Build all example ROMs.
fn buildExamples(b: *GbaBuild) void {
    _ = b.addExecutable(.{
        .name = "charBlock",
        .root_source_file = b.path("examples/charBlock/charBlock.zig"),
    });
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
    const bgAffine_pal = color.PalettizerNearest.create(
        b.allocator(),
        &[_]color.ColorRgba32{
            .transparent,
            .white,
            .red,
            .green,
            .aqua,
        },
    ) catch @panic("OOM");
    _ = bgAffine.addConvertImageTiles8BppStep(.{
        .image_path = "examples/bgAffine/tiles.png",
        .output_path = "examples/bgAffine/tiles.bin",
        .options = .{ .palettizer = bgAffine_pal.pal() },
    });

    var jesuMusic = b.addExecutable(.{
        .name = "jesuMusic",
        .root_source_file = b.path("examples/jesuMusic/jesuMusic.zig"),
    });
    const jesuMusic_pal = color.PalettizerNearest.create(
        b.allocator(),
        &[_]color.ColorRgba32{
            .transparent,
            .white,
            .black,
        },
    ) catch @panic("OOM");
    _ = jesuMusic.addConvertImageTiles4BppStep(.{
        .image_path = "examples/jesuMusic/charset.png",
        .output_path = "examples/jesuMusic/charset.bin",
        .options = .{ .palettizer = jesuMusic_pal.pal() },
    });

    var mode4flip = b.addExecutable(.{
        .name = "mode4flip",
        .root_source_file = b.path("examples/mode4flip/mode4flip.zig"),
    });
    const mode4flip_pal = color.PalettizerNaive.create(
        b.allocator(),
        256,
    ) catch @panic("OOM");
    var mode4flip_pal_step = mode4flip.addSaveQuantizedPalettizerPaletteStep(.{
        .palettizer = mode4flip_pal.pal(),
        .output_path = "examples/mode4flip/mode4flip.agp",
    });
    const mode4flip_front_step = mode4flip.addConvertImageBitmap8BppStep(.{
        .image_path = "examples/mode4flip/front.bmp",
        .output_path = "examples/mode4flip/front.agi",
        .options = .{ .palettizer = mode4flip_pal.pal() },
    });
    const mode4flip_back_step = mode4flip.addConvertImageBitmap8BppStep(.{
        .image_path = "examples/mode4flip/back.bmp",
        .output_path = "examples/mode4flip/back.agi",
        .options = .{ .palettizer = mode4flip_pal.pal() },
    });
    mode4flip_pal_step.step.dependOn(&mode4flip_front_step.step);
    mode4flip_pal_step.step.dependOn(&mode4flip_back_step.step);

    var mode4fliplz = b.addExecutable(.{
        .name = "mode4fliplz",
        .root_source_file = b.path("examples/mode4fliplz/mode4fliplz.zig"),
    });
    var mode4fliplz_pal_step = mode4fliplz.addSaveQuantizedPalettizerPaletteStep(.{
        .palettizer = mode4flip_pal.pal(),
        .output_path = "examples/mode4fliplz/mode4fliplz.agp",
    });
    const mode4fliplz_front_step = mode4fliplz.addConvertImageBitmap8BppStep(.{
        .image_path = "examples/mode4fliplz/front.bmp",
        .output_path = "examples/mode4fliplz/front.lz",
        .options = .{
            .palettizer = mode4flip_pal.pal(),
            .compress_lz77 = true,
        },
    });
    const mode4fliplz_back_step = mode4fliplz.addConvertImageBitmap8BppStep(.{
        .image_path = "examples/mode4fliplz/back.bmp",
        .output_path = "examples/mode4fliplz/back.lz",
        .options = .{
            .palettizer = mode4flip_pal.pal(),
            .compress_lz77 = true,
        },
    });
    mode4fliplz_pal_step.step.dependOn(&mode4fliplz_back_step.step);
    mode4fliplz_pal_step.step.dependOn(&mode4fliplz_front_step.step);
}

/// Build entry point.
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

    // Run tests with `zig build test`.
    const test_math = std_b.addRunArtifact(std_b.addTest(.{
        .root_module = std_b.createModule(.{
            .root_source_file = std_b.path("src/gba/math.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    }));
    const test_format = std_b.addRunArtifact(std_b.addTest(.{
        .root_module = std_b.createModule(.{
            .root_source_file = std_b.path("src/gba/format.zig"),
            .target = host_target,
            .optimize = optimize,
        }),
    }));

    const test_step = std_b.step("test", "Run unit tests");
    test_step.dependOn(&test_math.step);
    test_step.dependOn(&test_format.step);
}
