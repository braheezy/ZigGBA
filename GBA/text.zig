const std = @import("std");
const gba = @import("gba.zig");
const bg = gba.bg;
const Color = gba.Color;
const display = gba.display;
const bios = gba.bios;
const surface = @import("surface.zig");
const sys_glyphs = @import("fonts/sys.zig").glyphs;
const verdana_glyphs = @import("fonts/verdana.zig").glyphs;
const verdana_widths = @import("fonts/verdana.zig").widths;

// TTE color attribute indices: ink, shadow, paper, special effects
const TTE_INK: usize = 0;
const TTE_SHADOW: usize = 1;
const TTE_PAPER: usize = 2;
const TTE_SPECIAL: usize = 3;

/// Classic convenience initialiser targeting the global default context.
pub fn initSeDefault(bg_number: i32, bg_control: bg.Control) void {
    initSeCtx(&default_ctx, bg_number, bg_control, 0xF000, Color.yellow, 0, &sys_font, null);
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
// Minimal printf-style formatter (integer-only, like iprintf)
// ------------------------------------------------------------

/// Format the given `fmt` string with `std.fmt` and draw the result using the
/// currently active text backend (whatever was set up with `initSeDefault`,
/// `initChr4cDefault`, etc.). The implementation keeps a 256-byte stack buffer
/// so it brings in no allocator and mirrors libtonc’s lightweight `iprintf`.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined; // increase if you need longer lines
    const slice = std.fmt.bufPrint(&buf, fmt, args) catch return;
    write(slice);
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

    // The surface we are drawing to.
    surface: surface.Surface = .{},

    // Font currently in use.
    font: *const Font = &sys_font,

    // Cursor position in pixels (not tiles).
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,

    // Pointer to a backend-specific glyph renderer. If null, nothing is drawn.
    draw_glyph: ?*const fn (*TextContext, u8) void = null,

    // Color attributes for ink, shadow, paper, and special effects.
    cattr: [4]u16 = .{ 0, 0, 0, 0 },

    // Saved cursor position for Ps/Pr commands.
    saved_x: u16 = 0,
    saved_y: u16 = 0,
    // Margin rectangle for text rendering (defaults to full screen).
    margin_left: u16 = 0,
    margin_top: u16 = 0,
    margin_right: u16 = gba.screen_width,
    margin_bottom: u16 = gba.screen_height,
};

/// Global default context used by the classic convenience wrappers.
var default_ctx = TextContext{};

// ------------------------------------------------------------
// Internal state & helpers
// ------------------------------------------------------------

// (Former global state is now stored per-context.)

fn octup(val: u4) u32 {
    const v: u32 = val;
    return v * 0x11111111;
}

fn chr4Lmask(left: u16) u32 {
    return @as(u32, 0xFFFFFFFF) << @as(u5, @intCast((left & 7) * 4));
}

fn chr4Rmask(right: u16) u32 {
    // Equivalent to C's `(-right & 7)`
    return @as(u32, 0xFFFFFFFF) >> @as(u5, @intCast(((~right + 1) & 7) * 4));
}

fn chr4cColset(dstD: [*]volatile u32, left_rem: u16, right_rem: u16, height: u16, clr: u32) void {
    const mask = chr4Lmask(left_rem) & chr4Rmask(right_rem);
    const final_clr = clr & mask;
    var i: u16 = 0;
    while (i < height) : (i += 1) {
        dstD[i] = (dstD[i] & ~mask) | final_clr;
    }
}

fn newLineCtx(ctx: *TextContext) void {
    ctx.cursor_x = ctx.margin_left;
    // Advance by font height (not full cell) to avoid off-screen lines
    ctx.cursor_y += @intCast(ctx.font.char_h);
    if (ctx.cursor_y >= ctx.margin_bottom) {
        ctx.cursor_y = ctx.margin_top;
    }
}

// ---------------------------------------------------------------------------
// Erase helpers – clear the visible text area for the current backend
// ---------------------------------------------------------------------------

