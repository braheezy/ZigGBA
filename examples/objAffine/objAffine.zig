const gba = @import("gba");
const input = gba.input;
const display = gba.display;
const obj = gba.obj;
const debug = gba.debug;
const math = gba.math;
const metr = @import("metr.zig");

export var header linksection(".gbaheader") = gba.initHeader("OBJAFFINE", "AODE", "00", 0);

export fn main() void {
    display.ctrl.* = .{
        .obj_mapping = .one_dimension,
        .bg0 = .enable,
        .obj = .enable,
    };

    debug.init();

    gba.mem.memcpy32(obj.tile_ram, &metr.box_tiles, metr.box_tiles.len * 4);
    gba.mem.memcpy32(obj.palette, &metr.pal, metr.pal.len * 4);

    gba.text.initChr4cDefault(0, .{
        .tile_base_block = 2,
        .screen_base_block = 28,
    });

    // Set text margins equivalent to tonc's tte_set_margins(8, 128, 232, 160).
    gba.text.setMargins(8, 128, 232, 160);

    const metroid = obj.allocate();
    metroid.* = .{
        .affine_mode = .affine,
        .transform = .{ .affine_index = 0 },
    };
    metroid.setSize(.@"64x64");
    metroid.setPosition(96, 32);
    metroid.getAffine().setIdentity();

    const shadow_metroid = obj.allocate();
    shadow_metroid.* = .{
        .affine_mode = .affine,
        .transform = .{ .affine_index = 31 },
        .palette = 1,
    };
    shadow_metroid.setSize(.@"64x64");
    shadow_metroid.setPosition(96, 32);
    shadow_metroid.getAffine().setIdentity();

    obj.update(128);

    const fmt = "#{{P:8,136}}P = | {X:0>4}\t{X:0>4} |\n    | {X:0>4}\t{X:0>4} |\nhello";

    while (true) {
        display.naiveVSync();
        _ = input.poll();

        const aff = metroid.getAffine();
        gba.text.printf(fmt, .{
            @as(u16, @bitCast(aff.pa.raw())),
            @as(u16, @bitCast(aff.pb.raw())),
            @as(u16, @bitCast(aff.pc.raw())),
            @as(u16, @bitCast(aff.pd.raw())),
        });
    }
}
