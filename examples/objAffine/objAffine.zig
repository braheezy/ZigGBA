const gba = @import("gba");
const interrupt = gba.interrupt;
const bios = gba.bios;
const input = gba.input;
const display = gba.display;
const obj = gba.obj;
const math = gba.math;
const metr = @import("metr.zig");

export var header linksection(".gbaheader") = gba.initHeader("OBJAFFINE", "AODE", "00", 0);

var affine_state: AffineState = .null;
var aff_value: i32 = 0;
// 'speeds' of transformations
const aff_diffs = [_]i32{ 0, 128, 4, 4, 4, 4 };
const aff_keys = [_]?input.Key{ null, .L, .select, .select, .right, .up };

pub export fn main() void {
    // Initialize interrupt system and enable VBlank interrupts
    interrupt.init();
    _ = interrupt.add(.vblank, null);

    display.ctrl.* = .{
        .obj_mapping = .one_dimension,
        .bg0 = .enable,
        .obj = .enable,
    };

    // Use the new, safer API
    obj.hideAllObjects();

    // Manually copy tile and palette data
    // Low OBJ charblock (block 0) starts at 0x06010000 (gba.mem.vram + 0x10000)
    const tile_ram: *volatile [512]display.Tile(.bpp_4) = @ptrFromInt(gba.mem.vram + 0x10000);
    // Palette RAM for objects (256 entries at 0x5000200).
    const pal_ram16: *volatile [256]u16 = @ptrFromInt(gba.mem.palette + 0x200);
    const pal_ram32: *volatile [128]u32 = @ptrFromInt(gba.mem.palette + 0x200);
    // Copy the metroid sprite + bounding box graphics (64 tiles, 4bpp) into OBJ VRAM block 0
    gba.mem.memcpy32(tile_ram, &metr.box_tiles, metr.box_tiles.len * @sizeOf(u32));
    const pal_src32: *const [16]u32 = &metr.pal;
    // Copy 16 u32 words (32 colors) into palette bank 0 and 1
    gba.mem.memcpy32(pal_ram32, pal_src32, metr.pal.len * @sizeOf(u32));
    gba.mem.memcpy32(pal_ram32 + 8, pal_src32, metr.pal.len * @sizeOf(u32));
    // Set transparent color (index 0 and 16) to black
    pal_ram16[0] = 0;
    pal_ram16[16] = 0;

    gba.text.initChr4cDefault(0, .{
        .tile_base_block = 2,
        .screen_base_block = 28,
    });

    gba.text.setMargins(8, 128, 232, 160);

    var x: i9 = 96;
    var y: i8 = 32;

    // Get pointers to the objects in OAM
    const metroid = &obj.objects[0];
    const shadow_metroid = &obj.objects[1];

    // Initialize metroid
    metroid.* = .{
        .mode = .affine,
        .transform = .{ .affine_index = 0 },
        .tile = .{ .index = 0, .block = 0 },
    };
    metroid.setSize(.@"64x64");
    metroid.setPosition(@bitCast(x), @bitCast(y));

    // Initialize shadow metroid
    shadow_metroid.* = .{
        .mode = .affine,
        .transform = .{ .affine_index = 31 },
        .palette = 1,
        .tile = .{ .index = 0, .block = 0 },
    };
    shadow_metroid.setSize(.@"64x64");
    shadow_metroid.setPosition(@bitCast(x), @bitCast(y));

    var oaff_curr = obj.AffineTransform.Identity;
    var oaff_base = obj.AffineTransform.Identity;
    var oaff_new = obj.AffineTransform.Identity;
    oaff_curr.set(0);
    oaff_base.set(1);
    oaff_new.set(2);
    obj.AffineTransform.Identity.set(31);

    const fmt = "#{{es;P:8,136}}P = | {X:0>4}\t{X:0>4} |\n      | {X:0>4}\t{X:0>4} |";
    var new_state: AffineState = .null;

    while (true) {
        _ = input.poll();

        if (input.isKeyPressed(.select) and input.isAnyPressed(input.Combo.dir)) {
            x += 2 * @as(i9, @intCast(input.getAxis(.horizontal).toInt()));
            y += 2 * @as(i8, @intCast(input.getAxis(.vertical).toInt()));
            metroid.setPosition(@bitCast(x), @bitCast(y));
            shadow_metroid.setPosition(@bitCast(x), @bitCast(y));
            new_state = .null;
        } else {
            new_state = getAffineState();
        }

        if (new_state != .null) {
            if (new_state == affine_state) {
                oaff_new = getAffNew();
                oaff_curr = oaff_base.multiply(oaff_new);
            } else {
                oaff_base = oaff_curr;
                oaff_new = obj.AffineTransform.Identity;
                aff_value = 0;
            }
            affine_state = new_state;
        }

        if (input.isKeyJustPressed(.start)) {
            if (input.isKeyPressed(.select)) {
                oaff_curr = obj.AffineTransform.Identity;
                oaff_base = obj.AffineTransform.Identity;
                oaff_new = obj.AffineTransform.Identity;
                aff_value = 0;
            } else {
                if (metroid.mode == .affine) {
                    metroid.mode = .affine_double;
                } else if (metroid.mode == .affine_double) {
                    metroid.mode = .affine;
                }
                if (shadow_metroid.mode == .affine) {
                    shadow_metroid.mode = .affine_double;
                } else if (shadow_metroid.mode == .affine_double) {
                    shadow_metroid.mode = .affine;
                }
                oaff_base = oaff_curr;
            }
        }

        bios.waitVBlank();

        oaff_curr.set(0);

        gba.text.printf(fmt, .{
            @as(u16, @bitCast(oaff_curr.values[0].raw())),
            @as(u16, @bitCast(oaff_curr.values[1].raw())),
            @as(u16, @bitCast(oaff_curr.values[2].raw())),
            @as(u16, @bitCast(oaff_curr.values[3].raw())),
        });
    }
}

