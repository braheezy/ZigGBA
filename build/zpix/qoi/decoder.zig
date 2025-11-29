const std = @import("std");
const image = @import("../image/root.zig");
const color = @import("../color/root.zig");
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

/// Decode a QOI image from a reader.
pub fn decode(allocator: std.mem.Allocator, r: *std.Io.Reader) !image.Image {
    var buf_list = std.ArrayListUnmanaged(u8){};
    defer buf_list.deinit(allocator);
    const max_bytes = comptime @as(usize, QOI_HEADER_SIZE + QOI_PADDING_SIZE + QOI_PIXELS_MAX * 4);
    try r.appendRemaining(allocator, &buf_list, @enumFromInt(max_bytes));
    return decodeFromBuffer(allocator, buf_list.items);
}

fn decodeFromBuffer(allocator: std.mem.Allocator, data: []const u8) !image.Image {
    if (data.len < QOI_HEADER_SIZE + QOI_PADDING_SIZE) {
        return error.InvalidQoiData;
    }

    var p: usize = 0;
    const magic = readBE32(data, &p);
    if (magic != QOI_MAGIC) {
        return error.InvalidQoiHeader;
    }

    const width = readBE32(data, &p);
    const height = readBE32(data, &p);
    const channels = data[p];
    p += 1;
    const colorspace = data[p];
    p += 1;

    if (width == 0 or height == 0 or (channels != 3 and channels != 4) or colorspace > 1 or
        height >= QOI_PIXELS_MAX / width)
    {
        return error.InvalidQoiHeader;
    }

    const pixelCount = @as(usize, width) * @as(usize, height);
    const chunks_len = data.len - QOI_PADDING_SIZE;

    const rect = image.Rectangle.init(0, 0, @intCast(width), @intCast(height));
    const img = try image.RGBAImage.init(allocator, rect);
    var out = img.pixels;

    // Initialize the QOI index array to zeroed RGBA slots.
    var index: [64]RGBA = std.mem.zeroes([64]RGBA);
    var run: usize = 0;
    var px: RGBA = .{ .a = 255 };

    var i: usize = 0;
    while (i < pixelCount) : (i += 1) {
        if (run > 0) {
            run -= 1;
        } else if (p < chunks_len) {
            const b1 = data[p];
            p += 1;
            if (b1 == QOI_OP_RGB) {
                px.r = data[p];
                px.g = data[p + 1];
                px.b = data[p + 2];
                p += 3;
            } else if (b1 == QOI_OP_RGBA) {
                px.r = data[p];
                px.g = data[p + 1];
                px.b = data[p + 2];
                px.a = data[p + 3];
                p += 4;
            } else {
                const tag = b1 & QOI_MASK_2;
                if (tag == QOI_OP_INDEX) {
                    px = index[b1 & 0x3f];
                } else if (tag == QOI_OP_DIFF) {
                    // Small diff encoding: each channel delta stored in 2 bits, biased by 2.
                    const dr_u: u8 = (b1 >> 4) & 0x3;
                    const dg_u: u8 = (b1 >> 2) & 0x3;
                    const db_u: u8 = b1 & 0x3;
                    const dr_i: i8 = @bitCast(dr_u);
                    const dr: i8 = dr_i - 2;
                    const dg_i: i8 = @bitCast(dg_u);
                    const dg: i8 = dg_i - 2;
                    const db_i: i8 = @bitCast(db_u);
                    const db: i8 = db_i - 2;
                    px.r = @intCast(@as(i16, @intCast(px.r)) + dr);
                    px.g = @intCast(@as(i16, px.g) + dg);
                    px.b = @intCast(@as(i16, px.b) + db);
                } else if (tag == QOI_OP_LUMA) {
                    const b2 = data[p];
                    p += 1;
                    const dg_u: u8 = b1 & 0x3f;
                    const dr_dg_u: u8 = (b2 >> 4) & 0xf;
                    const db_dg_u: u8 = b2 & 0xf;
                    const dg_i: i8 = @bitCast(dg_u);
                    const dg: i8 = dg_i - 32;
                    const dr_dg_i: i8 = @bitCast(dr_dg_u);
                    const dr_dg: i8 = dr_dg_i - 8;
                    const db_dg_i: i8 = @bitCast(db_dg_u);
                    const db_dg: i8 = db_dg_i - 8;
                    px.r = @intCast(@as(i16, px.r) + dg + dr_dg);
                    px.g = @intCast(@as(i16, px.g) + dg);
                    px.b = @intCast(@as(i16, px.b) + dg + db_dg);
                } else {
                    run = @as(usize, b1 & 0x3f);
                }
            }
            index[indexPos(px)] = px;
        }

        const base = i * 4;
        out[base + 0] = px.r;
        out[base + 1] = px.g;
        out[base + 2] = px.b;
        out[base + 3] = px.a;
    }

    return .{ .RGBA = img };
}

fn readBE32(data: []const u8, p: *usize) u32 {
    const b0 = data[p.*];
    const b1 = data[p.* + 1];
    const b2 = data[p.* + 2];
    const b3 = data[p.* + 3];
    p.* += 4;
    return (@as(u32, b0) << 24) | (@as(u32, b1) << 16) | (@as(u32, b2) << 8) | @as(u32, b3);
}

fn indexPos(c: RGBA) usize {
    return (@as(usize, c.r) * 3 + @as(usize, c.g) * 5 + @as(usize, c.b) * 7 + @as(usize, c.a) * 11) & 63;
}

comptime {
    _ = std.testing.refAllDecls(@This());
}
