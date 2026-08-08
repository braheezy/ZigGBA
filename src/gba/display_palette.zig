//! Implements an API for dealing with background and object palettes.

const gba = @import("gba.zig");
const std = @import("std");
const assert = std.debug.assert;
const palette_bank_color_count = 16;

/// Represents a 256-color palette, to be used with either backgrounds or
/// objects/sprites.
///
/// Depending on the settings for a background or object, it may either use
/// the corresponding palette as a single 256-color palette (8 bits per pixel)
/// or it may select a 16-color subset, called a "bank" (4 bits per pixel).
pub const Palette = extern union {
    /// A palette of 16 colors.
    /// The color at `bank[0]` is always transparent.
    pub const Bank = [16]gba.ColorRgb555;

    /// Array of palette banks. Relevant for 4bpp graphics.
    /// The first color of each bank is always treated as transparent.
    banks: [16]Bank,
    /// Full palette of 256 colors. Relevant for 8bpp graphics.
    /// The first color, `colors[0]`, is treated as transparent.
    /// It is also used as the backdrop color, when no opaque pixels are
    /// drawn at a screen position.
    colors: [256]gba.ColorRgb555,
};

/// Palette used for backgrounds.
pub const bg_palette: *volatile Palette = @ptrCast(&gba.mem.palette[0x000]);

/// Palette used for objects/sprites.
pub const obj_palette: *volatile Palette = @ptrCast(&gba.mem.palette[0x100]);

/// Return one 16-color background palette bank.
pub fn backgroundPaletteBank(bank: u4) *volatile Palette.Bank {
    return &bg_palette.banks[bank];
}

/// Return one 16-color object palette bank.
pub fn objectPaletteBank(bank: u4) *volatile Palette.Bank {
    return &obj_palette.banks[bank];
}

/// Copy memory into the background palette.
pub fn memcpyBackgroundPalette(
    /// Offset, in colors. Each palette color uses two bytes.
    color_offset: u8,
    /// Pointer to color data that should be copied into palette memory.
    data: []align(2) const gba.ColorRgb555,
) void {
    assert(color_offset + data.len <= bg_palette.colors.len);
    gba.mem.memcpy16(&bg_palette.colors[color_offset], data.ptr, data.len);
}

/// Copy memory into one 16-color background palette bank.
pub inline fn memcpyBackgroundPaletteBank(
    /// Copy color data into this bank, 0-15.
    bank: u4,
    /// Offset within this bank, in colors.
    color_offset: u4,
    /// Pointer to color data that should be copied into palette memory.
    data: []align(2) const gba.ColorRgb555,
) void {
    assert(paletteBankContains(color_offset, data.len));
    gba.mem.memcpy16(&backgroundPaletteBank(bank)[color_offset], data.ptr, data.len);
}

/// Copy memory into the object palette.
pub fn memcpyObjectPalette(
    /// Offset, in colors. Each palette color uses two bytes.
    color_offset: u8,
    /// Pointer to color data that should be copied into palette memory.
    data: []align(2) const gba.ColorRgb555,
) void {
    assert(color_offset + data.len <= obj_palette.colors.len);
    gba.mem.memcpy16(&obj_palette.colors[color_offset], data.ptr, data.len);
}

/// Copy memory into one 16-color object palette bank.
pub inline fn memcpyObjectPaletteBank(
    /// Copy color data into this bank, 0-15.
    bank: u4,
    /// Offset within this bank, in colors.
    color_offset: u4,
    /// Pointer to color data that should be copied into palette memory.
    data: []align(2) const gba.ColorRgb555,
) void {
    assert(paletteBankContains(color_offset, data.len));
    gba.mem.memcpy16(&objectPaletteBank(bank)[color_offset], data.ptr, data.len);
}

fn paletteBankContains(color_offset: u4, color_count: usize) bool {
    return color_count <= palette_bank_color_count - @as(usize, color_offset);
}

test "palette bank offsets and bounds" {
    var palette = Palette{ .colors = [_]gba.ColorRgb555{.black} ** 256 };
    palette.banks[1][0] = .white;
    palette.banks[15][15] = gba.ColorRgb555.rgb(1, 2, 3);

    try std.testing.expectEqual(gba.ColorRgb555.white, palette.colors[16]);
    try std.testing.expectEqual(gba.ColorRgb555.rgb(1, 2, 3), palette.colors[255]);
    try std.testing.expect(paletteBankContains(0, 16));
    try std.testing.expect(paletteBankContains(15, 1));
    try std.testing.expect(!paletteBankContains(1, 16));
    try std.testing.expect(!paletteBankContains(15, 2));
}
