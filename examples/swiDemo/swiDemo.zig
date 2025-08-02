const gba = @import("gba");
const bios = gba.bios;
const Color = gba.Color;
const display = gba.display;
const text = gba.text;

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
    text.printf("#{{P:168,132;ci:{}}}div", .{red_val});
}

pub export fn main() void {
    display.ctrl.* = display.Control{
        .bg2 = .enable,
        .mode = .mode3,
    };

    text.initBmpDefault(3);

    divDemo();

    while (true) {}
}
