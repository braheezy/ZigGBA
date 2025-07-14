const gba = @import("gba");
const input = gba.input;
const display = gba.display;
const decompress = gba.decompress;

export var header linksection(".gbaheader") = gba.initHeader("MODE4FLIP", "AMFE", "00", 0);

const front_image_data = @embedFile("front.lz");
const back_image_data = @embedFile("back.lz");
const palette_data = @embedFile("mode4fliplz.agp");

fn loadImageData() void {
    decompress.lz77ToVRAM(front_image_data, display.vram);
    decompress.lz77ToVRAM(back_image_data, display.back_page);
    gba.mem.memcpy32(gba.bg.palette, @as([*]align(2) const u8, @ptrCast(@alignCast(palette_data))), palette_data.len);
}

export fn main() void {
    display.ctrl.* = .{
        .mode = .mode4,
        .bg2 = .enable,
    };

    loadImageData();

    var i: u32 = 0;
    while (true) : (i += 1) {
        _ = input.poll();
        while (input.isKeyPressed(.start)) {
            _ = input.poll();
        }

        display.naiveVSync();

        if (i == 60 * 2) {
            i = 0;
            display.pageFlip();
        }
    }
}
