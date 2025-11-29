const std = @import("std");
const color = @import("color");
const RGBA = color.RGBA;

// Constants from the QOI specification
const QOI_MAGIC = 0x716F6966;
const QOI_OP_INDEX = 0x00;
const QOI_OP_DIFF = 0x40;
const QOI_OP_LUMA = 0x80;
const QOI_OP_RUN = 0xc0;
const QOI_OP_RGB = 0xfe;
const QOI_OP_RGBA = 0xff;
const QOI_MASK_2 = 0xc0;
const QOI_HEADER_SIZE = 14;
const QOI_PADDING_SIZE = 8;
const QOI_PIXELS_MAX = 400_000_000;
const QOI_PADDING = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };

/// The parameters describing the image to encode in QOI format.
pub const Desc = struct {
    width: u32,
    height: u32,
    channels: u8, // 3 = RGB, 4 = RGBA
    colorspace: u8, // 0 = sRGB with linear alpha, 1 = all channels linear
};

/// Encode an RGB(A) pixel buffer into QOI format with the given descriptor.
/// Returns a buffer containing the encoded QOI data.
pub fn encode(
    allocator: std.mem.Allocator,
    pixels: []const u8,
    desc: Desc,
) ![]u8 {
    if (desc.width == 0 or desc.height == 0 or (desc.channels < 3 or desc.channels > 4) or desc.colorspace > 1 or desc.height >= QOI_PIXELS_MAX / desc.width) {
        return error.InvalidQoiHeader;
    }

    const pixelCount = @as(usize, desc.width) * @as(usize, desc.height);
    const pxLen = pixelCount * @as(usize, desc.channels);

    const maxSize =
        @as(usize, desc.width) * @as(usize, desc.height) * @as(usize, desc.channels + 1) + QOI_HEADER_SIZE + QOI_PADDING_SIZE;

    var list = std.ArrayListUnmanaged(u8){};
    defer list.deinit(allocator);
    try list.ensureTotalCapacity(allocator, maxSize);

    // Write header
    var header: [QOI_HEADER_SIZE]u8 = undefined;
    var hp: usize = 0;
    writeBE32(header[hp..], QOI_MAGIC);
    hp += 4;
    writeBE32(header[hp..], desc.width);
    hp += 4;
    writeBE32(header[hp..], desc.height);
    hp += 4;
    header[hp] = desc.channels;
    hp += 1;
    header[hp] = desc.colorspace;
    hp += 1;
    try list.appendSlice(allocator, header[0..hp]);

    // Initialize the QOI index array to zeroed RGBA slots.
    var index: [64]RGBA = std.mem.zeroes([64]RGBA);
    var px_prev: RGBA = .{ .a = 255 };
    var run: u32 = 0;
    var px: RGBA = px_prev;

    var pxi: usize = 0;
    while (pxi < pxLen) : (pxi += @as(usize, desc.channels)) {
        px.r = pixels[pxi + 0];
        px.g = pixels[pxi + 1];
        px.b = pixels[pxi + 2];
        if (desc.channels == 4) px.a = pixels[pxi + 3];

        if (px.r == px_prev.r and px.g == px_prev.g and px.b == px_prev.b and px.a == px_prev.a) {
            run += 1;
            if (run == 62 or pxi + desc.channels == pxLen) {
                const run_minus: u8 = @truncate(run - 1);
                try list.append(allocator, QOI_OP_RUN | run_minus);
                run = 0;
            }
        } else {
            if (run > 0) {
                const run_minus: u8 = @truncate(run - 1);
                try list.append(allocator, QOI_OP_RUN | run_minus);
                run = 0;
            }

            const idx = indexPos(px);
            if (index[idx].r == px.r and index[idx].g == px.g and index[idx].b == px.b and index[idx].a == px.a) {
                const idx_u: u8 = @bitCast(@as(u8, @intCast(idx)));
                try list.append(allocator, QOI_OP_INDEX | idx_u);
            } else {
                index[idx] = px;
                if (px.a == px_prev.a) {
                    const vr = @as(i16, @intCast(px.r)) - @as(i16, @intCast(px_prev.r));
                    const vg = @as(i16, @intCast(px.g)) - @as(i16, @intCast(px_prev.g));
                    const vb = @as(i16, @intCast(px.b)) - @as(i16, @intCast(px_prev.b));
                    const vg_r = vr - vg;
                    const vg_b = vb - vg;
                    if (vr > -3 and vr < 2 and vg > -3 and vg < 2 and vb > -3 and vb < 2) {
                        try list.append(allocator, QOI_OP_DIFF |
                            @as(u8, @intCast(((vr + 2) << 4) | ((vg + 2) << 2) | (vb + 2))));
                    } else if (vg_r > -9 and vg_r < 8 and vg > -33 and vg < 32 and vg_b > -9 and vg_b < 8) {
                        try list.append(allocator, QOI_OP_LUMA | @as(u8, @intCast(vg + 32)));
                        try list.append(allocator, @as(u8, @intCast(((vg_r + 8) << 4) | (vg_b + 8))));
                    } else {
                        try list.append(allocator, QOI_OP_RGB);
                        try list.append(allocator, px.r);
                        try list.append(allocator, px.g);
                        try list.append(allocator, px.b);
                    }
                } else {
                    try list.append(allocator, QOI_OP_RGBA);
                    try list.append(allocator, px.r);
                    try list.append(allocator, px.g);
                    try list.append(allocator, px.b);
                    try list.append(allocator, px.a);
                }
            }
        }
        px_prev = px;
    }

    // End marker
    for (QOI_PADDING) |b| {
        try list.append(allocator, b);
    }

    return list.toOwnedSlice(allocator);
}

fn writeBE32(buf: []u8, v: u32) void {
    const b0: u8 = @truncate(v >> 24);
    const b1: u8 = @truncate(v >> 16);
    const b2: u8 = @truncate(v >> 8);
    const b3: u8 = @truncate(v);
    buf[0] = b0;
    buf[1] = b1;
    buf[2] = b2;
    buf[3] = b3;
}

fn indexPos(c: RGBA) usize {
    return (@as(usize, c.r) * 3 + @as(usize, c.g) * 5 + @as(usize, c.b) * 7 + @as(usize, c.a) * 11) & 63;
}

comptime {
    _ = std.testing.refAllDecls(@This());
}
