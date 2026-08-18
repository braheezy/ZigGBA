//! High-level image assets for GBA projects.
//!
//! This module intentionally sits above the lower-level image converters. It
//! provides a convention-driven path for common assets while leaving the
//! converter APIs available to projects with custom pipelines.

const std = @import("std");
const color = @import("color.zig");
const image = @import("image.zig");
const lz77 = @import("lz77.zig");
const ColorRgb555 = @import("../src/gba/graphics/color.zig").ColorRgb555;
const BackgroundSize = @import("../src/gba/display/mod.zig").BackgroundSize;

/// A converted image and the generated module that exposes its runtime data.
pub const ImageAsset = struct {
    /// The module containing the typed image data. Add it to an executable
    /// module with `std.Build.Module.addImport`.
    module: *std.Build.Module,
    /// Generated tile data, or its transformed output when configured.
    tiles: std.Build.LazyPath,
    /// Generated palette data, or its transformed output when configured.
    palette: std.Build.LazyPath,
    /// Generated screenblock entries, or their transformed output when configured.
    map: ?std.Build.LazyPath = null,
    /// Generated Mode 4 pixels, or their transformed output when configured.
    pixels: ?std.Build.LazyPath = null,

    pub const Format = enum {
        /// 4bpp tiles for use with GBA OBJ (sprite) graphics.
        obj_tiles_4bpp,
        /// 4bpp tiles and a normal-background tilemap.
        bg_tilemap_4bpp,
        /// 4bpp tiles and a normal-background tilemap using up to sixteen
        /// independent 16-color palette banks.
        bg_tilemap_4bpp_multi_bank,
        /// 8bpp tiles and a normal-background tilemap.
        bg_tilemap_8bpp,
        /// 8bpp tiles and an affine-background tilemap.
        affine_bg_tilemap_8bpp,
        /// 8bpp indexed pixels for a full-screen Mode 4 bitmap.
        mode4_bitmap_8bpp,
    };

    /// How opaque image colors are assigned to target palette entries.
    /// Palette index zero is always reserved for transparent pixels.
    pub const Palette = union(enum) {
        /// Extract the exact RGB555 colors used by the image. This is the
        /// safe default and rejects images that exceed the target's capacity.
        auto,
        /// Use these opaque RGB555 colors exactly. Every opaque source color
        /// must appear in this palette after RGB555 conversion.
        provided: []const ColorRgb555,
        /// Use these opaque RGB555 colors, mapping every opaque source color
        /// to its closest entry. This is intentionally lossy.
        nearest: []const ColorRgb555,
    };

    /// Options for GBA BIOS LZ77 compression.
    pub const Lz77Options = struct {
        /// Keep back-references safe for `gba.bios.lz77UnCompVRAM`. This costs
        /// a little compression ratio, but makes the output safe for either
        /// the WRAM or VRAM BIOS decompressor.
        vram_safe: bool = true,
    };

    /// A transform applied independently to one generated asset output.
    /// More transform kinds can be added without changing image formats.
    pub const OutputTransform = union(enum) {
        lz77: Lz77Options,
    };

    /// Opt-in transforms for generated asset outputs.
    ///
    /// A transformed output is exported as `{name}_lz77` and
    /// `{name}_lz77_uncompressed_len`, rather than `{name}`. This prevents
    /// the uncompressed data from also being embedded in the ROM.
    pub const OutputTransforms = struct {
        tiles: ?OutputTransform = null,
        palette: ?OutputTransform = null,
        map: ?OutputTransform = null,
        pixels: ?OutputTransform = null,
    };

    /// Describes a grid of equally sized sprite frames in the source image.
    /// Both dimensions must be non-zero multiples of eight pixels.
    pub const SpriteSheet = struct {
        frame_width: u16,
        frame_height: u16,
    };

    /// Options specific to normal 4bpp background tilemaps.
    pub const TilemapOptions = struct {
        /// Palette bank stored in every generated screenblock entry.
        palette_bank: u4 = 0,
        /// Reuse identical source tiles. Disabled by default so tile indices
        /// retain source order and are easy to inspect while developing.
        dedupe: bool = false,
        /// Also reuse horizontally and vertically flipped tiles. Only has an
        /// effect when `dedupe` is enabled.
        dedupe_flips: bool = false,
    };

    /// Options specific to multi-bank normal 4bpp background tilemaps.
    pub const MultiBankTilemap4BppOptions = struct {
        /// Palette-bank assignment. `.auto` uses deterministic greedy packing;
        /// `.provided` preserves artist-supplied bank layouts exactly.
        palette_banks: image.MultiBankPalette4Bpp = .auto,
        /// Reuse identical source tiles. Disabled by default so tile indices
        /// retain source order and are easy to inspect while developing.
        dedupe: bool = false,
        /// Also reuse horizontally and vertically flipped tiles. Only has an
        /// effect when `dedupe` is enabled.
        dedupe_flips: bool = false,
    };

    /// Options specific to normal 8bpp background tilemaps.
    pub const Tilemap8BppOptions = struct {
        /// Reuse identical source tiles. Disabled by default so tile indices
        /// retain source order and are easy to inspect while developing.
        dedupe: bool = false,
        /// Also reuse horizontally and vertically flipped tiles. Only has an
        /// effect when `dedupe` is enabled.
        dedupe_flips: bool = false,
    };

    /// Options specific to affine 8bpp background tilemaps.
    pub const AffineTilemap8BppOptions = struct {
        /// Explicit affine map size. When omitted, the smallest square GBA
        /// affine size that contains the source tile grid is selected.
        size: ?BackgroundSize.Affine = null,
        /// Repeat the source tile grid to fill the affine map. Otherwise the
        /// source occupies the top-left and remaining entries use tile zero.
        repeat_source: bool = false,
        /// Reuse identical source tiles. Disabled by default so tile indices
        /// retain source order and are easy to inspect while developing.
        dedupe: bool = false,
    };

    pub const Options = struct {
        /// Source image to convert. It must be available when `build.zig` is
        /// evaluated; generated images are not supported by this eager path.
        source_file: std.Build.LazyPath,
        /// Output format. More image targets will be added alongside their
        /// corresponding typed runtime interfaces.
        format: Format = .obj_tiles_4bpp,
        /// Palette handling for paletted formats.
        palette: Palette = .auto,
        /// Optional transforms applied to the generated binary outputs.
        transforms: OutputTransforms = .{},
        /// Optional sprite-frame grid. When omitted, the full image is one
        /// frame. Tiles remain in the source image's row-major tile order.
        sprite_sheet: ?SpriteSheet = null,
        /// Tilemap handling for `bg_tilemap_4bpp`.
        tilemap: TilemapOptions = .{},
        /// Tilemap handling for `bg_tilemap_4bpp_multi_bank`.
        multi_bank_tilemap_4bpp: MultiBankTilemap4BppOptions = .{},
        /// Tilemap handling for `bg_tilemap_8bpp`.
        tilemap_8bpp: Tilemap8BppOptions = .{},
        /// Tilemap handling for `affine_bg_tilemap_8bpp`.
        affine_tilemap_8bpp: AffineTilemap8BppOptions = .{},
    };

    /// Adds this asset as an import of `consumer_module`.
    ///
    /// `gba_module` should be the module used by the executable so generated
    /// asset types and game code share the same SDK instance.
    pub fn addImport(
        self: *ImageAsset,
        consumer_module: *std.Build.Module,
        import_name: []const u8,
        gba_module: *std.Build.Module,
    ) void {
        self.module.addImport("gba", gba_module);
        consumer_module.addImport(import_name, self.module);
    }

    /// Creates an image asset using the safe default palette policy: reserve
    /// index zero for transparency, extract all remaining colors exactly after
    /// RGB555 conversion, and fail if the image exceeds the target palette
    /// capacity.
    pub fn create(b: *std.Build, options: Options) *ImageAsset {
        validateOutputTransforms(options);
        const source_path = switch (options.source_file) {
            .generated => std.debug.panic(
                "generated image inputs are not supported by ImageAsset yet; " ++
                    "use the lower-level image converters for build-step inputs",
                .{},
            ),
            else => options.source_file.getPath(b),
        };

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();

        var source = image.Image.fromFilePath(b.allocator, threaded.io(), source_path) catch |err| {
            std.debug.panic("unable to load image asset '{s}': {s}", .{ source_path, @errorName(err) });
        };
        defer source.deinit(b.allocator);

        return switch (options.format) {
            .obj_tiles_4bpp => createObjTiles4Bpp(b, source_path, source, options),
            .bg_tilemap_4bpp => createBackgroundTilemap4Bpp(b, source_path, source, options),
            .bg_tilemap_4bpp_multi_bank => createMultiBankBackgroundTilemap4Bpp(b, source_path, source, options),
            .bg_tilemap_8bpp => createBackgroundTilemap8Bpp(b, source_path, source, options),
            .affine_bg_tilemap_8bpp => createAffineBackgroundTilemap8Bpp(b, source_path, source, options),
            .mode4_bitmap_8bpp => createMode4Bitmap8Bpp(b, source_path, source, options),
        };
    }
};

