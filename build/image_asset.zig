//! High-level image assets for GBA projects.
//!
//! This module intentionally sits above the lower-level image converters. It
//! provides a convention-driven path for common assets while leaving the
//! converter APIs available to projects with custom pipelines.

const std = @import("std");
const color = @import("color.zig");
const image = @import("image.zig");
const ColorRgb555 = @import("../src/gba/graphics/color.zig").ColorRgb555;

/// A converted image and the generated module that exposes its runtime data.
pub const ImageAsset = struct {
    /// The module containing the typed image data. Add it to an executable
    /// module with `std.Build.Module.addImport`.
    module: *std.Build.Module,
    /// Generated 4bpp tile data.
    tiles: std.Build.LazyPath,
    /// Generated 16-color palette data in RGB555 format.
    palette: std.Build.LazyPath,

    pub const Format = enum {
        /// 4bpp tiles for use with GBA OBJ (sprite) graphics.
        obj_tiles_4bpp,
    };

    /// How opaque image colors are assigned to the 15 usable 4bpp palette
    /// entries. Palette index zero is always reserved for transparent pixels.
    pub const Palette = union(enum) {
        /// Extract the exact RGB555 colors used by the image. This is the
        /// safe default and rejects images with more than 15 opaque colors.
        auto,
        /// Use these opaque RGB555 colors exactly. Every opaque source color
        /// must appear in this palette after RGB555 conversion.
        provided: []const ColorRgb555,
        /// Use these opaque RGB555 colors, mapping every opaque source color
        /// to its closest entry. This is intentionally lossy.
        nearest: []const ColorRgb555,
    };

    /// Describes a grid of equally sized sprite frames in the source image.
    /// Both dimensions must be non-zero multiples of eight pixels.
    pub const SpriteSheet = struct {
        frame_width: u16,
        frame_height: u16,
    };

    pub const Options = struct {
        /// Source image to convert. It must be available when `build.zig` is
        /// evaluated; generated images are not supported by this eager path.
        source_file: std.Build.LazyPath,
        /// Output format. More image targets will be added alongside their
        /// corresponding typed runtime interfaces.
        format: Format = .obj_tiles_4bpp,
        /// Palette handling for 4bpp formats.
        palette: Palette = .auto,
        /// Optional sprite-frame grid. When omitted, the full image is one
        /// frame. Tiles remain in the source image's row-major tile order.
        sprite_sheet: ?SpriteSheet = null,
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
    /// RGB555 conversion, and fail if the image needs more than 15 opaque
    /// colors.
    pub fn create(b: *std.Build, options: Options) *ImageAsset {
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
        };
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
    validateObjImage(source_path, source);
    const frames = getSpriteSheetInfo(source_path, source, options.sprite_sheet);

    const palette = preparePalette4Bpp(source, options.palette) catch |err| switch (err) {
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
    const tiles_path = write_files.add("tiles.bin", std.mem.sliceAsBytes(tiles));
    const palette_path = write_files.add("palette.bin", std.mem.sliceAsBytes(&palette.colors));
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
        \\const tiles_data align(4) = @embedFile("tiles.bin").*;
        \\const palette_data align(2) = @embedFile("palette.bin").*;
        \\pub const tiles: *align(4) const [tile_count]gba.display.Tile4Bpp = @ptrCast(&tiles_data);
        \\pub const palette: *align(2) const [16]gba.ColorRgb555 = @ptrCast(&palette_data);
        \\ 
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
    }));
    const module = b.createModule(.{ .root_source_file = module_path });
    const asset = b.allocator.create(ImageAsset) catch @panic("OOM");
    asset.* = .{
        .module = module,
        .tiles = tiles_path,
        .palette = palette_path,
    };
    return asset;
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

fn validateObjImage(source_path: []const u8, source: image.Image) void {
    if (source.isEmpty()) {
        std.debug.panic("image asset '{s}' is empty", .{source_path});
    }
    if ((source.getWidth() & 0x7) != 0 or (source.getHeight() & 0x7) != 0) {
        std.debug.panic(
            "image asset '{s}' is {d}x{d}; 4bpp OBJ images must have dimensions divisible by 8",
            .{ source_path, source.getWidth(), source.getHeight() },
        );
    }
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
