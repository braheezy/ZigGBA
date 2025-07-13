const gba = @import("gba");

export var header linksection(".gbaheader") = gba.initHeader("TEXT", "ATEX", "00", 0);

export fn main() void {
    gba.display.ctrl.* = .{
        .mode = .mode0,
        .bg0 = .enable,
    };

    gba.text.initSeDefault(0, .{
        .tile_base_block = 0,
        .screen_base_block = 31,
        .palette_mode = .color_16,
    });

    gba.text.write("#{P:72,64}");
    gba.text.write("Hello World!");
}