fn eraseScreenCtx(ctx: *TextContext) void {
    if (ctx.draw_glyph == &chr4cDrawGlyph) {
        const left = ctx.margin_left;
        const top = ctx.margin_top;
        const right = ctx.margin_right;
        const bottom = ctx.margin_bottom;

        if (left >= right or top >= bottom) return;

        const height = bottom - top;
        const clr = octup(@intCast(ctx.cattr[TTE_PAPER]));

        const srf = &ctx.surface;
        const base_addr = @intFromPtr(srf.data orelse return);
        const pitch_bytes = srf.pitch;

        const x_start_rem = left & 7;
        const x_end_rem = right & 7;

        var dst_addr = base_addr + (left / 8 * pitch_bytes);
        var dst_ptr: [*]volatile u32 = @ptrFromInt(dst_addr);

        if (((left / 8) * 8) == (((right - 1) / 8) * 8)) {
            chr4cColset(dst_ptr[top..], x_start_rem, x_end_rem, height, clr);
            return;
        }

        chr4cColset(dst_ptr[top..], x_start_rem, 8, height, clr);
        dst_addr += pitch_bytes;

        var ix = (left + 7) & 0xFFF8;
        while (ix < (right & 0xFFF8)) : (ix += 8) {
            dst_ptr = @ptrFromInt(dst_addr);
            chr4cColset(dst_ptr[top..], 0, 8, height, clr);
            dst_addr += pitch_bytes;
        }

        dst_ptr = @ptrFromInt(dst_addr);
        chr4cColset(dst_ptr[top..], 0, x_end_rem, height, clr);
    } else {
        // se backend – reset tile map entries to blank glyph
        const map_block = &bg.screen_block_ram[ctx.screen_block];
        var ei: usize = 0;
        while (ei < 1024) : (ei += 1) {
            map_block.*[ei] = .{
                .tile_index = @intCast(ctx.tile_start),
                .flip = .{},
                .palette_index = ctx.palette_bank,
            };
        }
    }

    // Reset cursor to origin after erase, consistent with TONC behaviour.
    ctx.cursor_x = ctx.margin_left;
    ctx.cursor_y = ctx.margin_top;
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
    // code is expected to start with "#{" and end with '}', but the slice
    // we receive already includes both. We begin parsing after the "#{".
    // Extract inner portion without the leading "#{" and trailing "}".
    if (code.len < 4) return; // needs at least "#{x}"

    const inner = code[2 .. code.len - 1];

    var start: usize = 0;
    while (start < inner.len) {
        // find ';' separator to isolate a single token
        var end: usize = start;
        while (end < inner.len and inner[end] != ';') : (end += 1) {}

        const tok = inner[start..end];

        if (tok.len > 0) {
            const cmd = tok[0];
            switch (cmd) {
                // Absolute/relative positioning handles
                'P' => {
                    if (tok.len == 1) {
                        // #{P} – go to margin top-left (0,0 for now)
                        ctx.cursor_x = ctx.margin_left;
                        ctx.cursor_y = ctx.margin_top;
                    } else if (tok.len >= 2 and tok[1] == 's') {
                        // #{Ps} – save current position
                        ctx.saved_x = ctx.cursor_x;
                        ctx.saved_y = ctx.cursor_y;
                    } else if (tok.len >= 2 and tok[1] == 'r') {
                        // #{Pr} – restore position
                        ctx.cursor_x = ctx.saved_x;
                        ctx.cursor_y = ctx.saved_y;
                    } else if (tok.len >= 2 and tok[1] == ':') {
                        // #{P:x,y}
                        var idx: usize = 2;
                        var x_val: u32 = 0;
                        while (idx < tok.len and std.ascii.isDigit(tok[idx])) : (idx += 1) {
                            x_val = x_val * 10 + (tok[idx] - '0');
                        }
                        ctx.cursor_x = @intCast(x_val);

                        if (idx < tok.len and tok[idx] == ',') {
                            idx += 1;
                            var y_val: u32 = 0;
                            while (idx < tok.len and std.ascii.isDigit(tok[idx])) : (idx += 1) {
                                y_val = y_val * 10 + (tok[idx] - '0');
                            }
                            ctx.cursor_y = @intCast(y_val);
                        }
                    }
                },
                'X' => {
                    if (tok.len == 1) {
                        ctx.cursor_x = ctx.margin_left;
                    } else if (tok[1] == ':') {
                        const val = parseUnsigned(tok[2..]);
                        ctx.cursor_x = @intCast(val);
                    }
                },
                'Y' => {
                    if (tok.len == 1) {
                        ctx.cursor_y = ctx.margin_top;
                    } else if (tok[1] == ':') {
                        const val = parseUnsigned(tok[2..]);
                        ctx.cursor_y = @intCast(val);
                    }
                },
                'x' => {
                    if (tok.len >= 2 and tok[1] == ':') {
                        const delta = parseSigned(tok[2..]);
                        var new_x: i32 = @as(i32, ctx.cursor_x);
                        new_x += delta;
                        if (new_x < 0) new_x = 0;
                        ctx.cursor_x = @intCast(new_x);
                    }
                },
                'y' => {
                    if (tok.len >= 2 and tok[1] == ':') {
                        const delta = parseSigned(tok[2..]);
                        var new_y: i32 = @as(i32, ctx.cursor_y);
                        new_y += delta;
                        if (new_y < 0) new_y = 0;
                        ctx.cursor_y = @intCast(new_y);
                    }
                },
                'p' => {
                    if (tok.len >= 2 and tok[1] == ':') {
                        var idx: usize = 2;
                        const dx = parseSignedAdvance(tok, &idx);
                        var new_x: i32 = @as(i32, ctx.cursor_x) + dx;
                        if (idx < tok.len and tok[idx] == ',') {
                            idx += 1;
                            const dy = parseSignedAdvance(tok, &idx);
                            var new_y: i32 = @as(i32, ctx.cursor_y) + dy;
                            if (new_y < 0) new_y = 0;
                            ctx.cursor_y = @intCast(new_y);
                        }
                        if (new_x < 0) new_x = 0;
                        ctx.cursor_x = @intCast(new_x);
                    }
                },
                'e' => {
                    // Erase commands. Only implement "es" (erase screen) for now.
                    if (std.mem.eql(u8, tok, "es")) {
                        eraseScreenCtx(ctx);
                    }
                },
                else => {},
            }
        }

        // Advance to next token (skip ';' if present)
        start = if (end < inner.len) end + 1 else inner.len;
    }
}

