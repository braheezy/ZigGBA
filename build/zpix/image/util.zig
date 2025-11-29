const image = @import("root.zig");

// drawYCbCr draws the YCbCr source image on the RGBA destination image with
// rect.min in dst aligned with sp in src. It reports whether the draw was
// successful. If it returns false, no dst pixels were changed.
//
// This function assumes that r is entirely within dst's bounds and the
// translation of r from dst coordinate space to src coordinate space is
// entirely within src's bounds.
pub fn drawYCbCr(
    dst: *image.RGBAImage,
    rect: image.Rectangle,
    src: image.YCbCrImage,
    sp: image.Point,
) !bool {
    const x0 = (rect.min.x - dst.rect.min.x) * 4;
    const x1: usize = @intCast((rect.max.x - dst.rect.min.x) * 4);
    const y0: usize = @intCast(rect.min.y - dst.rect.min.y);
    const y1 = rect.max.y - dst.rect.min.y;

    switch (src.subsample_ratio) {
        .Ratio444 => {
            var y = y0;
            var sy = sp.y;
            while (y != y1) {
                y += 1;
                sy += 1;
                const y_delta: usize = @intCast(sy - src.rect.min.y);
                const x_delta: usize = @intCast(sp.x - src.rect.min.x);

                const dpix = dst.pixels[y * dst.stride ..];
                var yi = y_delta * src.y_stride + x_delta;
                var ci = y_delta * src.c_stride + x_delta;

                var x: usize = @intCast(x0);
                while (x != x1) {
                    x += 4;
                    yi += 1;
                    ci += 1;

                    const yy1: i32 = @as(i32, src.y[yi]) * 0x10101;
                    const cb1: i32 = @as(i32, src.cb[ci]) - 128;
                    const cr1: i32 = @as(i32, src.cr[ci]) - 128;

                    // The bit twiddling below is equivalent to
                    //
                    // r := (yy1 + 91881*cr1) >> 16
                    // if r < 0 {
                    //     r = 0
                    // } else if r > 0xff {
                    //     r = ^int32(0)
                    // }
                    //
                    // but uses fewer branches and is faster.
                    // Note that the uint8 type conversion in the return
                    // statement will convert ^int32(0) to 0xff.
                    // The code below to compute g and b uses a similar pattern.
                    var r = yy1 + 91881 * cr1;
                    if (@as(u32, @bitCast(r)) & 0xff000000 == 0) {
                        r >>= 16;
                    } else {
                        r = ~(@as(i32, r) >> 31);
                    }

                    var g = yy1 - 22554 * cb1 - 46802 * cr1;
                    if (@as(u32, @bitCast(g)) & 0xff000000 == 0) {
                        g >>= 16;
                    } else {
                        g = ~(@as(i32, g) >> 31);
                    }

                    var b = yy1 + 116130 * cb1;
                    if (@as(u32, @bitCast(b)) & 0xff000000 == 0) {
                        b >>= 16;
                    } else {
                        b = ~(@as(i32, b) >> 31);
                    }

                    // Write to RGBA pixel
                    const rgba = dpix[x .. x + 4];
                    rgba[0] = @as(u8, @intCast(r));
                    rgba[1] = @as(u8, @intCast(g));
                    rgba[2] = @as(u8, @intCast(b));
                    rgba[3] = 255;
                }
            }
        },

        .Ratio422 => {
            var y = y0;
            var sy = sp.y;
            while (y != y1) {
                y += 1;
                sy += 1;

                const y_delta: usize = @intCast(sy - src.rect.min.y);
                const x_delta: usize = @intCast(sp.x - src.rect.min.x);
                const x_half: usize = @intCast(@divTrunc(src.rect.min.x, 2));

                const dpix = dst.pixels[y * dst.stride ..];
                var yi = y_delta * src.y_stride + x_delta;
                const ci_base = y_delta * src.c_stride - x_half;

                var x: usize = @intCast(x0);
                var sx = sp.x;
                while (x != x1) {
                    x += 4;
                    sx += 1;
                    yi += 1;
                    const sx_half: usize = @intCast(@divTrunc(sx, 2));
                    const ci = ci_base + sx_half;

                    const yy1: i32 = @as(i32, src.y[yi]) * 0x10101;
                    const cb1: i32 = @as(i32, src.cb[ci]) - 128;
                    const cr1: i32 = @as(i32, src.cr[ci]) - 128;

                    // The bit twiddling below is equivalent to
                    //
                    // r := (yy1 + 91881*cr1) >> 16
                    // if r < 0 {
                    //     r = 0
                    // } else if r > 0xff {
                    //     r = ^int32(0)
                    // }
                    //
                    // but uses fewer branches and is faster.
                    // Note that the uint8 type conversion in the return
                    // statement will convert ^int32(0) to 0xff.
                    // The code below to compute g and b uses a similar pattern.

                    var r = yy1 + 91881 * cr1;
                    if (@as(u32, @bitCast(r)) & 0xff000000 == 0) {
                        r >>= 16;
                    } else {
                        r = ~(@as(i32, r) >> 31);
                    }

                    var g = yy1 - 22554 * cb1 - 46802 * cr1;
                    if (@as(u32, @bitCast(g)) & 0xff000000 == 0) {
                        g >>= 16;
                    } else {
                        g = ~(@as(i32, g) >> 31);
                    }

                    var b = yy1 + 116130 * cb1;
                    if (@as(u32, @bitCast(b)) & 0xff000000 == 0) {
                        b >>= 16;
                    } else {
                        b = ~(@as(i32, b) >> 31);
                    }

                    const rgba = dpix[x .. x + 4];
                    rgba[0] = @as(u8, @intCast(r));
                    rgba[1] = @as(u8, @intCast(g));
                    rgba[2] = @as(u8, @intCast(b));
                    rgba[3] = 255;
                }
            }
        },

        .Ratio420 => {
            var y = y0;
            var sy = sp.y;
            while (y != y1) {
                y += 1;
                sy += 1;

                const y_delta: usize = @intCast(sy - src.rect.min.y);
                const x_delta: usize = @intCast(sp.x - src.rect.min.x);
                const x_half: usize = @intCast(@divTrunc(src.rect.min.x, 2));
                const y_delta_half: usize = @intCast((@divTrunc(sy, 2) - @divTrunc(src.rect.min.y, 2)));

                const dpix = dst.pixels[y * dst.stride ..];
                var yi = y_delta * src.y_stride + x_delta;
                const ci_base = y_delta_half * src.c_stride - x_half;

                var x: usize = @intCast(x0);
                var sx = sp.x;
                while (x != x1) {
                    x += 4;
                    sx += 1;
                    yi += 1;
                    const sx_half: usize = @intCast(@divTrunc(sx, 2));
                    const ci = ci_base + sx_half;

                    const yy1: i32 = @as(i32, src.y[yi]) * 0x10101;
                    const cb1: i32 = @as(i32, src.cb[ci]) - 128;
                    const cr1: i32 = @as(i32, src.cr[ci]) - 128;
                    // The bit twiddling below is equivalent to
                    //
                    // r := (yy1 + 91881*cr1) >> 16
                    // if r < 0 {
                    //     r = 0
                    // } else if r > 0xff {
                    //     r = ^int32(0)
                    // }
                    //
                    // but uses fewer branches and is faster.
                    // Note that the uint8 type conversion in the return
                    // statement will convert ^int32(0) to 0xff.
                    // The code below to compute g and b uses a similar pattern.

                    var r = yy1 + 91881 * cr1;
                    r = if ((@as(u32, @bitCast(r)) & 0xff000000) == 0) r >> 16 else ~(@as(i32, r) >> 31);
                    var g = yy1 - 22554 * cb1 - 46802 * cr1;
                    g = if ((@as(u32, @bitCast(g)) & 0xff000000) == 0) g >> 16 else ~(@as(i32, g) >> 31);
                    var b = yy1 + 116130 * cb1;
                    b = if ((@as(u32, @bitCast(b)) & 0xff000000) == 0) b >> 16 else ~(@as(i32, b) >> 31);

                    const rgba = dpix[x .. x + 4];
                    rgba[0] = @as(u8, @intCast(r));
                    rgba[1] = @as(u8, @intCast(g));
                    rgba[2] = @as(u8, @intCast(b));
                    rgba[3] = 255;
                }
            }
        },

        .Ratio440 => {
            var y = y0;
            var sy = sp.y;
            while (y != y1) {
                y += 1;
                sy += 1;

                const y_delta: usize = @intCast(sy - src.rect.min.y);
                const x_delta: usize = @intCast(sp.x - src.rect.min.x);
                const y_delta_half: usize = @intCast((@divTrunc(sy, 2) - @divTrunc(src.rect.min.y, 2)));

                const dpix = dst.pixels[y * dst.stride ..];
                var yi = y_delta * src.y_stride + x_delta;
                const ci = y_delta_half * src.c_stride + x_delta;

                var x: usize = @intCast(x0);
                var sx = sp.x;
                while (x != x1) {
                    x += 4;
                    sx += 1;
                    yi += 1;

                    const yy1: i32 = @as(i32, src.y[yi]) * 0x10101;
                    const cb1: i32 = @as(i32, src.cb[ci]) - 128;
                    const cr1: i32 = @as(i32, src.cr[ci]) - 128;

                    // The bit twiddling below is equivalent to
                    //
                    // r := (yy1 + 91881*cr1) >> 16
                    // if r < 0 {
                    //     r = 0
                    // } else if r > 0xff {
                    //     r = ^int32(0)
                    // }
                    //
                    // but uses fewer branches and is faster.
                    // Note that the uint8 type conversion in the return
                    // statement will convert ^int32(0) to 0xff.
                    // The code below to compute g and b uses a similar pattern.

                    var r = yy1 + 91881 * cr1;
                    if (@as(u32, @bitCast(r)) & 0xff000000 == 0) {
                        r >>= 16;
                    } else {
                        r = ~(@as(i32, r) >> 31);
                    }

                    var g = yy1 - 22554 * cb1 - 46802 * cr1;
                    if (@as(u32, @bitCast(g)) & 0xff000000 == 0) {
                        g >>= 16;
                    } else {
                        g = ~(@as(i32, g) >> 31);
                    }

                    var b = yy1 + 116130 * cb1;
                    if (@as(u32, @bitCast(b)) & 0xff000000 == 0) {
                        b >>= 16;
                    } else {
                        b = ~(@as(i32, b) >> 31);
                    }

                    const rgba = dpix[x .. x + 4];
                    rgba[0] = @as(u8, @intCast(r));
                    rgba[1] = @as(u8, @intCast(g));
                    rgba[2] = @as(u8, @intCast(b));
                    rgba[3] = 255;
                }
            }
        },
        else => return false,
    }
    return true;
}
