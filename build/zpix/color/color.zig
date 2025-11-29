pub const Gray = struct { y: u8 = 0 };
pub const Gray16 = struct { y: u16 = 0 };
pub const RGB = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0 };
pub const RGBA = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };
pub const NRGBA = struct { r: u8 = 0, g: u8 = 0, b: u8 = 0, a: u8 = 0 };
pub const NRGBA64 = struct { r: u16 = 0, g: u16 = 0, b: u16 = 0, a: u16 = 0 };
pub const RGBA64 = struct { r: u16 = 0, g: u16 = 0, b: u16 = 0, a: u16 = 0 };
pub const YCbCr = struct { y: u8 = 0, cb: u8 = 0, cr: u8 = 0 };
const CMYK = struct { c: u8 = 0, m: u8 = 0, y: u8 = 0, k: u8 = 0 };

///! Color can convert itself to alpha-premultiplied 16-bits per channel RGBA.
///! The conversion may be lossy.
pub const Color = union(enum) {
    rgb: RGB,
    rgba: RGBA,
    nrgba: NRGBA,
    nrgba64: NRGBA64,
    rgba64: RGBA64,
    ycbcr: YCbCr,
    cmyk: CMYK,
    gray: Gray,
    gray16: Gray16,

    // RGBA returns the alpha-premultiplied red, green, blue and alpha values
    // for the color. Each value ranges within [0, 0xffff], but is represented
    // by a uint32 so that multiplying by a blend factor up to 0xffff will not
    // overflow.
    //
    // An alpha-premultiplied color component c has been scaled by alpha (a),
    // so has valid values 0 <= c <= a.
    pub fn toRGBA(self: Color) struct { u32, u32, u32, u32 } {
        return switch (self) {
            .rgb => |c| .{ c.r, c.g, c.b, 255 },
            .rgba => |c| {
                var r: u32 = @intCast(c.r);
                r |= r << 8;
                var g: u32 = @intCast(c.g);
                g |= g << 8;
                var b: u32 = @intCast(c.b);
                b |= b << 8;
                var a: u32 = @intCast(c.a);
                a |= a << 8;
                return .{ r, g, b, a };
            },
            .rgba64 => |c| {
                const r: u32 = @intCast(c.r);
                const g: u32 = @intCast(c.g);
                const b: u32 = @intCast(c.b);
                const a: u32 = @intCast(c.a);
                return .{ r, g, b, a };
            },
            .nrgba => |c| {
                var r: u32 = @intCast(c.r);
                r |= r << 8;
                r *= @intCast(c.a);
                r /= 0xff;

                var g: u32 = @intCast(c.g);
                g |= g << 8;
                g *= @intCast(c.a);
                g /= 0xff;

                var b: u32 = @intCast(c.b);
                b |= b << 8;
                b *= @intCast(c.a);
                b /= 0xff;

                var a: u32 = @intCast(c.a);
                a |= a << 8;

                return .{ r, g, b, a };
            },
            .nrgba64 => |c| {
                var r: u32 = @intCast(c.r);
                r *= @intCast(c.a);
                r /= 0xffff;

                var g: u32 = @intCast(c.g);
                g *= @intCast(c.a);
                g /= 0xffff;

                var b: u32 = @intCast(c.b);
                b *= @intCast(c.a);
                b /= 0xffff;

                const a: u32 = @intCast(c.a);

                return .{ r, g, b, a };
            },
            .ycbcr => |c| {
                // This code returns values in the range [0, 0xffff] instead of [0, 0xff]. There is a
                // subtle difference between doing this and having YCbCr satisfy the Color
                // interface by first converting to an RGBA. The latter loses some
                // information by going to and from 8 bits per channel.
                const yy1 = @as(i32, c.y) * 0x10101;
                const cb1 = @as(i32, c.cb) - 128;
                const cr1 = @as(i32, c.cr) - 128;

                var r = yy1 + 91881 * cr1;
                r = if ((@as(u32, @bitCast(r)) & 0xff000000) == 0) r >> 8 else ~(@as(i32, r) >> 31) & 0xffff;

                var g = yy1 - 22554 * cb1 - 46802 * cr1;
                g = if ((@as(u32, @bitCast(g)) & 0xff000000) == 0) g >> 8 else ~(@as(i32, g) >> 31) & 0xffff;

                var b = yy1 + 116130 * cb1;
                b = if ((@as(u32, @bitCast(b)) & 0xff000000) == 0) b >> 8 else ~(@as(i32, b) >> 31) & 0xffff;

                return .{
                    @as(u32, @intCast(r)),
                    @as(u32, @intCast(g)),
                    @as(u32, @intCast(b)),
                    0xffff,
                };
            },
            .cmyk => |c| {
                const w = 0xffff - @as(u32, c.k) * 0x101;
                const r = (0xffff - @as(u32, c.c) * 0x101) * w / 0xffff;
                const g = (0xffff - @as(u32, c.m) * 0x101) * w / 0xffff;
                const b = (0xffff - @as(u32, c.y) * 0x101) * w / 0xffff;
                return .{ r, g, b, 0xffff };
            },
            .gray => |c| {
                var y: u32 = @intCast(c.y);
                y |= y << 8;
                return .{ y, y, y, 0xffff };
            },
            .gray16 => |c| {
                const y: u32 = @intCast(c.y);
                return .{ y, y, y, 0xffff };
            },
        };
    }

    pub fn fromRGBA(r: u8, g: u8, b: u8, a: u8) Color {
        return Color{ .rgba = .{ .r = r, .g = g, .b = b, .a = a } };
    }

    pub fn fromRGBA64(r: u16, g: u16, b: u16, a: u16) Color {
        return Color{ .rgba64 = .{ .r = r, .g = g, .b = b, .a = a } };
    }

    pub fn fromCMYK(c: u8, m: u8, y: u8, k: u8) Color {
        return Color{ .cmyk = .{ .c = c, .m = m, .y = y, .k = k } };
    }

    pub fn fromGray(y: u8) Color {
        return Color{ .gray = .{ .y = y } };
    }

    pub fn fromGray16(y: u16) Color {
        return Color{ .gray16 = .{ .y = y } };
    }

    pub fn fromYCbCr(y: u8, cb: u8, cr: u8) Color {
        return Color{ .ycbcr = .{ .y = y, .cb = cb, .cr = cr } };
    }
};

