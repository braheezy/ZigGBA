const gba = @import("gba");
const bios = gba.bios;
const ColorRgb555 = gba.ColorRgb555;
const display = gba.display;
const math = gba.math;

const std = @import("std");

export const gameHeader linksection(".gbaheader") = gba.Header.init(
    "SWID",
    "ASTE",
    "00",
    0,
);

fn divDemo(mode3: gba.display.Mode3Surface) void {
    var ix: i32 = 1;
    while (ix < gba.display.screen_width) : (ix += 1) {
        const y = bios.div(0x0a000000, ix).quotient >> 16;
        if (y <= gba.display.screen_height) {
            mode3.setPixel(@intCast(ix), @as(u8, @intCast(gba.display.screen_height - y)), ColorRgb555.red);
        }
    }
    mode3.draw().text("div", .init(ColorRgb555.red), .{
        .x = 168,
        .y = 132,
    });
}

fn sqrtDemo(mode3: gba.display.Mode3Surface) void {
    var ix: i32 = 0;
    while (ix < gba.display.screen_width) : (ix += 1) {
        const y = bios.sqrt(@intCast(bios.div(320 * ix, 3).quotient));
        mode3.setPixel(@intCast(ix), @as(u8, @intCast(gba.display.screen_height - y)), ColorRgb555.green);
    }

    mode3.draw().text("sqrt", .init(ColorRgb555.green), .{
        .x = 160,
        .y = 8,
    });
}

fn affDemo(mode3: gba.display.Mode3Surface) void {
    // Source parameters for OBJ affine BIOS call (4-byte aligned)
    var af_src align(4) = [_]bios.ObjAffineSetOptions{.{
        .scale = .init(math.FixedI16R8.one, math.FixedI16R8.fromInt(80)),
        .angle = math.FixedU16R16.zero,
    }};

    // Destination matrix written by the BIOS (a, b, c, d)
    var af_dest: math.Affine2x2 = .identity;

    for (0..gba.display.screen_width) |ix| {
        // Call BIOS ObjAffineSet - pass array as slice
        bios.objAffineSetStruct(&af_src, @ptrCast(&af_dest));

        const cc = 80 * af_dest.a.to(i32) >> 8;
        const ss = af_dest.c.to(i32) >> 8;
        mode3.setPixel(@intCast(ix), @as(u8, @intCast(80 - @as(i16, @intCast(cc)))), ColorRgb555.yellow);
        mode3.setPixel(@intCast(ix), @as(u8, @intCast(80 - @as(i16, @intCast(ss)))), ColorRgb555.cyan);

        af_src[0].angle.value +%= 0x0111;
    }

    mode3.draw().text("cos", .init(ColorRgb555.yellow), .{
        .x = 48,
        .y = 38,
    });
    mode3.draw().text("sin", .init(ColorRgb555.cyan), .{
        .x = 72,
        .y = 20,
    });
}

const I2_14 = math.FixedPoint(.signed, 2, 14);

fn arctan2Demo(mode3: gba.display.Mode3Surface) void {
    const ww = gba.display.screen_width / 2;
    const hh = gba.display.screen_height / 2;

    // y = 80 + tan((x-120)/16) * (64)*2/pi
    // ArcTan2 lies in < -0x4000, 0x4000 >
    const x_val: i16 = 0x10;

    for (0..gba.display.screen_width) |ix| {
        // raw Q2.14 fixed-point; >>8 yields tonc's y/256 integer offset
        const y_off: i16 = bios.arctan2(x_val, @intCast(ix - ww));
        const y_pos: u8 = @intCast(hh - (y_off >> 8));
        mode3.setPixel(@intCast(ix), y_pos, ColorRgb555.magenta);
    }

    mode3.draw().text("atan", .init(ColorRgb555.magenta), .{
        .x = 144,
        .y = 40,
    });
}

pub export fn main() void {
    gba.display.ctrl.* = .initMode3(.{});

    const mode3 = gba.display.getMode3Surface();

    divDemo(mode3);
    sqrtDemo(mode3);
    affDemo(mode3);
    // arctan2Demo(mode3);

    while (true) {}
}