// ------------------------------------------------------------
// Small helpers for parsing integers within control tokens
// ------------------------------------------------------------

inline fn parseUnsigned(slice: []const u8) u32 {
    var val: u32 = 0;
    for (slice) |c| {
        if (!std.ascii.isDigit(c)) break;
        val = val * 10 + (c - '0');
    }
    return val;
}

inline fn parseSigned(slice: []const u8) i32 {
    var idx: usize = 0;
    return parseSignedAdvance(slice, &idx);
}

inline fn parseSignedAdvance(slice: []const u8, idx_ptr: *usize) i32 {
    var idx: usize = idx_ptr.*;
    var negative = false;
    if (idx < slice.len and slice[idx] == '-') {
        negative = true;
        idx += 1;
    }
    var val: i32 = 0;
    while (idx < slice.len and std.ascii.isDigit(slice[idx])) : (idx += 1) {
        val = val * 10 + @as(i32, slice[idx] - '0');
    }
    if (negative) val = -val;
    idx_ptr.* = idx;
    return val;
}
// ------------------------------------------------------------
// Embedded sys font glyphs (96 glyphs * 2 u32 each = 192 u32)
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
    /// doing variable-width rendering, but for sys they’re both 8).
    cell_w: u8,
    cell_h: u8,

    /// Size of one glyph cell in bytes (`cell_w * cell_h * bpp / 8`).
    cell_size: u16,

    /// Bit-depth of the encoded font data (1 for sys).
    bpp: u8,
    /// Free byte for future use / alignment (mirrors TONC’s `extra`).
    extra: u8,
};