const AffineState = enum {
    null,
    rotate,
    scale_x,
    scale_y,
    shear_x,
    shear_y,
};

fn getAffineState() AffineState {
    return if (input.isComboPressed(input.Keys.initMany(&[_]input.Key{ .L, .R })))
        .rotate
    else if (input.isKeyPressed(.A))
        .scale_x
    else if (input.isKeyPressed(.B))
        .scale_y
    else if (input.isComboPressed(input.Keys.initMany(&[_]input.Key{ .left, .right })))
        .shear_x
    else if (input.isComboPressed(input.Keys.initMany(&[_]input.Key{ .up, .down })))
        .shear_y
    else
        .null;
}

fn getAffNew() obj.AffineTransform {
    const diff = aff_diffs[@intFromEnum(affine_state)];
    const maybe_key = aff_keys[@intFromEnum(affine_state)];
    if (maybe_key) |key| {
        aff_value += if (input.isKeyPressed(key)) diff else -diff;
    }

    switch (affine_state) {
        .rotate => {
            return obj.AffineTransform.rotate(aff_value);
        },
        .scale_x => {
            const scale_val = @as(gba.math.I8_8, @bitCast(@as(i16, @intCast((1 << 8) - aff_value))));
            return obj.AffineTransform.scale(scale_val, gba.math.I8_8.fromInt(1));
        },
        .scale_y => {
            const scale_val = @as(gba.math.I8_8, @bitCast(@as(i16, @intCast((1 << 8) - aff_value))));
            return obj.AffineTransform.scale(gba.math.I8_8.fromInt(1), scale_val);
        },
        .shear_x => {
            return obj.AffineTransform.init(gba.math.I8_8.fromInt(1), @as(gba.math.I8_8, @bitCast(@as(i16, @intCast(aff_value)))), .{}, gba.math.I8_8.fromInt(1));
        },
        .shear_y => {
            return obj.AffineTransform.init(gba.math.I8_8.fromInt(1), .{}, @as(gba.math.I8_8, @bitCast(@as(i16, @intCast(aff_value)))), gba.math.I8_8.fromInt(1));
        },
        else => return obj.AffineTransform.Identity,
    }
}
