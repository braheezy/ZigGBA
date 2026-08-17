const std = @import("std");
const color = @import("color.zig");
const Image = @import("image.zig").Image;
const Screenblock = @import("../src/gba/display/mod.zig").Screenblock;
const Tile4Bpp = @import("../src/gba/display/mod.zig").Tile4Bpp;
const ColorRgb555 = @import("../src/gba/graphics/color.zig").ColorRgb555;

/// Palette-bank policy for a 4bpp normal background.
pub const PaletteBanks = union(enum) {
    /// Assign tiles to banks in source order, adding colors to the first bank
    /// that can represent a complete tile. This is deterministic but greedy.
    auto,
    /// Use exact artist-supplied banks. A tile must fit completely in at least
    /// one supplied bank; index zero of every bank remains transparent.
    provided: []const [16]ColorRgb555,
};

pub const ConvertImageTilemap4BppMultiBankOptions = struct {
    palette_banks: PaletteBanks = .auto,
    dedupe: bool = true,
    dedupe_flips: bool = true,
    allow_empty: bool = false,
};

pub const ConvertImageTilemap4BppMultiBankOutput = struct {
    tiles: []Tile4Bpp,
    map: []Screenblock.Entry,
    palette: [16][16]ColorRgb555,
    palette_bank_count: usize,
    source_width_tiles: u16,
    source_height_tiles: u16,
    map_width_tiles: u16,
    map_height_tiles: u16,

    pub fn deinit(self: ConvertImageTilemap4BppMultiBankOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.tiles);
        allocator.free(self.map);
    }
};

pub const ConvertImageTilemap4BppMultiBankError = error{
    UnexpectedImageSize,
    EmptyImage,
    MapTooLarge,
    TooManyTiles,
    TileTooManyColors,
    TooManyPaletteBanks,
    ColorNotInPaletteBanks,
    InvalidPaletteBanks,
};

const TileColors = struct {
    colors: [15]ColorRgb555 = undefined,
    count: usize = 0,
};

const TileMatch = struct {
    index: u10,
    flip_x: bool = false,
    flip_y: bool = false,
};

pub fn convertImageTilemap4BppMultiBank(
    allocator: std.mem.Allocator,
    image: Image,
    options: ConvertImageTilemap4BppMultiBankOptions,
) !ConvertImageTilemap4BppMultiBankOutput {
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

    var palette: [16][16]ColorRgb555 = @splat(@splat(.black));
    var palette_counts: [16]usize = @splat(1);
    var palette_bank_count: usize = 1;
    switch (options.palette_banks) {
        .auto => {},
        .provided => |banks| {
            if (banks.len == 0 or banks.len > 16) return error.InvalidPaletteBanks;
            for (banks, 0..) |bank, index| palette[index] = bank;
            palette_bank_count = banks.len;
        },
    }

    var tiles: std.ArrayList(Tile4Bpp) = .empty;
    defer tiles.deinit(allocator);
    for (0..source_height_tiles) |source_y| {
        for (0..source_width_tiles) |source_x| {
            const tile_colors = try collectTileColors(image, @intCast(source_x), @intCast(source_y));
            const bank_index = switch (options.palette_banks) {
                .auto => try assignAutoBank(&palette, &palette_counts, &palette_bank_count, tile_colors),
                .provided => try findProvidedBank(palette[0..palette_bank_count], tile_colors),
            };
            const tile = writeTile(image, @intCast(source_x), @intCast(source_y), palette[bank_index]);
            const match = try findOrAppendTile(allocator, &tiles, tile, options.dedupe, options.dedupe_flips);
            map[normalMapIndex(@intCast(source_x), @intCast(source_y), map_width_tiles)] = .{
                .tile = match.index,
                .flip_x = match.flip_x,
                .flip_y = match.flip_y,
                .palette = @intCast(bank_index),
            };
        }
    }

    return .{
        .tiles = try tiles.toOwnedSlice(allocator),
        .map = map,
        .palette = palette,
        .palette_bank_count = palette_bank_count,
        .source_width_tiles = source_width_tiles,
        .source_height_tiles = source_height_tiles,
        .map_width_tiles = map_width_tiles,
        .map_height_tiles = map_height_tiles,
    };
}

fn validateImage(image: Image, allow_empty: bool) ConvertImageTilemap4BppMultiBankError!void {
    if (!allow_empty and image.isEmpty()) return error.EmptyImage;
    if ((image.getWidth() & 7) != 0 or (image.getHeight() & 7) != 0) {
        return error.UnexpectedImageSize;
    }
}

fn collectTileColors(image: Image, tile_x: u16, tile_y: u16) ConvertImageTilemap4BppMultiBankError!TileColors {
    var result: TileColors = .{};
    for (0..8) |pixel_y| {
        for (0..8) |pixel_x| {
            const source = image.getPixelColor(
                @intCast((tile_x << 3) + pixel_x),
                @intCast((tile_y << 3) + pixel_y),
            );
            if (source.a < 0xff) continue;
            const converted = color.convertColorDepthLinear(source);
            if (containsColor(result.colors[0..result.count], converted)) continue;
            if (result.count == result.colors.len) return error.TileTooManyColors;
            result.colors[result.count] = converted;
            result.count += 1;
        }
    }
    return result;
}

