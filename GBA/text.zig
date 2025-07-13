const std = @import("std");
const gba = @import("gba.zig");
const bg = gba.bg;
const Color = gba.Color;
const display = gba.display;
const bios = gba.bios;

/// Classic convenience initialiser targeting the global default context.
pub fn initSeDefault(bg_number: i32, bg_control: bg.Control) void {
    initSeCtx(&default_ctx, bg_number, bg_control, 0xF000, Color.yellow, 0, &sys8_font, null);
}

/// Write a (potentially control-coded) UTF-8 string using the given context.
/// Only ASCII 32-126 are currently supported.
pub fn writeCtx(ctx: *TextContext, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        // Very small subset of the TTE control language: #{P:x,y}
        if (c == '#' and i + 1 < text.len and text[i + 1] == '{') {
            var close_idx: ?usize = null;
            var j_idx: usize = i + 2;
            while (j_idx < text.len) : (j_idx += 1) {
                if (text[j_idx] == '}') {
                    close_idx = j_idx;
                    break;
                }
            }
            if (close_idx == null) {
                // No closing brace – treat literally.
                if (ctx.draw_glyph) |dg| dg(ctx, '#');
                continue;
            }
            const close = close_idx.?;
            parseControlCtx(ctx, text[i .. close + 1]);
            i = close; // loop will add 1
            continue;
        }

        if (c == '\n') {
            newLineCtx(ctx);
        } else if (c >= 32 and c <= 126) {
            if (ctx.draw_glyph) |dg| dg(ctx, c);
        }
    }
}

/// Convenience wrapper that writes using the global default context.
pub fn write(text: []const u8) void {
    writeCtx(&default_ctx, text);
}

// ------------------------------------------------------------
// Generic text-engine context & backend abstraction
// ------------------------------------------------------------

/// Runtime context for the text engine. Multiple instances can coexist, each
/// with their own target surface/back-end.
pub const TextContext = struct {
    // Target tile/surface parameters (for SE back-end).
    tile_start: u32 = 0,
    palette_bank: u4 = 0,
    char_block: u5 = 0,
    screen_block: u5 = 0,

    // Font currently in use.
    font: *const Font = &sys8_font,

    // Cursor position in pixels (not tiles).
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,

    // Pointer to a backend-specific glyph renderer. If null, nothing is drawn.
    draw_glyph: ?*const fn (*TextContext, u8) void = null,
};

/// Global default context used by the classic convenience wrappers.
var default_ctx = TextContext{};

// ------------------------------------------------------------
// Internal state & helpers
// ------------------------------------------------------------

// (Former global state is now stored per-context.)

fn newLineCtx(ctx: *TextContext) void {
    ctx.cursor_x = 0;
    ctx.cursor_y += @as(u16, ctx.font.cell_h);
}

// ---------------------------------------------------------------------------
// Screen-entry (regular BG) glyph renderer – previously `putChar`
// ---------------------------------------------------------------------------

fn seDrawGlyph(ctx: *TextContext, ascii: u8) void {
    if (ascii < 32 or ascii > 127) return; // unsupported

    const gid: u32 = @as(u32, ascii) - @as(u32, ctx.font.char_offset);
    const tx: u16 = ctx.cursor_x / @as(u16, ctx.font.cell_w);
    const ty: u16 = ctx.cursor_y / @as(u16, ctx.font.cell_h);
    if (tx >= 32 or ty >= 32) return; // out of bounds

    const map_block_ptr: *volatile bg.TextScreenBlock =
        &bg.screen_block_ram[ctx.screen_block];

    const entry_index = ty * 32 + tx;
    map_block_ptr.*[entry_index] = .{
        .tile_index = @intCast(ctx.tile_start + gid),
        .flip = .{},
        .palette_index = ctx.palette_bank,
    };

    ctx.cursor_x += @as(u16, ctx.font.cell_w);
}

/// Parse the very small subset of control codes we care about.
/// Currently only "#{P:x,y}" is handled.
fn parseControlCtx(ctx: *TextContext, code: []const u8) void {
    // Expect format #{P:NN,NN}
    if (code.len < 4) return;
    if (code[2] != 'P' or code[3] != ':') return;

    var j: usize = 4;
    var x: u16 = 0;
    while (j < code.len and std.ascii.isDigit(code[j])) : (j += 1) {
        x = x * 10 + (code[j] - '0');
    }
    if (j >= code.len or code[j] != ',') return;
    j += 1; // skip comma

    var y: u16 = 0;
    while (j < code.len and std.ascii.isDigit(code[j])) : (j += 1) {
        y = y * 10 + (code[j] - '0');
    }

    // Update cursor position.
    ctx.cursor_x = x;
    ctx.cursor_y = y;
}

