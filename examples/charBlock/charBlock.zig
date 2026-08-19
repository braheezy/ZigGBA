const gba = @import("gba");
const assets = @import("assets");

export var header linksection(".gbaheader") = gba.Header.init("CHARBLOCK", "ACBE", "00", 0);

const charblock_4bpp_index: u2 = 0;
const screenblock_4bpp_index: u5 = 2;

pub export fn main() void {
    const bg0_map = gba.display.BackgroundMap.setup(0, .{
        .base_charblock = charblock_4bpp_index,
        .base_screenblock = screenblock_4bpp_index,
        .size = assets.ids.background_size,
    });

    gba.display.memcpyBackgroundPalette(0, assets.ids.palette[0..]);
    gba.bios.lz77UnCompVRAM(@ptrCast(assets.ids.tiles_lz77), @ptrCast(@volatileCast(&gba.mem.vram[0])));
    gba.bios.lz77UnCompVRAM(@ptrCast(assets.ids.map_lz77), @ptrCast(@volatileCast(bg0_map.getBaseScreenblock())));

    gba.display.ctrl.* = .initMode0(.{ .bg0 = true });
    while (true) gba.display.naiveVSync();
}
