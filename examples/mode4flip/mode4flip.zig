const gba = @import("gba");
const assets = @import("assets");

export var header linksection(".gbaheader") = gba.Header.init("MODE4FLIP", "AMFE", "00", 0);

pub export fn main() void {
    // Initialize graphics mode 4.
    gba.display.ctrl.* = .initMode4(.{});

    // The generated LZ77 streams are safe for direct VRAM decompression.
    gba.bios.lz77UnCompVRAM(@ptrCast(assets.front.pixels_lz77), @ptrCast(@volatileCast(&gba.display.getMode4Surface(0).data[0])));
    gba.bios.lz77UnCompVRAM(@ptrCast(assets.back.pixels_lz77), @ptrCast(@volatileCast(&gba.display.getMode4Surface(1).data[0])));
    gba.display.memcpyBackgroundPalette(0, assets.front.palette[0..]);

    // Enable VBlank interrupts.
    // This will allow running the main loop once per frame.
    gba.display.status.vblank_interrupt = true;
    gba.interrupt.enable.vblank = true;
    gba.interrupt.master.enable = true;

    var i: u32 = 0;
    while (true) {
        // Run this loop at most once per frame.
        gba.bios.vblankIntrWait();

        // Flip every 120 frames, i.e. about every two seconds,
        // but pause this while the start button is held down.
        if (!gba.input.state.isPressed(.start)) {
            i += 1;
            if (i >= 120) {
                gba.display.ctrl.bitmapFlip();
                i = 0;
            }
        }
    }
}