const AssetOutput = struct {
    path: std.Build.LazyPath,
    file_name: []const u8,
    raw_len: usize,
    compressed_len: usize,
    transform: ?ImageAsset.OutputTransform,
};

fn validateOutputTransforms(options: ImageAsset.Options) void {
    const transforms = options.transforms;
    switch (options.format) {
        .obj_tiles_4bpp => {
            rejectTransform("map", transforms.map);
            rejectTransform("pixels", transforms.pixels);
        },
        .bg_tilemap_4bpp,
        .bg_tilemap_4bpp_multi_bank,
        .bg_tilemap_8bpp,
        .affine_bg_tilemap_8bpp,
        => rejectTransform("pixels", transforms.pixels),
        .mode4_bitmap_8bpp => {
            rejectTransform("tiles", transforms.tiles);
            rejectTransform("map", transforms.map);
        },
    }
}

fn rejectTransform(name: []const u8, transform: ?ImageAsset.OutputTransform) void {
    if (transform != null) {
        std.debug.panic("this image format does not generate a '{s}' output to transform", .{name});
    }
}

fn writeAssetOutput(
    b: *std.Build,
    write_files: *std.Build.Step.WriteFile,
    raw_file_name: []const u8,
    raw_data: []const u8,
    transform: ?ImageAsset.OutputTransform,
) AssetOutput {
    if (transform) |selected| {
        switch (selected) {
            .lz77 => |options| {
                const data = lz77.compress(b.allocator, raw_data, options.vram_safe) catch |err| {
                    std.debug.panic("unable to LZ77-compress generated asset output: {s}", .{@errorName(err)});
                };
                defer b.allocator.free(data);
                const file_name = b.fmt("{s}.lz77", .{std.fs.path.stem(raw_file_name)});
                return .{
                    .path = write_files.add(file_name, data),
                    .file_name = file_name,
                    .raw_len = raw_data.len,
                    .compressed_len = data.len,
                    .transform = selected,
                };
            },
        }
    }
    return .{
        .path = write_files.add(raw_file_name, raw_data),
        .file_name = raw_file_name,
        .raw_len = raw_data.len,
        .compressed_len = raw_data.len,
        .transform = null,
    };
}

fn assetOutputDeclaration(
    b: *std.Build,
    output: AssetOutput,
    name: []const u8,
    raw_type: []const u8,
    raw_count: usize,
    raw_alignment: usize,
) []const u8 {
    if (output.transform) |selected| {
        switch (selected) {
            .lz77 => return b.fmt(
                \\/// LZ77-compressed data. Decompresses to {d} bytes.
                \\const {s}_lz77_data align(4) = @embedFile("{s}").*;
                \\pub const {s}_lz77: *align(4) const [{d}]u8 = @ptrCast(&{s}_lz77_data);
                \\pub const {s}_lz77_uncompressed_len: usize = {d};
            , .{ output.raw_len, name, output.file_name, name, output.compressed_len, name, name, output.raw_len }),
        }
    }
    return b.fmt(
        \\const {s}_data align({d}) = @embedFile("{s}").*;
        \\pub const {s}: *align({d}) const [{d}]{s} = @ptrCast(&{s}_data);
    , .{ name, raw_alignment, output.file_name, name, raw_alignment, raw_count, raw_type, name });
}

/// An exact shared palette for related Mode 4 frames.
///
/// Construct this from every frame that will share a Mode 4 palette, then
/// supply `getOpaqueColors()` through `ImageAsset.Palette.provided` for each
/// frame. This keeps palette indices stable across flips and animations.
pub const Mode4Palette = struct {
    colors: [256]ColorRgb555,
    color_count: usize,

    pub const Options = struct {
        /// All images that will use this palette. They must be available while
        /// `build.zig` is evaluated.
        source_files: []const std.Build.LazyPath,
    };

    pub fn create(b: *std.Build, options: Options) *Mode4Palette {
        if (options.source_files.len == 0) {
            @panic("Mode4Palette requires at least one source image");
        }
        var palette: [256]ColorRgb555 = @splat(.black);
        var count: usize = 1;
        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();

        for (options.source_files) |source_file| {
            const source_path = switch (source_file) {
                .generated => std.debug.panic(
                    "generated image inputs are not supported by Mode4Palette yet",
                    .{},
                ),
                else => source_file.getPath(b),
            };
            var source = image.Image.fromFilePath(b.allocator, threaded.io(), source_path) catch |err| {
                std.debug.panic("unable to load Mode 4 palette source '{s}': {s}", .{ source_path, @errorName(err) });
            };
            defer source.deinit(b.allocator);

            appendImagePalette8Bpp(source, &palette, &count) catch |err| switch (err) {
                error.TooManyColors => std.debug.panic(
                    "Mode 4 palette sources need more than 255 opaque RGB555 colors",
                    .{},
                ),
                else => unreachable,
            };
        }

        const result = b.allocator.create(Mode4Palette) catch @panic("OOM");
        result.* = .{ .colors = palette, .color_count = count };
        return result;
    }

    /// Returns the opaque entries for use with `.palette = .{ .provided = ... }`.
    pub fn getOpaqueColors(self: *const Mode4Palette) []const ColorRgb555 {
        return self.colors[1..self.color_count];
    }
};

