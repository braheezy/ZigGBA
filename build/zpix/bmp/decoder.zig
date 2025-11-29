const std = @import("std");
const image = @import("../image/root.zig");
const color = @import("../color/root.zig");

pub const Decoder = @This();

// Memory allocator
allocator: std.mem.Allocator,
// Reader for BMP data
r: *std.Io.Reader,

// Parsed config
width: u32 = 0,
height: u32 = 0,
top_down: bool = false,
bits_per_pixel: u16 = 0,
allow_alpha: bool = false,
palette: ?color.Palette = null,

const file_header_len: usize = 14;
const info_header_len: usize = 40;
const v4_info_header_len: usize = 108;
const v5_info_header_len: usize = 124;

pub fn decode(allocator: std.mem.Allocator, r: *std.Io.Reader) !image.Image {
    var d = Decoder{
        .allocator = allocator,
        .r = r,
    };

    var offset: u32 = 0;
    try d.readHeader(&offset);

    switch (d.bits_per_pixel) {
        1, 2, 4, 8 => return try d.decodePaletted(),
        24 => return try d.decodeRGB(),
        32 => return try d.decodeNRGBA(),
        else => return error.UnsupportedBPP,
    }
}

fn readHeader(self: *Decoder, out_offset: *u32) !void {
    // Use a scratch buffer like the Go impl
    var b: [1024]u8 = undefined;

    // Read file header prefix: 14 (file) + 4 (first 4 bytes of info header)
    try self.r.readSliceAll(b[0 .. file_header_len + 4]);
    if (!(b[0] == 'B' and b[1] == 'M')) {
        return error.InvalidSignature;
    }

    const pixel_data_offset = readU32LE(b[10..14]);
    const info_len = readU32LE(b[14..18]);
    if (info_len != info_header_len and info_len != v4_info_header_len and info_len != v5_info_header_len) {
        return error.UnsupportedHeader;
    }

    // Read remaining info header bytes
    try self.r.readSliceAll(b[file_header_len + 4 .. file_header_len + info_len]);

    const width_i32 = @as(i32, @bitCast(readU32LE(b[18..22])));
    const height_i32 = @as(i32, @bitCast(readU32LE(b[22..26])));
    var height_abs = height_i32;
    var top_down = false;
    if (height_abs < 0) {
        height_abs = -height_abs;
        top_down = true;
    }
    if (width_i32 < 0 or height_abs < 0) {
        return error.UnsupportedDimensions;
    }

    const planes = readU16LE(b[26..28]);
    const bpp = readU16LE(b[28..30]);
    var compression = readU32LE(b[30..34]);

    // If BI_BITFIELDS with default masks and header >= V4, treat as BI_RGB (no compression)
    if (compression == 3 and info_len > info_header_len) {
        const red_mask = readU32LE(b[54..58]);
        const green_mask = readU32LE(b[58..62]);
        const blue_mask = readU32LE(b[62..66]);
        const alpha_mask = readU32LE(b[66..70]);
        if (red_mask == 0xff0000 and green_mask == 0x00ff00 and blue_mask == 0x0000ff and alpha_mask == 0xff000000) {
            compression = 0;
        }
    }

    if (planes != 1 or compression != 0) {
        return error.UnsupportedCompression;
    }

    self.width = @intCast(width_i32);
    self.height = @intCast(height_abs);
    self.top_down = top_down;
    self.bits_per_pixel = bpp;
    self.allow_alpha = info_len > info_header_len; // allow alpha only for V4/V5

    // Handle palette if needed
    switch (bpp) {
        1, 2, 4, 8 => {
            var color_used = readU32LE(b[46..50]);
            if (color_used == 0) {
                color_used = @as(u32, 1) << @intCast(bpp);
            } else if (color_used > (@as(u32, 1) << @intCast(bpp))) {
                return error.UnsupportedPaletteSize;
            }

            if (pixel_data_offset != file_header_len + info_len + color_used * 4) {
                return error.UnsupportedColorOffset;
            }

            // Read palette entries: BGRA (A is padding), convert to RGBA with A=0xFF
            // We will read directly into a temporary buffer in chunks
            var pal = try self.allocator.alloc(color.Color, color_used);
            errdefer self.allocator.free(pal);

            // We'll read color_used*4 bytes
            const to_read: usize = @intCast(color_used * 4);
            var read_total: usize = 0;
            while (read_total < to_read) {
                var chunk = @min(to_read - read_total, b.len);
                // Ensure we process complete palette entries (4 bytes each)
                if (chunk > 4) {
                    chunk -= chunk % 4;
                }
                try self.r.readSliceAll(b[0..chunk]);
                // process this chunk in 4-byte steps
                var i: usize = 0;
                while (i < chunk) : (i += 4) {
                    const idx = (read_total + i) / 4;
                    if (idx >= pal.len) break; // safety for final partial chunk
                    // BMP: B,G,R,Pad
                    pal[idx] = .{ .rgba = .{
                        .r = b[i + 2],
                        .g = b[i + 1],
                        .b = b[i + 0],
                        .a = 0xFF,
                    } };
                }
                read_total += chunk;
            }
            self.palette = pal;
        },
        24 => {
            if (pixel_data_offset != file_header_len + info_len) {
                return error.UnsupportedColorOffset;
            }
        },
        32 => {
            if (pixel_data_offset != file_header_len + info_len) {
                return error.UnsupportedColorOffset;
            }
        },
        else => return error.UnsupportedBPP,
    }

    out_offset.* = pixel_data_offset;
}

