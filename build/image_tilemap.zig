const std = @import("std");
const Image = @import("image.zig").Image;
const Palettizer = @import("color.zig").Palettizer;
const Screenblock = @import("../src/gba/display/mod.zig").Screenblock;
const Tile4Bpp = @import("../src/gba/display/mod.zig").Tile4Bpp;

pub const ConvertImageTilemap4BppOptions = struct {
    /// Used to resolve palette indices from colors in the image.
    palettizer: Palettizer,
    /// Palette bank written into every generated screenblock entry.
    palette: u4 = 0,
    /// If true, identical tiles are emitted once and referenced many times.
    dedupe: bool = true,
    /// If true, hflip/vflip/both are considered during deduplication.
    dedupe_flips: bool = true,
    /// If not set, then an empty input image will trigger an error.
    allow_empty: bool = false,
};

pub const ConvertImageTilemap4BppOutput = struct {
    tiles: []Tile4Bpp,
    map: []Screenblock.Entry,
    source_width_tiles: u16,
    source_height_tiles: u16,
    map_width_tiles: u16,
    map_height_tiles: u16,

    pub fn deinit(self: ConvertImageTilemap4BppOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
        allocator.free(self.map);
    }
};

pub const ConvertImageTilemap4BppError = error{
    UnexpectedImageSize,
    InvalidImage,
    EmptyImage,
    ImageTooLarge,
    MapTooLarge,
    TooManyTiles,
    UnexpectedPaletteIndex,
};

const TileMatch = struct {
    index: u10,
    flip_x: bool = false,
    flip_y: bool = false,
};

pub fn convertImageTilemap4BppPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    options: ConvertImageTilemap4BppOptions,
) !ConvertImageTilemap4BppOutput {
    var image = try Image.fromFilePath(allocator, io, image_path);
    defer image.deinit(allocator);
    return convertImageTilemap4Bpp(allocator, image, options);
}

pub fn convertSaveImageTilemap4BppPath(
    allocator: std.mem.Allocator,
    io: std.Io,
    image_path: []const u8,
    tiles_output_path: []const u8,
    map_output_path: []const u8,
    options: ConvertImageTilemap4BppOptions,
) !void {
    const output = try convertImageTilemap4BppPath(allocator, io, image_path, options);
    defer output.deinit(allocator);

    var tiles_file = try std.Io.Dir.cwd().createFile(io, tiles_output_path, .{});
    defer tiles_file.close(io);
    try tiles_file.writeStreamingAll(io, std.mem.sliceAsBytes(output.tiles));

    var map_file = try std.Io.Dir.cwd().createFile(io, map_output_path, .{});
    defer map_file.close(io);
    try map_file.writeStreamingAll(io, std.mem.sliceAsBytes(output.map));
}

pub fn convertImageTilemap4Bpp(
    allocator: std.mem.Allocator,
    image: Image,
    options: ConvertImageTilemap4BppOptions,
) !ConvertImageTilemap4BppOutput {
    if (!options.allow_empty and image.isEmpty()) {
        return ConvertImageTilemap4BppError.EmptyImage;
    } else if (((image.getWidth() & 0x7) != 0) or
        ((image.getHeight() & 0x7) != 0))
    {
        return ConvertImageTilemap4BppError.UnexpectedImageSize;
    }

    const source_width_tiles = image.getWidth() >> 3;
    const source_height_tiles = image.getHeight() >> 3;
    if (source_width_tiles > 64 or source_height_tiles > 64) {
        return ConvertImageTilemap4BppError.MapTooLarge;
    }

    const map_width_tiles: u16 = if (source_width_tiles <= 32) 32 else 64;
    const map_height_tiles: u16 = if (source_height_tiles <= 32) 32 else 64;
    const map_entry_count = @as(usize, map_width_tiles) * @as(usize, map_height_tiles);
    var map = try allocator.alloc(Screenblock.Entry, map_entry_count);
    errdefer allocator.free(map);
    @memset(map, .{});

    var tiles: std.ArrayList(Tile4Bpp) = .empty;
    defer tiles.deinit(allocator);

    for (0..source_height_tiles) |source_y| {
        for (0..source_width_tiles) |source_x| {
            const tile = try readTile4Bpp(image, @intCast(source_x), @intCast(source_y), options.palettizer);
            const match = try findOrAppendTile(allocator, &tiles, tile, options.dedupe, options.dedupe_flips);
            map[getNormalMapIndex(
                @intCast(source_x),
                @intCast(source_y),
                map_width_tiles,
            )] = .{
                .tile = match.index,
                .flip_x = match.flip_x,
                .flip_y = match.flip_y,
                .palette = options.palette,
            };
        }
    }

    return .{
        .tiles = try tiles.toOwnedSlice(allocator),
        .map = map,
        .source_width_tiles = source_width_tiles,
        .source_height_tiles = source_height_tiles,
        .map_width_tiles = map_width_tiles,
        .map_height_tiles = map_height_tiles,
    };
}