/// Collects generated assets into one Zig module.
///
/// Register all assets first, then call `addImport` once to expose them as
/// members of a single module in game code.
pub const AssetModule = struct {
    const Entry = struct {
        name: []const u8,
        asset: *ImageAsset,
    };

    b: *std.Build,
    consumer_module: *std.Build.Module,
    gba_module: *std.Build.Module,
    entries: std.ArrayList(Entry) = .empty,
    module: ?*std.Build.Module = null,

    pub fn create(
        b: *std.Build,
        consumer_module: *std.Build.Module,
        gba_module: *std.Build.Module,
    ) *AssetModule {
        const assets = b.allocator.create(AssetModule) catch @panic("OOM");
        assets.* = .{
            .b = b,
            .consumer_module = consumer_module,
            .gba_module = gba_module,
        };
        return assets;
    }

    /// Adds a named image asset to this module.
    ///
    /// Names must be valid Zig identifiers because they become fields of the
    /// generated module, such as `assets.player`.
    pub fn addImage(self: *AssetModule, name: []const u8, options: ImageAsset.Options) *ImageAsset {
        if (self.module != null) {
            @panic("cannot add an asset after AssetModule.addImport");
        }
        if (!std.zig.isValidId(name)) {
            std.debug.panic("asset name '{s}' is not a valid Zig identifier", .{name});
        }
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                std.debug.panic("asset module already contains an asset named '{s}'", .{name});
            }
        }

        const asset = ImageAsset.create(self.b, options);
        self.entries.append(self.b.allocator, .{ .name = name, .asset = asset }) catch @panic("OOM");
        return asset;
    }

    /// Adds this aggregate module to the executable's root module.
    ///
    /// For example, `assets.addImport("assets")` makes the registered assets
    /// available to game code with `const assets = @import("assets");`.
    pub fn addImport(self: *AssetModule, import_name: []const u8) void {
        if (self.module) |module| {
            self.consumer_module.addImport(import_name, module);
            return;
        }

        var source: std.ArrayList(u8) = .empty;
        for (self.entries.items) |entry| {
            source.appendSlice(self.b.allocator, self.b.fmt(
                "pub const {s} = @import(\"{s}\");\n",
                .{ entry.name, entry.name },
            )) catch @panic("OOM");
        }
        if (self.entries.items.len == 0) {
            source.appendSlice(self.b.allocator, "// Empty asset module.\n") catch @panic("OOM");
        }

        const write_files = self.b.addWriteFiles();
        const module_path = write_files.add("assets.zig", source.items);
        const module = self.b.createModule(.{ .root_source_file = module_path });
        for (self.entries.items) |entry| {
            entry.asset.module.addImport("gba", self.gba_module);
            module.addImport(entry.name, entry.asset.module);
        }
        self.module = module;
        self.consumer_module.addImport(import_name, module);
    }
};