fn assignAutoBank(
    palette: *[16][16]ColorRgb555,
    palette_counts: *[16]usize,
    palette_bank_count: *usize,
    tile_colors: TileColors,
) ConvertImageTilemap4BppMultiBankError!usize {
    for (0..palette_bank_count.*) |bank_index| {
        if (!canFit(palette[bank_index], palette_counts[bank_index], tile_colors)) continue;
        appendMissingColors(&palette[bank_index], &palette_counts[bank_index], tile_colors);
        return bank_index;
    }
    if (palette_bank_count.* == palette.len) return error.TooManyPaletteBanks;

    const bank_index = palette_bank_count.*;
    palette[bank_index] = @splat(.black);
    palette_counts[bank_index] = 1;
    appendMissingColors(&palette[bank_index], &palette_counts[bank_index], tile_colors);
    palette_bank_count.* += 1;
    return bank_index;
}

fn findProvidedBank(
    palette_banks: []const [16]ColorRgb555,
    tile_colors: TileColors,
) ConvertImageTilemap4BppMultiBankError!usize {
    for (palette_banks, 0..) |bank, bank_index| {
        if (canFit(bank, bank.len, tile_colors)) return bank_index;
    }
    return error.ColorNotInPaletteBanks;
}

fn canFit(bank: [16]ColorRgb555, bank_count: usize, tile_colors: TileColors) bool {
    var missing: usize = 0;
    for (tile_colors.colors[0..tile_colors.count]) |tile_color| {
        if (!containsColor(bank[1..bank_count], tile_color)) missing += 1;
    }
    return bank_count + missing <= bank.len;
}

fn appendMissingColors(bank: *[16]ColorRgb555, bank_count: *usize, tile_colors: TileColors) void {
    for (tile_colors.colors[0..tile_colors.count]) |tile_color| {
        if (containsColor(bank[1..bank_count.*], tile_color)) continue;
        bank[bank_count.*] = tile_color;
        bank_count.* += 1;
    }
}

fn writeTile(image: Image, tile_x: u16, tile_y: u16, bank: [16]ColorRgb555) Tile4Bpp {
    var tile: Tile4Bpp = .init(@splat(0));
    for (0..8) |pixel_y| {
        for (0..8) |pixel_x| {
            const source = image.getPixelColor(
                @intCast((tile_x << 3) + pixel_x),
                @intCast((tile_y << 3) + pixel_y),
            );
            if (source.a < 0xff) continue;
            const converted = color.convertColorDepthLinear(source);
            tile.setPixel8(
                @intCast(pixel_x),
                @intCast(pixel_y),
                @intCast(colorIndex(bank[1..], converted).?),
            );
        }
    }
    return tile;
}

fn colorIndex(colors: []const ColorRgb555, wanted: ColorRgb555) ?usize {
    for (colors, 1..) |color_value, index| {
        if (color_value == wanted) return index;
    }
    return null;
}

fn containsColor(colors: []const ColorRgb555, wanted: ColorRgb555) bool {
    return colorIndex(colors, wanted) != null;
}

fn findOrAppendTile(
    allocator: std.mem.Allocator,
    tiles: *std.ArrayList(Tile4Bpp),
    tile: Tile4Bpp,
    dedupe: bool,
    dedupe_flips: bool,
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
    if (tiles.items.len >= 1024) return error.TooManyTiles;
    const index: u10 = @intCast(tiles.items.len);
    try tiles.append(allocator, tile);
    return .{ .index = index };
}

fn tileMatches(existing: Tile4Bpp, wanted: Tile4Bpp, flip_x: bool, flip_y: bool) bool {
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

test "auto palette banks greedily add complete tile palettes" {
    var palette: [16][16]ColorRgb555 = @splat(@splat(.black));
    var counts: [16]usize = @splat(1);
    var bank_count: usize = 1;
    const red = ColorRgb555.red;
    const green = ColorRgb555.green;
    const blue = ColorRgb555.blue;
    var first_colors: [15]ColorRgb555 = @splat(.black);
    first_colors[0] = red;
    var second_colors: [15]ColorRgb555 = @splat(.black);
    second_colors[0] = red;
    second_colors[1] = green;
    second_colors[2] = blue;

    const first = try assignAutoBank(&palette, &counts, &bank_count, .{ .colors = first_colors, .count = 1 });
    const second = try assignAutoBank(&palette, &counts, &bank_count, .{ .colors = second_colors, .count = 3 });
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(usize, 0), second);
    try std.testing.expectEqual(@as(usize, 4), counts[0]);

    counts[0] = 16;
    var third_colors: [15]ColorRgb555 = @splat(.black);
    third_colors[0] = ColorRgb555.white;
    const third = try assignAutoBank(&palette, &counts, &bank_count, .{ .colors = third_colors, .count = 1 });
    try std.testing.expectEqual(@as(usize, 1), third);
    try std.testing.expectEqual(@as(usize, 2), bank_count);
}

test "provided palette banks reject a tile that fits no bank" {
    const banks = [_][16]ColorRgb555{@splat(.black)};
    var colors: [15]ColorRgb555 = @splat(.black);
    colors[0] = ColorRgb555.red;
    try std.testing.expectError(
        error.ColorNotInPaletteBanks,
        findProvidedBank(&banks, .{ .colors = colors, .count = 1 }),
    );
}