fn decodePaletted(self: *Decoder) !image.Image {
    const width = self.width;
    const height = self.height;
    if (width == 0 or height == 0) {
        // Create empty image with palette
        const img = try image.PalettedImage.init(self.allocator, image.Rectangle.init(0, 0, 0, 0), self.palette.?);
        // PalettedImage.init duplicates the palette; free the temporary one we allocated.
        if (self.palette) |pal| {
            self.allocator.free(pal);
            self.palette = null;
        }
        return .{ .Paletted = img };
    }

    var paletted = try image.PalettedImage.init(self.allocator, image.Rectangle.init(0, 0, @intCast(width), @intCast(height)), self.palette.?);

    const bpp: u16 = self.bits_per_pixel;
    const pixels_per_byte: usize = 8 / bpp;
    // Rows are 4-byte aligned
    const bytes_per_row_unaligned: usize = (width + pixels_per_byte - 1) / pixels_per_byte;
    const bytes_per_row: usize = (bytes_per_row_unaligned + 3) & ~@as(usize, 3);
    const rowbuf = try self.allocator.alloc(u8, bytes_per_row);
    defer self.allocator.free(rowbuf);

    const mask: u8 = switch (bpp) {
        1 => 0x01,
        2 => 0x03,
        4 => 0x0F,
        8 => 0xFF,
        else => 0xFF,
    };

    var y0: i32 = @intCast(height - 1);
    var y1: i32 = -1;
    var y_delta: i32 = -1;
    if (self.top_down) {
        y0 = 0;
        y1 = @intCast(height);
        y_delta = 1;
    }

    var y: i32 = y0;
    while (y != y1) : (y += y_delta) {
        try self.r.readSliceAll(rowbuf);
        const stride: usize = paletted.stride;
        var p = paletted.pixels[@as(usize, @intCast(y)) * stride ..];
        // We only care about the first 'width' pixels
        p = p[0..@intCast(width)];

        var byte_index: usize = 0;
        var bit_index: i32 = 8;
        var pix_index: usize = 0;
        while (pix_index < width) : (pix_index += 1) {
            bit_index -= @intCast(bpp);
            const val: u8 = (rowbuf[byte_index] >> @intCast(bit_index)) & mask;
            p[pix_index] = val;
            if (bit_index == 0) {
                byte_index += 1;
                bit_index = 8;
            }
        }
    }

    // PalettedImage.init duplicates the palette; free the temporary one we allocated.
    if (self.palette) |pal| {
        self.allocator.free(pal);
        self.palette = null;
    }
    return .{ .Paletted = paletted };
}

fn decodeRGB(self: *Decoder) !image.Image {
    const width = self.width;
    const height = self.height;
    var rgba = try image.RGBAImage.init(self.allocator, image.Rectangle.init(0, 0, @intCast(width), @intCast(height)));
    if (width == 0 or height == 0) {
        return .{ .RGBA = rgba };
    }

    // 3 bytes per pixel, rows aligned to 4 bytes
    const rowbuf = try self.allocator.alloc(u8, (@as(usize, 3) * width + 3) & ~@as(usize, 3));
    defer self.allocator.free(rowbuf);

    var y0: i32 = @intCast(height - 1);
    var y1: i32 = -1;
    var y_delta: i32 = -1;
    if (self.top_down) {
        y0 = 0;
        y1 = @intCast(height);
        y_delta = 1;
    }

    var y: i32 = y0;
    while (y != y1) : (y += y_delta) {
        try self.r.readSliceAll(rowbuf);
        var p = rgba.pixels[@as(usize, @intCast(y)) * rgba.stride ..][0 .. width * 4];
        var i: usize = 0;
        var j: usize = 0;
        while (i < p.len) : ({
            i += 4;
            j += 3;
        }) {
            p[i + 0] = rowbuf[j + 2]; // R
            p[i + 1] = rowbuf[j + 1]; // G
            p[i + 2] = rowbuf[j + 0]; // B
            p[i + 3] = 0xFF; // A
        }
    }

    return .{ .RGBA = rgba };
}

fn decodeNRGBA(self: *Decoder) !image.Image {
    const width = self.width;
    const height = self.height;
    var nrgba = try image.NRGBAImage.init(self.allocator, image.Rectangle.init(0, 0, @intCast(width), @intCast(height)));
    if (width == 0 or height == 0) {
        return .{ .NRGBA = nrgba };
    }

    var y0: i32 = @intCast(height - 1);
    var y1: i32 = -1;
    var y_delta: i32 = -1;
    if (self.top_down) {
        y0 = 0;
        y1 = @intCast(height);
        y_delta = 1;
    }

    var y: i32 = y0;
    while (y != y1) : (y += y_delta) {
        var p = nrgba.pixels[@as(usize, @intCast(y)) * nrgba.stride ..][0 .. width * 4];
        try self.r.readSliceAll(p);
        var idx: usize = 0;
        while (idx < p.len) : (idx += 4) {
            // Swap B and R (BGRA -> RGBA)
            const r = p[idx + 2];
            const b = p[idx + 0];
            p[idx + 0] = r;
            p[idx + 2] = b;
            if (!self.allow_alpha) {
                p[idx + 3] = 0xFF;
            }
        }
    }

    return .{ .NRGBA = nrgba };
}

inline fn readU16LE(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}

inline fn readU32LE(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

pub const Error = error{
    InvalidSignature,
    UnsupportedHeader,
    UnsupportedDimensions,
    UnsupportedCompression,
    UnsupportedBPP,
    UnsupportedPaletteSize,
    UnsupportedColorOffset,
};