// ------------------------------------------------------------
// Embedded sys8 font glyphs (96 glyphs * 2 u32 each = 192 u32)
// ------------------------------------------------------------

/// Direct translation of libtonc's `TFont` structure.
/// Used for describing bitmap fonts so that we can later re-use more of the
/// original TONC text engine without large changes.
pub const Font = extern struct {
    /// Pointer to raw character data (usually 1-bpp packed rows).
    data: *const anyopaque,
    /// Optional width table for variable-width fonts (null if fixed-width).
    widths: ?[*]const u8,
    /// Optional height table for variable-height fonts (null if fixed-height).
    heights: ?[*]const u8,

    /// First character code contained in this font (usually 32 for space).
    char_offset: u16,
    /// Number of characters present in this font.
    char_count: u16,

    /// Default character width/height in pixels.
    char_w: u8,
    char_h: u8,

    /// Width/height of each glyph "cell" (might differ from `char_w/h` when
    /// doing variable-width rendering, but for sys8 they’re both 8).
    cell_w: u8,
    cell_h: u8,

    /// Size of one glyph cell in bytes (`cell_w * cell_h * bpp / 8`).
    cell_size: u16,

    /// Bit-depth of the encoded font data (1 for sys8).
    bpp: u8,
    /// Free byte for future use / alignment (mirrors TONC’s `extra`).
    extra: u8,
};

/// Constant describing the built-in 1-bpp sys8 font that ships with TONC.
pub const sys8_font: Font = .{
    .data = &sys8_glyphs,
    .widths = null, // fixed-width
    .heights = null,
    .char_offset = 32,
    .char_count = 96,
    .char_w = 8,
    .char_h = 8,
    .cell_w = 8,
    .cell_h = 8,
    .cell_size = 8, // 8 bytes per glyph (1-bpp, 8×8)
    .bpp = 1,
    .extra = 0,
};

// ---------------------------------------------------------------------------
// Temporary stub for the `initSe` function – we will flesh this out while
// porting more of TONC's TTE later. For now its only purpose is to satisfy
// the compiler so that we can iterate in smaller steps.
// ---------------------------------------------------------------------------

fn initSeCtx(
    ctx: *TextContext,
    bg_number: i32,
    bg_control: bg.Control,
    se0: u32,
    clrs: Color,
    bupofs: u32,
    font: ?*const Font,
    proc: ?*const fn (*TextContext, u8) void,
) void {
    // Select font (default to sys8 if null).
    const f_ptr: *const Font = if (font) |p| p else &sys8_font;

    // Decode screen-entry parameters: tile start index and palette bank.
    const tile_start: u32 = se0 & 0x03FF;
    const palette_bank: u4 = @as(u4, @intCast((se0 >> 12) & 0xF));
    _ = bupofs;

    // Store runtime parameters for other routines and configure BG control.
    ctx.font = f_ptr;
    ctx.char_block = bg_control.tile_base_block;
    ctx.screen_block = bg_control.screen_base_block;
    ctx.tile_start = tile_start;
    ctx.palette_bank = palette_bank;
    ctx.draw_glyph = if (proc) |p| p else &seDrawGlyph;
    bg.ctrl[@intCast(bg_number)] = bg_control;

    // Prepare the palette: entry 1 = ink color.
    bg.palette.banks[palette_bank][1] = clrs;

    // Bit‑unpack each glyph (8 bytes of 1bpp → 32 bytes of 4bpp) into its tile slot.
    var args = bios.BitUnpackArgs{
        .src_len_bytes = f_ptr.*.cell_size,
        .src_bit_width = .@"1",
        .dest_bit_width = .@"4",
        // MSB of each source byte maps to leftmost pixel nibble
        .data_offset = @as(u31, 0),
        .zero_data = true,
    };
    const raw_array: [*]const u8 = @ptrCast(f_ptr.*.data);
    const cell_size = @as(usize, f_ptr.*.cell_size);
    const glyph_count = @as(usize, f_ptr.*.char_count);
    for (0..glyph_count) |i| {
        const src_slice = &raw_array[i * cell_size];
        const idx: u32 = @intCast(i);
        const dst_ptr: *align(4) const anyopaque = @volatileCast(&bg.tile_ram[bg_control.tile_base_block][tile_start + idx]);
        bios.bitUnpack(src_slice, dst_ptr, &args);
        args.zero_data = false;
    }

    // Clear the tile map for the target screen block.
    const map_block = &bg.screen_block_ram[bg_control.screen_base_block];
    var ei: usize = 0;
    while (ei < 1024) : (ei += 1) {
        map_block.*[ei] = .{
            .tile_index = @intCast(tile_start),
            .flip = .{},
            .palette_index = palette_bank,
        };
    }

    // Reset cursor position.
    ctx.cursor_x = 0;
    ctx.cursor_y = 0;
}

