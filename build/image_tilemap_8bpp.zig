const std = @import("std");
const Image = @import("image.zig").Image;
const Palettizer = @import("color.zig").Palettizer;
const BackgroundSize = @import("../src/gba/display/mod.zig").BackgroundSize;
const Screenblock = @import("../src/gba/display/mod.zig").Screenblock;
const Tile8Bpp = @import("../src/gba/display/mod.zig").Tile8Bpp;

pub const ConvertImageNormalTilemap8BppOptions = struct {
    palettizer: Palettizer,
    dedupe: bool = true,
    dedupe_flips: bool = true,
    allow_empty: bool = false,
};

pub const ConvertImageNormalTilemap8BppOutput = struct {
    tiles: []Tile8Bpp,
    map: []Screenblock.Entry,
    source_width_tiles: u16,
    source_height_tiles: u16,
    map_width_tiles: u16,
    map_height_tiles: u16,

    pub fn deinit(self: ConvertImageNormalTilemap8BppOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
        allocator.free(self.map);
    }
};

pub const ConvertImageAffineTilemap8BppOptions = struct {
    palettizer: Palettizer,
    size: BackgroundSize.Affine,
    /// Repeat the source tile grid to fill the affine map. Otherwise, source
    /// tiles occupy the top-left of the map and remaining entries are zero.
    repeat_source: bool = false,
    dedupe: bool = true,
    allow_empty: bool = false,
};

pub const ConvertImageAffineTilemap8BppOutput = struct {
    tiles: []Tile8Bpp,
    map: []Screenblock.AffinePair,
    source_width_tiles: u16,
    source_height_tiles: u16,
    map_dimension_tiles: u16,

    pub fn deinit(self: ConvertImageAffineTilemap8BppOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
        allocator.free(self.map);
    }
};

pub const ConvertImageTilemap8BppError = error{
    UnexpectedImageSize,
    EmptyImage,
    MapTooLarge,
    TooManyTiles,
};

const TileMatch = struct {
    index: u10,
    flip_x: bool = false,
    flip_y: bool = false,
};