/// Model can convert any [Color] to one from its own color model. The conversion
/// may be lossy.
pub const Model = union(enum) {
    RGB: void,
    YCbCr: void,
    RGBA: void,
    Gray: void,

    pub fn convert(self: Model, c: Color) Color {
        return switch (self) {
            .RGB => c, // No conversion needed for RGB.
            .YCbCr => {
                const yuv = rgbToYCbCr(c.r, c.g, c.b);
                return Color.ycbcr(
                    yuv[0],
                    yuv[1],
                    yuv[2],
                );
            },
            .RGBA => {
                const rgba = c.toRGBA();
                return Color.rgba(
                    rgba[0],
                    rgba[1],
                    rgba[2],
                    rgba[3],
                );
            },
            .Gray => {
                const rgba = c.toRGBA();
                // Apply the grayscale formula (same coefficients as Go)
                const y = @as(u8, @intCast((19595 * rgba[0] + 38470 * rgba[1] + 7471 * rgba[2] + (1 << 15)) >> 24));
                return Color.gray(y);
            },
            .CMYK => {
                const r, const g, const b, _ = c.toRGBA();
                const cc, const mm, const yy, const kk = rgbToCmyk(@as(u8, r >> 8), @as(u8, g >> 8), @as(u8, b >> 8));
                return Color.cmyk(cc, mm, yy, kk);
            },
        };
    }
};

pub const Palette = []Color;
/// rgbToYCbCr converts an RGB triple to a Y'CbCr triple.
pub fn rgbToYCbCr(r: u8, g: u8, b: u8) struct { u8, u8, u8 } {
    // The JFIF specification says:
    //  Y' =  0.2990*R + 0.5870*G + 0.1140*B
    //  Cb = -0.1687*R - 0.3313*G + 0.5000*B + 128
    //  Cr =  0.5000*R - 0.4187*G - 0.0813*B + 128
    // https://www.w3.org/Graphics/JPEG/jfif3.pdf says Y but means Y'.

    const r1: i32 = @intCast(r);
    const g1: i32 = @intCast(g);
    const b1: i32 = @intCast(b);

    // yy is in range [0,0xff].
    //
    // Note that 19595 + 38470 + 7471 equals 65536.
    const yy = (19595 * r1 + 38470 * g1 + 7471 * b1 + 1 << 15) >> 16;

    // The bit twiddling below is equivalent to
    //
    // cb := (-11056*r1 - 21712*g1 + 32768*b1 + 257<<15) >> 16
    // if cb < 0 {
    //     cb = 0
    // } else if cb > 0xff {
    //     cb = ^int32(0)
    // }
    //
    // but uses fewer branches and is faster.
    // Note that the uint8 type conversion in the return
    // statement will convert ^u32(0) to 0xff.
    // The code below to compute cr uses a similar pattern.
    //
    // Note that -11056 - 21712 + 32768 equals 0.
    var cb = -11056 * r1 - 21712 * g1 + 32768 * b1 + 257 << 15;
    if (@as(i64, cb) & 0xff000000 == 0) {
        cb >>= 16;
    } else {
        cb = ~(cb >> 31);
    }

    // Note that 32768 - 27440 - 5328 equals 0.
    var cr = 32768 * r1 - 27440 * g1 - 5328 * b1 + 257 << 15;
    if (@as(i64, cr) & 0xff000000 == 0) {
        cr >>= 16;
    } else {
        cr = ~(cr >> 31);
    }

    return .{ @intCast(yy), @intCast(cb), @intCast(cr) };
}

/// rgbToCmyk
pub fn rgbToCmyk(r: u8, g: u8, b: u8) struct { u8, u8, u8, u8 } {
    const rr: u32 = @intCast(r);
    const gg: u32 = @intCast(g);
    const bb: u32 = @intCast(b);
    var w = rr;

    if (w < gg) {
        w = gg;
    }
    if (w < bb) {
        w = bb;
    }
    if (w == 0) {
        return .{ 0, 0, 0, 0xff };
    }
    const c = (w - rr) * 0xff / w;
    const m = (w - gg) * 0xff / w;
    const y = (w - bb) * 0xff / w;
    const k = 0xff - w;

    return .{ c, m, y, k };
}
