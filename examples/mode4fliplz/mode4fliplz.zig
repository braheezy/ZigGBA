const gba = @import("gba");
const input = gba.input;
const display = gba.display;

export var header linksection(".gbaheader") = gba.Header.init("MODE4FLIPLZ", "AMFE", "00", 0);

const front_image_data = @embedFile("front.lz");
const back_image_data = @embedFile("back.lz");
const palette_data = @embedFile("mode4fliplz.agp");

var front_buffer: [240 * 160]u8 align(4) = undefined;
var back_buffer: [240 * 160]u8 align(4) = undefined;

export fn main() void {
    // Initialize graphics mode 4.
    gba.display.ctrl.* = .initMode4(.{});

    // Decompress to WRAM buffers first
    gba.bios.lz77UnCompWRAM(@ptrCast(@alignCast(front_image_data.ptr)), &front_buffer);
    gba.bios.lz77UnCompWRAM(@ptrCast(@alignCast(back_image_data.ptr)), &back_buffer);

    // Copy to VRAM
    gba.mem.memcpy(gba.display.getMode4Surface(0).data, &front_buffer, front_buffer.len);
    gba.mem.memcpy(gba.display.getMode4Surface(1).data, &back_buffer, back_buffer.len);

    gba.mem.memcpy(gba.display.bg_palette, palette_data, palette_data.len);

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