pub fn convertImageNormalTilemap8Bpp(
    allocator: std.mem.Allocator,
    image: Image,
    options: ConvertImageNormalTilemap8BppOptions,
) !ConvertImageNormalTilemap8BppOutput {
    try validateImage(image, options.allow_empty);
    const source_width_tiles = image.getWidth() >> 3;
    const source_height_tiles = image.getHeight() >> 3;
    if (source_width_tiles > 64 or source_height_tiles > 64) return error.MapTooLarge;

    const map_width_tiles: u16 = if (source_width_tiles <= 32) 32 else 64;
    const map_height_tiles: u16 = if (source_height_tiles <= 32) 32 else 64;
    var map = try allocator.alloc(
        Screenblock.Entry,
        @as(usize, map_width_tiles) * @as(usize, map_height_tiles),
    );
    errdefer allocator.free(map);
    @memset(map, .{});

    var tiles: std.ArrayList(Tile8Bpp) = .empty;
    defer tiles.deinit(allocator);
    for (0..source_height_tiles) |source_y| {
        for (0..source_width_tiles) |source_x| {
            const tile = readTile(image, @intCast(source_x), @intCast(source_y), options.palettizer);
            const match = try findOrAppendTile(allocator, &tiles, tile, options.dedupe, options.dedupe_flips, 1024);
            map[normalMapIndex(@intCast(source_x), @intCast(source_y), map_width_tiles)] = .{
                .tile = match.index,
                .flip_x = match.flip_x,
                .flip_y = match.flip_y,
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

pub fn convertImageAffineTilemap8Bpp(
    allocator: std.mem.Allocator,
    image: Image,
    options: ConvertImageAffineTilemap8BppOptions,
) !ConvertImageAffineTilemap8BppOutput {
    try validateImage(image, options.allow_empty);
    const source_width_tiles = image.getWidth() >> 3;
    const source_height_tiles = image.getHeight() >> 3;
    const map_dimension_tiles = affineDimension(options.size);
    if (source_width_tiles > map_dimension_tiles or source_height_tiles > map_dimension_tiles) {
        return error.MapTooLarge;
    }

    var tiles: std.ArrayList(Tile8Bpp) = .empty;
    defer tiles.deinit(allocator);
    const source_tile_count = @as(usize, source_width_tiles) * @as(usize, source_height_tiles);
    const source_indices = try allocator.alloc(u8, source_tile_count);
    defer allocator.free(source_indices);
    for (0..source_height_tiles) |source_y| {
        for (0..source_width_tiles) |source_x| {
            const tile = readTile(image, @intCast(source_x), @intCast(source_y), options.palettizer);
            const match = try findOrAppendTile(allocator, &tiles, tile, options.dedupe, false, 256);
            source_indices[source_x + source_y * @as(usize, source_width_tiles)] = @intCast(match.index);
        }
    }

    const map_entry_count = @as(usize, map_dimension_tiles) * @as(usize, map_dimension_tiles);
    var map = try allocator.alloc(Screenblock.AffinePair, map_entry_count / 2);
    errdefer allocator.free(map);
    for (0..map.len) |pair_index| {
        const first = affineSourceIndex(
            pair_index * 2,
            source_width_tiles,
            source_height_tiles,
            map_dimension_tiles,
            source_indices,
            options.repeat_source,
        );
        const second = affineSourceIndex(
            pair_index * 2 + 1,
            source_width_tiles,
            source_height_tiles,
            map_dimension_tiles,
            source_indices,
            options.repeat_source,
        );
        map[pair_index] = .{ .lo = first, .hi = second };
    }

    return .{
        .tiles = try tiles.toOwnedSlice(allocator),
        .map = map,
        .source_width_tiles = source_width_tiles,
        .source_height_tiles = source_height_tiles,
        .map_dimension_tiles = map_dimension_tiles,
    };
}

fn validateImage(image: Image, allow_empty: bool) ConvertImageTilemap8BppError!void {
    if (!allow_empty and image.isEmpty()) return error.EmptyImage;
    if ((image.getWidth() & 7) != 0 or (image.getHeight() & 7) != 0) {
        return error.UnexpectedImageSize;
    }
}

fn readTile(image: Image, tile_x: u16, tile_y: u16, palettizer: Palettizer) Tile8Bpp {
    var tile: Tile8Bpp = .init(@splat(0));
    for (0..8) |pixel_y| {
        for (0..8) |pixel_x| {
            const image_x: u16 = @intCast((tile_x << 3) + pixel_x);
            const image_y: u16 = @intCast((tile_y << 3) + pixel_y);
            tile.setPixel8(
                @intCast(pixel_x),
                @intCast(pixel_y),
                palettizer.get(.{
                    .color = image.getPixelColor(image_x, image_y),
                    .x = image_x,
                    .y = image_y,
                }),
            );
        }
    }
    return tile;
}

fn findOrAppendTile(
    allocator: std.mem.Allocator,
    tiles: *std.ArrayList(Tile8Bpp),
    tile: Tile8Bpp,
    dedupe: bool,
    dedupe_flips: bool,
    max_tiles: usize,
) !TileMatch {
    if (dedupe) {
        for (tiles.items, 0..) |existing, index| {
            if (tileMatches(existing, tile, false, false)) return .{ .index = @intCast(index) };
            if (dedupe_flips) {
                if (tileMatches(existing, tile, true, false)) return .{ .index = @intCast(index), .flip_x = true };
                if (tileMatches(existing, tile, false, true)) return .{ .index = @intCast(index), .flip_y = true };
                if (tileMatches(existing, tile, true, true)) return .{ .index = @intCast(index), .flip_x = true, .flip_y = true };
            }
        }
    }
    if (tiles.items.len >= max_tiles) return error.TooManyTiles;
    const index: u10 = @intCast(tiles.items.len);
    try tiles.append(allocator, tile);
    return .{ .index = index };
}

fn tileMatches(existing: Tile8Bpp, wanted: Tile8Bpp, flip_x: bool, flip_y: bool) bool {
    for (0..8) |y| {
        for (0..8) |x| {
            const existing_x: u3 = @intCast(if (flip_x) 7 - x else x);
            const existing_y: u3 = @intCast(if (flip_y) 7 - y else y);
            if (wanted.getPixel(@intCast(x), @intCast(y)) != existing.getPixel(existing_x, existing_y)) return false;
        }
    }
    return true;
}

fn normalMapIndex(x: u16, y: u16, map_width_tiles: u16) usize {
    const screenblock_x = x >> 5;
    const screenblock_y = y >> 5;
    const screenblock_columns = map_width_tiles >> 5;
    const screenblock_index = screenblock_x + screenblock_y * screenblock_columns;
    return (@as(usize, screenblock_index) << 10) + @as(usize, x & 31) + (@as(usize, y & 31) << 5);
}

fn affineDimension(size: BackgroundSize.Affine) u16 {
    return @as(u16, 16) << @intFromEnum(size);
}

fn affineSourceIndex(
    map_index: usize,
    source_width_tiles: u16,
    source_height_tiles: u16,
    map_dimension_tiles: u16,
    source_indices: []const u8,
    repeat_source: bool,
) u8 {
    const x = map_index % @as(usize, map_dimension_tiles);
    const y = map_index / @as(usize, map_dimension_tiles);
    if (repeat_source or (x < source_width_tiles and y < source_height_tiles)) {
        const source_x = x % @as(usize, source_width_tiles);
        const source_y = y % @as(usize, source_height_tiles);
        return source_indices[source_x + source_y * @as(usize, source_width_tiles)];
    }
    return 0;
}

test "normal 8bpp maps use GBA screenblock layout" {
    try std.testing.expectEqual(@as(usize, 0), normalMapIndex(0, 0, 64));
    try std.testing.expectEqual(@as(usize, 1024), normalMapIndex(32, 0, 64));
    try std.testing.expectEqual(@as(usize, 2048), normalMapIndex(0, 32, 64));
}

test "affine 8bpp repeat maps tile-sheet coordinates" {
    const source_indices = [_]u8{ 1, 2, 3, 4 };
    try std.testing.expectEqual(
        @as(u8, 1),
        affineSourceIndex(0, 2, 2, 16, &source_indices, true),
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        affineSourceIndex(33, 2, 2, 16, &source_indices, true),
    );
    try std.testing.expectEqual(
        @as(u8, 0),
        affineSourceIndex(2, 2, 2, 16, &source_indices, false),
    );
}
