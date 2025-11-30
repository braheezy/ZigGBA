const gba = @import("gba");
const bios = gba.bios;
const display = gba.display;
const math = gba.math;
const metr = @import("metr.zig");

export var header linksection(".gbaheader") = gba.Header.init(
    "SWIVSYNCDMO1",
    "SVSN",
    "00",
    0,
);

pub export fn main() void {
    gba.interrupt.master.enable = true;
    gba.interrupt.enable.vblank = true;
    gba.display.status.vblank_interrupt = true;

    display.memcpyObjectTiles4Bpp(0, @ptrCast(&metr.tiles));
    display.memcpyObjectPalette(0, @ptrCast(&metr.pal));

    display.hideAllObjects();

    const metroid: display.Object = .initAffine(.{
        .size = .size_64x64,
        // Position is top-left; offset half the size to center the sprite.
        .x = 120 - 32,
        .y = 80 - 32,
        .affine_index = 0,
        .base_tile = 0,
        .palette = 0,
    });
    display.objects[0] = metroid;
    display.setObjectTransform(metroid.transform.affine_index, .identity);

    display.ctrl.* = display.Control{
        .bg0 = true,
        .obj = true,
        .obj_mapping = .map_1d,
    };

    var angle: u16 = 0;
    while (true) {
        bios.vblankIntrWait();
        // Rotate by increment (0x0111 per frame) => approx 1/4 rev/s
        angle +%= 0x0111;
        display.setObjectTransform(
            metroid.transform.affine_index,
            math.Affine2x2.initRotation(.initRaw(angle)),
        );
    }
}
