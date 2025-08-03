const gba = @import("gba");
const bios = gba.bios;
const Color = gba.Color;
const display = gba.display;
const text = gba.text;
const math = gba.math;

export const gameHeader linksection(".gbaheader") = gba.initHeader("SWID", "ASTE", "00", 0);

fn divDemo() void {
    var ix: u16 = 1;
    while (ix < gba.screen_width) : (ix += 1) {
        const y = bios.div(0x0a000000, @intCast(ix)).quotient >> 16;
        if (y <= gba.screen_height) {
            gba.bitmap.Mode3.setPixel(@intCast(ix), @as(u8, @intCast(gba.screen_height - @as(u16, @intCast(y)))), Color.red);
        }
    }
    const red_val: u16 = @as(u16, @bitCast(Color.red));
    text.printf("#{{P:168,132;ci:{d}}}div", .{red_val});
}

fn sqrtDemo() void {
    var ix: u16 = 0;
    while (ix < gba.screen_width) : (ix += 1) {
        const y = bios.sqrt(@intCast(bios.div(320 * ix, 3).quotient));
        gba.bitmap.Mode3.setPixel(@intCast(ix), @as(u8, @intCast(gba.screen_height - @as(u16, @intCast(y)))), Color.lime);
    }
    const lime_val: u16 = @as(u16, @bitCast(Color.lime));
    text.printf("#{{P:160,8;ci:{d}}}sqrt", .{lime_val});
}

fn affDemo() void {
    // 4-byte-aligned source parameters for OBJ affine BIOS call
    var af_src align(4) = bios.ObjAffineSource{
        .scale_x = math.I8_8.fromInt(1),
        .scale_y = math.I8_8.fromInt(80),
        .angle = math.U8_8.fromInt(0),
    };

    // Destination matrix written by the BIOS (pa, pb, pc, pd)
    var af_dest: bios.ObjAffineDest = .{
        .a = math.I8_8.fromInt(1),
        .b = .{},
        .c = .{},
        .d = math.I8_8.fromInt(1),
    };

    for (0..gba.screen_width) |ix| {
        bios.objAffineSet2(&af_src, &af_dest);
        const cc = 80 * af_dest.a.toInt32() >> 8;
        const ss = af_dest.c.toInt32() >> 8;
        gba.bitmap.Mode3.setPixel(@intCast(ix), @as(u8, @intCast(80 - @as(u16, @intCast(cc)))), Color.yellow);
        gba.bitmap.Mode3.setPixel(@intCast(ix), @as(u8, @intCast(80 - @as(u16, @intCast(ss)))), Color.cyan);
        af_src.angle = @bitCast(af_src.angle.raw() + 0x0111);
    }

    const yellow_val: u16 = @as(u16, @bitCast(Color.yellow));
    const cyan_val: u16 = @as(u16, @bitCast(Color.cyan));
    text.printf("#{{P:48,38;ci:{d}}}cos", .{yellow_val});
    text.printf("#{{P:72,20;ci:{d}}}sin", .{cyan_val});
}

const I2_14 = math.FixedPoint(.signed, 2, 14);

fn arctan2Demo() void {
    const ww = gba.screen_width / 2;
    const hh = gba.screen_height / 2;

    // The tonc demo passes raw i16 integers to the BIOS SWI.
    const x_val: i16 = 0x10;

    for (0..gba.screen_width) |ix| {
        const y_val: i16 = @intCast(ix - ww);

        // Call with raw i16 values, not FixedPoint structs
        const y = bios.arctan2(x_val, y_val);

        // The result `y` is a raw i16 fixed-point number.
        // We scale it back to an integer by shifting right (tonc's y/256).
        const y_screen_i: i32 = @as(i32, hh) - (@as(i32, y) >> 8);

        const final_y: u8 = @intCast(y_screen_i);
        gba.bitmap.Mode3.setPixel(@intCast(ix), final_y, Color.magenta);
    }

    const magenta_val: u16 = @as(u16, @bitCast(Color.magenta));
    text.printf("#{{P:144,40;ci:{d}}}atan", .{magenta_val});
}

pub export fn main() void {
    display.ctrl.* = display.Control{
        .bg2 = .enable,
        .mode = .mode3,
    };

    text.initBmpDefault(3);

    divDemo();
    sqrtDemo();
    affDemo();
    // arctan2Demo();

    while (true) {}
}
