//! Build script for ZigGBA - A GBA development library for Zig.

const std = @import("std");

/// Build helpers used by a game's `build.zig` to produce GBA ROMs and assets.
pub const GbaBuild = @import("gba_build.zig").GbaBuild;

// Import asset processing utilities
const root_path = GbaBuild.ziggbaPath();
/// Color types and palette helpers available to build scripts.
pub const color = @import("build/color.zig");

/// Add a Zig documentation generator command and install its static output.
const DocsImport = struct {
    name: []const u8,
    source_file: std.Build.LazyPath,
};

fn addDocs(
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    imports: []const DocsImport,
) *std.Build.Step.InstallDir {
    const generate = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build-lib",
        "-fno-emit-bin",
        "--cache-dir",
        b.cache_root.path orelse ".zig-cache",
        "--global-cache-dir",
        b.graph.global_cache_root.path orelse ".zig-global-cache",
    });
    const generated_output_dir = generate.addPrefixedOutputDirectoryArg("-femit-docs=", name);
    for (imports) |import| {
        generate.addArg("--dep");
        generate.addArg(import.name);
    }
    generate.addPrefixedFileArg("-Mroot=", root_source_file);
    for (imports) |import| {
        generate.addPrefixedFileArg(b.fmt("-M{s}=", .{import.name}), import.source_file);
    }

    // The compiler discovers imports itself, so rerun documentation generation
    // whenever this build step is requested rather than tracking only its root.
    generate.stdio = .inherit;

    // A documentation root in the repository root makes Zig archive all of
    // its descendants, including an existing .zig-cache. Those generated
    // sources are not part of the API and may be incomplete while a build is
    // in progress, which otherwise makes the docs UI report parse errors.
    const filter_sources = b.addSystemCommand(&.{
        "python3",
        b.pathFromRoot("scripts/filter_doc_sources.py"),
    });
    filter_sources.addDirectoryArg(generated_output_dir);
    const output_dir = filter_sources.addOutputDirectoryArg("filtered-docs");

    return b.addInstallDirectory(.{
        .source_dir = output_dir,
        .install_dir = .prefix,
        .install_subdir = b.fmt("docs/{s}", .{name}),
    });
}

// Build all example ROMs.
fn buildExamples(b: *GbaBuild) void {
    const math_test = b.addExecutable(.{
        .name = "mathTest",
        .root_source_file = b.path("examples/mathTest/mathTest.zig"),
    });
    // The shared test module owns its relative SDK import as well.
    const gba_module = math_test.step.root_module.import_table.fetchSwapRemove("gba").?.value;
    math_test.step.root_module.addAnonymousImport("gba_tests", .{
        .root_source_file = b.path("src/gba/test.zig"),
        .target = gba_module.resolved_target,
        .optimize = gba_module.optimize,
        .imports = &.{.{ .name = "ziggba_build_options", .module = gba_module.import_table.get("ziggba_build_options").? }},
    });
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
        .name = "save",
        .root_source_file = b.path("examples/save/save.zig"),
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
    var audio = b.addExecutable(.{
        .name = "audio",
        .root_source_file = b.path("examples/audio/audio.zig"),
        .build_options = .{
            .audio = .{},
            .text_charsets = .{ .latin = true },
        },
    });
    var audio_assets = audio.createAudioAssetModule();
    audio_assets.addSound("celeste_level_select", b.path("examples/audio/celeste_level_select.wav"));
    audio_assets.addMusic("bad_apple", b.path("examples/audio/bad_apple.xm"));
    audio_assets.addImport("audio_assets");
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

/// Compile every save-medium code path for the ARM target without executing
/// hardware commands. Host tests cover recovery; this catches target-only
/// calling-convention, volatile-access, and IWRAM placement regressions.
fn compileSaveBackends(b: *GbaBuild) void {
    const gba_module = b.addModule(
        "save-backends-compile-gba",
        b.path("src/gba/gba.zig"),
        .{},
    );
    const check = b.addObject(
        "save-backends-compile",
        b.path("src/gba/save/target_compile.zig"),
        .{},
    );
    check.root_module.addImport("gba", gba_module);

    const check_step = b.b.step("save-backends-compile", "Compile all save media backends for the GBA target");
    check_step.dependOn(&check.step);
    b.b.default_step.dependOn(&check.step);
}

// Build entry point.
pub fn build(std_b: *std.Build) void {
    const b = GbaBuild.create(std_b);

    // Build font data with `zig build font`.
    const font_step = std_b.step("font", "Build fonts for gba.text");
    font_step.dependOn(&b.addBuildFontsStep().step);

    // Build all examples.
    buildExamples(b);
    compileSaveBackends(b);

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

    // Generate the two public API references. Zig's built-in documentation
    // generator emits a self-contained HTML, JavaScript, WebAssembly site.
    const runtime_docs = addDocs(std_b, "gba", std_b.path("src/gba/gba.zig"), &.{});
    // Do not use this repository's build.zig as a documentation root: its
    // exported build function constructs every example and asset pipeline.
    const build_docs = addDocs(std_b, "build", std_b.path("build/build_api.zig"), &.{
        .{ .name = "gba_build", .source_file = std_b.path("gba_build.zig") },
    });
    const docs_index = std_b.addInstallFile(std_b.path("docs/api-index.html"), "docs/index.html");

    const docs_step = std_b.step("docs", "Generate API documentation in zig-out/docs");
    docs_step.dependOn(&runtime_docs.step);
    docs_step.dependOn(&build_docs.step);
    docs_step.dependOn(&docs_index.step);

    const docs_port = std_b.option(u16, "docs-port", "Port used by the docs-serve step") orelse 8000;
    const serve_docs = std_b.addSystemCommand(&.{
        "python3",
        "-m",
        "http.server",
        "--directory",
        std_b.getInstallPath(.prefix, "docs"),
        std_b.fmt("{d}", .{docs_port}),
    });
    serve_docs.step.dependOn(docs_step);

    const serve_docs_step = std_b.step("docs-serve", "Generate and serve API documentation");
    serve_docs_step.dependOn(&serve_docs.step);
}