/// Constant describing the built-in 1-bpp sys font that ships with TONC.
pub const sys_font: Font = .{
    .data = &sys_glyphs,
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

pub const verdana_font: Font = .{
    .data = &verdana_glyphs,
    .widths = &verdana_widths,
    .heights = null,
    .char_offset = 32,
    .char_count = 224,
    .char_w = 8,
    .char_h = 12,
    .cell_w = 8,
    .cell_h = 16,
    .cell_size = 64,
    .bpp = 4,
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
    // Select font (default to sys if null).
    const f_ptr: *const Font = if (font) |p| p else &sys_font;

    // Decode screen-entry parameters: tile start index and palette bank.
    const tile_start: u32 = se0 & 0x03FF;
    const palette_bank: u4 = @intCast((se0 >> 12) & 0xF);
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
    ctx.cursor_x = ctx.margin_left;
    ctx.cursor_y = ctx.margin_top;
}

// Using BIOS SWI for bit-unpacking is more reliable for correct bit orders;
// manual conversion pipeline is removed until we get the core path working.

// ---------------------------------------------------------------------------
// Helper: Plot a 4bpp pixel on a column-major tiled surface (chr4c backend)
// ---------------------------------------------------------------------------
fn setPixelChr4c(ctx: *const TextContext, x: u16, y: u16, color: u4) void {
    // This function's logic is a direct port of the chr4c_plot function
    // from libtonc's tonc_schr4c.c, which treats VRAM as a series of
    // vertical strips.
    const srf = &ctx.surface;
    const base: *anyopaque = srf.data orelse return;
    const pitch = srf.pitch;

    const addr: usize = @intFromPtr(base) + (y * 4) + (x / 8 * pitch);
    const ptr: *volatile u32 = @ptrFromInt(addr);

    const shift = (x % 8) * 4;
    const mask = @as(u32, 0xF) << @as(u5, @intCast(shift));

    ptr.* = (ptr.* & ~mask) | (@as(u32, color) << @as(u5, @intCast(shift)));
}

// ---------------------------------------------------------------------------
// chr4c glyph renderer (4-bpp → 4-bpp column-major tiles) with color attributes
// ---------------------------------------------------------------------------
fn chr4cDrawGlyph(ctx: *TextContext, ascii: u8) void {
    // Only ASCII range and valid glyphs
    if (ascii < @as(u8, @intCast(ctx.font.char_offset)) or ascii >= @as(u8, @intCast(ctx.font.char_offset)) + ctx.font.char_count) return;
    const gid = @as(usize, ascii) - @as(usize, ctx.font.char_offset);

    const font = ctx.font.*;
    // Variable-width/height support
    const charW = if (font.widths) |w| @as(usize, w[gid]) else @as(usize, font.char_w);
    const charH = if (font.heights) |h| @as(usize, h[gid]) else @as(usize, font.char_h);

    // Source glyph data (4bpp packed nibble strips)
    const raw_data: [*]const u32 = @ptrCast(@alignCast(font.data));
    const srcP = @as(usize, font.cell_h);
    var srcD = raw_data + gid * srcP;

    const srf = &ctx.surface;
    const base_addr = @intFromPtr(srf.data orelse return);
    const dstP = @as(usize, srf.pitch) / 4;

    const x0 = @as(usize, ctx.cursor_x);
    const y0 = @as(usize, ctx.cursor_y);
    const x_rem = x0 % 8;
    const lsl: u5 = @intCast(4 * x_rem);
    const lsr: u5 = @intCast(32 - 4 * x_rem);
    const right = @as(u32, x_rem + charW);

    const dst_addr = base_addr + y0 * 4 + (x0 / 8) * dstP * 4;
    var dstD: [*]volatile u32 = @ptrFromInt(dst_addr);
    var dstL: [*]volatile u32 = undefined;

    const amask: u32 = 0x1111_1111;
    const ink_idx = @as(u32, ctx.cattr[TTE_INK]);
    const shade_idx = @as(u32, ctx.cattr[TTE_SHADOW]);

    var iw: usize = 0;
    while (iw < charW) : (iw += 8) {
        dstL = dstD;
        dstD = @ptrFromInt(@intFromPtr(dstD) + dstP * 4);
        var srcL = srcD;
        srcD = srcD + @as(usize, srcP);

        var iy: usize = charH;
        while (iy > 0) : (iy -= 1) {
        var raw = srcL[0];
            srcL += 1;
            var px = raw & amask;
            raw = (raw >> 1) & amask;
            var pxmask = px | raw;
            if (pxmask != 0) {
                px = px * ink_idx;
                px += raw * shade_idx;
                pxmask *= 15;

                // Write left tile portion
                dstL[0] = (dstL[0] & ~(pxmask << lsl)) | (px << lsl);
                // Write right tile if glyph spills over
                if (right > 8) {
                    dstL[dstP] = (dstL[dstP] & ~(pxmask >> lsr)) | (px >> lsr);
                }
            }
            dstL += 1;
        }
    }

    // Advance cursor by glyph width
    ctx.cursor_x += @intCast(charW);
}

// ---------------------------------------------------------------------------
// chr4c backend initialization
// ---------------------------------------------------------------------------
fn initChr4cCtx(
    ctx: *TextContext,
    bg_number: i32,
    bg_control: bg.Control,
    se0: u32,
    ink_color: Color,
    shadow_color: Color,
    paper_color: Color,
    bupofs: u32,
    font: ?*const Font,
    proc: ?*const fn (*TextContext, u8) void,
) void {
    _ = bupofs; // Unused for now.

    const f_ptr: *const Font = if (font) |p| p else &verdana_font;

    // Decode screen-entry parameters.
    const tile_start: u32 = se0 & 0x03FF;
    const palette_bank: u4 = @intCast((se0 >> 12) & 0xF);

    ctx.font = f_ptr;
    ctx.char_block = bg_control.tile_base_block;
    ctx.screen_block = bg_control.screen_base_block;
    ctx.tile_start = tile_start;
    ctx.palette_bank = palette_bank;
    ctx.draw_glyph = if (proc) |p| p else &chr4cDrawGlyph;

    // Initialize the surface for this context.
    const data_ptr: *anyopaque = @volatileCast(&bg.tile_ram[bg_control.tile_base_block][0]);
    const pal_ptr: [*]u16 = @ptrCast(&bg.palette.banks[palette_bank]);
    ctx.surface.init(.chr4c, data_ptr, gba.screen_width, gba.screen_height, 4, pal_ptr);

    // Apply BG control register.
    var final_bg_control = bg_control;
    final_bg_control.tile_map_size.normal = .@"32x32";
    bg.ctrl[@intCast(bg_number)] = final_bg_control;

    // Prepare AGB palette entries and TTE color attributes.
    ctx.cattr[TTE_PAPER] = @as(u16, 0);
    ctx.cattr[TTE_INK] = @as(u16, 1);
    ctx.cattr[TTE_SHADOW] = @as(u16, 2);
    ctx.cattr[TTE_SPECIAL] = @as(u16, 0);
    const pal = &bg.palette.banks[palette_bank];
    pal[ctx.cattr[TTE_PAPER]] = paper_color;
    pal[ctx.cattr[TTE_INK]] = ink_color;
    pal[ctx.cattr[TTE_SHADOW]] = shadow_color;

    // Prepare tile map (column-major layout) only for the visible 30×20 area.
    const map_block = &bg.screen_block_ram[bg_control.screen_base_block];
    const width_tiles: usize = gba.screen_width / 8; // 240px → 30 tiles (X axis)
    const height_tiles: usize = gba.screen_height / 8; // 160px → 20 tiles (Y axis)

    // For a 240x160 screen, the vertical stride between tile columns is 20 tiles.
    const stride_tiles: usize = 20;

    var iy: usize = 0;
    while (iy < height_tiles) : (iy += 1) {
        var ix: usize = 0;
        while (ix < width_tiles) : (ix += 1) {
            const entry_index: usize = iy * 32 + ix; // screen-block row-major index (row stride 32)
            map_block.*[entry_index] = .{
                .tile_index = @intCast(tile_start + ix * stride_tiles + iy), // column-major tile index
                .flip = .{},
                .palette_index = palette_bank,
            };
        }
    }

    // This mode emulates a bitmap, so we only set up the tile map to create a
    // linear address space. We do not pre-load font glyphs or clear tile
    // memory here; that is handled by the glyph renderer on-the-fly.

    // Reset cursor.
    ctx.cursor_x = ctx.margin_left;
    ctx.cursor_y = ctx.margin_top;
}

/// Classic convenience initialiser for chr4c backend targeting the global default context.
pub fn initChr4cDefault(bg_number: i32, bg_control: bg.Control) void {
    // Use palette bank 15, tile_start 0.
    // Use palette bank 15, tile_start 0, yellow ink, orange shadow, black paper.
    initChr4cCtx(
        &default_ctx,
        bg_number,
        bg_control,
        0xF000,
        Color.yellow,
        Color.rgb(31, 16, 0),
        Color.black,
        0,
        &verdana_font,
        null,
    );
}

// ------------------------------------------------------------
// Margin management helpers (tte_set_margins equivalent)
// ------------------------------------------------------------

pub fn setMarginsCtx(ctx: *TextContext, left: u16, top: u16, right: u16, bottom: u16) void {
    ctx.margin_left = left;
    ctx.margin_top = top;
    ctx.margin_right = right;
    ctx.margin_bottom = bottom;
    ctx.cursor_x = left;
    ctx.cursor_y = top;
}

/// Convenience wrapper that sets margins on the global default context.
pub fn setMargins(left: u16, top: u16, right: u16, bottom: u16) void {
    setMarginsCtx(&default_ctx, left, top, right, bottom);
}
