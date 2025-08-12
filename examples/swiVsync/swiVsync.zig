const gba = @import("gba");
const interrupt = gba.interrupt;
const bios = gba.bios;
const display = gba.display;
const obj = gba.obj;
const math = gba.math;
const metr = @import("metr.zig");

export var header linksection(".gbaheader") = gba.initHeader("SWIVSYNC", "ASVE", "00", 0);

pub export fn main() void {
    interrupt.init();
    _ = interrupt.add(.vblank, null);

    display.ctrl.* = .{
        .obj_mapping = .one_dimension,
        .obj = .enable,
    };

    var aff_src = obj.AffineTransform.scale(math.I8_8.fromInt(1), math.I8_8.fromInt(1));
    aff_src.set(0);

    const tile_ram: *volatile [512]display.Tile(.bpp_4) = @ptrFromInt(gba.mem.vram + 0x14000);
    const pal_ram: *volatile [16]gba.Color = @ptrFromInt(gba.mem.palette + 0x200);
    // memcpy32 expects byte count, so multiply by element size
    gba.mem.memcpy32(tile_ram, &metr.tiles, metr.tiles.len * @sizeOf(u32));
    gba.mem.memcpy32(pal_ram, &metr.pal, metr.pal.len * @sizeOf(u32));

    // Get pointers to the objects in OAM
    const metroid = &obj.objects[0];

    // Initialize metroid (double-size affine so it rotates around its center)
    metroid.* = .{
        .mode = .affine_double,
        .transform = .{ .affine_index = 0 },
        .tile = .{ .index = 0, .block = 1 },
    };
    metroid.setSize(.@"64x64");
    metroid.setPosition(120 - 64, 80 - 64);

    var angle: i32 = 0;
    while (true) {
        bios.waitInterrupt(.discard_old_wait_new, interrupt.Flags.initMany(&[_]interrupt.Flag{.vblank}));
        // Rotate by increment (0x0111 per frame) => approx 1/4 rev/s
        angle += 0x0111;
        aff_src = obj.AffineTransform.rotate(angle);
        // Write affine matrix during VBlank, before drawing next frame
        aff_src.set(0);
    }
}