// Using BIOS SWI for bit-unpacking is more reliable for correct bit orders;
// manual conversion pipeline is removed until we get the core path working.

// ---------------------------------------------------------------------------
// Embedded sys8 font glyphs (96 glyphs * 2 u32 each = 192 u32)
// ---------------------------------------------------------------------------
const sys8_glyphs: [192]u32 = block: {
    const a: [192]u32 = [_]u32{
        0x00000000, 0x00000000, 0x18181818, 0x00180018, 0x00003636, 0x00000000, 0x367F3636, 0x0036367F,
        0x3C067C18, 0x00183E60, 0x1B356600, 0x0033566C, 0x6E16361C, 0x00DE733B, 0x000C1818, 0x00000000,
        0x0C0C1830, 0x0030180C, 0x3030180C, 0x000C1830, 0xFF3C6600, 0x0000663C, 0x7E181800, 0x00001818,
        0x00000000, 0x0C181800, 0x7E000000, 0x00000000, 0x00000000, 0x00181800, 0x183060C0, 0x0003060C,
        0x7E76663C, 0x003C666E, 0x181E1C18, 0x00181818, 0x3060663C, 0x007E0C18, 0x3860663C, 0x003C6660,
        0x33363C38, 0x0030307F, 0x603E067E, 0x003C6660, 0x3E060C38, 0x003C6666, 0x3060607E, 0x00181818,
        0x3C66663C, 0x003C6666, 0x7C66663C, 0x001C3060, 0x00181800, 0x00181800, 0x00181800, 0x0C181800,
        0x06186000, 0x00006018, 0x007E0000, 0x0000007E, 0x60180600, 0x00000618, 0x3060663C, 0x00180018,

        0x5A5A663C, 0x003C067A, 0x7E66663C, 0x00666666, 0x3E66663E, 0x003E6666, 0x06060C78, 0x00780C06,
        0x6666361E, 0x001E3666, 0x1E06067E, 0x007E0606, 0x1E06067E, 0x00060606, 0x7606663C, 0x007C6666,
        0x7E666666, 0x00666666, 0x1818183C, 0x003C1818, 0x60606060, 0x003C6660, 0x0F1B3363, 0x0063331B,
        0x06060606, 0x007E0606, 0x6B7F7763, 0x00636363, 0x7B6F6763, 0x00636373, 0x6666663C, 0x003C6666,
        0x3E66663E, 0x00060606, 0x3333331E, 0x007E3B33, 0x3E66663E, 0x00666636, 0x3C0E663C, 0x003C6670,
        0x1818187E, 0x00181818, 0x66666666, 0x003C6666, 0x66666666, 0x00183C3C, 0x6B636363, 0x0063777F,
        0x183C66C3, 0x00C3663C, 0x183C66C3, 0x00181818, 0x0C18307F, 0x007F0306, 0x0C0C0C3C, 0x003C0C0C,
        0x180C0603, 0x00C06030, 0x3030303C, 0x003C3030, 0x00663C18, 0x00000000, 0x00000000, 0x003F0000,

        0x00301818, 0x00000000, 0x603C0000, 0x007C667C, 0x663E0606, 0x003E6666, 0x063C0000, 0x003C0606,
        0x667C6060, 0x007C6666, 0x663C0000, 0x003C067E, 0x0C3E0C38, 0x000C0C0C, 0x667C0000, 0x3C607C66,
        0x663E0606, 0x00666666, 0x18180018, 0x00301818, 0x30300030, 0x1E303030, 0x36660606, 0x0066361E,
        0x18181818, 0x00301818, 0x7F370000, 0x0063636B, 0x663E0000, 0x00666666, 0x663C0000, 0x003C6666,
        0x663E0000, 0x06063E66, 0x667C0000, 0x60607C66, 0x663E0000, 0x00060606, 0x063C0000, 0x003E603C,
        0x0C3E0C0C, 0x00380C0C, 0x66660000, 0x007C6666, 0x66660000, 0x00183C66, 0x63630000, 0x00367F6B,
        0x36630000, 0x0063361C, 0x66660000, 0x0C183C66, 0x307E0000, 0x007E0C18, 0x0C181830, 0x00301818,
        0x18181818, 0x00181818, 0x3018180C, 0x000C1818, 0x003B6E00, 0x00000000, 0x00000000, 0x00000000,
    };
    // The glyph data is already in the correct little-endian byte order for the GBA,
    // so no additional swapping is required.
    break :block a;
};