fn createObjTiles4Bpp(
    b: *std.Build,
    source_path: []const u8,
    source: image.Image,
    options: ImageAsset.Options,
) *ImageAsset {
    validate4BppImage(source_path, source, "4bpp OBJ");
    const frames = getSpriteSheetInfo(source_path, source, options.sprite_sheet);

    const palette = preparePaletteOrPanic(source_path, source, options.palette);
    var palette_adapter = PaletteMapper{
        .colors = palette.colors[0..palette.count],
        .mode = switch (options.palette) {
            .nearest => .nearest,
            else => .exact,
        },
    };
    const tiles = image.convertImageTiles4Bpp(
        b.allocator,
        source,
        .{ .palettizer = palette_adapter.palettizer() },
    ) catch |err| {
        std.debug.panic("unable to convert image asset '{s}' to 4bpp OBJ tiles: {s}", .{
            source_path,
            @errorName(err),
        });
    };
    defer b.allocator.free(tiles);

    const write_files = b.addWriteFiles();
    const tiles_output = writeAssetOutput(b, write_files, "tiles.bin", std.mem.sliceAsBytes(tiles), options.transforms.tiles);
    const palette_output = writeAssetOutput(b, write_files, "palette.bin", std.mem.sliceAsBytes(&palette.colors), options.transforms.palette);
    const tiles_declaration = assetOutputDeclaration(b, tiles_output, "tiles", "gba.display.Tile4Bpp", tiles.len, 4);
    const palette_declaration = assetOutputDeclaration(b, palette_output, "palette", "gba.ColorRgb555", 16, 2);
    const module_path = write_files.add("asset.zig", b.fmt(
        \\const gba = @import("gba");
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const tile_count: usize = {d};
        \\pub const palette_color_count: usize = {d};
        \\pub const width_tiles: usize = {d};
        \\pub const height_tiles: usize = {d};
        \\pub const frame_width: u16 = {d};
        \\pub const frame_height: u16 = {d};
        \\pub const frame_width_tiles: usize = {d};
        \\pub const frame_height_tiles: usize = {d};
        \\pub const frames_x: usize = {d};
        \\pub const frames_y: usize = {d};
        \\pub const frame_count: usize = {d};
        \\pub const frame_tile_count: usize = {d};
        \\/// Returns a source-order tile index for a tile within a frame.
        \\/// Frame tiles are not necessarily contiguous when `frames_x > 1`.
        \\pub fn frameTileIndex(frame: usize, tile_x: usize, tile_y: usize) usize {{
        \\    return ((frame / frames_x) * frame_height_tiles + tile_y) * width_tiles +
        \\        (frame % frames_x) * frame_width_tiles + tile_x;
        \\}}
        \\{s}
        \\{s}
    , .{
        source.getWidth(),
        source.getHeight(),
        tiles.len,
        palette.count,
        frames.width_tiles,
        frames.height_tiles,
        frames.frame_width,
        frames.frame_height,
        frames.frame_width_tiles,
        frames.frame_height_tiles,
        frames.frames_x,
        frames.frames_y,
        frames.frame_count,
        frames.frame_tile_count,
        tiles_declaration,
        palette_declaration,
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{
        .module = module,
        .tiles = tiles_output.path,
        .palette = palette_output.path,
    };
    return asset;
}

fn createBackgroundTilemap4Bpp(
    b: *std.Build,
    source_path: []const u8,
    source: image.Image,
    options: ImageAsset.Options,
) *ImageAsset {
    validate4BppImage(source_path, source, "4bpp background tilemap");
    if (source.getWidth() > 512 or source.getHeight() > 512) {
        std.debug.panic(
            "background image asset '{s}' is {d}x{d}; normal background maps support at most 512x512 pixels",
            .{ source_path, source.getWidth(), source.getHeight() },
        );
    }

    const palette = preparePaletteOrPanic(source_path, source, options.palette);
    var palette_adapter = PaletteMapper{
        .colors = palette.colors[0..palette.count],
        .mode = switch (options.palette) {
            .nearest => .nearest,
            else => .exact,
        },
    };
    const output = image.convertImageTilemap4Bpp(
        b.allocator,
        source,
        .{
            .palettizer = palette_adapter.palettizer(),
            .palette = options.tilemap.palette_bank,
            .dedupe = options.tilemap.dedupe,
            .dedupe_flips = options.tilemap.dedupe_flips,
        },
    ) catch |err| {
        std.debug.panic("unable to convert image asset '{s}' to a 4bpp background tilemap: {s}", .{
            source_path,
            @errorName(err),
        });
    };
    defer output.deinit(b.allocator);

    const write_files = b.addWriteFiles();
    const tiles_output = writeAssetOutput(b, write_files, "tiles.bin", std.mem.sliceAsBytes(output.tiles), options.transforms.tiles);
    const palette_output = writeAssetOutput(b, write_files, "palette.bin", std.mem.sliceAsBytes(&palette.colors), options.transforms.palette);
    const map_output = writeAssetOutput(b, write_files, "map.bin", std.mem.sliceAsBytes(output.map), options.transforms.map);
    const tiles_declaration = assetOutputDeclaration(b, tiles_output, "tiles", "gba.display.Tile4Bpp", output.tiles.len, 4);
    const palette_declaration = assetOutputDeclaration(b, palette_output, "palette", "gba.ColorRgb555", 16, 2);
    const map_declaration = assetOutputDeclaration(b, map_output, "map", "gba.display.Screenblock.Entry", output.map.len, 2);
    const module_path = write_files.add("asset.zig", b.fmt(
        \\const gba = @import("gba");
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const source_width_tiles: usize = {d};
        \\pub const source_height_tiles: usize = {d};
        \\pub const map_width_tiles: usize = {d};
        \\pub const map_height_tiles: usize = {d};
        \\pub const tile_count: usize = {d};
        \\pub const map_entry_count: usize = {d};
        \\pub const palette_color_count: usize = {d};
        \\pub const background_size: gba.display.BackgroundSize.Normal = .{s};
        \\{s}
        \\{s}
        \\{s}
    , .{
        source.getWidth(),
        source.getHeight(),
        output.source_width_tiles,
        output.source_height_tiles,
        output.map_width_tiles,
        output.map_height_tiles,
        output.tiles.len,
        output.map.len,
        palette.count,
        normalBackgroundSizeName(output.map_width_tiles, output.map_height_tiles),
        tiles_declaration,
        palette_declaration,
        map_declaration,
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{
        .module = module,
        .tiles = tiles_output.path,
        .palette = palette_output.path,
        .map = map_output.path,
    };
    return asset;
}

fn createMultiBankBackgroundTilemap4Bpp(
    b: *std.Build,
    source_path: []const u8,
    source: image.Image,
    options: ImageAsset.Options,
) *ImageAsset {
    validate4BppImage(source_path, source, "multi-bank 4bpp background");
    if (source.getWidth() > 512 or source.getHeight() > 512) {
        std.debug.panic(
            "multi-bank 4bpp background image asset '{s}' is {d}x{d}; maps support at most 512x512 pixels",
            .{ source_path, source.getWidth(), source.getHeight() },
        );
    }
    switch (options.palette) {
        .auto => {},
        else => @panic("use multi_bank_tilemap_4bpp.palette_banks to configure a multi-bank 4bpp palette"),
    }

    const output = image.convertImageTilemap4BppMultiBank(b.allocator, source, .{
        .palette_banks = options.multi_bank_tilemap_4bpp.palette_banks,
        .dedupe = options.multi_bank_tilemap_4bpp.dedupe,
        .dedupe_flips = options.multi_bank_tilemap_4bpp.dedupe_flips,
    }) catch |err| {
        switch (err) {
            error.TileTooManyColors => std.debug.panic(
                "multi-bank 4bpp image asset '{s}' has a tile with more than 15 opaque RGB555 colors",
                .{source_path},
            ),
            error.TooManyPaletteBanks => std.debug.panic(
                "multi-bank 4bpp image asset '{s}' needs more than 16 palette banks; " ++
                    "supply artist-authored banks or simplify the per-tile color sets",
                .{source_path},
            ),
            error.ColorNotInPaletteBanks => std.debug.panic(
                "multi-bank 4bpp image asset '{s}' has a tile that fits none of its provided palette banks",
                .{source_path},
            ),
            error.InvalidPaletteBanks => std.debug.panic(
                "multi-bank 4bpp image asset '{s}' needs one through sixteen provided palette banks",
                .{source_path},
            ),
            else => std.debug.panic("unable to convert image asset '{s}' to a multi-bank 4bpp background tilemap: {s}", .{
                source_path,
                @errorName(err),
            }),
        }
    };
    defer output.deinit(b.allocator);

    const write_files = b.addWriteFiles();
    const tiles_output = writeAssetOutput(b, write_files, "tiles.bin", std.mem.sliceAsBytes(output.tiles), options.transforms.tiles);
    const palette_output = writeAssetOutput(b, write_files, "palette.bin", std.mem.sliceAsBytes(&output.palette), options.transforms.palette);
    const map_output = writeAssetOutput(b, write_files, "map.bin", std.mem.sliceAsBytes(output.map), options.transforms.map);
    const tiles_declaration = assetOutputDeclaration(b, tiles_output, "tiles", "gba.display.Tile4Bpp", output.tiles.len, 4);
    const palette_declaration = assetOutputDeclaration(b, palette_output, "palette", "gba.ColorRgb555", 256, 2);
    const map_declaration = assetOutputDeclaration(b, map_output, "map", "gba.display.Screenblock.Entry", output.map.len, 2);
    const module_path = write_files.add("asset.zig", b.fmt(
        \\const gba = @import("gba");
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const source_width_tiles: usize = {d};
        \\pub const source_height_tiles: usize = {d};
        \\pub const map_width_tiles: usize = {d};
        \\pub const map_height_tiles: usize = {d};
        \\pub const tile_count: usize = {d};
        \\pub const map_entry_count: usize = {d};
        \\pub const palette_bank_count: usize = {d};
        \\pub const background_size: gba.display.BackgroundSize.Normal = .{s};
        \\{s}
        \\{s}
        \\{s}
    , .{
        source.getWidth(),
        source.getHeight(),
        output.source_width_tiles,
        output.source_height_tiles,
        output.map_width_tiles,
        output.map_height_tiles,
        output.tiles.len,
        output.map.len,
        output.palette_bank_count,
        normalBackgroundSizeName(output.map_width_tiles, output.map_height_tiles),
        tiles_declaration,
        palette_declaration,
        map_declaration,
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{ .module = module, .tiles = tiles_output.path, .palette = palette_output.path, .map = map_output.path };
    return asset;
}

fn createBackgroundTilemap8Bpp(
    b: *std.Build,
    source_path: []const u8,
    source: image.Image,
    options: ImageAsset.Options,
) *ImageAsset {
    validate8BppTilemapImage(source_path, source, "normal");
    if (source.getWidth() > 512 or source.getHeight() > 512) {
        std.debug.panic(
            "normal 8bpp background image asset '{s}' is {d}x{d}; maps support at most 512x512 pixels",
            .{ source_path, source.getWidth(), source.getHeight() },
        );
    }

    const palette = preparePalette8BppOrPanic(source_path, source, options.palette);
    var palette_adapter = PaletteMapper{
        .colors = palette.colors[0..palette.count],
        .mode = switch (options.palette) {
            .nearest => .nearest,
            else => .exact,
        },
    };
    const output = image.convertImageNormalTilemap8Bpp(b.allocator, source, .{
        .palettizer = palette_adapter.palettizer(),
        .dedupe = options.tilemap_8bpp.dedupe,
        .dedupe_flips = options.tilemap_8bpp.dedupe_flips,
    }) catch |err| {
        std.debug.panic("unable to convert image asset '{s}' to a normal 8bpp background tilemap: {s}", .{
            source_path,
            @errorName(err),
        });
    };
    defer output.deinit(b.allocator);

    return createNormal8BppModule(b, source, palette, output, options.transforms);
}

fn createNormal8BppModule(
    b: *std.Build,
    source: image.Image,
    palette: Palette8Bpp,
    output: image.ConvertImageNormalTilemap8BppOutput,
    transforms: ImageAsset.OutputTransforms,
) *ImageAsset {
    const write_files = b.addWriteFiles();
    const tiles_output = writeAssetOutput(b, write_files, "tiles.bin", std.mem.sliceAsBytes(output.tiles), transforms.tiles);
    const palette_output = writeAssetOutput(b, write_files, "palette.bin", std.mem.sliceAsBytes(&palette.colors), transforms.palette);
    const map_output = writeAssetOutput(b, write_files, "map.bin", std.mem.sliceAsBytes(output.map), transforms.map);
    const tiles_declaration = assetOutputDeclaration(b, tiles_output, "tiles", "gba.display.Tile8Bpp", output.tiles.len, 4);
    const palette_declaration = assetOutputDeclaration(b, palette_output, "palette", "gba.ColorRgb555", 256, 2);
    const map_declaration = assetOutputDeclaration(b, map_output, "map", "gba.display.Screenblock.Entry", output.map.len, 2);
    const module_path = write_files.add("asset.zig", b.fmt(
        \\const gba = @import("gba");
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const source_width_tiles: usize = {d};
        \\pub const source_height_tiles: usize = {d};
        \\pub const map_width_tiles: usize = {d};
        \\pub const map_height_tiles: usize = {d};
        \\pub const tile_count: usize = {d};
        \\pub const map_entry_count: usize = {d};
        \\pub const palette_color_count: usize = {d};
        \\pub const background_size: gba.display.BackgroundSize.Normal = .{s};
        \\{s}
        \\{s}
        \\{s}
    , .{
        source.getWidth(),
        source.getHeight(),
        output.source_width_tiles,
        output.source_height_tiles,
        output.map_width_tiles,
        output.map_height_tiles,
        output.tiles.len,
        output.map.len,
        palette.count,
        normalBackgroundSizeName(output.map_width_tiles, output.map_height_tiles),
        tiles_declaration,
        palette_declaration,
        map_declaration,
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{ .module = module, .tiles = tiles_output.path, .palette = palette_output.path, .map = map_output.path };
    return asset;
}

fn createAffineBackgroundTilemap8Bpp(
    b: *std.Build,
    source_path: []const u8,
    source: image.Image,
    options: ImageAsset.Options,
) *ImageAsset {
    validate8BppTilemapImage(source_path, source, "affine");
    const affine_size = options.affine_tilemap_8bpp.size orelse affineSizeForSource(source_path, source);
    const map_dimension = affineDimension(affine_size);
    if (source.getWidth() / 8 > map_dimension or source.getHeight() / 8 > map_dimension) {
        std.debug.panic(
            "affine background image asset '{s}' does not fit its {d}x{d}-tile map",
            .{ source_path, map_dimension, map_dimension },
        );
    }

    const palette = preparePalette8BppOrPanic(source_path, source, options.palette);
    var palette_adapter = PaletteMapper{
        .colors = palette.colors[0..palette.count],
        .mode = switch (options.palette) {
            .nearest => .nearest,
            else => .exact,
        },
    };
    const output = image.convertImageAffineTilemap8Bpp(b.allocator, source, .{
        .palettizer = palette_adapter.palettizer(),
        .size = affine_size,
        .repeat_source = options.affine_tilemap_8bpp.repeat_source,
        .dedupe = options.affine_tilemap_8bpp.dedupe,
    }) catch |err| {
        std.debug.panic("unable to convert image asset '{s}' to an affine 8bpp background tilemap: {s}", .{
            source_path,
            @errorName(err),
        });
    };
    defer output.deinit(b.allocator);

    const write_files = b.addWriteFiles();
    const tiles_output = writeAssetOutput(b, write_files, "tiles.bin", std.mem.sliceAsBytes(output.tiles), options.transforms.tiles);
    const palette_output = writeAssetOutput(b, write_files, "palette.bin", std.mem.sliceAsBytes(&palette.colors), options.transforms.palette);
    const map_output = writeAssetOutput(b, write_files, "map.bin", std.mem.sliceAsBytes(output.map), options.transforms.map);
    const tiles_declaration = assetOutputDeclaration(b, tiles_output, "tiles", "gba.display.Tile8Bpp", output.tiles.len, 4);
    const palette_declaration = assetOutputDeclaration(b, palette_output, "palette", "gba.ColorRgb555", 256, 2);
    const map_declaration = assetOutputDeclaration(b, map_output, "map", "gba.display.Screenblock.AffinePair", output.map.len, 2);
    const module_path = write_files.add("asset.zig", b.fmt(
        \\const gba = @import("gba");
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const source_width_tiles: usize = {d};
        \\pub const source_height_tiles: usize = {d};
        \\pub const map_dimension_tiles: usize = {d};
        \\pub const tile_count: usize = {d};
        \\pub const map_pair_count: usize = {d};
        \\pub const palette_color_count: usize = {d};
        \\pub const background_size: gba.display.BackgroundSize.Affine = .{s};
        \\{s}
        \\{s}
        \\{s}
    , .{
        source.getWidth(),
        source.getHeight(),
        output.source_width_tiles,
        output.source_height_tiles,
        output.map_dimension_tiles,
        output.tiles.len,
        output.map.len,
        palette.count,
        affineBackgroundSizeName(affine_size),
        tiles_declaration,
        palette_declaration,
        map_declaration,
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{ .module = module, .tiles = tiles_output.path, .palette = palette_output.path, .map = map_output.path };
    return asset;
}

fn createMode4Bitmap8Bpp(
    b: *std.Build,
    source_path: []const u8,
    source: image.Image,
    options: ImageAsset.Options,
) *ImageAsset {
    if (source.getWidth() != 240 or source.getHeight() != 160) {
        std.debug.panic(
            "Mode 4 image asset '{s}' is {d}x{d}; Mode 4 assets must be exactly 240x160 pixels",
            .{ source_path, source.getWidth(), source.getHeight() },
        );
    }

    const palette = preparePalette8BppOrPanic(source_path, source, options.palette);
    var palette_adapter = PaletteMapper{
        .colors = palette.colors[0..palette.count],
        .mode = switch (options.palette) {
            .nearest => .nearest,
            else => .exact,
        },
    };
    const output = image.convertImageBitmap8Bpp(
        b.allocator,
        source,
        .{ .palettizer = palette_adapter.palettizer() },
    ) catch |err| {
        std.debug.panic("unable to convert image asset '{s}' to a Mode 4 bitmap: {s}", .{
            source_path,
            @errorName(err),
        });
    };
    defer b.allocator.free(output.data);

    const write_files = b.addWriteFiles();
    const pixels_output = writeAssetOutput(b, write_files, "pixels.bin", output.data, options.transforms.pixels);
    const palette_output = writeAssetOutput(b, write_files, "palette.bin", std.mem.sliceAsBytes(&palette.colors), options.transforms.palette);
    const pixels_declaration = assetOutputDeclaration(b, pixels_output, "pixels", "u8", output.data.len, 4);
    const palette_declaration = assetOutputDeclaration(b, palette_output, "palette", "gba.ColorRgb555", 256, 2);
    const module_path = write_files.add("asset.zig", b.fmt(
        \\const gba = @import("gba");
        \\pub const width: u16 = {d};
        \\pub const height: u16 = {d};
        \\pub const pixel_count: usize = {d};
        \\pub const palette_color_count: usize = {d};
        \\{s}
        \\{s}
    , .{
        output.width,
        output.height,
        output.data.len,
        palette.count,
        pixels_declaration,
        palette_declaration,
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{
        .module = module,
        .tiles = pixels_output.path,
        .palette = palette_output.path,
        .pixels = pixels_output.path,
    };
    return asset;
}

fn preparePaletteOrPanic(
    source_path: []const u8,
    source: image.Image,
    policy: ImageAsset.Palette,
) Palette4Bpp {
    return preparePalette4Bpp(source, policy) catch |err| switch (err) {
        error.TooManyColors => std.debug.panic(
            "image asset '{s}' needs more than 15 opaque RGB555 colors; " ++
                "set the palette policy to nearest to opt into lossy mapping",
            .{source_path},
        ),
        error.EmptyPalette => std.debug.panic(
            "image asset '{s}' has an empty explicit palette; provide one to 15 opaque colors",
            .{source_path},
        ),
        error.PaletteTooLarge => std.debug.panic(
            "image asset '{s}' has more than 15 explicit opaque palette colors",
            .{source_path},
        ),
        error.DuplicatePaletteColor => std.debug.panic(
            "image asset '{s}' has duplicate explicit RGB555 palette colors",
            .{source_path},
        ),
        error.ColorNotInPalette => std.debug.panic(
            "image asset '{s}' uses an opaque color not present in its explicit RGB555 palette; " ++
                "use the nearest palette policy to opt into lossy mapping",
            .{source_path},
        ),
    };
}

fn preparePalette8BppOrPanic(
    source_path: []const u8,
    source: image.Image,
    policy: ImageAsset.Palette,
) Palette8Bpp {
    return preparePalette8Bpp(source, policy) catch |err| switch (err) {
        error.TooManyColors => std.debug.panic(
            "Mode 4 image asset '{s}' needs more than 255 opaque RGB555 colors; " ++
                "set the palette policy to nearest to opt into lossy mapping",
            .{source_path},
        ),
        error.EmptyPalette => std.debug.panic(
            "Mode 4 image asset '{s}' has an empty explicit palette; provide one to 255 opaque colors",
            .{source_path},
        ),
        error.PaletteTooLarge => std.debug.panic(
            "Mode 4 image asset '{s}' has more than 255 explicit opaque palette colors",
            .{source_path},
        ),
        error.DuplicatePaletteColor => std.debug.panic(
            "Mode 4 image asset '{s}' has duplicate explicit RGB555 palette colors",
            .{source_path},
        ),
        error.ColorNotInPalette => std.debug.panic(
            "Mode 4 image asset '{s}' uses an opaque color not present in its explicit RGB555 palette; " ++
                "use the nearest palette policy to opt into lossy mapping",
            .{source_path},
        ),
    };
}

const PaletteError = error{
    TooManyColors,
    EmptyPalette,
    PaletteTooLarge,
    DuplicatePaletteColor,
    ColorNotInPalette,
};

const Palette4Bpp = struct {
    colors: [16]ColorRgb555,
    count: usize,
};

const Palette8Bpp = struct {
    colors: [256]ColorRgb555,
    count: usize,
};

/// GBA OBJ palettes reserve index zero for transparency, leaving 15 opaque
/// colors. Colors are compared after conversion to RGB555, matching runtime
/// representation and avoiding needless palette entries.
fn extractPalette4Bpp(source: image.Image) PaletteError!Palette4Bpp {
    var palette: [16]ColorRgb555 = @splat(.black);
    var count: usize = 1;

    for (0..source.getHeight()) |y| {
        for (0..source.getWidth()) |x| {
            try appendPaletteColor(&palette, &count, source.getPixelColor(@intCast(x), @intCast(y)));
        }
    }

    return .{ .colors = palette, .count = count };
}

fn extractPalette4BppColors(source_colors: []const color.ColorRgba32) PaletteError!Palette4Bpp {
    var palette: [16]ColorRgb555 = @splat(.black);
    var count: usize = 1;
    for (source_colors) |source_color| {
        try appendPaletteColor(&palette, &count, source_color);
    }
    return .{ .colors = palette, .count = count };
}

fn appendPaletteColor(
    palette: *[16]ColorRgb555,
    count: *usize,
    source_color: color.ColorRgba32,
) PaletteError!void {
    if (source_color.a < 0xff) return;
    const converted = color.convertColorDepthLinear(source_color);
    if (paletteContains(palette[1..count.*], converted)) return;
    if (count.* == palette.len) return error.TooManyColors;
    palette[count.*] = converted;
    count.* += 1;
}

fn appendImagePalette8Bpp(
    source: image.Image,
    palette: *[256]ColorRgb555,
    count: *usize,
) PaletteError!void {
    for (0..source.getHeight()) |y| {
        for (0..source.getWidth()) |x| {
            try appendPaletteColor8Bpp(palette, count, source.getPixelColor(@intCast(x), @intCast(y)));
        }
    }
}

fn appendPaletteColor8Bpp(
    palette: *[256]ColorRgb555,
    count: *usize,
    source_color: color.ColorRgba32,
) PaletteError!void {
    if (source_color.a < 0xff) return;

    const converted = color.convertColorDepthLinear(source_color);
    if (paletteContains(palette[1..count.*], converted)) return;
    if (count.* == palette.len) return error.TooManyColors;
    palette[count.*] = converted;
    count.* += 1;
}

fn preparePalette4Bpp(source: image.Image, policy: ImageAsset.Palette) PaletteError!Palette4Bpp {
    return switch (policy) {
        .auto => extractPalette4Bpp(source),
        .provided => |colors| blk: {
            const palette = try explicitPalette4Bpp(colors);
            try validateExactPalette(source, palette.colors[0..palette.count]);
            break :blk palette;
        },
        .nearest => |colors| explicitPalette4Bpp(colors),
    };
}

fn preparePalette8Bpp(source: image.Image, policy: ImageAsset.Palette) PaletteError!Palette8Bpp {
    return switch (policy) {
        .auto => extractPalette8Bpp(source),
        .provided => |colors| blk: {
            const palette = try explicitPalette8Bpp(colors);
            try validateExactPalette(source, palette.colors[0..palette.count]);
            break :blk palette;
        },
        .nearest => |colors| explicitPalette8Bpp(colors),
    };
}

fn extractPalette8Bpp(source: image.Image) PaletteError!Palette8Bpp {
    var palette: [256]ColorRgb555 = @splat(.black);
    var count: usize = 1;
    try appendImagePalette8Bpp(source, &palette, &count);
    return .{ .colors = palette, .count = count };
}

fn explicitPalette8Bpp(opaque_colors: []const ColorRgb555) PaletteError!Palette8Bpp {
    if (opaque_colors.len == 0) return error.EmptyPalette;
    if (opaque_colors.len > 255) return error.PaletteTooLarge;

    var palette: [256]ColorRgb555 = @splat(.black);
    for (opaque_colors, 1..) |palette_color, index| {
        if (paletteContains(palette[1..index], palette_color)) {
            return error.DuplicatePaletteColor;
        }
        palette[index] = palette_color;
    }
    return .{ .colors = palette, .count = opaque_colors.len + 1 };
}

fn explicitPalette4Bpp(opaque_colors: []const ColorRgb555) PaletteError!Palette4Bpp {
    if (opaque_colors.len == 0) return error.EmptyPalette;
    if (opaque_colors.len > 15) return error.PaletteTooLarge;

    var palette: [16]ColorRgb555 = @splat(.black);
    for (opaque_colors, 1..) |palette_color, index| {
        if (paletteContains(palette[1..index], palette_color)) {
            return error.DuplicatePaletteColor;
        }
        palette[index] = palette_color;
    }
    return .{ .colors = palette, .count = opaque_colors.len + 1 };
}

fn validateExactPalette(source: image.Image, palette: []const ColorRgb555) PaletteError!void {
    for (0..source.getHeight()) |y| {
        for (0..source.getWidth()) |x| {
            try validateExactPaletteColor(source.getPixelColor(@intCast(x), @intCast(y)), palette);
        }
    }
}

fn validateExactPaletteColors(
    source_colors: []const color.ColorRgba32,
    palette: []const ColorRgb555,
) PaletteError!void {
    for (source_colors) |source_color| {
        try validateExactPaletteColor(source_color, palette);
    }
}

fn validateExactPaletteColor(
    source_color: color.ColorRgba32,
    palette: []const ColorRgb555,
) PaletteError!void {
    if (source_color.a < 0xff) return;
    if (!paletteContains(palette[1..], color.convertColorDepthLinear(source_color))) {
        return error.ColorNotInPalette;
    }
}

fn paletteContains(colors: []const ColorRgb555, wanted: ColorRgb555) bool {
    for (colors) |color_value| {
        if (color_value == wanted) return true;
    }
    return false;
}

const PaletteMapper = struct {
    const Mode = enum { exact, nearest };

    colors: []const ColorRgb555,
    mode: Mode,

    fn palettizer(self: *const PaletteMapper) color.Palettizer {
        return .{
            .context = @constCast(self),
            .vtable = .{
                .get = get,
                .getPalette = getPalette,
            },
        };
    }

    fn get(context: *anyopaque, pixel: color.Palettizer.Pixel) u8 {
        const self: *const PaletteMapper = @ptrCast(@alignCast(context));
        if (pixel.color.a < 0xff) return 0;

        const converted = color.convertColorDepthLinear(pixel.color);
        for (self.colors[1..], 1..) |palette_color, index| {
            if (palette_color == converted) return @intCast(index);
        }
        return switch (self.mode) {
            .exact => unreachable,
            .nearest => self.nearestIndex(converted),
        };
    }

    fn nearestIndex(self: *const PaletteMapper, wanted: ColorRgb555) u8 {
        var best_index: usize = 1;
        var best_distance = colorDistanceSquared(self.colors[best_index], wanted);
        for (self.colors[2..], 2..) |palette_color, index| {
            const distance = colorDistanceSquared(palette_color, wanted);
            if (distance < best_distance) {
                best_index = index;
                best_distance = distance;
            }
        }
        return @intCast(best_index);
    }

    fn getPalette(context: *anyopaque) []const color.ColorRgba32 {
        _ = context;
        // The low-level tile converter only needs palette indices. This empty
        // view keeps the adapter compatible with the public Palettizer API.
        return &.{};
    }
};

fn colorDistanceSquared(a: ColorRgb555, b: ColorRgb555) u32 {
    const dr: i32 = @as(i32, a.r) - @as(i32, b.r);
    const dg: i32 = @as(i32, a.g) - @as(i32, b.g);
    const db: i32 = @as(i32, a.b) - @as(i32, b.b);
    return @intCast(dr * dr + dg * dg + db * db);
}

const SpriteSheetInfo = struct {
    width_tiles: usize,
    height_tiles: usize,
    frame_width: u16,
    frame_height: u16,
    frame_width_tiles: usize,
    frame_height_tiles: usize,
    frames_x: usize,
    frames_y: usize,
    frame_count: usize,
    frame_tile_count: usize,
};

fn validate4BppImage(source_path: []const u8, source: image.Image, target: []const u8) void {
    if (source.isEmpty()) {
        std.debug.panic("image asset '{s}' is empty", .{source_path});
    }
    if ((source.getWidth() & 0x7) != 0 or (source.getHeight() & 0x7) != 0) {
        std.debug.panic(
            "image asset '{s}' is {d}x{d}; {s} images must have dimensions divisible by 8",
            .{ source_path, source.getWidth(), source.getHeight(), target },
        );
    }
}

fn validate8BppTilemapImage(source_path: []const u8, source: image.Image, target: []const u8) void {
    if (source.isEmpty()) {
        std.debug.panic("{s} 8bpp background image asset '{s}' is empty", .{ target, source_path });
    }
    if ((source.getWidth() & 7) != 0 or (source.getHeight() & 7) != 0) {
        std.debug.panic(
            "{s} 8bpp background image asset '{s}' is {d}x{d}; dimensions must be divisible by 8",
            .{ target, source_path, source.getWidth(), source.getHeight() },
        );
    }
}

fn affineSizeForSource(source_path: []const u8, source: image.Image) BackgroundSize.Affine {
    const source_dimension = @max(source.getWidth() / 8, source.getHeight() / 8);
    return switch (source_dimension) {
        0...16 => .size_16,
        17...32 => .size_32,
        33...64 => .size_64,
        65...128 => .size_128,
        else => std.debug.panic(
            "affine background image asset '{s}' is {d}x{d}; maps support at most 1024x1024 pixels",
            .{ source_path, source.getWidth(), source.getHeight() },
        ),
    };
}

fn affineDimension(size: BackgroundSize.Affine) u16 {
    return @as(u16, 16) << @intFromEnum(size);
}

fn affineBackgroundSizeName(size: BackgroundSize.Affine) []const u8 {
    return switch (size) {
        .size_16 => "size_16",
        .size_32 => "size_32",
        .size_64 => "size_64",
        .size_128 => "size_128",
    };
}

fn normalBackgroundSizeName(width_tiles: u16, height_tiles: u16) []const u8 {
    return switch (width_tiles) {
        32 => switch (height_tiles) {
            32 => "size_32x32",
            64 => "size_32x64",
            else => unreachable,
        },
        64 => switch (height_tiles) {
            32 => "size_64x32",
            64 => "size_64x64",
            else => unreachable,
        },
        else => unreachable,
    };
}

fn getSpriteSheetInfo(
    source_path: []const u8,
    source: image.Image,
    requested: ?ImageAsset.SpriteSheet,
) SpriteSheetInfo {
    const frame: ImageAsset.SpriteSheet = requested orelse .{
        .frame_width = source.getWidth(),
        .frame_height = source.getHeight(),
    };
    if (frame.frame_width == 0 or frame.frame_height == 0 or
        (frame.frame_width & 0x7) != 0 or (frame.frame_height & 0x7) != 0)
    {
        std.debug.panic(
            "image asset '{s}' has an invalid sprite-sheet frame size {d}x{d}; " ++
                "both dimensions must be non-zero multiples of 8",
            .{ source_path, frame.frame_width, frame.frame_height },
        );
    }
    if (@rem(source.getWidth(), frame.frame_width) != 0 or
        @rem(source.getHeight(), frame.frame_height) != 0)
    {
        std.debug.panic(
            "image asset '{s}' is {d}x{d}, which is not evenly divisible by sprite-sheet frame size {d}x{d}",
            .{ source_path, source.getWidth(), source.getHeight(), frame.frame_width, frame.frame_height },
        );
    }

    const width_tiles = @as(usize, source.getWidth() >> 3);
    const height_tiles = @as(usize, source.getHeight() >> 3);
    const frame_width_tiles = @as(usize, frame.frame_width >> 3);
    const frame_height_tiles = @as(usize, frame.frame_height >> 3);
    const frames_x = width_tiles / frame_width_tiles;
    const frames_y = height_tiles / frame_height_tiles;
    return .{
        .width_tiles = width_tiles,
        .height_tiles = height_tiles,
        .frame_width = frame.frame_width,
        .frame_height = frame.frame_height,
        .frame_width_tiles = frame_width_tiles,
        .frame_height_tiles = frame_height_tiles,
        .frames_x = frames_x,
        .frames_y = frames_y,
        .frame_count = frames_x * frames_y,
        .frame_tile_count = frame_width_tiles * frame_height_tiles,
    };
}

test "auto palette reserves transparency and deduplicates RGB555 colors" {
    const palette = try extractPalette4BppColors(&.{
        .transparent,
        .rgb(0xf8, 0, 0),
        .rgb(0xff, 0, 0),
        .rgba(0, 0, 0, 1),
    });
    try std.testing.expectEqual(@as(usize, 2), palette.count);
    try std.testing.expectEqual(ColorRgb555.black, palette.colors[0]);
    try std.testing.expectEqual(ColorRgb555.red, palette.colors[1]);
}

test "auto palette rejects a sixteenth opaque RGB555 color" {
    const colors = [_]color.ColorRgba32{
        .rgb(0, 0, 0),  .rgb(8, 0, 0),   .rgb(16, 0, 0),  .rgb(24, 0, 0),
        .rgb(32, 0, 0), .rgb(40, 0, 0),  .rgb(48, 0, 0),  .rgb(56, 0, 0),
        .rgb(64, 0, 0), .rgb(72, 0, 0),  .rgb(80, 0, 0),  .rgb(88, 0, 0),
        .rgb(96, 0, 0), .rgb(104, 0, 0), .rgb(112, 0, 0), .rgb(120, 0, 0),
    };
    try std.testing.expectError(error.TooManyColors, extractPalette4BppColors(&colors));
}

test "provided palettes reject colors they do not contain" {
    const palette = try explicitPalette4Bpp(&.{ColorRgb555.red});
    try std.testing.expectError(
        error.ColorNotInPalette,
        validateExactPaletteColors(&.{color.ColorRgba32.blue}, palette.colors[0..palette.count]),
    );
}

test "nearest palette chooses the closest opaque color" {
    const palette = try explicitPalette4Bpp(&.{ ColorRgb555.blue, ColorRgb555.red });
    const mapper = PaletteMapper{ .colors = palette.colors[0..palette.count], .mode = .nearest };
    try std.testing.expectEqual(@as(u8, 2), mapper.nearestIndex(.rgb(30, 0, 1)));
}

test "background tilemap defaults preserve source tile order" {
    const options: ImageAsset.TilemapOptions = .{};
    try std.testing.expect(!options.dedupe);
    try std.testing.expect(!options.dedupe_flips);
    try std.testing.expectEqualStrings("size_64x32", normalBackgroundSizeName(64, 32));
}

test "Mode 4 explicit palettes support more than 4bpp palettes" {
    const palette = try explicitPalette8Bpp(&.{ ColorRgb555.red, ColorRgb555.green, ColorRgb555.blue });
    try std.testing.expectEqual(@as(usize, 4), palette.count);
    try validateExactPaletteColors(
        &.{ color.ColorRgba32.red, color.ColorRgba32.green, color.ColorRgba32.blue },
        palette.colors[0..palette.count],
    );
}