fn readTile4Bpp(
    image: Image,
    tile_x: u16,
    tile_y: u16,
    palettizer: Palettizer,
) !Tile4Bpp {
    var tile: Tile4Bpp = .init(@splat(0));
    for (0..8) |pixel_y| {
        for (0..8) |pixel_x| {
            const image_x: u16 = @intCast((tile_x << 3) + pixel_x);
            const image_y: u16 = @intCast((tile_y << 3) + pixel_y);
            const pal_index = palettizer.get(.{
                .color = image.getPixelColor(image_x, image_y),
                .x = image_x,
                .y = image_y,
            });
            if (pal_index >= 16) {
                return ConvertImageTilemap4BppError.UnexpectedPaletteIndex;
            }
            tile.setPixel8(@intCast(pixel_x), @intCast(pixel_y), @intCast(pal_index));
        }
    }
    return tile;
}

fn findOrAppendTile(
    allocator: std.mem.Allocator,
    tiles: *std.ArrayList(Tile4Bpp),
    tile: Tile4Bpp,
    dedupe: bool,
    dedupe_flips: bool,
) !TileMatch {
    if (dedupe) {
        for (tiles.items, 0..) |existing, i| {
            if (tileMatches(existing, tile, false, false)) {
                return .{ .index = @intCast(i) };
            }
            if (dedupe_flips) {
                if (tileMatches(existing, tile, true, false)) {
                    return .{ .index = @intCast(i), .flip_x = true };
                }
                if (tileMatches(existing, tile, false, true)) {
                    return .{ .index = @intCast(i), .flip_y = true };
                }
                if (tileMatches(existing, tile, true, true)) {
                    return .{ .index = @intCast(i), .flip_x = true, .flip_y = true };
                }
            }
        }
    }

    if (tiles.items.len >= 1024) {
        return ConvertImageTilemap4BppError.TooManyTiles;
    }
    const index: u10 = @intCast(tiles.items.len);
    try tiles.append(allocator, tile);
    return .{ .index = index };
}

fn tileMatches(existing: Tile4Bpp, wanted: Tile4Bpp, flip_x: bool, flip_y: bool) bool {
    for (0..8) |y| {
        for (0..8) |x| {
            const existing_x: u3 = @intCast(if (flip_x) 7 - x else x);
            const existing_y: u3 = @intCast(if (flip_y) 7 - y else y);
            if (wanted.getPixel(@intCast(x), @intCast(y)) != existing.getPixel(existing_x, existing_y)) {
                return false;
            }
        }
    }
    return true;
}

fn getNormalMapIndex(x: u16, y: u16, map_width_tiles: u16) usize {
    const screenblock_x = x >> 5;
    const screenblock_y = y >> 5;
    const screenblock_columns = map_width_tiles >> 5;
    const screenblock_index = screenblock_x + (screenblock_y * screenblock_columns);
    return (@as(usize, screenblock_index) << 10) +
        @as(usize, x & 31) +
        (@as(usize, y & 31) << 5);
}

pub const ConvertImageTilemap4BppStep = struct {
    pub const Options = struct {
        name: ?[]const u8 = null,
        image_path: []const u8,
        tiles_output_path: []const u8,
        map_output_path: []const u8,
        options: ConvertImageTilemap4BppOptions,
    };

    step: std.Build.Step,
    image_path: []const u8,
    tiles_output_path: []const u8,
    map_output_path: []const u8,
    options: ConvertImageTilemap4BppOptions,

    pub fn create(b: *std.Build, options: Options) *ConvertImageTilemap4BppStep {
        const step_name = options.name orelse b.fmt(
            "ConvertImageTilemap4BppStep {s} -> {s}, {s}",
            .{ options.image_path, options.tiles_output_path, options.map_output_path },
        );
        const convert_step = b.allocator.create(ConvertImageTilemap4BppStep) catch @panic("OOM");
        convert_step.* = .{
            .image_path = options.image_path,
            .tiles_output_path = options.tiles_output_path,
            .map_output_path = options.map_output_path,
            .options = options.options,
            .step = std.Build.Step.init(.{
                .id = .custom,
                .owner = b,
                .makeFn = make,
                .name = step_name,
            }),
        };
        return convert_step;
    }

    fn make(
        step: *std.Build.Step,
        make_options: std.Build.Step.MakeOptions,
    ) !void {
        const self: *ConvertImageTilemap4BppStep = @fieldParentPtr("step", step);
        const node_name = step.owner.fmt(
            "Converting image tilemap: {s} -> {s}, {s}",
            .{ self.image_path, self.tiles_output_path, self.map_output_path },
        );
        var node = make_options.progress_node.start(node_name, 1);
        defer node.end();

        var threaded: std.Io.Threaded = .init_single_threaded;
        defer threaded.deinit();
        try convertSaveImageTilemap4BppPath(
            step.owner.allocator,
            threaded.io(),
            self.image_path,
            self.tiles_output_path,
            self.map_output_path,
            self.options,
        );
    }
};
